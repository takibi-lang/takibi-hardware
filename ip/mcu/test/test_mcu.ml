open! Base
open! Hardcaml
open Stdio
module Sim = Cyclesim.With_interface (Mcu.I) (Mcu.O)
module Bench = Mcu_bench.Bench

(* Inline tests run in _build/default/ip/mcu/test. *)
let firmware name = Bench.firmware ("../../../sw/" ^ name)

let run config ~image ~input ~cycles =
  let sim = Sim.create (Bench.create config (Scope.create ~flatten_design:true ())) in
  Bench.run config sim ~image ~input ~cycles ()
;;

(* Instruction and cycle counts depend on the cross compiler's version
   (the devcontainer and CI images ship different gcc releases), so the
   expectations only contain what the hardware determines: the program's
   output, the LEDs, the trap, lockstep agreement and, for Dhrystone, the
   CPI. *)
let print_result ?(mask_numbers = false) (r : Bench.result) =
  let output =
    if mask_numbers
    then (
      (* Each run of digits becomes one '#'. *)
      let b = Buffer.create (String.length r.output) in
      String.iteri r.output ~f:(fun k c ->
        if not (Char.is_digit c)
        then Buffer.add_char b c
        else if k = 0 || not (Char.is_digit r.output.[k - 1])
        then Buffer.add_char b '#');
      Buffer.contents b)
    else r.output
  in
  printf "%S\n" output;
  printf
    "leds=%d trap=%s retired>0=%b\n%s\n"
    r.leds
    (Option.value_map r.trap ~default:"none" ~f:Int.to_string)
    (r.retired > 0)
    (Option.value r.mismatch ~default:"lockstep: ok")
;;

(* "dhrystone: runs=N cycles=C instret=I" from the harness. *)
let dhrystone_counts output =
  List.find_map (String.split_lines output) ~f:(fun line ->
    try Some (Stdlib.Scanf.sscanf line "dhrystone: runs=%d cycles=%d instret=%d" (fun r c i -> r, c, i)) with
    | _ -> None)
;;

let%expect_test "iCEstick configuration: RV32E echo firmware, in lockstep" =
  print_result
    (run
       Bench.icestick
       ~image:(firmware "echo_rv32e.bin")
       ~input:"hello\rRV32e!\r"
       ~cycles:200_000);
  [%expect
    {|
    "RV32 MCU ready\r\n> hello\r\nHELLO\r\n> RV32e!\r\nRV32E!\r\n> "
    leds=6 trap=none retired>0=true
    lockstep: ok
    |}]
;;

let%expect_test "i9 configuration: RV32I echo firmware, in lockstep" =
  print_result
    (run Bench.i9_multicycle ~image:(firmware "echo_rv32i.bin") ~input:"rv32i\r" ~cycles:200_000);
  [%expect {|
    "RV32 MCU ready\r\n> rv32i\r\nRV32I\r\n> "
    leds=5 trap=none retired>0=true
    lockstep: ok
    |}]
;;

let%expect_test "i9 configuration: Dhrystone (50 runs), in lockstep" =
  let r =
    run Bench.i9_multicycle ~image:(firmware "dhrystone_sim.bin") ~input:"" ~cycles:3_000_000
  in
  print_result ~mask_numbers:true r;
  (match dhrystone_counts r.output with
   | Some (runs, cycles, instret) ->
     printf "runs=%d CPI=%.2f\n" runs (Float.of_int cycles /. Float.of_int instret)
   | None -> print_endline "no dhrystone line");
  [%expect {|
    "dhrystone: runs=# cycles=# instret=#\r\ndhrystone: DMIPS/MHz=#.#\r\nMicroseconds for one run through Dhrystone: #\r\nDhrystones per Second:                      #\r\n"
    leds=1 trap=2 retired>0=true
    lockstep: ok
    runs=50 CPI=2.69
    |}]
;;

let%expect_test "i9 configuration: interrupts and traps (timer, software, ecall, UART RX)" =
  let r = run Bench.i9_multicycle ~image:(firmware "irq_rv32i.bin") ~input:"irq\r" ~cycles:200_000 in
  print_result r;
  printf "interrupts>10=%b\n" (r.interrupts > 10);
  [%expect {|
    "irq: timer ok, software ok, ecall ok\r\n> irq\r\nIRQ\r\n> "
    leds=1 trap=none retired>0=true
    lockstep: ok
    interrupts>10=true
    |}]
;;

(* The pipelined core (#4) in the i9 configuration *)
let i9_pipeline = Bench.i9

let%expect_test "i9 pipeline: echo, Dhrystone and interrupts, in lockstep" =
  print_result
    (run i9_pipeline ~image:(firmware "echo_rv32i.bin") ~input:"rv32i\r" ~cycles:200_000);
  let r = run i9_pipeline ~image:(firmware "dhrystone_sim.bin") ~input:"" ~cycles:3_000_000 in
  print_result ~mask_numbers:true r;
  (match dhrystone_counts r.output with
   | Some (runs, cycles, instret) ->
     printf "runs=%d CPI=%.2f\n" runs (Float.of_int cycles /. Float.of_int instret)
   | None -> print_endline "no dhrystone line");
  let r = run i9_pipeline ~image:(firmware "irq_rv32i.bin") ~input:"irq\r" ~cycles:200_000 in
  print_result r;
  printf "interrupts>10=%b\n" (r.interrupts > 10);
  [%expect {|
    "RV32 MCU ready\r\n> rv32i\r\nRV32I\r\n> "
    leds=5 trap=none retired>0=true
    lockstep: ok
    "dhrystone: runs=# cycles=# instret=#\r\ndhrystone: DMIPS/MHz=#.#\r\nMicroseconds for one run through Dhrystone: #\r\nDhrystones per Second:                      #\r\n"
    leds=1 trap=2 retired>0=true
    lockstep: ok
    runs=50 CPI=1.67
    "irq: timer ok, software ok, ecall ok\r\n> irq\r\nIRQ\r\n> "
    leds=1 trap=none retired>0=true
    lockstep: ok
    interrupts>10=true
    |}]
;;
