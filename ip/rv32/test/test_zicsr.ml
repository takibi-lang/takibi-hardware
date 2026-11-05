(* The Zicsr core (issue #3) in lockstep with the golden model: CSR
   semantics, trap entry and MRET, interrupts, and random programs with
   CSR accesses and randomly timed interrupts. *)
open! Base
open! Hardcaml
open Stdio
module A = Rv32_model.Asm
module C = Rv32_model.Asm.Csr
module H = Rv32_bench.Core_harness

let show (r : H.result) =
  printf
    "retired=%d%s trap=%s%s\n"
    r.retired
    (if r.interrupts > 0 then Printf.sprintf " interrupts=%d" r.interrupts else "")
    (Option.value_map r.trap ~default:"none" ~f:Int.to_string)
    (Option.value_map r.mismatch ~default:"" ~f:(fun m -> "\n" ^ m))
;;

let run ?irq ?(base = Rv32_model.Isa.Rv32e) program =
  show (H.run ~zicsr:true ?irq ~base program)
;;

(* [program] at 0, [handler] at [handler_at], padded with NOPs. *)
let with_handler ?(handler_at = 0x400) program handler =
  let n = List.length program in
  assert (4 * n <= handler_at);
  program @ List.init ((handler_at / 4) - n) ~f:(fun _ -> A.nop) @ handler
;;

let%expect_test "CSR read, write, set, clear" =
  run
    ([ A.addi 1 0 0x5a5
     ; A.csrrw 2 C.mscratch 1
     ; A.csrrs 3 C.mscratch 0
     ; A.csrrsi 4 C.mscratch 0b1010
     ; A.csrrci 5 C.mscratch 0b0101
     ; A.csrrc 6 C.mscratch 1
     ; A.csrr 7 C.mscratch
     ; A.addi 1 0 (-1)
     ; A.csrw C.mtvec 1 (* bits 1..0 read as 0 *)
     ; A.csrr 8 C.mtvec
     ; A.csrw C.mie 1 (* only 3, 7, 11 stick *)
     ; A.csrr 9 C.mie
     ; A.csrw C.mcause 1
     ; A.csrr 10 C.mcause
     ; A.csrr 11 C.mstatus
     ; A.csrr 12 C.misa
     ; A.csrr 13 C.mhartid
     ; A.csrr 14 C.mcycle
     ; A.csrr 15 C.minstret
     ; A.csrw C.mtvec 0
     ; A.ebreak
     ]);
  [%expect {| retired=20 trap=2 |}]
;;

let%expect_test "illegal CSR accesses halt without a handler" =
  List.iter
    [ [ A.csrr 1 0x7c0 ] (* no such CSR *)
    ; [ A.csrw C.cycle 1 ] (* read-only *)
    ; [ A.csrrsi 1 C.mhartid 1 ]
    ; [ A.csrr 1 C.cycle; A.csrrs 2 C.mhartid 0; A.ebreak ] (* reads are fine *)
    ]
    ~f:run;
  [%expect {|
    retired=0 trap=3
    retired=0 trap=3
    retired=0 trap=3
    retired=2 trap=2
    |}]
;;

let%expect_test "without Zicsr, CSR instructions are illegal" =
  show (H.run [ A.csrr 1 C.mscratch ]);
  [%expect {| retired=0 trap=3 |}]
;;

(* Handler: record mcause/mepc/mtval, skip the faulting instruction, return;
   EBREAK clears mtvec and stops. *)
let skip_handler =
  [ A.csrr 10 C.mcause
  ; A.csrr 11 C.mepc
  ; A.csrr 12 C.mtval
  ; A.addi 13 0 3
  ; A.bne 10 13 12
  ; A.csrw C.mtvec 0
  ; A.ebreak
  ; A.addi 11 11 4
  ; A.csrw C.mepc 11
  ; A.mret
  ]
;;

let%expect_test "synchronous traps enter the handler, MRET returns" =
  run
    (with_handler
       ([ A.addi 1 0 0x400; A.csrw C.mtvec 1; A.csrrsi 0 C.mstatus 8 ]
        @ [ A.ecall
          ; 0 (* illegal *)
          ; A.csrr 2 0x7c0
          ; A.lw 2 0 2
          ; A.sh 2 0 1
          ; A.jal 0 6
          ; A.csrr 3 C.mstatus (* MIE restored by MRET *)
          ; A.ebreak
          ])
       skip_handler);
  [%expect {| retired=65 trap=2 |}]
;;

(* A counter loop with interrupts enabled; the handler counts in x5. *)
let irq_program ~mie_bits =
  with_handler
    ([ A.addi 1 0 0x400
     ; A.csrw C.mtvec 1
     ]
     @ A.li 1 mie_bits
     @ [ A.csrw C.mie 1
     ; A.csrrsi 0 C.mstatus 8
     ; A.addi 2 0 200
     ; A.addi 2 2 (-1)
     ; A.bne 2 0 (-4)
       ; A.csrw C.mtvec 0
       ; A.ebreak
       ])
    [ A.addi 5 5 1; A.csrr 6 C.mcause; A.csrr 7 C.mip; A.mret ]
;;

let pulses l cycle =
  List.fold l ~init:0 ~f:(fun acc (start, len, bits) ->
    if cycle >= start && cycle < start + len then acc lor bits else acc)
;;

let%expect_test "interrupts: each source, priority, masking" =
  (* timer; software; external; all three at once (external first);
     timer while masked in mie (never taken) *)
  run ~irq:(pulses [ 100, 3, 2 ]) (irq_program ~mie_bits:0x888);
  run ~irq:(pulses [ 100, 3, 1 ]) (irq_program ~mie_bits:0x888);
  run ~irq:(pulses [ 100, 3, 4 ]) (irq_program ~mie_bits:0x888);
  run ~irq:(pulses [ 100, 40, 7 ]) (irq_program ~mie_bits:0x888);
  run ~irq:(pulses [ 100, 40, 2 ]) (irq_program ~mie_bits:0x808);
  let fast ~irq p =
    show (H.run ~zicsr:true ~dual_read:true ~fetch_overlap:true ~irq ~base:Rv32i p)
  in
  fast ~irq:(pulses [ 100, 3, 2 ]) (irq_program ~mie_bits:0x888);
  fast ~irq:(pulses [ 100, 40, 7 ]) (irq_program ~mie_bits:0x888);
  fast ~irq:(pulses [ 100, 40, 2 ]) (irq_program ~mie_bits:0x808);
  [%expect {|
    retired=413 interrupts=1 trap=2
    retired=413 interrupts=1 trap=2
    retired=413 interrupts=1 trap=2
    retired=423 interrupts=3 trap=2
    retired=408 trap=2
    retired=413 interrupts=1 trap=2
    retired=428 interrupts=4 trap=2
    retired=408 trap=2
    |}]
;;

(* The checker must catch a missed interrupt and a wrong priority. *)
let%expect_test "lockstep catches interrupt mistakes" =
  let p = irq_program ~mie_bits:0x888 in
  let first_line (r : H.result) =
    print_endline
      (Option.value_map r.mismatch ~default:"no mismatch" ~f:(fun m ->
         List.hd_exn (String.split_lines m)))
  in
  first_line (H.run ~zicsr:true ~checker_irq:(pulses [ 100, 3, 2 ]) p);
  first_line (H.run ~zicsr:true ~irq:(pulses [ 100, 3, 2 ]) ~checker_irq:(pulses [ 100, 3, 6 ]) p);
  [%expect {|
    retire #25: core missed interrupt 7
    retire #25: core took interrupt 7, expected 11
    |}]
;;

(* Random programs: arithmetic, loads/stores, forward branches, CSR
   accesses (mscratch, mie, the MIE bit, counters, mip) and randomly timed
   interrupts of all three kinds. The handler returns from interrupts and
   stops on the final EBREAK. *)
let random_program ?(ma = false) rng ~nregs ~length =
  let top = nregs - 1 in
  let reg () = 1 + Random.State.int rng (top - 2) in
  let any_reg () = Random.State.int rng top in
  let imm12 () = Random.State.int_incl rng (-2048) 2047 in
  let data_off size = size * Random.State.int rng (64 / size) in
  let setup =
    A.li top 0x800
    @ A.li 1 0x400
    @ [ A.csrw C.mtvec 1 ]
    @ A.li 1 (Random.State.int rng 0x1000)
    @ [ A.csrw C.mie 1; A.csrrsi 0 C.mstatus 8 ]
    @ List.concat_map (List.range 1 (top - 1)) ~f:(fun r -> A.li r (Random.State.bits rng))
  in
  let body =
    List.init length ~f:(fun k ->
      let remaining = length - k in
      let skip () = 4 * (1 + Random.State.int rng (Int.min 3 remaining)) in
      match Random.State.int rng (if ma then 26 else 16) with
      | 0 -> A.add (reg ()) (any_reg ()) (any_reg ())
      | 1 -> A.sub (reg ()) (any_reg ()) (any_reg ())
      | 2 -> A.xor (reg ()) (any_reg ()) (any_reg ())
      | 3 -> A.addi (reg ()) (any_reg ()) (imm12 ())
      | 4 -> A.lw (reg ()) top (data_off 4)
      | 5 -> A.sw (any_reg ()) top (data_off 4)
      | 6 -> A.lbu (reg ()) top (data_off 1)
      | 7 ->
        let br = [| A.beq; A.bne; A.blt; A.bgeu |] in
        br.(Random.State.int rng 4) (any_reg ()) (any_reg ()) (skip ())
      | 8 -> A.csrrw (reg ()) C.mscratch (any_reg ())
      | 9 -> A.csrrs (reg ()) C.mscratch (any_reg ())
      | 10 -> A.csrrc (reg ()) C.mscratch (any_reg ())
      | 11 -> A.csrrw (reg ()) C.mie (any_reg ())
      | 12 -> if Random.State.bool rng then A.csrrsi 0 C.mstatus 8 else A.csrrci 0 C.mstatus 8
      | 13 -> A.csrr (reg ()) [| C.mcycle; C.minstret; C.cycle; 0xb80 |].(Random.State.int rng 4)
      | 14 -> A.csrr (reg ()) C.mip
      | 15 -> A.jal (reg ()) (skip ())
      (* M and A ([ma]); atomics address the data region at x[top]. *)
      | 16 ->
        [| A.mul; A.mulh; A.mulhsu; A.mulhu |].(Random.State.int rng 4)
          (reg ())
          (any_reg ())
          (any_reg ())
      | 17 | 18 ->
        [| A.div; A.divu; A.rem; A.remu |].(Random.State.int rng 4)
          (reg ())
          (any_reg ())
          (any_reg ())
      | 19 -> A.div (reg ()) (any_reg ()) 0 (* division by zero *)
      | 20 | 21 -> A.lr_w (reg ()) top
      | 22 | 23 -> A.sc_w (reg ()) top (any_reg ())
      | _ ->
        [| A.amoswap_w; A.amoadd_w; A.amoxor_w; A.amoand_w; A.amoor_w; A.amomin_w; A.amomax_w
         ; A.amominu_w; A.amomaxu_w
        |].(Random.State.int rng 9)
          (reg ())
          top
          (any_reg ()))
  in
  let handler =
    [ A.csrr (top - 1) C.mcause
    ; A.blt (top - 1) 0 12
    ; A.csrw C.mtvec 0
    ; A.ebreak
    ; A.mret
    ]
  in
  with_handler (setup @ body @ [ A.ebreak ]) handler
;;

let random_irqs rng =
  let rec go t acc =
    if t > 3000
    then acc
    else (
      let len = 1 + Random.State.int rng 30 in
      go (t + len + Random.State.int rng 150) ((t, len, 1 + Random.State.int rng 7) :: acc))
  in
  pulses (go (Random.State.int rng 100) [])
;;

let random_programs ?(wait_states = false) ?dual_read ?fetch_overlap ?(ma = false) ~base () =
  let nregs = Rv32_model.Isa.num_regs base in
  let rng = Random.State.make [| 3 |] in
  let programs = 300 in
  let retired = ref 0 in
  let failures = ref 0 in
  let interrupts = ref 0 in
  for n = 1 to programs do
    let program = random_program ~ma rng ~nregs ~length:80 in
    let r =
      H.run
        ~zicsr:true
        ?dual_read
        ?fetch_overlap
        ~m:ma
        ~a:ma
        ?wait_states:(if wait_states then Some (Random.State.make [| n |]) else None)
        ~irq:(random_irqs rng)
        ~base
        program
    in
    retired := !retired + r.retired;
    interrupts := !interrupts + r.interrupts;
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
    "%s: %d programs, %d instructions, %d interrupts, %d failures\n"
    (Sexp.to_string (Rv32_model.Isa.sexp_of_base base))
    programs
    !retired
    !interrupts
    !failures
;;

let%expect_test "random programs with CSRs and interrupts" =
  random_programs ~base:Rv32e ();
  random_programs ~base:Rv32i ();
  random_programs ~dual_read:true ~base:Rv32i ();
  random_programs ~dual_read:true ~fetch_overlap:true ~base:Rv32i ();
  random_programs ~dual_read:true ~fetch_overlap:true ~ma:true ~base:Rv32i ();
  random_programs ~wait_states:true ~base:Rv32e ();
  random_programs ~wait_states:true ~dual_read:true ~fetch_overlap:true ~ma:true ~base:Rv32i ();
  [%expect {|
    Rv32e: 300 programs, 37701 instructions, 1014 interrupts, 0 failures
    Rv32i: 300 programs, 49918 instructions, 1682 interrupts, 0 failures
    Rv32i: 300 programs, 49569 instructions, 1594 interrupts, 0 failures
    Rv32i: 300 programs, 48529 instructions, 1335 interrupts, 0 failures
    Rv32i: 300 programs, 50415 instructions, 1617 interrupts, 0 failures
    Rv32e: 300 programs, 38497 instructions, 1212 interrupts, 0 failures
    Rv32i: 300 programs, 51540 instructions, 1900 interrupts, 0 failures
    |}]
;;
