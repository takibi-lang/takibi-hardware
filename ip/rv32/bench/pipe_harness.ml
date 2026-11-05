(* Runs the pipelined core (Rv32.Pipeline, #4) against an OCaml memory with
   an instruction port and a data port, checking every retirement in
   lockstep with the golden model (Lockstep, as Core_harness). Each port
   follows the request/ready, rvalid protocol: by default a request is
   accepted at once and read data comes in the next cycle (block RAM);
   with [~wait_states:rng] acceptance and latency (1..4) are random.

   Interrupts: the pipeline decides at its commit stage, in a cycle marked
   by [core.fetch]; the irq inputs of that cycle are the ones the model
   must see for the instruction that retires from it (later, for loads). *)
open! Base
open! Hardcaml
module P = Rv32.Pipeline
module Sim = Cyclesim.With_interface (P.I) (P.O)

let create_sim ?reset_pc ~base () =
  let scope = Scope.create ~flatten_design:true () in
  Sim.create ~config:Cyclesim.Config.trace_all (P.create ?reset_pc ~base scope)
;;

type port =
  { mutable pending : (int * int32) option (* cycles left, data *)
  ; mutable rdata : int32
  }

let run
  ?(irq = fun (_ : int) -> 0)
  ?(mem_base = 0)
  ?stop_on_write
  ?wait_states
  ?(base = Rv32_model.Isa.Rv32i)
  ?(mem_bytes = 4096)
  ?(max_cycles = 100_000)
  ?(trace = fun (_ : string) -> ())
  ?sim
  program
  : Core_harness.result
  =
  let sim = match sim with Some s -> s | None -> create_sim ~reset_pc:mem_base ~base () in
  let lockstep =
    Lockstep.create ~zicsr:true ~m:true ~a:true ~mem_base ~base ~mem_bytes ~program ()
  in
  let mem = Bytes.make mem_bytes '\000' in
  List.iteri program ~f:(fun k w -> Stdlib.Bytes.set_int32_le mem (4 * k) (Int32.of_int_trunc w));
  let word addr = Stdlib.Bytes.get_int32_le mem (addr land (mem_bytes - 4)) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let ip = { pending = None; rdata = 0l }
  and dp = { pending = None; rdata = 0l } in
  let present (p : port) =
    match p.pending with
    | Some (0, d) ->
      p.rdata <- d;
      p.pending <- None;
      true
    | _ -> false
  in
  let ready (p : port) =
    Option.is_none p.pending
    &&
    match wait_states with
    | None -> true
    | Some rng -> Random.State.int rng 3 > 0
  in
  let delay () =
    match wait_states with
    | None -> 1
    | Some rng -> 1 + Random.State.int rng 4
  in
  let advance (p : port) ~read ~addr ~ready =
    match p.pending with
    | Some (n, d) -> p.pending <- Some (n - 1, d)
    | None -> if read && ready then p.pending <- Some (delay () - 1, word addr)
  in
  let irq_decision = ref 0 in
  let result ~cycle ~trap ~stop : Core_harness.result =
    { retired = lockstep.retired
    ; interrupts = lockstep.interrupts
    ; cycles = cycle
    ; trap
    ; mismatch = lockstep.mismatch
    ; memory = mem
    ; stop_value = stop
    }
  in
  let rec loop cycle =
    if cycle >= max_cycles
    then result ~cycle ~trap:None ~stop:None
    else (
      let ivalid = present ip
      and dvalid = present dp in
      let iready = ready ip
      and dready = ready dp in
      i.imem_rdata := Bits.of_int32 ~width:32 ip.rdata;
      i.imem_rvalid := Bits.of_bool ivalid;
      i.imem_ready := Bits.of_bool iready;
      i.mem_rdata := Bits.of_int32 ~width:32 dp.rdata;
      i.mem_rvalid := Bits.of_bool dvalid;
      i.mem_ready := Bits.of_bool dready;
      let irq_now = irq cycle in
      i.irq := Bits.of_int ~width:3 (irq_now land 7);
      Cyclesim.cycle_check sim;
      Cyclesim.cycle_before_clock_edge sim;
      let c = o.core in
      if Bits.to_bool !(c.fetch) then irq_decision := irq_now;
      if Bits.to_bool !(c.halted)
      then (
        Lockstep.on_halt lockstep ~trap:(Bits.to_int !(c.trap));
        result ~cycle ~trap:(Some (Bits.to_int !(c.trap))) ~stop:None)
      else (
        trace
          (Printf.sprintf
             "%d: fetch=%b irq=%d retire=%b trap=%b pc=%x insn=%08x read=%b write=%b dready=%b dvalid=%b"
             cycle
             (Bits.to_bool !(c.fetch))
             irq_now
             (Bits.to_bool !(c.retire))
             (Bits.to_bool !(c.retire_trap))
             (Bits.to_int !(c.retire_pc))
             (Bits.to_int !(c.retire_insn))
             (Bits.to_bool !(c.mem_read))
             (Bits.to_bool !(c.mem_write))
             dready
             dvalid);
        if Bits.to_bool !(c.retire)
        then Lockstep.on_retire ~irq:irq_now ~irq_fetch:!irq_decision lockstep c;
        let daddr = Bits.to_int !(c.mem_addr) in
        let stop =
          match stop_on_write with
          | Some at when Bits.to_bool !(c.mem_write) && dready && daddr = at ->
            Some (Bits.to_int !(c.mem_wdata))
          | _ -> None
        in
        if Bits.to_bool !(c.mem_write) && dready
        then (
          let mask = Bits.to_int !(c.mem_wmask)
          and data = Bits.to_int !(c.mem_wdata) in
          for lane = 0 to 3 do
            if mask land (1 lsl lane) <> 0
            then
              Bytes.set
                mem
                ((daddr land (mem_bytes - 4)) + lane)
                (Char.of_int_exn ((data lsr (8 * lane)) land 0xff))
          done);
        advance ip ~read:(Bits.to_bool !(o.imem_read)) ~addr:(Bits.to_int !(o.imem_addr)) ~ready:iready;
        advance dp ~read:(Bits.to_bool !(c.mem_read)) ~addr:daddr ~ready:dready;
        Cyclesim.cycle_at_clock_edge sim;
        Cyclesim.cycle_after_clock_edge sim;
        if Option.is_some stop
        then result ~cycle ~trap:None ~stop
        else if Option.is_some lockstep.mismatch
        then result ~cycle ~trap:None ~stop:None
        else loop (cycle + 1)))
  in
  loop 0
;;
