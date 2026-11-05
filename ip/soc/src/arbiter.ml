(* The SoC's bus arbiter for two cores (issue #9), separate so that it can
   be proved on its own (formal/arbiter.sby).

   Inputs per core: its bus bridge's request (valid, write, the write is an
   SC, the read is an AMO's), and whether the core decides an SC in this
   cycle; from the bus: the selected target accepts ([ready]) and read
   data returns ([rvalid]).

   Rules:
   - one transaction at a time: nothing is granted while a read is
     outstanding (from its grant to its rvalid);
   - after an AMO's read is granted, only that core's next request (the
     AMO's write) is, so the read-modify-write is atomic;
   - an SC's write goes before any other write; otherwise round robin;
   - each core snoops the writes granted to the other one (its LR/SC
     reservation), and an SC may decide only when the other core has no
     ungranted write or AMO read, does not hold the AMO lock and, for
     core 1, core 0 is not deciding an SC in the same cycle ([sc_block]).
   With one core, core 1's inputs are tied low. *)
open! Base
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; valid : 'a [@bits 2]
    ; write : 'a [@bits 2]
    ; sc : 'a [@bits 2]
    ; lock : 'a [@bits 2]
    ; core0_sc : 'a (* core 0 decides an SC now (one bit: a 2-bit port
                       with core 1's would be a node-level loop, B-0049) *)
    ; ready : 'a
    ; rvalid : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { sel : 'a (* the core whose request goes to the bus *)
    ; sel_valid : 'a
    ; granted : 'a [@bits 2] (* accepted by the bus this cycle *)
    ; snoop : 'a [@bits 2] (* the other core's write was granted *)
    ; sc_block0 : 'a (* separate ports: core 1's depends on core 0's mem_sc *)
    ; sc_block1 : 'a
    ; read_busy : 'a
    ; locked : 'a
    ; lock_hart : 'a
    }
  [@@deriving hardcaml]
end

let create scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let read_busy = wire 1
  and locked = wire 1
  and lock_hart = wire 1
  and last = wire 1 in
  let v h = i.valid.:(h)
  and w h = i.write.:(h) in
  let eligible h = v h &: ~:read_busy &: (~:locked |: (lock_hart ==:. h)) in
  let e0 = eligible 0
  and e1 = eligible 1 in
  let sc0 = e0 &: w 0 &: i.sc.:(0)
  and sc1 = e1 &: w 1 &: i.sc.:(1) in
  (* an SC's write first, then the core not served last *)
  let sel = mux2 (sc0 |: sc1) (sc1 &: ~:sc0) (e1 &: (~:e0 |: (last ==:. 0))) -- "arb_sel" in
  let sel_valid = (e0 |: e1) -- "arb_valid" in
  let sel_write = mux2 sel (w 1) (w 0) in
  let sel_lock = mux2 sel i.lock.:(1) i.lock.:(0) in
  let accepted = (sel_valid &: i.ready) -- "arb_accepted" in
  let accepted_read = accepted &: ~:sel_write in
  read_busy
  <== (reg_fb spec ~width:1 ~f:(fun b -> mux2 accepted_read vdd (mux2 i.rvalid gnd b))
       -- "read_busy");
  locked
  <== (reg_fb spec ~width:1 ~f:(fun l ->
         mux2 (accepted_read &: sel_lock) vdd (mux2 (accepted &: sel_write) gnd l))
       -- "bus_locked");
  lock_hart <== (reg spec ~enable:(accepted_read &: sel_lock) sel -- "bus_lock_hart");
  last <== (reg spec ~enable:accepted sel -- "arb_last");
  let granted = (accepted &: sel) @: (accepted &: ~:sel) in
  let snoop = (accepted &: sel_write &: ~:sel) @: (accepted &: sel_write &: sel) in
  (* the other core g may still write: an ungranted write or AMO read, or
     the bus locked for g's AMO (B-0048: sby found an SC that decided while
     the other core's AMO held the lock; the AMO's write then came first) *)
  let may_write g =
    if Option.equal String.equal (Sys.getenv "EXPERIMENT") (Some "arbiter-b0048")
    then v g &: w g (* the rule before B-0048, for the formal negative test *)
    else (v g &: (w g |: i.lock.:(g))) |: (locked &: (lock_hart ==:. g))
  in
  let sc_block0 = may_write 1 -- "sc_block0" in
  (* core 1 also waits while core 0 decides an SC in the same cycle *)
  let sc_block1 = (may_write 0 |: i.core0_sc) -- "sc_block1" in
  { O.sel
  ; sel_valid
  ; granted
  ; snoop
  ; sc_block0
  ; sc_block1
  ; read_busy
  ; locked
  ; lock_hart
  }
;;

let hierarchical scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"arbiter" create
;;
