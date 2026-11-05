(* CLINT, SiFive layout (issue #28, Linux L7; [harts] up to 4, #9): msip
   at 4 * hart, mtimecmp at 0x4000 + 8 * hart, mtime at 0xbff8 (64-bit
   registers as two words).
   mtime counts at the timebase, [clock_hz / timebase_hz] cycles per tick
   (Soc_map: 1 MHz). Outputs: MSIP, MTIP and mtime for the core's time CSR
   and Sstc. Register for register as Soc_model.Devices.Clint. *)
open! Base
open! Hardcaml
open Signal

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; msip : 'a [@bits 4] (* per hart *)
    ; mtip : 'a [@bits 4]
    ; mtime : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

let create ?(harts = 1) ~cycles_per_tick scope (i : _ Regbus.I.t) =
  assert (harts >= 1 && harts <= 4);
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let reg ?(clear_to = 0) name w =
    let spec = Reg_spec.override spec ~clear_to:(of_int ~width:w clear_to) in
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let sfx h n = if h = 0 then n else Printf.sprintf "%s%d" n h in
  let msip = Array.init harts ~f:(fun h -> reg (sfx h "msip") 1) in
  let cmp_lo = Array.init harts ~f:(fun h -> reg ~clear_to:(-1) (sfx h "mtimecmp_lo") 32) in
  let cmp_hi = Array.init harts ~f:(fun h -> reg ~clear_to:(-1) (sfx h "mtimecmp_hi") 32) in
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
  let read_value =
    List.fold
      (List.range 0 harts)
      ~init:
        (mux2 (at 0xbff8) time_lo.value (mux2 (at 0xbffc) time_hi.value (zero 32)))
      ~f:(fun acc h ->
        mux2
          (at (4 * h))
          (uresize msip.(h).value 32)
          (mux2
             (at (0x4000 + (8 * h)))
             cmp_lo.(h).value
             (mux2 (at (0x4004 + (8 * h))) cmp_hi.(h).value acc)))
  in
  Always.(
    compile
      ([ prescale <-- mux2 tick (zero (width prescale.value)) (prescale.value +:. 1)
       ; when_ tick [ time_lo <-- next_time.:[31, 0]; time_hi <-- next_time.:[63, 32] ]
       ; when_ (w &: at 0xbff8) [ time_lo <-- i.wdata ]
       ; when_ (w &: at 0xbffc) [ time_hi <-- i.wdata ]
       ; when_ i.read [ rdata <-- read_value ]
       ]
       @ List.concat_map (List.range 0 harts) ~f:(fun h ->
         [ when_ (w &: at (4 * h)) [ msip.(h) <-- i.wdata.:(0) ]
         ; when_ (w &: at (0x4000 + (8 * h))) [ cmp_lo.(h) <-- i.wdata ]
         ; when_ (w &: at (0x4004 + (8 * h))) [ cmp_hi.(h) <-- i.wdata ]
         ])));
  let per_hart f = uresize (concat_lsb (List.init harts ~f)) 4 in
  { O.rdata = rdata.value
  ; msip = per_hart (fun h -> msip.(h).value)
  ; mtip =
      per_hart (fun h ->
        (mtime >=: (cmp_hi.(h).value @: cmp_lo.(h).value)) -- sfx h "mtip")
  ; mtime
  }
;;

let hierarchical ?harts ~cycles_per_tick scope =
  let module H = Hierarchy.In_scope (Regbus.I) (O) in
  H.hierarchical ~scope ~name:"clint" (create ?harts ~cycles_per_tick)
;;
