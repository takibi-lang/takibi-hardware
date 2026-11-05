(* Sv32 in the core (issue #6, Linux L3) in lockstep with the golden model:
   random programs under random page tables. The image (32 KiB at 0) holds
   the page tables, so every program has its own mappings:

     PA 0x0000  setup (M) and the M handler at 0x600
     PA 0x1000  S handler          VA 0x1000, R X, not U
     PA 0x2000  the body           VA 0x2000, R X, U if the body runs in U
     PA 0x3000  root table         satp
     PA 0x4000  level-0 table      also VA 0x18000 (R W, not U): the body
                                   rewrites data PTEs there (+ SFENCE.VMA)
     PA 0x5000..0x7fff  data       VA 0x10000..0x17fff with random
                                   permissions, and a 4 MiB superpage at VA
                                   0x400000 (= PA 0)

   Faulting mappings: VA 0x800000 (misaligned superpage), 0xc00000 (invalid
   root entry), 0x1a000 (invalid level-0 entry), 0x19000 (a level-0 entry
   that is a pointer). A body in M has MPRV set, so its data accesses are
   translated (with MPP = U or S). The handlers skip a faulting
   instruction, return to x1 after an instruction page fault (the body
   jumps to bad addresses with JALR x1) and disable an interrupt they
   take; EBREAK ends the program. *)
open! Base
open! Hardcaml
open Stdio
module A = Rv32_model.Asm
module C = Rv32_model.Asm.Csr
module H = Rv32_bench.Core_harness

let mem_bytes = 0x8000
let m_handler = 0x600
let s_handler = 0x1000
let body_at = 0x2000
let root = 0x3000
let l0 = 0x4000
let window = 0x18000

(* x30, x27: temporaries of generated sequences; x28, x29: S handler;
   x25, x26: M handler (it can interrupt the S handler); x1: link for
   JALR to bad addresses; random registers x2..x24. *)
let tmp = 30
let tmp2 = 27
let h1 = 29
let h2 = 28
let m1 = 26
let m2 = 25

let v = 1
let r = 2
let w = 4
let x = 8
let u = 16
let a_ = 64
let d = 128
let pte ~pa flags = ((pa lsr 12) lsl 10) lor flags

let m_handler_code =
  [ A.csrr m1 C.mcause
  ; A.blt m1 0 52 (* interrupt *)
  ; A.addi m2 0 3
  ; A.beq m1 m2 36 (* EBREAK: stop *)
  ; A.addi m2 0 12
  ; A.beq m1 m2 20 (* instruction page fault: return to x1 *)
  ; A.csrr m2 C.mepc
  ; A.addi m2 m2 4
  ; A.csrw C.mepc m2
  ; A.mret
  ; A.csrw C.mepc 1
  ; A.mret
  ; A.csrw C.mtvec 0 (* stop *)
  ; A.ebreak
  ; A.addi m2 0 1
  ; A.sll m2 m2 m1
  ; A.csrrc 0 C.mie m2
  ; A.mret
  ]
;;

let s_handler_code =
  [ A.csrr h1 C.scause
  ; A.blt h1 0 36
  ; A.addi h2 0 12
  ; A.beq h1 h2 20
  ; A.csrr h2 C.sepc
  ; A.addi h2 h2 4
  ; A.csrw C.sepc h2
  ; A.sret
  ; A.csrw C.sepc 1
  ; A.sret
  ; A.addi h2 0 1
  ; A.sll h2 h2 h1
  ; A.csrrc 0 C.sie h2
  ; A.sret
  ]
;;

let random_data_pte rng =
  let pick a = a.(Random.State.int rng (Array.length a)) in
  let pa = pick [| 0x5000; 0x6000; 0x7000 |] in
  let flags =
    pick
      [| v lor r lor w lor a_ lor d
       ; v lor r lor w lor a_ lor d lor u
       ; v lor r lor a_
       ; v lor r lor a_ lor u
       ; v lor x lor a_ (* execute only: MXR *)
       ; v lor x lor a_ lor u
       ; v lor r lor w lor a_ (* D clear: a store faults *)
       ; v lor r lor w lor d (* A clear *)
       ; v lor w lor a_ lor d (* W without R: invalid *)
       ; 0
       ; v lor r lor w lor x lor a_ lor d lor u
       ; Random.State.int rng 256 lor v
      |]
  in
  pte ~pa flags
;;

let random_program rng ~length =
  let pick a = a.(Random.State.int rng (Array.length a)) in
  let mpp = pick [| 0; 1; 3 |] in
  let reg () = 2 + Random.State.int rng 23 in
  let any_reg () = Random.State.int rng 25 in
  let image = Array.create ~len:(mem_bytes / 4) 0 in
  let put at words = List.iteri words ~f:(fun k wd -> image.((at / 4) + k) <- wd) in
  (* Page tables. *)
  put (root + (4 * 0)) [ pte ~pa:l0 v ];
  put (root + (4 * 1)) [ pte ~pa:0 (pick [| v lor r lor w lor a_ lor d; v lor r lor w lor a_ lor d lor u; v lor r lor a_ |]) ];
  put (root + (4 * 2)) [ pte ~pa:0x5000 (v lor r lor w lor a_ lor d) ];
  put (l0 + (4 * 1)) [ pte ~pa:s_handler (v lor r lor x lor a_) ];
  put (l0 + (4 * 2)) [ pte ~pa:body_at (v lor r lor x lor a_ lor if mpp = 0 then u else 0) ];
  for vpn = 0x10 to 0x17 do
    put (l0 + (4 * vpn)) [ random_data_pte rng ]
  done;
  put (l0 + (4 * 0x18)) [ pte ~pa:l0 (v lor r lor w lor a_ lor d) ];
  put (l0 + (4 * 0x19)) [ pte ~pa:0x5000 v ];
  for k = 0x5000 / 4 to (0x8000 / 4) - 1 do
    image.(k) <- Random.State.bits rng
  done;
  (* Data addresses, word aligned. *)
  let data_va () =
    let off = 4 * Random.State.int rng 1024 in
    pick
      [| 0x10000 + (0x1000 * Random.State.int rng 8) + off
       ; 0x10000 + (0x1000 * Random.State.int rng 8) + off
       ; 0x400000 + 0x5000 + (Random.State.int rng 0x3000 land lnot 3)
       ; 0x800000 + off
       ; 0xc00000 + off
       ; 0x1a000 + off
       ; 0x19000 + off
       ; window + off
       ; 0x2000 + off (* the code page: R, not W *)
      |]
  in
  let mem_op () =
    let va = data_va () in
    let rd = reg () in
    A.li tmp va
    @ [ (match Random.State.int rng 9 with
         | 0 | 1 -> A.lw rd tmp 0
         | 2 -> A.lbu rd tmp (Random.State.int rng 4)
         | 3 | 4 -> A.sw (any_reg ()) tmp 0
         | 5 -> A.sb (any_reg ()) tmp (Random.State.int rng 4)
         | 6 -> A.lr_w rd tmp
         | 7 -> A.sc_w rd tmp (any_reg ())
         | _ -> A.amoadd_w rd tmp (any_reg ()))
      ]
  in
  let item () =
    match Random.State.int rng 14 with
    | 0 | 1 | 2 | 3 | 4 -> mem_op ()
    | 5 -> [ A.add (reg ()) (any_reg ()) (any_reg ()) ]
    | 6 ->
      (* rewrite a data PTE through the window, then SFENCE.VMA *)
      A.li tmp (window + (4 * (0x10 + Random.State.int rng 8)))
      @ A.li tmp2 (random_data_pte rng)
      @ [ A.sw tmp2 tmp 0; A.sfence_vma 0 0 ]
    | 7 ->
      (* SUM (18), MXR (19) *)
      A.li tmp (pick [| 1 lsl 18; 1 lsl 19 |])
      @ [ (pick [| A.csrrs; A.csrrc |]) 0 (pick [| C.mstatus; C.sstatus |]) tmp ]
    | 8 ->
      (* MPP U or S (matters with MPRV, in M) *)
      A.li tmp (1 lsl 11) @ [ (pick [| A.csrrs; A.csrrc |]) 0 C.mstatus tmp ]
    | 9 -> [ A.sfence_vma (pick [| 0; tmp |]) 0 ]
    | 10 when mpp <> 3 ->
      (* jump to an address that cannot be executed *)
      (* (not the data pages: they may be executable) *)
      A.li tmp (pick [| 0x800000; 0xc00000; 0x1a000; 0x19000; window |])
      @ [ A.jalr 1 tmp 0 ]
    | 11 -> [ A.csrr (reg ()) (pick [| C.satp; C.stval; C.mtval; C.scause; C.mcause |]) ]
    | 12 -> [ A.ecall ]
    | _ -> [ A.lw (reg ()) 0 0 ] (* VA 0: unmapped below M *)
  in
  let body = List.concat (List.init length ~f:(fun _ -> item ())) @ [ A.ebreak ] in
  let set_with csr value = A.li tmp value @ [ A.csrw csr tmp ] in
  let medeleg =
    List.fold [ 0x0004; 0x0100; 0x0200; 0x1000; 0x2000; 0x8000 ] ~init:0 ~f:(fun acc b ->
      if Random.State.bool rng then acc lor b else acc)
  in
  let setup =
    A.li 2 m_handler
    @ [ A.csrw C.mtvec 2 ]
    @ A.li 2 s_handler
    @ [ A.csrw C.stvec 2 ]
    @ set_with C.medeleg medeleg
    @ set_with C.mideleg (pick [| 0; 0x222 |])
    @ set_with C.mie (Random.State.bits rng land 0xaaa)
    @ set_with C.satp (0x8000_0000 lor (root lsr 12))
    @ set_with
        C.mstatus
        ((mpp lsl 11)
         lor (1 lsl 17)
         lor (if Random.State.bool rng then 1 lsl 18 else 0)
         lor (if Random.State.bool rng then 1 lsl 19 else 0)
         (* SIE and MPIE (MIE after the MRET): an interrupt during the
            setup would overwrite mepc *)
         lor pick [| 0; 2; 0x80; 0x82 |])
    @ set_with C.mepc body_at
    @ List.concat_map (List.range 2 25) ~f:(fun rg -> A.li rg (Random.State.bits rng))
    @ [ A.mret ]
  in
  assert (4 * List.length setup <= m_handler);
  assert (4 * List.length body <= 0x1000);
  put 0 setup;
  put m_handler m_handler_code;
  put s_handler s_handler_code;
  put body_at body;
  Array.to_list image
;;

let random_irqs rng =
  let rec go t acc =
    if t > 3000
    then acc
    else (
      let len = 1 + Random.State.int rng 30 in
      go (t + len + Random.State.int rng 400) ((t, len, 1 + Random.State.int rng 15) :: acc))
  in
  let pulses = go (Random.State.int rng 300) [] in
  fun cycle ->
    List.fold pulses ~init:0 ~f:(fun acc (start, len, v) ->
      if cycle >= start && cycle < start + len then acc lor v else acc)
;;

let run_random ?(wait_states = false) ?dual_read ?fetch_overlap ?tlb_entries ?(programs = 100) ~seed () =
  let rng = Random.State.make [| seed |] in
  let retired = ref 0
  and failures = ref 0 in
  let entries = Hashtbl.create (module String) in
  let recent = Queue.create () in
  let trace (rt : Rv32_model.Machine.retire) =
    if Queue.length recent < 100000 then Queue.enqueue recent rt;
    Option.iter rt.trap ~f:(fun cause ->
      let target = if rt.next_pc = s_handler then "S" else "M" in
      if cause land 0x8000_0000 = 0 then Hashtbl.incr entries (Printf.sprintf "%s:%d" target cause))
  in
  for n = 1 to programs do
    Queue.clear recent;
    let program = random_program rng ~length:50 in
    let irq = random_irqs rng in
    let sim =
      H.create_sim
        ~zicsr:true
        ?dual_read
        ?fetch_overlap
        ~m:true
        ~a:true
        ~s:true
        ?tlb_entries
        ~reset_pc:0
        ~base:Rv32i
        ()
    in
    let res =
      H.run
        ~sim
        ~trace
        ~zicsr:true
        ~m:true
        ~a:true
        ~s:true
        ?wait_states:(if wait_states then Some (Random.State.make [| n |]) else None)
        ~irq
        ~time:(fun c -> c / 3)
        ~base:Rv32i
        ~mem_bytes
        ~max_cycles:100_000
        program
    in
    retired := !retired + res.retired;
    match res.mismatch, res.trap with
    | None, Some 2 -> ()
    | m, t ->
      Int.incr failures;
      if !failures <= 2
      then (
        printf
          "program %d: trap=%s %s\n"
          n
          (Option.value_map t ~default:"none" ~f:Int.to_string)
          (Option.value m ~default:"");
        let all = Queue.to_list recent in
        let first =
          Option.value ~default:0
            (List.findi all ~f:(fun _ (rt : Rv32_model.Machine.retire) -> Option.equal Int.equal rt.trap (Some 12))
             |> Option.map ~f:fst)
        in
        List.iteri all ~f:(fun k (rt : Rv32_model.Machine.retire) -> if k >= first - 12 && k <= first then
          printf
            "  pc=%x insn=%08x next=%x%s\n"
            rt.pc
            rt.insn
            rt.next_pc
            (Option.value_map rt.trap ~default:"" ~f:(Printf.sprintf " trap=%x"))))
  done;
  printf "%d programs, %d instructions, %d failures\n" programs !retired !failures;
  printf
    "entries: %s\n"
    (Hashtbl.keys entries |> List.sort ~compare:String.compare |> String.concat ~sep:" ")
;;

let%expect_test "Sv32: random programs under random page tables, in lockstep" =
  run_random ~seed:1 ();
  run_random ~dual_read:true ~fetch_overlap:true ~seed:2 ();
  run_random ~dual_read:true ~fetch_overlap:true ~tlb_entries:2 ~seed:3 ();
  (* memory with random wait states (#26) *)
  run_random ~wait_states:true ~dual_read:true ~fetch_overlap:true ~seed:4 ();
  [%expect {|
    100 programs, 53587 instructions, 0 failures
    entries: M:11 M:12 M:13 M:15 M:2 M:3 M:8 M:9 S:12 S:13 S:15 S:2 S:8 S:9
    100 programs, 52679 instructions, 0 failures
    entries: M:11 M:12 M:13 M:15 M:2 M:3 M:8 M:9 S:12 S:13 S:15 S:2 S:8 S:9
    100 programs, 53714 instructions, 0 failures
    entries: M:11 M:12 M:13 M:15 M:2 M:3 M:8 M:9 S:12 S:13 S:15 S:2 S:8 S:9
    100 programs, 53713 instructions, 0 failures
    entries: M:11 M:12 M:13 M:15 M:2 M:3 M:8 M:9 S:12 S:13 S:15 S:2 S:8 S:9
    |}]
;;
