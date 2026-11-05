(* CLINT, SiFive layout, one hart (issue #28, Linux L7): msip at 0x0,
   mtimecmp at 0x4000, mtime at 0xbff8 (64-bit registers as two words).
   mtime counts at the timebase, [clock_hz / timebase_hz] cycles per tick
   (Soc_map: 1 MHz). Outputs: MSIP, MTIP and mtime for the core's time CSR
   and Sstc. Register for register as Soc_model.Devices.Clint. *)
open! Base
open! Hardcaml
open Signal

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; msip : 'a
    ; mtip : 'a
    ; mtime : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

let create ~cycles_per_tick scope (i : _ Regbus.I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let reg ?(clear_to = 0) name w =
    let spec = Reg_spec.override spec ~clear_to:(of_int ~width:w clear_to) in
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let msip = reg "msip" 1 in
  let cmp_lo = reg ~clear_to:(-1) "mtimecmp_lo" 32 in
  let cmp_hi = reg ~clear_to:(-1) "mtimecmp_hi" 32 in
  let time_lo = reg "mtime_lo" 32 in
  let time_hi = reg "mtime_hi" 32 in
  let prescale = reg "prescale" (Int.max 1 (Int.ceil_log2 cycles_per_tick)) in
  let rdata = reg "rdata" 32 in
  let off = i.addr.:[15, 0] in
  let at a = off ==:. a in
  let w = i.write in
  let tick = (prescale.value ==:. cycles_per_tick - 1) -- "tick" in
  let mtime = time_hi.value @: time_lo.value in
  let next_time = mtime +:. 1 in
  Always.(
    compile
      [ prescale <-- mux2 tick (zero (width prescale.value)) (prescale.value +:. 1)
      ; when_ tick [ time_lo <-- next_time.:[31, 0]; time_hi <-- next_time.:[63, 32] ]
      ; when_ (w &: at 0x0) [ msip <-- i.wdata.:(0) ]
      ; when_ (w &: at 0x4000) [ cmp_lo <-- i.wdata ]
      ; when_ (w &: at 0x4004) [ cmp_hi <-- i.wdata ]
      ; when_ (w &: at 0xbff8) [ time_lo <-- i.wdata ]
      ; when_ (w &: at 0xbffc) [ time_hi <-- i.wdata ]
      ; when_
          i.read
          [ rdata
            <-- mux2
                  (at 0x0)
                  (uresize msip.value 32)
                  (mux2
                     (at 0x4000)
                     cmp_lo.value
                     (mux2
                        (at 0x4004)
                        cmp_hi.value
                        (mux2
                           (at 0xbff8)
                           time_lo.value
                           (mux2 (at 0xbffc) time_hi.value (zero 32)))))
          ]
      ]);
  { O.rdata = rdata.value
  ; msip = msip.value
  ; mtip = (mtime >=: (cmp_hi.value @: cmp_lo.value)) -- "mtip"
  ; mtime
  }
;;

let hierarchical ~cycles_per_tick scope =
  let module H = Hierarchy.In_scope (Regbus.I) (O) in
  H.hierarchical ~scope ~name:"clint" (create ~cycles_per_tick)
;;
