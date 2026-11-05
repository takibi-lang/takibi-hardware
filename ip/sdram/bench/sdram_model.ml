(* Behavioural model of the EM638325-6H SDRAM as wired on the Colorlight i9
   (CS# low, CKE high, DQM low), at command level, one call per clock
   cycle, with the datasheet timing checked in nanoseconds. Violations are
   collected, not fatal, so a test can show them (and a negative test can
   show that they are caught).

   Checked: the power-up sequence (200 us of NOP, PRECHARGE ALL, at least
   2 AUTO REFRESH, MODE REGISTER SET before the first ACTIVE); tRCD, tRAS,
   tRP, tRC, tRRD, tWR, tMRD, tRFC; ACTIVE only on an idle bank,
   READ/WRITE only on an open row; the refresh interval (4096 per 64 ms);
   the data bus driven by the controller during WRITE and never while the
   SDRAM drives read data; auto-precharge after the access (tRAS lockout:
   it starts no earlier than tRAS after ACTIVE).

   Read data: the word READ at cycle k addresses is on [dq_in] in cycle
   k + [read_latency] (CAS latency and the board round trip, as the
   controller's Config). *)
open! Base

type bank =
  { mutable row : int option
  ; mutable act_ns : float
  ; mutable ready_ns : float (* earliest next ACTIVE (after precharge) *)
  ; mutable last_write_ns : float
  }

type t =
  { period_ns : float
  ; read_latency : int
  ; cas_latency : int
  ; mem : Bytes.t
  ; banks : bank array
  ; mutable cycle : int
  ; mutable powered_ns : float
  ; mutable precharged_all : bool
  ; mutable init_refreshes : int
  ; mutable mode_set : int option (* CAS latency programmed *)
  ; mutable mode_ns : float
  ; mutable last_refresh_ns : float
  ; mutable refresh_ready_ns : float
  ; mutable last_act_ns : float
  ; pending : (int * int) Queue.t (* cycle, data driven then *)
  ; mutable violations : string list
  ; mutable reads : int
  ; mutable writes : int
  ; mutable refreshes : int
  }

(* EM638325-6H, ns *)
let t_rcd = 18.
let t_ras = 42.
let t_rp = 18.
let t_rc = 60.
let t_rrd = 12.
let t_wr = 12.
let t_mrd_cycles = 2
let t_rfc = 60.
let t_refi = 64_000_000. /. 4096.
let t_power_up = 200_000.

let create ~clock_mhz ~cas_latency ~read_latency () =
  { period_ns = 1000. /. Float.of_int clock_mhz
  ; read_latency
  ; cas_latency
  ; mem = Bytes.make (8 lsl 20) '\000'
  ; banks =
      Array.init 4 ~f:(fun _ ->
        { row = None; act_ns = -1e9; ready_ns = 0.; last_write_ns = -1e9 })
  ; cycle = 0
  ; powered_ns = 0.
  ; precharged_all = false
  ; init_refreshes = 0
  ; mode_set = None
  ; mode_ns = -1e9
  ; last_refresh_ns = 0.
  ; refresh_ready_ns = 0.
  ; last_act_ns = -1e9
  ; pending = Queue.create ()
  ; violations = []
  ; reads = 0
  ; writes = 0
  ; refreshes = 0
  }
;;

let violation t fmt =
  Printf.ksprintf
    (fun s ->
      if List.length t.violations < 20
      then t.violations <- Printf.sprintf "cycle %d: %s" t.cycle s :: t.violations)
    fmt
;;

let word ~bank ~row ~col = (((row lsl 2) lor bank) lsl 8) lor col

let read_word t w = Stdlib.Bytes.get_int32_le t.mem (4 * w) |> Int32.to_int_trunc |> fun v -> v land 0xffff_ffff
let write_word t w v = Stdlib.Bytes.set_int32_le t.mem (4 * w) (Int32.of_int_trunc v)

(* Precharge [b] at the earliest time allowed after the access at [now]. *)
let auto_precharge t (b : bank) ~start =
  let start = Float.max start (b.act_ns +. t_ras) in
  b.row <- None;
  b.ready_ns <- start +. t_rp;
  ignore t
;;

(* One clock cycle with the pins as the controller drives them; returns the
   data the SDRAM drives on DQ in this cycle (if any). *)
let step t ~cmd ~a ~ba ~dq_out ~dq_oe =
  let now = Float.of_int t.cycle *. t.period_ns in
  let all_idle () = Array.for_all t.banks ~f:(fun b -> Option.is_none b.row) in
  let initialised () = Option.is_some t.mode_set in
  if initialised () && Float.(now -. t.last_refresh_ns > t_refi)
  then (
    violation t "no AUTO REFRESH for %.0f ns (tREFI %.0f)" (now -. t.last_refresh_ns) t_refi;
    t.last_refresh_ns <- now);
  if cmd <> 0b111 && Float.(now < t_power_up)
  then violation t "command %d during the 200 us power-up" cmd;
  let b = t.banks.(ba) in
  (match cmd with
   | 0b111 -> ()
   | 0b011 ->
     (* ACTIVE *)
     if not (initialised ()) then violation t "ACTIVE before MODE REGISTER SET";
     if Option.is_some b.row then violation t "ACTIVE on bank %d with an open row" ba;
     if Float.(now < b.ready_ns) then violation t "tRP: ACTIVE on bank %d too early" ba;
     if Float.(now -. b.act_ns < t_rc) then violation t "tRC on bank %d" ba;
     if Float.(now -. t.last_act_ns < t_rrd) then violation t "tRRD";
     if Float.(now < t.refresh_ready_ns) then violation t "tRFC: ACTIVE after REFRESH";
     if t.cycle - Float.to_int (t.mode_ns /. t.period_ns) < t_mrd_cycles
     then violation t "tMRD";
     b.row <- Some (a land 0x7ff);
     b.act_ns <- now;
     t.last_act_ns <- now
   | 0b101 | 0b100 ->
     let write = cmd = 0b100 in
     (match b.row with
      | None -> violation t "%s on bank %d without an open row" (if write then "WRITE" else "READ") ba
      | Some row ->
        if Float.(now -. b.act_ns < t_rcd) then violation t "tRCD on bank %d" ba;
        let w = word ~bank:ba ~row ~col:(a land 0xff) in
        if write
        then (
          if not dq_oe then violation t "WRITE without the data bus driven";
          write_word t w dq_out;
          b.last_write_ns <- now;
          t.writes <- t.writes + 1)
        else (
          Queue.enqueue t.pending (t.cycle + t.read_latency, read_word t w);
          t.reads <- t.reads + 1);
        if a land 0x400 <> 0
        then
          auto_precharge
            t
            b
            ~start:(if write then now +. t.period_ns +. t_wr else now +. t.period_ns))
   | 0b010 ->
     (* PRECHARGE (A10: all banks) *)
     let targets = if a land 0x400 <> 0 then Array.to_list t.banks else [ b ] in
     List.iter targets ~f:(fun b ->
       if Option.is_some b.row
       then (
         if Float.(now -. b.act_ns < t_ras) then violation t "tRAS";
         if Float.(now -. b.last_write_ns < t_wr) then violation t "tWR";
         b.row <- None;
         b.ready_ns <- now +. t_rp));
     if a land 0x400 <> 0 && not (initialised ()) then t.precharged_all <- true
   | 0b001 ->
     (* AUTO REFRESH *)
     if not (all_idle ()) then violation t "REFRESH with an open row";
     if Array.exists t.banks ~f:(fun b -> Float.(now < b.ready_ns))
     then violation t "tRP: REFRESH too early";
     if Float.(now < t.refresh_ready_ns) then violation t "tRFC: REFRESH after REFRESH";
     if (not (initialised ())) && not t.precharged_all
     then violation t "REFRESH before PRECHARGE ALL";
     if not (initialised ()) then t.init_refreshes <- t.init_refreshes + 1;
     t.refresh_ready_ns <- now +. t_rfc;
     t.last_refresh_ns <- now;
     t.refreshes <- t.refreshes + 1
   | 0b000 ->
     (* MODE REGISTER SET *)
     if not (all_idle ()) then violation t "MODE REGISTER SET with an open row";
     if t.init_refreshes < 2 then violation t "MODE REGISTER SET after %d refreshes" t.init_refreshes;
     if a land 0x7 <> 0 then violation t "burst length %d (expected 1)" (1 lsl (a land 7));
     let cl = (a lsr 4) land 7 in
     if cl <> t.cas_latency then violation t "CAS latency %d programmed, %d expected" cl t.cas_latency;
     t.mode_set <- Some cl;
     t.mode_ns <- now;
     t.last_refresh_ns <- now
   | c -> violation t "unknown command %d" c);
  let driven =
    match Queue.peek t.pending with
    | Some (at, v) when at = t.cycle ->
      ignore (Queue.dequeue_exn t.pending : int * int);
      if dq_oe then violation t "bus contention: controller drives DQ during read data";
      Some v
    | _ -> None
  in
  t.cycle <- t.cycle + 1;
  driven
;;
