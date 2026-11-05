(* The SoC's memory cache (issue #7, Linux L8): one cache for instructions
   and data in front of the SDRAM, physically addressed, write-through
   with a one-entry write buffer and no allocation on a write miss.

   Being unified and physical, it needs nothing for FENCE.I (the core's
   instruction fetches and stores see the same lines) or SFENCE.VMA (the
   core's TLBs hold translations, the cache holds physical memory).

   [size] bytes (default 32 KiB), direct-mapped, 32-byte lines (one SDRAM
   line read, Sdram_ctrl's burst). Data in four byte-lane block RAMs, tags
   with a valid bit in one more; after reset every tag is invalidated, one
   line per cycle, before the first request is accepted.

   Host side: the core's bus protocol (#26). A read is accepted in Idle,
   the tag is checked a cycle later (block RAM latency); a hit answers in
   that cycle, a miss waits for the write buffer to drain, reads the line
   and answers with the requested word. A write is accepted in Idle when
   the write buffer is free: a hit updates the line (byte lanes), and the
   write goes to the SDRAM through the buffer. *)
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
    ; wdata : 'a [@bits 32]
    ; wmask : 'a [@bits 4]
    ; (* the SDRAM controller *)
      mem_ready : 'a
    ; mem_word_valid : 'a
    ; mem_word_index : 'a [@bits 3]
    ; mem_rdata : 'a [@bits 32]
    ; mem_rvalid : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready : 'a
    ; rvalid : 'a
    ; rdata : 'a [@bits 32]
    ; mem_read : 'a
    ; mem_write : 'a
    ; mem_burst : 'a
    ; mem_addr : 'a [@bits 23]
    ; mem_wdata : 'a [@bits 32]
    ; mem_wmask : 'a [@bits 4]
    ; hits : 'a [@bits 32] (* counters, for benches *)
    ; misses : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Invalidate
    | Idle
    | Lookup
    | Fill
    | Respond
  [@@deriving sexp_of, compare ~localize, enumerate]
end

let create ?(size = 32 * 1024) scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = Always.State_machine.create (module State) spec in
  ignore (sm.current -- "state" : Signal.t);
  let reg name w =
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let lines = size / 32 in
  let index_bits = Int.ceil_log2 lines in
  let tag_bits = 23 - 5 - index_bits in
  let index a = a.:[5 + index_bits - 1, 5] in
  let tag a = a.:[22, 5 + index_bits] in
  let word_addr a = a.:[5 + index_bits - 1, 2] in
  (* the accepted request *)
  let op_write = reg "op_write" 1 in
  let op_addr = reg "op_addr" 23 in
  let op_wdata = reg "op_wdata" 32 in
  let op_wmask = reg "op_wmask" 4 in
  let inv_index = reg "invalidate_index" index_bits in
  let rdata = reg "rdata" 32 in
  (* write buffer *)
  let wb_valid = reg "wbuf_valid" 1 in
  let wb_addr = reg "wbuf_addr" 23 in
  let wb_data = reg "wbuf_data" 32 in
  let wb_mask = reg "wbuf_mask" 4 in
  let fill_issued = reg "fill_issued" 1 in
  let hits = reg "hits" 32 in
  let misses = reg "misses" 32 in
  (* RAM ports driven from the state machine *)
  let tag_we = Always.Variable.wire ~default:gnd in
  let tag_waddr = Always.Variable.wire ~default:(zero index_bits) in
  let tag_wdata = Always.Variable.wire ~default:(zero (tag_bits + 1)) in
  let data_we = Always.Variable.wire ~default:(zero 4) in
  let data_waddr = Always.Variable.wire ~default:(zero (index_bits + 3)) in
  let data_wdata = Always.Variable.wire ~default:(zero 32) in
  (* Reads are addressed by the incoming request in Idle (so the data and
     tag are there in Lookup) and by the accepted one otherwise. *)
  let raddr_word = mux2 (sm.is Idle) (word_addr i.addr) (word_addr op_addr.value) in
  let ram ~name ~size ~we ~waddr ~wdata ~raddr =
    (Ram.create
       ~name
       ~attributes:[ Rtl_attribute.create "no_rw_check" ]
       ~collision_mode:Read_before_write
       ~size
       ~write_ports:
         [| { write_clock = i.clock; write_address = waddr; write_enable = we; write_data = wdata }
         |]
       ~read_ports:[| { read_clock = i.clock; read_address = raddr; read_enable = vdd } |]
       ()).(0)
    -- (name ^ "_q")
  in
  let tag_q =
    ram
      ~name:"cache_tags"
      ~size:lines
      ~we:tag_we.value
      ~waddr:tag_waddr.value
      ~wdata:tag_wdata.value
      ~raddr:(raddr_word.:[index_bits + 2, 3])
  in
  let data_q =
    List.init 4 ~f:(fun k ->
      ram
        ~name:(Printf.sprintf "cache_data_b%d" k)
        ~size:(lines * 8)
        ~we:data_we.value.:(k)
        ~waddr:data_waddr.value
        ~wdata:data_wdata.value.:[(8 * k) + 7, 8 * k]
        ~raddr:raddr_word)
    |> concat_lsb
  in
  let hit = (tag_q.:(tag_bits) &: (tag_q.:[tag_bits - 1, 0] ==: tag op_addr.value)) -- "hit" in
  (* the write buffer drains whenever it holds a write; a line fill is
     requested only once it is empty (reads after writes) *)
  let wb_drain = wb_valid.value in
  let fill_read = sm.is Fill &: ~:(fill_issued.value) in
  let accept_read = sm.is Idle &: i.read in
  let accept_write = sm.is Idle &: i.write &: ~:(wb_valid.value) in
  Always.(
    compile
      [ when_ (wb_drain &: i.mem_ready) [ wb_valid <-- gnd ]
      ; sm.switch
          [ ( Invalidate
            , [ tag_we <-- vdd
              ; tag_waddr <-- inv_index.value
              ; inv_index <-- inv_index.value +:. 1
              ; when_ (inv_index.value ==:. lines - 1) [ sm.set_next Idle ]
              ] )
          ; ( Idle
            , [ when_
                  (accept_read |: accept_write)
                  [ op_write <-- i.write
                  ; op_addr <-- i.addr
                  ; op_wdata <-- i.wdata
                  ; op_wmask <-- i.wmask
                  ; sm.set_next Lookup
                  ]
              ] )
          ; ( Lookup
            , [ if_
                  op_write.value
                  [ (* update the line on a hit; the SDRAM gets it from the
                       write buffer either way *)
                    when_
                      hit
                      [ data_we <-- op_wmask.value
                      ; data_waddr <-- word_addr op_addr.value
                      ; data_wdata <-- op_wdata.value
                      ]
                  ; wb_valid <-- vdd
                  ; wb_addr <-- op_addr.value
                  ; wb_data <-- op_wdata.value
                  ; wb_mask <-- op_wmask.value
                  ; sm.set_next Idle
                  ]
                  [ if_
                      hit
                      [ rdata <-- data_q; hits <-- hits.value +:. 1; sm.set_next Respond ]
                      [ misses <-- misses.value +:. 1; fill_issued <-- gnd; sm.set_next Fill ]
                  ]
              ] )
          ; ( Fill
            , [ when_ (fill_read &: ~:(wb_valid.value) &: i.mem_ready) [ fill_issued <-- vdd ]
              ; when_
                  i.mem_word_valid
                  [ data_we <--. 0xf
                  ; data_waddr <-- index op_addr.value @: i.mem_word_index
                  ; data_wdata <-- i.mem_rdata
                  ; when_ (i.mem_word_index ==: op_addr.value.:[4, 2]) [ rdata <-- i.mem_rdata ]
                  ]
              ; when_
                  i.mem_rvalid
                  [ tag_we <-- vdd
                  ; tag_waddr <-- index op_addr.value
                  ; tag_wdata <-- vdd @: tag op_addr.value
                  ; sm.set_next Respond
                  ]
              ] )
          ; Respond, [ sm.set_next Idle ]
          ]
      ]);
  let fill_req = fill_read &: ~:(wb_valid.value) in
  { O.ready = accept_read |: accept_write
  ; rvalid = sm.is Respond
  ; rdata = rdata.value
  ; mem_read = fill_req
  ; mem_write = ~:fill_req &: wb_drain
  ; mem_burst = fill_req
  ; mem_addr = mux2 fill_req op_addr.value wb_addr.value
  ; mem_wdata = wb_data.value
  ; mem_wmask = wb_mask.value
  ; hits = hits.value
  ; misses = misses.value
  }
;;

let hierarchical ?size scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"cache" (create ?size)
;;
