(* The core in lockstep with the golden model: directed programs for each
   instruction class and every trap, then random programs. *)
open! Base
open! Hardcaml
open Stdio
module A = Rv32_model.Asm
module H = Rv32_bench.Core_harness

let run program =
  let r = H.run program in
  printf
    "retired=%d cycles=%d trap=%s%s\n"
    r.retired
    r.cycles
    (Option.value_map r.trap ~default:"none" ~f:Int.to_string)
    (Option.value_map r.mismatch ~default:"" ~f:(fun m -> "\n" ^ m))
;;

let%expect_test "arithmetic and shifts" =
  run
    ([ A.addi 1 0 5; A.addi 2 0 (-3); A.add 3 1 2; A.sub 4 2 1; A.addi 0 0 7 ]
     @ A.li 5 0xdeadbeef
     @ [ A.srai 6 5 4
       ; A.srli 7 5 28
       ; A.slli 8 5 31
       ; A.sll 9 5 1
       ; A.srl 10 5 2
       ; A.sra 11 5 2
       ; A.slt 12 2 1
       ; A.sltu 13 2 1
       ; A.slti 14 2 (-2)
       ; A.sltiu 14 2 (-2)
       ; A.xori 3 5 (-1)
       ; A.ori 3 5 0x0f0
       ; A.andi 3 5 0x0f0
       ; A.xor 3 5 1
       ; A.or_ 3 5 2
       ; A.and_ 3 5 2
       ; A.lui 3 0xfffff000
       ; A.auipc 4 0x1000
       ; A.ebreak
       ]);
  [%expect {| retired=25 cycles=236 trap=2 |}]
;;

let%expect_test "loop and branches" =
  run
    [ A.addi 1 0 10
    ; A.addi 2 0 0
    ; A.add 2 2 1
    ; A.addi 1 1 (-1)
    ; A.bne 1 0 (-8)
    ; A.addi 3 0 (-1)
    ; A.blt 3 0 8
    ; A.ecall
    ; A.bltu 3 0 8
    ; A.bge 0 3 8
    ; A.ecall
    ; A.bgeu 3 0 8
    ; A.ecall
    ; A.beq 0 0 8
    ; A.ecall
    ; A.ebreak
    ];
  [%expect {| retired=38 cycles=156 trap=2 |}]
;;

let%expect_test "loads, stores, calls" =
  run
    ([ A.addi 1 0 0x400 ]
     @ A.li 2 0x80ff7f01
     @ [ A.sw 2 1 0
       ; A.lb 3 1 3
       ; A.lbu 4 1 3
       ; A.lh 5 1 2
       ; A.lhu 6 1 0
       ; A.sb 0 1 1
       ; A.sh 2 1 6
       ; A.lw 7 1 0
       ; A.lw 8 1 4
       ; A.jal 9 12
       ; A.ebreak
       ; A.ebreak
       ; A.addi 10 0 42
       ; A.jalr 0 9 0
       ]);
  [%expect {| retired=15 cycles=70 trap=2 |}]
;;

(* The checker must be able to fail: give the model a different program. *)
let%expect_test "lockstep reports a divergence" =
  let r = H.run ~model_program:[ A.addi 1 0 6; A.ebreak ] [ A.addi 1 0 5; A.ebreak ] in
  print_endline (Option.value r.mismatch ~default:"no mismatch");
  [%expect {|
    retire #0 differs
      core:  ((pc 0) (insn 5243027) (rd_write ((1 5))) (mem_write ()) (next_pc 4)
     (trap ()))
      model: ((pc 0) (insn 6291603) (rd_write ((1 6))) (mem_write ()) (next_pc 4)
     (trap ()))
    |}]
;;

let%expect_test "x16..x31 are illegal on RV32E, ordinary on RV32I" =
  let p = [ A.addi 16 0 7; A.add 31 16 16; A.ebreak ] in
  run p;
  let r = H.run ~base:Rv32i p in
  printf "rv32i: retired=%d trap=%s\n" r.retired (Option.value_map r.trap ~default:"none" ~f:Int.to_string);
  [%expect {|
    retired=0 cycles=4 trap=3
    rv32i: retired=2 trap=2
    |}]
;;

let%expect_test "traps" =
  List.iter
    [ [ A.ecall ]
    ; [ A.ebreak ]
    ; [ 0x00000833 ] (* add x16, x0, x0 *)
    ; [ 0 ]
    ; [ A.jal 0 6 ]
    ; [ A.addi 1 0 2; A.jalr 0 1 0 ]
    ; [ A.lw 1 0 2 ]
    ; [ A.sh 1 0 1 ]
    ]
    ~f:run;
  [%expect
    {|
    retired=0 cycles=4 trap=1
    retired=0 cycles=4 trap=2
    retired=0 cycles=4 trap=3
    retired=0 cycles=4 trap=3
    retired=0 cycles=4 trap=4
    retired=1 cycles=8 trap=4
    retired=0 cycles=4 trap=5
    retired=0 cycles=4 trap=5
    |}]
;;

(* Random straight-line programs with forward branches and jumps. The top
   register (x15 or x31) holds the base of a data region and is never
   written, so every random load and store stays aligned and in range. *)
