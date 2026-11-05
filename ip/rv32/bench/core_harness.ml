(* Runs the bare core against an OCaml memory model, checking every
   retirement in lockstep with the golden model. The memory follows the
   core's request/ready, rvalid protocol (#26): by default it accepts every
   request at once and returns read data in the next cycle (block RAM);
   with [~wait_states:rng] it accepts a request in a random cycle and
   returns the data 1 to 4 cycles later. *)
open! Base
open! Hardcaml
module Sim = Cyclesim.With_interface (Rv32.Core.I) (Rv32.Core.O)

type result =
  { retired : int
  ; interrupts : int
  ; cycles : int
  ; trap : int option
  ; mismatch : string option
  ; memory : (Bytes.t[@sexp.opaque]) (* final memory contents *)
  ; stop_value : int option (* the word written to [stop_on_write] *)
  }
[@@deriving sexp_of]

let create_sim ?zicsr ?dual_read ?fetch_overlap ?m ?a ?s ?tlb_entries ?reset_pc ~base () =
  let scope = Scope.create ~flatten_design:true () in
  Sim.create
    ~config:Cyclesim.Config.trace_all
    (Rv32.Core.create
       ?zicsr
       ?dual_read
       ?fetch_overlap
       ?m
       ?a
       ?zifencei:m
       ?s
       ?tlb_entries
       ?reset_pc
       ~base
       scope)
;;

(* [model_program] (default: [program]) exists to test the checker itself.
   [irq cycle] drives the core's 3-bit interrupt input (Zicsr) and, in
   bit 3, SEIP ([~s]); [time cycle] is the CLINT time ([~s]);
   [trace] sees every retirement of the core;
   [checker_irq] (default [irq]) is what the lockstep checker is told, to
   test the checker itself. *)
let run
  ?(zicsr = false)
  ?dual_read
  ?fetch_overlap
  ?(m = false)
  ?(a = false)
  ?(s = false)
  ?(time = fun (_ : int) -> 0)
  ?(mem_base = 0)
  ?stop_on_write
  ?(irq = fun (_ : int) -> 0)
  ?checker_irq
  ?(trace = fun (_ : Rv32_model.Machine.retire) -> ())
  ?(base = Rv32_model.Isa.Rv32e)
  ?(mem_bytes = 4096)
  ?(max_cycles = 100_000)
  ?wait_states
  ?sim
  ?model_program
  program
  =
  let sim = match sim with Some s -> s | None -> create_sim ~zicsr ?dual_read ?fetch_overlap ~m ~a ~s ~reset_pc:mem_base ~base () in
  let lockstep =
    Lockstep.create ~zicsr ~m ~a ~s ~mem_base ~base ~mem_bytes ~program:(Option.value model_program ~default:program) ()
  in
  let mem = Bytes.make mem_bytes '\000' in
  List.iteri program ~f:(fun k w ->
    Stdlib.Bytes.set_int32_le mem (4 * k) (Int32.of_int_trunc w));
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let irq_fetch = ref 0 in
  let time_fetch = ref 0 in
  (* One cycle of clear: registers take their reset values (pc = mem_base). *)
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let word addr = Stdlib.Bytes.get_int32_le mem (addr land (mem_bytes - 4)) in
  (* The outstanding read: cycles until its data, and the data. *)
  let pending = ref None in
  let rdata = ref 0l in
  let rec loop cycle =
    if cycle >= max_cycles
    then { retired = lockstep.retired; interrupts = lockstep.interrupts; cycles = cycle; trap = None; mismatch = lockstep.mismatch; memory = mem; stop_value = None }
    else (
      let rvalid =
        match !pending with
        | Some (0, d) ->
          rdata := d;
          pending := None;
          true
        | _ -> false
      in
      let ready =
        Option.is_none !pending
        &&
        match wait_states with
        | None -> true
        | Some rng -> Random.State.int rng 3 > 0
      in
      i.mem_rdata := Bits.of_int32 ~width:32 !rdata;
      i.mem_rvalid := Bits.of_bool rvalid;
      i.mem_ready := Bits.of_bool ready;
      i.irq := Bits.of_int ~width:3 (irq cycle land 7);
      i.seip := Bits.of_bool (irq cycle land 8 <> 0);
      let time_now = time cycle in
      i.mtime := Bits.of_int ~width:64 time_now;
      let irq_now = (Option.value checker_irq ~default:irq) cycle in
      Cyclesim.cycle_check sim;
      Cyclesim.cycle_before_clock_edge sim;
      let irq_entry =
        Bits.to_bool !(o.retire_trap) && Bits.to_int !(o.retire_cause) land 0x8000_0000 <> 0
      in
      let boundary_irq = if irq_entry then irq_now else !irq_fetch in
      let boundary_time = if irq_entry then time_now else !time_fetch in
      if Bits.to_bool !(o.fetch)
      then (
        irq_fetch := irq_now;
        time_fetch := time_now);
      if Bits.to_bool !(o.halted)
      then (
        let trap = Bits.to_int !(o.trap) in
        Lockstep.on_halt lockstep ~trap;
        { retired = lockstep.retired; interrupts = lockstep.interrupts; cycles = cycle; trap = Some trap; mismatch = lockstep.mismatch; memory = mem; stop_value = None })
      else (
        if Bits.to_bool !(o.retire) then trace (Lockstep.of_core o);
        if Bits.to_bool !(o.retire) then Lockstep.on_retire
            ~irq:irq_now
            ~irq_fetch:boundary_irq
            ~time:time_now
            ~time_fetch:boundary_time
            lockstep
            o;
        let addr = Bits.to_int !(o.mem_addr) in
        let stop =
          match stop_on_write with
          | Some at when Bits.to_bool !(o.mem_write) && ready && Bits.to_int !(o.mem_addr) = at ->
            Some (Bits.to_int !(o.mem_wdata))
          | _ -> None
        in
        if Bits.to_bool !(o.mem_write) && ready
        then (
          let mask = Bits.to_int !(o.mem_wmask) in
          let data = Bits.to_int !(o.mem_wdata) in
          for lane = 0 to 3 do
            if mask land (1 lsl lane) <> 0
            then
              Bytes.set
                mem
                ((addr land (mem_bytes - 4)) + lane)
                (Char.of_int_exn ((data lsr (8 * lane)) land 0xff))
          done);
        (match !pending with
         | Some (n, d) -> pending := Some (n - 1, d)
         | None ->
           if Bits.to_bool !(o.mem_read) && ready
           then (
             let delay =
               match wait_states with
               | None -> 1
               | Some rng -> 1 + Random.State.int rng 4
             in
             pending := Some (delay - 1, word addr)));
        Cyclesim.cycle_at_clock_edge sim;
        Cyclesim.cycle_after_clock_edge sim;
        if Option.is_some stop
        then
          { retired = lockstep.retired
          ; interrupts = lockstep.interrupts
          ; cycles = cycle
          ; trap = None
          ; mismatch = lockstep.mismatch
          ; memory = mem
          ; stop_value = stop
          }
        else if Option.is_some lockstep.mismatch
        then
          { retired = lockstep.retired; interrupts = lockstep.interrupts; cycles = cycle; trap = None; mismatch = lockstep.mismatch; memory = mem; stop_value = None }
        else loop (cycle + 1)))
  in
  loop 0
;;
