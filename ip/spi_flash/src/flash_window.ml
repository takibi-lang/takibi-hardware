(* Read-only memory window onto the W25Q64JV SPI flash of the Colorlight
   i9 (issue #27, Linux L6): single-bit SPI, READ (03h) with a 24-bit
   address, SCK = clock / 2 (25 MHz at 50 MHz; READ allows 50 MHz).

   Host side: the core's bus protocol (#26); a word read returns the four
   flash bytes at the address, little-endian. Writes are accepted and
   ignored. Sequential reads stream: after a word, CS# stays low and the
   next read of the following word only clocks 32 more bits (64 cycles
   instead of 130); any other address ends the transfer.

   SPI mode 0 at CS# fall; each bit is two cycles, SCK low then high.
   MOSI changes while SCK is low, the flash samples it on the rising edge;
   the flash shifts a data bit out on the falling edge and the controller
   samples [miso] at the end of the low cycle (half a period of setup).
   Between streamed words SCK rests high. *)
open! Base
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; read : 'a
    ; write : 'a
    ; addr : 'a [@bits 23]
    ; miso : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready : 'a
    ; rvalid : 'a
    ; rdata : 'a [@bits 32]
    ; sck : 'a
    ; mosi : 'a
    ; cs_n : 'a
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Idle
    | Deselect
    | Command
    | Data
    | Respond
  [@@deriving sexp_of, compare ~localize, enumerate]
end

let create scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = Always.State_machine.create (module State) spec in
  ignore (sm.current -- "state" : Signal.t);
  let reg ?clear_to name w =
    let spec =
      match clear_to with
      | None -> spec
      | Some v -> Reg_spec.override spec ~clear_to:(of_int ~width:w v)
    in
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let cs_n = reg ~clear_to:1 "cs_n" 1 in
  let sck = reg "sck" 1 in
  let shift_out = reg "shift_out" 32 in
  let shift_in = reg "shift_in" 32 in
  let bits = reg "bits" 6 in
  let streaming = reg "streaming" 1 in
  let next_addr = reg "next_addr" 23 in
  let rdata = reg "rdata" 32 in
  (* the word holding the addressed byte (the core extracts its lane) *)
  let word_addr = (i.addr.:[22, 2] @: zero 2) -- "word_addr" in
  let continue = (streaming.value &: (word_addr ==: next_addr.value)) -- "continue" in
  let bswap x = concat_lsb [ x.:[31, 24]; x.:[23, 16]; x.:[15, 8]; x.:[7, 0] ] in
  let start_command =
    Always.
      [ cs_n <-- gnd
      ; sck <-- gnd
      ; shift_out <-- of_int ~width:8 0x03 @: (gnd @: word_addr)
      ; bits <--. 32
      ; next_addr <-- word_addr
      ; sm.set_next Command
      ]
  in
  Always.(
    compile
      [ sm.switch
          [ ( Idle
            , [ when_
                  i.read
                  [ if_
                      continue
                      [ bits <--. 32; sck <-- vdd; sm.set_next Data ]
                      [ if_
                          streaming.value
                          [ cs_n <-- vdd; sck <-- gnd; streaming <-- gnd; sm.set_next Deselect ]
                          start_command
                      ]
                  ]
              ] )
          ; (* CS# high for one cycle (tSHSL: 10 ns) *)
            Deselect, [ when_ i.read start_command ]
          ; ( Command
            , [ (* low cycle: MOSI = the next bit; high cycle: rising edge *)
                if_
                  (sck.value ==:. 0)
                  [ sck <-- vdd ]
                  [ shift_out <-- sll shift_out.value 1
                  ; bits <-- bits.value -:. 1
                  ; sck <-- gnd
                  ; when_ (bits.value ==:. 1) [ bits <--. 32; sm.set_next Data ]
                  ]
              ] )
          ; ( Data
            , [ if_
                  (sck.value ==:. 0)
                  [ (* the bit shifted out on the falling edge *)
                    shift_in <-- shift_in.value.:[30, 0] @: i.miso
                  ; sck <-- vdd
                  ; bits <-- bits.value -:. 1
                  ; when_
                      (bits.value ==:. 1)
                      [ rdata <-- bswap (shift_in.value.:[30, 0] @: i.miso)
                      ; streaming <-- vdd
                      ; next_addr <-- next_addr.value +:. 4
                      ; sm.set_next Respond
                      ]
                  ]
                  [ sck <-- gnd ]
              ] )
          ; Respond, [ sm.set_next Idle ]
          ]
      ]);
  (* Reads are accepted in Idle (the transfer starts there); writes are
     accepted at once and ignored. *)
  { O.ready = (sm.is Idle &: ~:(i.read &: streaming.value &: ~:continue)) |: sm.is Deselect |: i.write
  ; rvalid = sm.is Respond
  ; rdata = rdata.value
  ; sck = sck.value
  ; mosi = shift_out.value.:(31)
  ; cs_n = cs_n.value
  }
;;

let hierarchical scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"flash_window" create
;;
