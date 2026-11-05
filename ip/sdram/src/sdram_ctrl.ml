(* Controller for the Colorlight i9 v7.2 SDRAM (EM638325-6H: 4 banks x
   2048 rows x 256 columns x 32 bits = 8 MiB; issue #7, Linux L5).

   The board ties CS# low, CKE high and DQM low: there are no byte masks,
   so a write with a partial mask is a read-modify-write of the word (READ
   without auto-precharge, merge, WRITE with auto-precharge in the same
   open row). Burst length 1; every access opens its row (ACTIVE) and closes
   it with auto-precharge; refresh has priority between accesses.

   Host side: the rv32 core's bus protocol (#26). A request is accepted
   ([ready]) only in Idle; read data comes with [rvalid] when the access
   is done. Addresses are byte addresses inside the 8 MiB; word address
   bits 9..2 are the column, 11..10 the bank, 22..12 the row.

   Pins: [cmd] is RAS#, CAS#, WE# (registered, like [a], [ba], [dq_out],
   [dq_oe]); [dq_in] is the data bus as seen by the controller.
   [read_latency] is the number of cycles from the cycle in which READ is
   on the pins to the cycle in which the controller samples [dq_in]: CAS
   latency plus the board's round trip, a board-level parameter (L10).

   Initialisation (JEDEC): [init_cycles] of NOP (200 us), PRECHARGE ALL,
   8 AUTO REFRESH, MODE REGISTER SET (burst length 1, CAS latency), then
   Idle. *)
open! Base
open! Hardcaml
open Signal

module Config = struct
  type t =
    { cas_latency : int
    ; read_latency : int
    ; trcd : int (* ACTIVE to READ/WRITE, cycles *)
    ; trp : int (* PRECHARGE to ACTIVE *)
    ; twr_trp : int (* WRITE with auto-precharge to the next command *)
    ; trc : int (* ACTIVE/REFRESH to the next ACTIVE/REFRESH *)
    ; tmrd : int
    ; refresh_interval : int (* cycles between AUTO REFRESH commands *)
    ; init_cycles : int
    }
  [@@deriving sexp_of]

  (* EM638325-6H at [clock_mhz], with [read_latency] from the board. *)
  let create ?(cas_latency = 2) ?read_latency ?init_cycles ~clock_mhz () =
    let cycles ns = Int.max 1 ((ns * clock_mhz + 999) / 1000) in
    { cas_latency
    ; read_latency = Option.value read_latency ~default:(cas_latency + 1)
    ; trcd = cycles 18
    ; trp = cycles 18
    ; twr_trp = cycles 12 + cycles 18 + 1
    ; trc = cycles 60
    ; tmrd = 2
    ; (* 4096 refreshes per 64 ms: one per 15.6 us, with margin *)
      refresh_interval = 15 * clock_mhz - 20
    ; init_cycles = Option.value init_cycles ~default:(200 * clock_mhz)
    }
  ;;
end

