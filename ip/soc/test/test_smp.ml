(* The SoC with two cores (#9) in Cyclesim with the board models, both in
   lockstep with their golden models (shared RAM): from the boot ROM, both
   harts add to one counter in SDRAM, N times with an LR/SC loop and M
   times with AMOADD, then set their done flag; hart 0 waits for hart 1
   and checks the counter (2N + 2M), so a lost update shows as "bad". *)
open! Base
open Stdio
module A = Rv32_model.Asm
module C = Rv32_model.Asm.Csr
module H = Soc_bench.Soc_harness
module Map = Soc_model.Soc_map

let n = 40
let m = 40

let putc r =
  A.li 31 Map.uart_base
  @ [ A.lbu 30 31 5; A.andi 30 30 0x20; A.beq 30 0 (-8); A.sb r 31 0 ]
;;

let puts s = List.concat_map (String.to_list s) ~f:(fun c -> A.li 29 (Char.to_int c) @ putc 29)

let program =
  let common =
    [ A.csrr 1 C.mhartid ]
    @ A.li 2 Map.ram_base (* the counter *)
    @ A.li 3 n
    (* LR/SC loop *)
    @ [ A.lr_w 4 2; A.addi 4 4 1; A.sc_w 5 2 4; A.bne 5 0 (-12); A.addi 3 3 (-1); A.bne 3 0 (-20) ]
    @ A.li 3 m
    @ A.li 6 1
    (* AMOADD loop *)
    @ [ A.amoadd_w 0 2 6; A.addi 3 3 (-1); A.bne 3 0 (-8) ]
    (* done[hart] = 1 at RAM + 0x100 + 4 * hart *)
    @ [ A.slli 7 1 2; A.add 7 7 2; A.sw 6 7 0x100 ]
  in
  let hart1_spin = [ A.beq 1 0 8; A.jal 0 0 (* hart 1 stops here *) ] in
  let hart0 =
    [ A.lw 8 2 0x104; A.beq 8 0 (-4) ] (* wait for hart 1 *)
    @ [ A.lw 9 2 0 ]
    @ A.li 10 (2 * (n + m))
    @ [ A.beq 9 10 0 (* patched below *) ]
  in
  let bad = puts "bad\n" in
  let ok = puts "ok\n" in
  let finish =
    A.li 31 Map.uart_base
    @ [ A.lbu 30 31 5; A.andi 30 30 0x40; A.beq 30 0 (-8); A.csrw C.mtvec 0; A.ebreak ]
  in
  (* beq x9, x10 -> ok (skip bad and its jump) *)
  let jump_over_ok = [ A.jal 0 (4 * (1 + List.length ok)) ] in
  let hart0 =
    List.take hart0 (List.length hart0 - 1)
    @ [ A.beq 9 10 (4 * (1 + List.length bad + 1)) ]
    @ bad
    @ jump_over_ok
    @ ok
  in
  Array.of_list (common @ hart1_spin @ hart0 @ finish)
;;

let%expect_test "two cores: LR/SC and AMOs on one counter, both in lockstep" =
  let r =
    H.run ~harts:2 ~boot_rom:program ~flash:"" ~max_cycles:200_000 ()
  in
  printf
    "output %S\nhalted %s, retired>0 %b\nmismatch %s\nsdram %s\n"
    r.output
    (Option.value_map r.halted ~default:"no" ~f:Int.to_string)
    (r.retired > 0)
    (Option.value r.mismatch ~default:"none")
    (String.concat ~sep:"; " r.sdram_violations);
  [%expect {|
    output "ok\n"
    halted 2, retired>0 true
    mismatch none
    sdram
    |}]
;;
