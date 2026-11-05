(* The core with S/U modes (issue #6, Linux L2) in lockstep with the golden
   model: random programs that start in a random privilege level and change
   delegation, interrupt enables, counter enables, Sstc, the mstatus
   trap/permission bits and the software-writable pending bits, with
   randomly timed MSI/MTI/MEI/SEI pulses and a running time. The M and S
   handlers skip a synchronous trap (xepc + 4) and disable the interrupt
   they took; EBREAK (never delegated) ends the program. *)
open! Base
open! Hardcaml
open Stdio
module A = Rv32_model.Asm
module C = Rv32_model.Asm.Csr
module H = Rv32_bench.Core_harness

let m_handler = 0x600
let s_handler = 0x700
let data = 0x800

(* x31: data pointer; x30: temporary of the generated sequences; x28, x29:
   handler temporaries; random registers are x1..x27. *)
let top = 31
let tmp = 30
let h1 = 29
let h2 = 28

(* Handlers. The M handler stops on EBREAK (cause 3) by clearing mtvec and
   executing EBREAK again (no handler: the core halts). *)
let m_handler_code =
  [ A.csrr h1 C.mcause
  ; A.blt h1 0 32 (* interrupt *)
  ; A.addi h2 0 3
  ; A.beq h1 h2 20 (* EBREAK: stop *)
  ; A.csrr h2 C.mepc
  ; A.addi h2 h2 4
  ; A.csrw C.mepc h2
  ; A.mret
  ; A.csrw C.mtvec 0 (* stop *)
  ; A.ebreak
  ; A.addi h2 0 1 (* interrupt: disable it in mie *)
  ; A.sll h2 h2 h1
  ; A.csrrc 0 C.mie h2
  ; A.mret
  ]
;;

let s_handler_code =
  [ A.csrr h1 C.scause
  ; A.blt h1 0 20
  ; A.csrr h2 C.sepc
  ; A.addi h2 h2 4
  ; A.csrw C.sepc h2
  ; A.sret
  ; A.addi h2 0 1 (* interrupt: disable it in sie *)
  ; A.sll h2 h2 h1
  ; A.csrrc 0 C.sie h2
  ; A.sret
  ]
;;

let place ~at code image =
  let n = List.length image in
  assert (4 * n <= at);
  image @ List.init ((at / 4) - n) ~f:(fun _ -> A.nop) @ code
;;

let random_program rng ~length =
  let reg () = 1 + Random.State.int rng 27 in
  let any_reg () = Random.State.int rng 28 in
  let bits () = Random.State.bits rng lor (Random.State.int rng 4 lsl 30) in
  let pick a = a.(Random.State.int rng (Array.length a)) in
  let csr_op rd csr rs = (pick [| A.csrrw; A.csrrs; A.csrrc |]) rd csr rs in
  (* Writes through x30 of a controlled value. *)
  let set_with csr v = A.li tmp v @ [ A.csrw csr tmp ] in
  let medeleg_value () =
    (* Never EBREAK (3): it ends the program in M-mode. *)
    pick [| 0; 0xb1f7 land Random.State.bits rng; 0x0300; 0xb004; 0x0004; 0xb3f7 |]
  in
  let mideleg_value () = pick [| 0; 0x222; 0x020; 0x200; 0x002; Random.State.bits rng |] in
  let mie_value () = Random.State.bits rng land 0xaaa in
  let mstatus_bits () =
    (* SIE, MIE, SUM, MXR, TVM, TW; never TSR (the S handler returns with
       SRET) *)
    pick [| 0x2; 0x8; 0xa; 1 lsl 18; 1 lsl 19; 1 lsl 20; 1 lsl 21; 0x2 lor (1 lsl 21) |]
  in
  let item () =
    match Random.State.int rng 34 with
    | 0 -> [ A.add (reg ()) (any_reg ()) (any_reg ()) ]
    | 1 -> [ A.xor (reg ()) (any_reg ()) (any_reg ()) ]
    | 2 -> [ A.addi (reg ()) (any_reg ()) (Random.State.int_incl rng (-2048) 2047) ]
    | 3 -> [ A.lw (reg ()) top (4 * Random.State.int rng 16) ]
    | 4 -> [ A.sw (any_reg ()) top (4 * Random.State.int rng 16) ]
    | 5 -> [ A.ecall ]
    | 6 -> [ A.wfi ]
    | 7 -> [ A.sfence_vma (any_reg ()) (any_reg ()) ]
    | 8 -> [ csr_op (reg ()) (pick [| C.sscratch; C.mscratch |]) (any_reg ()) ]
    | 9 ->
      [ A.csrr
          (reg ())
          (pick
             [| C.mstatus; C.sstatus; C.mie; C.sie; C.mip; C.sip; C.misa; C.medeleg; C.mideleg
              ; C.mcounteren; C.scounteren; C.menvcfgh; C.stvec; C.sepc; C.scause; C.stval
              ; C.mepc; C.mcause; C.mtval; C.satp; C.stimecmp; C.stimecmph; 0x3a0; 0x7a0
              ; 0x3f0 (* not implemented: illegal *); 0x7c0 (* custom: illegal *)
             |])
      ]
    | 10 ->
      [ A.csrr
          (reg ())
          (pick [| C.cycle; C.time; C.instret; 0xc80; C.timeh; 0xc82; 0xc03; C.mcycle |])
      ]
    | 11 -> set_with C.medeleg (medeleg_value ())
    | 12 -> set_with C.mideleg (mideleg_value ())
    | 13 -> set_with C.mie (mie_value ())
    | 14 -> set_with C.sie (mie_value ())
    | 15 -> A.li tmp (mstatus_bits ()) @ [ (pick [| A.csrrs; A.csrrc |]) 0 C.mstatus tmp ]
    | 16 -> A.li tmp (mstatus_bits ()) @ [ (pick [| A.csrrs; A.csrrc |]) 0 C.sstatus tmp ]
    | 17 -> [ (pick [| A.csrrsi; A.csrrci |]) 0 (pick [| C.mstatus; C.sstatus |]) (pick [| 2; 8; 10 |]) ]
    | 18 -> set_with C.mcounteren (Random.State.int rng 8)
    | 19 -> set_with C.scounteren (Random.State.int rng 8)
    | 20 -> set_with C.menvcfgh (pick [| 0; 1 lsl 31 |])
    | 21 ->
      (* stimecmp: soon (in time units) or far *)
      set_with C.stimecmp (Random.State.int rng 3000) @ [ A.csrw C.stimecmph 0 ]
    | 22 -> set_with C.mip (Random.State.bits rng land 0x222)
    | 23 -> set_with C.sip (Random.State.bits rng land 0x222)
    | 24 ->
      (* satp: MODE stays 0 (no MMU in the core yet) *)
      set_with C.satp (Random.State.bits rng land 0x3f_ffff)
    | 25 -> [ csr_op (reg ()) C.sepc (any_reg ()) ]
    | 26 -> [ csr_op (reg ()) C.stval (any_reg ()) ]
    | 27 -> [ csr_op (reg ()) C.scause (any_reg ()) ]
    | 28 -> [ A.csrw C.mcycle (any_reg ()) ]
    | 29 -> [ A.csrw C.minstret (any_reg ()) ]
    | 30 -> [ A.mul (reg ()) (any_reg ()) (any_reg ()) ]
    | 31 -> [ A.amoadd_w (reg ()) top (any_reg ()) ]
    | 32 -> [ A.lr_w (reg ()) top; A.sc_w (reg ()) top (any_reg ()) ]
    | _ ->
      (* any value but TSR (the S handler returns with SRET); MPP = 2 keeps
         the old MPP *)
      A.li tmp (lnot (1 lsl 22)) @ [ A.and_ tmp tmp (any_reg ()); A.csrw C.mstatus tmp ]
  in
  ignore (bits : unit -> int);
  let items = List.init length ~f:(fun _ -> item ()) in
  (* Forward branches and jumps, placed before an item, over it and up to
     three more whole items (never into a sequence). *)
  let items =
    let arr = Array.of_list items in
    List.mapi items ~f:(fun k it ->
      if Random.State.int rng 8 = 0 && k + 1 < Array.length arr
      then (
        let n = 1 + Random.State.int rng (Int.min 3 (Array.length arr - k - 1)) in
        let skip =
          4
          * (1
             + List.length it
             + List.sum (module Int) (List.range (k + 1) (k + 1 + n)) ~f:(fun j ->
               List.length arr.(j)))
        in
        (if Random.State.bool rng
         then (pick [| A.beq; A.bne; A.blt; A.bgeu |]) (any_reg ()) (any_reg ()) skip
         else A.jal (reg ()) skip)
        :: it)
      else it)
  in
  let body = List.concat items @ [ A.ebreak ] in
  let mpp = pick [| 0; 1; 3 |] in
  let setup =
    A.li top data
    @ A.li 1 m_handler
    @ [ A.csrw C.mtvec 1 ]
    @ A.li 1 s_handler
    @ [ A.csrw C.stvec 1 ]
    @ set_with C.medeleg (medeleg_value ())
    @ set_with C.mideleg (mideleg_value ())
    @ set_with C.mie (mie_value ())
    @ set_with C.mcounteren (Random.State.int rng 8)
    @ set_with C.scounteren (Random.State.int rng 8)
    @ set_with C.menvcfgh (pick [| 0; 1 lsl 31 |])
    @ set_with C.stimecmp (Random.State.int rng 3000)
    @ [ A.csrw C.stimecmph 0 ]
    @ A.li tmp ((mpp lsl 11) lor mstatus_bits ())
    @ [ A.csrw C.mstatus tmp ]
    @ List.concat_map (List.range 1 28) ~f:(fun r -> A.li r (Random.State.bits rng))
  in
  (* mepc: the body, after the setup and the 4 words below. *)
  let body_at = 4 * (List.length setup + 4) in
  let image = setup @ A.li tmp body_at @ [ A.csrw C.mepc tmp ] in
  let image = image @ [ A.mret ] @ body in
  place ~at:s_handler s_handler_code (place ~at:m_handler m_handler_code image)
;;

(* Pulses on the 4 interrupt inputs (MSI, MTI, MEI, SEI). *)
let random_irqs rng =
  let rec go t acc =
    if t > 4000
    then acc
    else (
      let len = 1 + Random.State.int rng 30 in
      go (t + len + Random.State.int rng 200) ((t, len, 1 + Random.State.int rng 15) :: acc))
  in
  let pulses = go (Random.State.int rng 100) [] in
  fun cycle ->
    List.fold pulses ~init:0 ~f:(fun acc (start, len, v) ->
      if cycle >= start && cycle < start + len then acc lor v else acc)
;;

let run_random ?dual_read ?fetch_overlap ?(programs = 300) ~seed () =
  let rng = Random.State.make [| seed |] in
  let retired = ref 0
  and failures = ref 0 in
  (* Coverage: trap and interrupt entries by (target mode, cause). *)
  let entries = Hashtbl.create (module String) in
  let trace (r : Rv32_model.Machine.retire) =
    Option.iter r.trap ~f:(fun cause ->
      let target = if r.next_pc = s_handler then "S" else "M" in
      let name =
        if cause land 0x8000_0000 <> 0
        then Printf.sprintf "%s:irq%d" target (cause land 0x1f)
        else Printf.sprintf "%s:%d" target cause
      in
      Hashtbl.incr entries name)
  in
  for n = 1 to programs do
    let program = random_program rng ~length:60 in
    let irq = random_irqs rng in
    let divider = 1 + Random.State.int rng 4 in
    let r =
      H.run
        ~trace
        ~zicsr:true
        ?dual_read
        ?fetch_overlap
        ~m:true
        ~a:true
        ~s:true
        ~irq
        ~time:(fun c -> c / divider)
        ~base:Rv32i
        ~mem_bytes:4096
        ~max_cycles:200_000
        program
    in
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
  printf "%d programs, %d instructions, %d failures\n" programs !retired !failures;
  (* Present or absent, not counts: the counts change with any timing
     change, the coverage should not. *)
  printf
    "entries: %s\n"
    (Hashtbl.keys entries |> List.sort ~compare:String.compare |> String.concat ~sep:" ")
;;

let%expect_test "S/U modes: random programs in lockstep" =
  run_random ~seed:1 ();
  run_random ~dual_read:true ~fetch_overlap:true ~seed:2 ();
  [%expect {|
    300 programs, 43600 instructions, 0 failures
    entries: M:11 M:2 M:3 M:8 M:9 M:irq11 M:irq3 M:irq5 M:irq7 M:irq9 S:2 S:8 S:9 S:irq1 S:irq5 S:irq9
    300 programs, 45195 instructions, 0 failures
    entries: M:11 M:2 M:3 M:8 M:9 M:irq1 M:irq11 M:irq3 M:irq5 M:irq7 M:irq9 S:2 S:8 S:9 S:irq5 S:irq9
    |}]
;;


(* Negative test: the checker must notice when the core sees an SEIP pulse
   the checker is not told about. *)
let%expect_test "lockstep detects a hidden SEIP" =
  let rng = Random.State.make [| 7 |] in
  let detected = ref 0 in
  for _ = 1 to 100 do
    let program = random_program rng ~length:60 in
    let irq = random_irqs rng in
    let r =
      H.run
        ~zicsr:true
        ~m:true
        ~a:true
        ~s:true
        ~irq:(fun c -> irq c lor 8)
        ~checker_irq:(fun c -> irq c land 7)
        ~base:Rv32i
        ~mem_bytes:4096
        ~max_cycles:200_000
        program
    in
    if Option.is_some r.mismatch then Int.incr detected
  done;
  printf "detected in %d of 100 programs\n" !detected;
  [%expect {| detected in 34 of 100 programs |}]
;;

(* Verilog generation (port names, reserved words) is otherwise first
   exercised by the board flows; check the S configuration here. *)
let%expect_test "the S configuration prints as Verilog" =
  let module Circ = Circuit.With_interface (Rv32.Core.I) (Rv32.Core.O) in
  let scope = Scope.create ~flatten_design:true () in
  let circuit =
    Circ.create_exn
      ~name:"rv32_core"
      (Rv32.Core.create
         ~s:true
         ~m:true
         ~a:true
         ~zifencei:true
         ~dual_read:true
         ~fetch_overlap:true
         ~base:Rv32i
         scope)
  in
  let buffer = Buffer.create 100_000 in
  Rtl.output ~output_mode:(To_buffer buffer) Verilog circuit;
  printf "ok: %b\n" (Buffer.length buffer > 0);
  [%expect {| ok: true |}]
;;
