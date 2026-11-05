(* The SDRAM controller (issue #7, Linux L5) against the EM638325 model:
   random reads, full and partial writes checked against a reference
   memory, and the datasheet timing. Negative tests show that the model's
   checks and the data comparison can fail. *)
open! Base
open Stdio
module Ctrl = Sdram.Sdram_ctrl
module S = Sdram_bench.Sdram_sim

let show (r : S.result) =
  printf
    "%d operations, %d SDRAM reads, %d writes, refreshes>0=%b; %d data errors, %d violations\n"
    r.operations
    r.reads
    r.writes
    (r.refreshes > 0)
    (List.length r.data_errors)
    (List.length r.violations);
  List.iter (List.take r.data_errors 2) ~f:(printf "  %s\n");
  List.iter (List.take r.violations 2) ~f:(printf "  %s\n")
;;

let config = Ctrl.Config.create ~clock_mhz:50 ()

let%expect_test "config at 50 MHz" =
  print_s [%sexp (config : Ctrl.Config.t)];
  [%expect {|
    ((cas_latency 2) (read_latency 3) (trcd 1) (trp 1) (twr_trp 3) (trc 3)
     (tmrd 2) (refresh_interval 730) (init_cycles 10000))
    |}]
;;

let%expect_test "random accesses at 50 MHz" =
  show (S.run ~config ~clock_mhz:50 ~operations:3000 ~seed:1 ());
  show
    (S.run
       ~config:(Ctrl.Config.create ~cas_latency:3 ~read_latency:5 ~clock_mhz:50 ())
       ~clock_mhz:50
       ~operations:1000
       ~seed:2
       ());
  [%expect {|
    3000 operations, 5707 SDRAM reads, 1531 writes, refreshes>0=true; 0 data errors, 0 violations
    1000 operations, 1990 SDRAM reads, 462 writes, refreshes>0=true; 0 data errors, 0 violations
    |}]
;;

let%expect_test "negative: the checks fail" =
  (* refresh too rare *)
  show
    (S.run
       ~config:{ config with refresh_interval = 2000 }
       ~clock_mhz:50
       ~operations:300
       ~seed:3
       ());
  (* a 50 MHz controller on a 100 MHz SDRAM clock: tRCD, tRP, ... *)
  show (S.run ~model_clock_mhz:100 ~config ~clock_mhz:50 ~operations:300 ~seed:4 ());
  (* the controller samples the data bus a cycle early *)
  show
    (S.run ~model_read_latency:(config.read_latency + 1) ~config ~clock_mhz:50 ~operations:300 ~seed:5 ());
  [%expect {|
    300 operations, 588 SDRAM reads, 162 writes, refreshes>0=true; 0 data errors, 4 violations
      cycle 10808: no AUTO REFRESH for 15640 ns (tREFI 15625)
      cycle 11590: no AUTO REFRESH for 15640 ns (tREFI 15625)
    300 operations, 524 SDRAM reads, 151 writes, refreshes>0=true; 0 data errors, 20 violations
      cycle 10001: command 2 during the 200 us power-up
      cycle 10002: command 1 during the 200 us power-up
    300 operations, 600 SDRAM reads, 149 writes, refreshes>0=true; 5 data errors, 20 violations
      read 0x000004: got 0xdeadbeef, expected 0x00000000
      read 0x0003b4: got 0xdeadbeef, expected 0x00000000
      cycle 10046: bus contention: controller drives DQ during read data
      cycle 10101: bus contention: controller drives DQ during read data
    |}]
;;