let random_program rng ~nregs ~length =
  let top = nregs - 1 in
  let reg () = 1 + Random.State.int rng (top - 1) in
  let any_reg () = Random.State.int rng top in
  let imm12 () = Random.State.int_incl rng (-2048) 2047 in
  let data_off size = size * Random.State.int rng (64 / size) in
  let setup =
    A.li top 0x800
    @ List.concat_map (List.range 1 top) ~f:(fun r -> A.li r (Random.State.bits rng))
  in
  let body =
    List.init length ~f:(fun k ->
      let remaining = length - k in
      let skip () = 4 * (1 + Random.State.int rng (Int.min 3 remaining)) in
      match Random.State.int rng 22 with
      | 0 -> A.add (reg ()) (any_reg ()) (any_reg ())
      | 1 -> A.sub (reg ()) (any_reg ()) (any_reg ())
      | 2 -> A.sll (reg ()) (any_reg ()) (any_reg ())
      | 3 -> A.srl (reg ()) (any_reg ()) (any_reg ())
      | 4 -> A.sra (reg ()) (any_reg ()) (any_reg ())
      | 5 -> A.slt (reg ()) (any_reg ()) (any_reg ())
      | 6 -> A.sltu (reg ()) (any_reg ()) (any_reg ())
      | 7 -> A.xor (reg ()) (any_reg ()) (any_reg ())
      | 8 -> A.or_ (reg ()) (any_reg ()) (any_reg ())
      | 9 -> A.and_ (reg ()) (any_reg ()) (any_reg ())
      | 10 -> A.addi (reg ()) (any_reg ()) (imm12 ())
      | 11 -> A.slti (reg ()) (any_reg ()) (imm12 ())
      | 12 -> A.sltiu (reg ()) (any_reg ()) (imm12 ())
      | 13 -> A.xori (reg ()) (any_reg ()) (imm12 ())
      | 14 ->
        let sh = Random.State.int rng 32 in
        (match Random.State.int rng 3 with
         | 0 -> A.slli (reg ()) (any_reg ()) sh
         | 1 -> A.srli (reg ()) (any_reg ()) sh
         | _ -> A.srai (reg ()) (any_reg ()) sh)
      | 15 -> A.lui (reg ()) (Random.State.bits rng lsl 12)
      | 16 -> A.auipc (reg ()) (Random.State.bits rng lsl 12)
      | 17 ->
        (match Random.State.int rng 5 with
         | 0 -> A.lb (reg ()) top (data_off 1)
         | 1 -> A.lbu (reg ()) top (data_off 1)
         | 2 -> A.lh (reg ()) top (data_off 2)
         | 3 -> A.lhu (reg ()) top (data_off 2)
         | _ -> A.lw (reg ()) top (data_off 4))
      | 18 ->
        (match Random.State.int rng 3 with
         | 0 -> A.sb (any_reg ()) top (data_off 1)
         | 1 -> A.sh (any_reg ()) top (data_off 2)
         | _ -> A.sw (any_reg ()) top (data_off 4))
      | 19 | 20 ->
        let br = [| A.beq; A.bne; A.blt; A.bge; A.bltu; A.bgeu |] in
        br.(Random.State.int rng 6) (any_reg ()) (any_reg ()) (skip ())
      | _ -> A.jal (reg ()) (skip ()))
  in
  setup @ body @ [ A.ebreak ]
;;

let random_programs ?dual_read ?fetch_overlap ?barrel_shift ~base () =
  let nregs = Rv32_model.Isa.num_regs base in
  let rng = Random.State.make [| 2026 |] in
  let programs = 300 in
  let retired = ref 0 in
  let failures = ref 0 in
  for n = 1 to programs do
    let program = random_program rng ~nregs ~length:80 in
    let r = H.run ?dual_read ?fetch_overlap ?barrel_shift ~base program in
    retired := !retired + r.retired;
    match r.mismatch, r.trap with
    | None, Some 2 -> ()
    | m, t ->
      Int.incr failures;
      if !failures <= 2
      then
        printf
          "program %d: trap=%s %s\n"
          n
          (Option.value_map t ~default:"none" ~f:Int.to_string)
          (Option.value m ~default:"")
  done;
  printf
    "%s: %d programs, %d instructions, %d failures\n"
    (Sexp.to_string (Rv32_model.Isa.sexp_of_base base))
    programs
    !retired
    !failures
;;

let%expect_test "random programs" =
  random_programs ~base:Rv32e ();
  random_programs ~base:Rv32i ();
  random_programs ~dual_read:true ~base:Rv32i ();
  random_programs ~dual_read:true ~fetch_overlap:true ~base:Rv32i ();
  random_programs ~dual_read:true ~fetch_overlap:true ~barrel_shift:true ~base:Rv32i ();
  [%expect {|
    Rv32e: 300 programs, 31044 instructions, 0 failures
    Rv32i: 300 programs, 40739 instructions, 0 failures
    Rv32i: 300 programs, 40739 instructions, 0 failures
    Rv32i: 300 programs, 40739 instructions, 0 failures
    |}]
;;
