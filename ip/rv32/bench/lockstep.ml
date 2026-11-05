(* Lockstep checking: every instruction the core retires is compared with
   the golden model executing the same instruction.

   Memory-mapped I/O loads cannot be predicted by the model (a UART status
   register depends on timing), so the model's I/O loads return whatever
   the core loaded; everything else must match exactly.

   With Zicsr (issue #3): mip and the counters come from the hardware, so
   the model reads the core's values at the retiring instruction; an
   interrupt is injected into the model where the core took it (a retire
   record with [retire_trap] and mcause bit 31).

   With S-mode (issue #6): the core's SEIP input and the CLINT time come
   from the bench too ([irq] bit 3 is SEIP); which interrupt the core must
   take at a boundary is the model's [pending_interrupt], given the inputs
   of the cycle where the core decided. *)
open! Base
open! Hardcaml
module Machine = Rv32_model.Machine

type t =
  { model : Machine.t
  ; mutable io_load_value : int
  ; mutable mip : int
  ; mutable time : int
  ; mutable mcycle : int
  ; mutable minstret : int
  ; mutable retired : int
  ; mutable interrupts : int
  ; mutable mismatch : string option
  }

let csr_input t csr =
  let lo v = v land 0xffff_ffff
  and hi v = (v lsr 32) land 0xffff_ffff in
  match csr with
  | 0x344 -> t.mip
  | 0xc01 -> lo t.time
  | 0xc81 -> hi t.time
  | 0xb00 | 0xc00 -> lo t.mcycle
  | 0xb80 | 0xc80 -> hi t.mcycle
  | 0xb02 | 0xc02 -> lo t.minstret
  | 0xb82 | 0xc82 -> hi t.minstret
  | _ -> 0
;;

let create
  ?(is_io = fun _ -> false)
  ?(zicsr = false)
  ?(m = false)
  ?(a = false)
  ?(s = false)
  ?(mem_base = 0)
  ~base
  ~mem_bytes
  ~program
  ()
  =
  let rec t =
    lazy
      { model =
          Machine.create
            ~io:
              { is_io
              ; load = (fun ~addr:_ ~bytes -> (force t).io_load_value land ((1 lsl (8 * bytes)) - 1))
              ; store = (fun ~addr:_ ~bytes:_ ~value:_ -> ())
              }
            ~zicsr
            ~m
            ~a
            ~zifencei:(m || a)
            ~s
            ~mem_base
            ~csr_input:(fun csr -> csr_input (force t) csr)
            ~base
            ~mem_bytes
            ()
      ; io_load_value = 0
      ; mip = 0
      ; time = 0
      ; mcycle = 0
      ; minstret = 0
      ; retired = 0
      ; interrupts = 0
      ; mismatch = None
      }
  in
  let t = force t in
  Machine.load_program t.model program;
  t
;;

let trap_code : Machine.trap -> int = function
  | Ecall -> Rv32.Core.Trap.ecall
  | Ebreak -> Rv32.Core.Trap.ebreak
  | Illegal_instruction _ -> Rv32.Core.Trap.illegal
  | Misaligned_fetch _ -> Rv32.Core.Trap.misaligned_fetch
  | Misaligned_access _ -> Rv32.Core.Trap.misaligned_access
  | Page_fault _ -> Rv32.Core.Trap.page_fault
  | Access_fault _ -> -1
;;

(* The core's retire outputs, in the model's terms. *)
let of_core (o : Bits.t ref Rv32.Core.O.t) : Machine.retire =
  let u r = Bits.to_int !r in
  let mem_write =
    if Bits.to_bool !(o.retire_mem_we)
    then (
      let bytes = 1 lsl u o.retire_mem_size in
      Some (u o.retire_mem_addr, bytes, u o.retire_mem_value land ((1 lsl (8 * bytes)) - 1)))
    else None
  in
  { pc = u o.retire_pc
  ; insn = u o.retire_insn
  ; rd_write =
      (if Bits.to_bool !(o.retire_rd_we)
       then Some (u o.retire_rd, u o.retire_rd_value)
       else None)
  ; mem_write
  ; next_pc = u o.retire_next_pc
  ; trap = (if Bits.to_bool !(o.retire_trap) then Some (u o.retire_cause) else None)
  }
;;

let fail t msg = if Option.is_none t.mismatch then t.mismatch <- Some msg

let show r = Sexp.to_string_hum (Machine.sexp_of_retire r)

(* mip as the CSR shows it, from the core's interrupt inputs: [irq] bits
   0..2 are MSIP, MTIP, MEIP; bit 3 is SEIP (S-mode). *)
let mip_of_irq irq =
  ((irq land 1) lsl 3)
  lor (((irq lsr 1) land 1) lsl 7)
  lor (((irq lsr 2) land 1) lsl 11)
  lor (((irq lsr 3) land 1) lsl 9)
;;

(* The interrupt the model would take at this boundary with [irq] pending
   and [time]: the model's choice, if the target mode's vector is set. *)
let expected_interrupt t ~irq ~time =
  t.mip <- mip_of_irq irq;
  t.time <- time;
  match Machine.pending_interrupt t.model with
  | Some code when Machine.trap_vector t.model ~cause:(0x8000_0000 lor code) <> 0 -> Some code
  | _ -> None
;;

(* Call in a cycle where the core's [retire] output is high; [irq] is the
   core's irq input in that cycle and [irq_fetch] the one in the Fetch
   cycle that started this instruction (where an interrupt would have been
   taken instead). *)
let on_retire ?(irq = 0) ?(irq_fetch = 0) ?(time = 0) ?(time_fetch = 0) t (o : Bits.t ref Rv32.Core.O.t) =
  let core = of_core o in
  (match core.trap, expected_interrupt t ~irq:irq_fetch ~time:time_fetch with
   | Some cause, expected when cause land 0x8000_0000 <> 0 ->
     if not (Option.equal Int.equal expected (Some (cause land 0x1f)))
     then
       fail
         t
         (Printf.sprintf
            "retire #%d: core took interrupt %d, expected %s"
            t.retired
            (cause land 0x1f)
            (Option.value_map expected ~default:"none" ~f:Int.to_string))
   | _, Some code ->
     fail t (Printf.sprintf "retire #%d: core missed interrupt %d" t.retired code)
   | _, None -> ());
  Option.iter core.rd_write ~f:(fun (_, v) -> t.io_load_value <- v);
  t.mip <- mip_of_irq irq;
  t.time <- time;
  t.mcycle <- Bits.to_int !(o.csr_mcycle);
  t.minstret <- Bits.to_int !(o.csr_minstret);
  let stepped =
    match core.trap with
    | Some cause when cause land 0x8000_0000 <> 0 ->
      t.interrupts <- t.interrupts + 1;
      (match Machine.interrupt t.model ~code:(cause land 0x1f) with
       | Ok r -> Ok r
       | Error msg ->
         fail t (Printf.sprintf "retire #%d: core took interrupt %d, model: %s" t.retired (cause land 0x1f) msg);
         Ok core)
    | _ -> Machine.step t.model
  in
  (match stepped with
   | Ok model when Machine.equal_retire model core -> ()
   | Ok model ->
     fail
       t
       (Printf.sprintf
          "retire #%d differs\n  core:  %s\n  model: %s"
          t.retired
          (show core)
          (show model))
   | Error trap ->
     fail
       t
       (Printf.sprintf
          "retire #%d: core retired %s but the model trapped with %s"
          t.retired
          (show core)
          (Sexp.to_string (Machine.sexp_of_trap trap))));
  t.retired <- t.retired + 1
;;

(* Call once the core has halted with [trap]. *)
let on_halt t ~trap =
  match Machine.step t.model with
  | Error model_trap when trap_code model_trap = trap -> ()
  | Error model_trap ->
    fail
      t
      (Printf.sprintf
         "core halted with trap %d, model with %s"
         trap
         (Sexp.to_string (Machine.sexp_of_trap model_trap)))
  | Ok r -> fail t (Printf.sprintf "core halted with trap %d, model retired %s" trap (show r))
;;
