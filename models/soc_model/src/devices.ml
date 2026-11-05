(* Devices of the Linux SoC model (issue #25), register for register what
   the hardware will implement (#28):

   - CLINT, SiFive layout: msip (+0x0), mtimecmp (+0x4000), mtime
     (+0xbff8). mtime advances through [Clint.tick].
   - PLIC, SiFive layout: priority (+4*source), pending (+0x1000), enables
     (+0x2000 + 0x80*context), threshold and claim/complete (+0x200000 +
     0x1000*context). Level-triggered sources; a claimed source is not
     pending again until completed.
   - 16550 subset: RBR/THR, IER (receive data, transmit holding register
     empty), IIR, FCR (accepted, FIFOs not modelled beyond the receive
     queue), LCR (DLAB), MCR, LSR, MSR, SCR, divisor latches. Transmission
     is instantaneous: THR empty at all times. *)
open! Base

let u32 v = v land 0xffff_ffff

module Clint = struct
  (* 64-bit registers as 32-bit halves (OCaml ints are 63 bits). One msip
     and mtimecmp per hart (SiFive layout: msip at 4 * hart, mtimecmp at
     0x4000 + 8 * hart; #9). *)
  type t =
    { msip : bool array
    ; cmp_lo : int array
    ; cmp_hi : int array
    ; mutable time_lo : int
    ; mutable time_hi : int
    }

  let create ?(harts = 1) () =
    { msip = Array.create ~len:harts false
    ; cmp_lo = Array.create ~len:harts 0xffff_ffff
    ; cmp_hi = Array.create ~len:harts 0xffff_ffff
    ; time_lo = 0
    ; time_hi = 0
    }
  ;;

  let harts t = Array.length t.msip

  let tick t n =
    let lo = t.time_lo + n in
    t.time_lo <- u32 lo;
    t.time_hi <- u32 (t.time_hi + (lo lsr 32))
  ;;

  let mtip ?(hart = 0) t =
    t.time_hi > t.cmp_hi.(hart) || (t.time_hi = t.cmp_hi.(hart) && t.time_lo >= t.cmp_lo.(hart))
  ;;

  let msip ?(hart = 0) t = t.msip.(hart)

  let load t off =
    let h = harts t in
    if off < 4 * h && off % 4 = 0
    then Bool.to_int t.msip.(off / 4)
    else if off >= 0x4000 && off < 0x4000 + (8 * h)
    then (
      let k = (off - 0x4000) / 8 in
      if (off - 0x4000) % 8 = 0 then t.cmp_lo.(k) else t.cmp_hi.(k))
    else (
      match off with
      | 0xbff8 -> t.time_lo
      | 0xbffc -> t.time_hi
      | _ -> 0)
  ;;

  let store t off v =
    let v = u32 v in
    let h = harts t in
    if off < 4 * h && off % 4 = 0
    then t.msip.(off / 4) <- v land 1 <> 0
    else if off >= 0x4000 && off < 0x4000 + (8 * h)
    then (
      let k = (off - 0x4000) / 8 in
      if (off - 0x4000) % 8 = 0 then t.cmp_lo.(k) <- v else t.cmp_hi.(k) <- v)
    else (
      match off with
      | 0xbff8 -> t.time_lo <- v
      | 0xbffc -> t.time_hi <- v
      | _ -> ())
  ;;
end

module Plic = struct
  type t =
    { sources : int
    ; contexts : int
    ; priority : int array
    ; mutable level : int (* current input levels, bit per source *)
    ; mutable pending : int
    ; mutable claimed : int (* in service until completed *)
    ; enable : int array
    ; threshold : int array
    }

  let create ~sources ~contexts =
    { sources
    ; contexts
    ; priority = Array.create ~len:(sources + 1) 0
    ; level = 0
    ; pending = 0
    ; claimed = 0
    ; enable = Array.create ~len:contexts 0
    ; threshold = Array.create ~len:contexts 0
    }
  ;;

  (* Level-triggered gateway: a source becomes pending while its level is
     high and it is not in service. *)
  let set_level t ~source high =
    let bit = 1 lsl source in
    t.level <- (if high then t.level lor bit else t.level land lnot bit);
    if high && t.claimed land bit = 0 then t.pending <- t.pending lor bit
  ;;

  let best t ctx =
    let best = ref 0 in
    for s = 1 to t.sources do
      let bit = 1 lsl s in
      if t.pending land bit <> 0
         && t.enable.(ctx) land bit <> 0
         && t.priority.(s) > t.threshold.(ctx)
         && (!best = 0 || t.priority.(s) > t.priority.(!best))
      then best := s
    done;
    !best
  ;;

  let irq t ~context = best t context <> 0

  let load t off =
    if off < 0x1000
    then if off / 4 <= t.sources then t.priority.(off / 4) else 0
    else if off = 0x1000
    then t.pending
    else if off >= 0x2000 && off < 0x2000 + (0x80 * t.contexts)
    then if (off - 0x2000) % 0x80 = 0 then t.enable.((off - 0x2000) / 0x80) else 0
    else if off >= 0x20_0000 && off < 0x20_0000 + (0x1000 * t.contexts)
    then (
      let ctx = (off - 0x20_0000) / 0x1000 in
      match (off - 0x20_0000) % 0x1000 with
      | 0 -> t.threshold.(ctx)
      | 4 ->
        let s = best t ctx in
        if s <> 0
        then (
          t.pending <- t.pending land lnot (1 lsl s);
          t.claimed <- t.claimed lor (1 lsl s));
        s
      | _ -> 0)
    else 0
  ;;

  let store t off v =
    if off < 0x1000
    then (if off / 4 >= 1 && off / 4 <= t.sources then t.priority.(off / 4) <- v land 7)
    else if off >= 0x2000 && off < 0x2000 + (0x80 * t.contexts)
    then (
      if (off - 0x2000) % 0x80 = 0
      then t.enable.((off - 0x2000) / 0x80) <- v land (((1 lsl t.sources) - 1) lsl 1))
    else if off >= 0x20_0000 && off < 0x20_0000 + (0x1000 * t.contexts)
    then (
      let ctx = (off - 0x20_0000) / 0x1000 in
      match (off - 0x20_0000) % 0x1000 with
      | 0 -> t.threshold.(ctx) <- v land 7
      | 4 ->
        if v >= 1 && v <= t.sources
        then (
          let bit = 1 lsl v in
          t.claimed <- t.claimed land lnot bit;
          if t.level land bit <> 0 then t.pending <- t.pending lor bit)
      | _ -> ())
  ;;
end

module Uart = struct
  type t =
    { rx : int Queue.t
    ; mutable ier : int
    ; mutable lcr : int
    ; mutable mcr : int
    ; mutable scr : int
    ; mutable dll : int
    ; mutable dlm : int
    ; mutable fcr : int
    ; mutable thre_pending : bool (* THRE interrupt, cleared by an IIR read or a THR write *)
    ; output : Buffer.t
    }

  let create () =
    { rx = Queue.create ()
    ; ier = 0
    ; lcr = 0
    ; mcr = 0
    ; scr = 0
    ; dll = 0
    ; dlm = 0
    ; fcr = 0
    ; thre_pending = true
    ; output = Buffer.create 4096
    }
  ;;

  let receive t c = Queue.enqueue t.rx (Char.to_int c)
  let dlab t = t.lcr land 0x80 <> 0

  let iir t =
    let fifo = if t.fcr land 1 <> 0 then 0xc0 else 0 in
    if t.ier land 1 <> 0 && not (Queue.is_empty t.rx)
    then fifo lor 0x04
    else if t.ier land 2 <> 0 && t.thre_pending
    then fifo lor 0x02
    else fifo lor 0x01
  ;;

  let irq t = iir t land 1 = 0

  let load t off =
    match off with
    | 0 when dlab t -> t.dll
    | 0 -> Option.value (Queue.dequeue t.rx) ~default:0
    | 1 when dlab t -> t.dlm
    | 1 -> t.ier
    | 2 ->
      let v = iir t in
      if v land 0xf = 0x02 then t.thre_pending <- false;
      v
    | 3 -> t.lcr
    | 4 -> t.mcr
    | 5 -> 0x60 lor Bool.to_int (not (Queue.is_empty t.rx)) (* TEMT, THRE, DR *)
    | 6 -> 0xb0 (* DCD, DSR, CTS *)
    | 7 -> t.scr
    | _ -> 0
  ;;

  let store t off v =
    let v = v land 0xff in
    match off with
    | 0 when dlab t -> t.dll <- v
    | 0 ->
      Buffer.add_char t.output (Char.of_int_exn v);
      t.thre_pending <- true
    | 1 when dlab t -> t.dlm <- v
    | 1 ->
      (* Enabling the THRE interrupt with THR empty raises it. *)
      if v land 2 <> 0 && t.ier land 2 = 0 then t.thre_pending <- true;
      t.ier <- v land 0xf
    | 2 -> t.fcr <- v
    | 3 -> t.lcr <- v
    | 4 -> t.mcr <- v
    | 7 -> t.scr <- v
    | _ -> ()
  ;;
end
