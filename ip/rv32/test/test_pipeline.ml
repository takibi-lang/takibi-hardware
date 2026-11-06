(* The pipelined core (#4) in lockstep with the golden model: the random
   programs of test_core.ml (ALU, branches, jumps, loads and stores) and of
   test_zicsr.ml (CSRs, M, A, traps and randomly timed interrupts), with
   block-RAM ports and with random wait states on both ports. *)
open! Base
open Stdio
module PH = Rv32_bench.Pipe_harness

let report name ~programs ~run =
  let retired = ref 0
  and cycles = ref 0
  and failures = ref 0
  and interrupts = ref 0 in
  for n = 1 to programs do
    let (r : Rv32_bench.Core_harness.result) = run n in
    retired := !retired + r.retired;
    cycles := !cycles + r.cycles;
    interrupts := !interrupts + r.interrupts;
    match r.mismatch, r.trap with
    | None, Some 2 -> ()
    | m, t ->
      Int.incr failures;
      if !failures <= 2
      then
        printf
          "%s program %d: trap=%s %s\n"
          name
          n
          (Option.value_map t ~default:"none" ~f:Int.to_string)
          (Option.value m ~default:"")
  done;
  printf
    "%s: %d programs, %d instructions, %d interrupts, %d failures\n"
    name
    programs
    !retired
    !interrupts
    !failures
;;

let%expect_test "pipeline: random programs in lockstep" =
  let rng = Random.State.make [| 2026 |] in
  report "base" ~programs:300 ~run:(fun _ ->
    PH.run ~base:Rv32i (Test_core.random_program rng ~nregs:32 ~length:80));
  let rng = Random.State.make [| 3 |] in
  report "csr+ma+irq" ~programs:300 ~run:(fun _ ->
    let program = Test_zicsr.random_program ~ma:true rng ~nregs:32 ~length:80 in
    PH.run ~irq:(Test_zicsr.random_irqs rng) ~base:Rv32i program);
  let rng = Random.State.make [| 4 |] in
  report "csr+ma+irq, wait states" ~programs:300 ~run:(fun n ->
    let program = Test_zicsr.random_program ~ma:true rng ~nregs:32 ~length:80 in
    PH.run
      ~wait_states:(Random.State.make [| n |])
      ~irq:(Test_zicsr.random_irqs rng)
      ~base:Rv32i
      program);
  [%expect {|
    base: 300 programs, 40739 instructions, 0 interrupts, 0 failures
    csr+ma+irq: 300 programs, 47003 instructions, 765 interrupts, 0 failures
    csr+ma+irq, wait states: 300 programs, 48882 instructions, 1222 interrupts, 0 failures
    |}]
;;