module Cmd = struct
  (* RAS#, CAS#, WE# *)
  let nop = 0b111
  let active = 0b011
  let read = 0b101
  let write = 0b100
  let precharge = 0b010
  let refresh = 0b001
  let mode = 0b000
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; read : 'a
    ; write : 'a
    ; addr : 'a [@bits 23]
    ; wdata : 'a [@bits 32]
    ; wmask : 'a [@bits 4]
    ; dq_in : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready : 'a
    ; rvalid : 'a
    ; rdata : 'a [@bits 32]
    ; cmd : 'a [@bits 3]
    ; a : 'a [@bits 11]
    ; ba : 'a [@bits 2]
    ; dq_out : 'a [@bits 32]
    ; dq_oe : 'a
    ; init_done : 'a
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Init_wait
    | Init_precharge
    | Init_refresh
    | Init_mode
    | Idle
    | Activate
    | Read_wait
    | Respond
    | Wait
  [@@deriving sexp_of, compare ~localize, enumerate]
end

let create (c : Config.t) scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = Always.State_machine.create (module State) spec in
  ignore (sm.current -- "state" : Signal.t);
  let reg name w =
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let count_bits =
    Int.ceil_log2 (Int.max c.init_cycles c.refresh_interval + 2)
  in
  let count = reg "count" count_bits in
  let refreshes = reg "refreshes" 4 in
  let since_refresh = reg "since_refresh" count_bits in
  (* Registered pins; NOP and the bus released unless set this cycle. *)
  (* NOP from reset: the reset value 0 would be MODE REGISTER SET *)
  let cmd =
    let (v : Always.Variable.t) =
      Always.Variable.reg
        ~width:3
        (Reg_spec.override spec ~clear_to:(of_int ~width:3 Cmd.nop))
    in
    ignore (v.value -- "cmd" : Signal.t);
    v
  in
  let a = reg "a" 11 in
  let ba = reg "ba" 2 in
  let dq_out = reg "dq_out" 32 in
  let dq_oe = reg "dq_oe" 1 in
  (* The accepted request. *)
  let op_write = reg "op_write" 1 in
  let op_addr = reg "op_addr" 23 in
  let op_wdata = reg "op_wdata" 32 in
  let op_wmask = reg "op_wmask" 4 in
  let rdata = reg "rdata" 32 in
  let init_done = reg "init_done" 1 in
  let refresh_due = (since_refresh.value >=:. c.refresh_interval) -- "refresh_due" in
  let ready = (sm.is Idle &: ~:refresh_due) -- "ready_w" in
  let row x = x.:[22, 12]
  and bank x = x.:[11, 10]
  and col x = x.:[9, 2] in
  let set_cmd ?(addr = zero 11) ?(bank_ = zero 2) code =
    Always.[ cmd <--. code; a <-- addr; ba <-- bank_ ]
  in
  let wait n next = Always.[ count <--. n - 1; sm.set_next next ] in
  (* Column address with A10 = auto-precharge. *)
  let col_addr ~ap x = ap @: zero 2 @: col x in
  let merged =
    concat_msb
      (List.rev
         (List.init 4 ~f:(fun k ->
            let byte s = s.:[(8 * k) + 7, 8 * k] in
            mux2 op_wmask.value.:(k) (byte op_wdata.value) (byte i.dq_in))))
    -- "merged"
  in
  Always.(
    compile
      [ cmd <--. Cmd.nop
      ; dq_oe <-- gnd
      ; since_refresh <-- since_refresh.value +:. 1
      ; sm.switch
          [ ( Init_wait
            , [ count <-- count.value +:. 1
              ; when_
                  (count.value ==:. c.init_cycles)
                  (set_cmd ~addr:(of_int ~width:11 0x400) Cmd.precharge
                   @ wait c.trp Init_precharge)
              ] )
          ; ( Init_precharge
            , [ count <-- count.value -:. 1
              ; when_
                  (count.value ==:. 0)
                  (set_cmd Cmd.refresh
                   @ [ refreshes <--. 1 ]
                   @ wait c.trc Init_refresh)
              ] )
          ; ( Init_refresh
            , [ count <-- count.value -:. 1
              ; when_
                  (count.value ==:. 0)
                  [ if_
                      (refreshes.value ==:. 8)
                      (set_cmd
                         ~addr:(of_int ~width:11 (c.cas_latency lsl 4))
                         Cmd.mode
                       @ wait c.tmrd Init_mode)
                      (set_cmd Cmd.refresh
                       @ [ refreshes <-- refreshes.value +:. 1 ]
                       @ wait c.trc Init_refresh)
                  ]
              ] )
          ; ( Init_mode
            , [ count <-- count.value -:. 1
              ; when_
                  (count.value ==:. 0)
                  [ init_done <-- vdd; since_refresh <--. 0; sm.set_next Idle ]
              ] )
          ; ( Idle
            , [ if_
                  refresh_due
                  (set_cmd Cmd.refresh @ [ since_refresh <--. 0 ] @ wait c.trc Wait)
                  [ when_
                      (i.read |: i.write)
                      (set_cmd ~addr:(row i.addr) ~bank_:(bank i.addr) Cmd.active
                       @ [ op_write <-- i.write
                         ; op_addr <-- i.addr
                         ; op_wdata <-- i.wdata
                         ; op_wmask <-- i.wmask
                         ]
                       @ wait c.trcd Activate)
                  ]
              ] )
          ; ( Activate
            , [ count <-- count.value -:. 1
              ; when_
                  (count.value ==:. 0)
                  [ if_
                      (op_write.value &: (op_wmask.value ==:. 0xf))
                      (set_cmd
                         ~addr:(col_addr ~ap:vdd op_addr.value)
                         ~bank_:(bank op_addr.value)
                         Cmd.write
                       @ [ dq_oe <-- vdd; dq_out <-- op_wdata.value ]
                       @ wait (Int.max c.twr_trp c.trc) Wait)
                      (* a read, or the read of a read-modify-write: the row
                         stays open for the write *)
                      (set_cmd
                         ~addr:(col_addr ~ap:~:(op_write.value) op_addr.value)
                         ~bank_:(bank op_addr.value)
                         Cmd.read
                       @ [ count <--. c.read_latency; sm.set_next Read_wait ])
                  ]
              ] )
          ; ( Read_wait
            , [ count <-- count.value -:. 1
              ; when_
                  (count.value ==:. 0)
                  [ rdata <-- i.dq_in
                  ; if_
                      op_write.value
                      (set_cmd
                         ~addr:(col_addr ~ap:vdd op_addr.value)
                         ~bank_:(bank op_addr.value)
                         Cmd.write
                       @ [ dq_oe <-- vdd; dq_out <-- merged ]
                       @ wait c.twr_trp Wait)
                      [ sm.set_next Respond ]
                  ]
              ] )
          ; Respond, [ sm.set_next Idle ]
          ; ( Wait
            , [ count <-- count.value -:. 1; when_ (count.value ==:. 0) [ sm.set_next Idle ] ] )
          ]
      ]);
  { O.ready
  ; rvalid = sm.is Respond
  ; rdata = rdata.value
  ; cmd = cmd.value
  ; a = a.value
  ; ba = ba.value
  ; dq_out = dq_out.value
  ; dq_oe = dq_oe.value
  ; init_done = init_done.value
  }
;;

let hierarchical c scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"sdram_ctrl" (create c)
;;
