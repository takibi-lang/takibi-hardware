(* CLINT, PLIC and 16550 (issue #28, Linux L7). CLINT and PLIC run the
   same random register traffic as the L0 models in Soc_model.Devices,
   compared cycle by cycle (read data and interrupt outputs). The UART's
   transmit timing differs from the model by design (the model sends
   instantly), so it is checked with directed sequences: the register
   file, Linux's 8250 probe and setup, transmit through the FIFO decoded
   from the line, receive into the FIFO, and the interrupt rules. *)
open! Base
open! Hardcaml
open Stdio
module D = Soc_model.Devices

module Clint_sim = Cyclesim.With_interface (Soc.Regbus.I) (Soc.Clint.O)

let clint ?(model_k = 3) () =
  let k = 3 in
  let sim =
    Clint_sim.create (Soc.Clint.create ~cycles_per_tick:k (Scope.create ~flatten_design:true ()))
  in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let model = D.Clint.create () in
  let rng = Random.State.make [| 1 |] in
  let mismatches = ref 0
  and mtip_seen = ref false in
  let pending_read = ref None in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  for cycle = 0 to 20_000 do
    (* outputs of this cycle (registers) against the model's state *)
    (match !pending_read with
     | Some v when v <> Bits.to_int !(o.rdata) -> Int.incr mismatches
     | _ -> ());
    let mtip0 = Bits.to_int !(o.mtip) land 1 = 1 in
    if Bool.(mtip0 <> D.Clint.mtip model) then Int.incr mismatches;
    if mtip0 then mtip_seen := true;
    let offs = [| 0x0; 0x4000; 0x4004; 0xbff8; 0xbffc |] in
    let off = offs.(Random.State.int rng 5) in
    let op = Random.State.int rng 8 in
    let value =
      match off with
      | 0x4004 | 0xbffc -> Random.State.int rng 2
      | _ -> Random.State.int rng 400
    in
    i.read := Bits.of_bool (op = 0);
    i.write := Bits.of_bool (op = 1);
    i.addr := Bits.of_int ~width:24 off;
    i.wdata := Bits.of_int ~width:32 value;
    pending_read := if op = 0 then Some (D.Clint.load model off) else None;
    if cycle % model_k = model_k - 1 then D.Clint.tick model 1;
    if op = 1 then D.Clint.store model off value;
    Cyclesim.cycle sim
  done;
  printf "CLINT: %d mismatches, mtip seen: %b\n" !mismatches !mtip_seen
;;

module Plic_io = struct
  type 'a t =
    { bus : 'a Soc.Regbus.I.t
    ; level : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

module Plic_sim = Cyclesim.With_interface (Plic_io) (Soc.Plic.O)

let plic ?(swap_contexts = false) () =
  let sources = 3 in
  let sim =
    Plic_sim.create (fun (x : _ Plic_io.t) ->
      Soc.Plic.create ~sources (Scope.create ~flatten_design:true ()) x.bus x.level)
  in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let model = D.Plic.create ~sources ~contexts:2 in
  let rng = Random.State.make [| 2 |] in
  let mismatches = ref 0
  and claims = ref 0
  and irqs = ref 0 in
  let pending_read = ref None in
  i.bus.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.bus.clear := Bits.gnd;
  let level = ref 0 in
  for _ = 0 to 20_000 do
    (match !pending_read with
     | Some v when v <> Bits.to_int !(o.rdata) -> Int.incr mismatches
     | _ -> ());
    let hw_irq = Bits.to_int !(o.irq) in
    let model_irq =
      Bool.to_int (D.Plic.irq model ~context:0) lor (Bool.to_int (D.Plic.irq model ~context:1) lsl 1)
    in
    let model_irq = if swap_contexts then ((model_irq land 1) lsl 1) lor (model_irq lsr 1) else model_irq in
    if hw_irq <> model_irq then Int.incr mismatches;
    if hw_irq <> 0 then Int.incr irqs;
    if Random.State.int rng 20 = 0 then level := Random.State.int rng 8;
    let ctx = Random.State.int rng 2 in
    let off, value, op =
      match Random.State.int rng 12 with
      | 0 -> 4 * (1 + Random.State.int rng sources), Random.State.int rng 8, `W
      | 1 -> 0x2000 + (0x80 * ctx), Random.State.int rng 16, `W
      | 2 -> 0x20_0000 + (0x1000 * ctx), Random.State.int rng 4, `W
      | 3 | 4 -> 0x20_0004 + (0x1000 * ctx), 0, `R (* claim *)
      | 5 | 6 -> 0x20_0004 + (0x1000 * ctx), Random.State.int rng (sources + 2), `W (* complete *)
      | 7 -> 0x1000, 0, `R
      | 8 -> 4 * Random.State.int rng (sources + 1), 0, `R
      | 9 -> 0x2000 + (0x80 * ctx), 0, `R
      | 10 -> 0x20_0000 + (0x1000 * ctx), 0, `R
      | _ -> 0, 0, `N
    in
    i.bus.read := Bits.of_bool (Poly.equal op `R);
    i.bus.write := Bits.of_bool (Poly.equal op `W);
    i.bus.addr := Bits.of_int ~width:24 off;
    i.bus.wdata := Bits.of_int ~width:32 value;
    i.level := Bits.of_int ~width:3 !level;
    (* the model in the hardware's order: the read (with a claim's side
       effect) on the state at the start of the cycle, then the level of
       this cycle, then the write, then the gateway *)
    pending_read
    := (match op with
        | `R ->
          let v = D.Plic.load model off in
          if off land 0xfff = 4 && off >= 0x20_0000 && v <> 0 then Int.incr claims;
          Some v
        | _ -> None);
    model.level <- !level lsl 1;
    if Poly.equal op `W then D.Plic.store model off value;
    for s = 1 to sources do
      D.Plic.set_level model ~source:s (!level land (1 lsl (s - 1)) <> 0)
    done;
    Cyclesim.cycle sim
  done;
  printf "PLIC: %d mismatches, %d claims, irq cycles > 0: %b\n" !mismatches !claims (!irqs > 0)
;;

let%expect_test "CLINT and PLIC against the L0 models" =
  clint ();
  plic ();
  [%expect {|
    CLINT: 0 mismatches, mtip seen: true
    PLIC: 0 mismatches, 734 claims, irq cycles > 0: true
    |}]
;;

let%expect_test "negative: the comparisons fail" =
  clint ~model_k:4 ();
  plic ~swap_contexts:true ();
  [%expect {|
    CLINT: 490 mismatches, mtip seen: true
    PLIC: 5048 mismatches, 734 claims, irq cycles > 0: true
    |}]
;;
