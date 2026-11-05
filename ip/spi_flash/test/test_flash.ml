(* The flash window (issue #27, Linux L6) against the W25Q64 model:
   sequential runs (streamed) and random addresses, every word compared
   with the image; writes are ignored. *)
open! Base
open! Hardcaml
open Stdio
module W = Spi_flash.Flash_window
module Sim = Cyclesim.With_interface (W.I) (W.O)

let run ?(corrupt_sample = false) ~seed ~reads () =
  let rng = Random.State.make [| seed |] in
  let image = String.init (1 lsl 16) ~f:(fun _ -> Char.of_int_exn (Random.State.int rng 256)) in
  let flash = Spi_flash_bench.W25q_model.create ~clock_mhz:50 image in
  let sim = Sim.create (W.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs ~clock_edge:Before sim
  (* the registered pins of the current cycle *)
  and pins = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let cycles = ref 0 in
  let previous_miso = ref false in
  (* One cycle; [f] sees the outputs of this cycle (before the edge) and
     returns its result. *)
  let cycle f =
    let miso =
      Spi_flash_bench.W25q_model.step
        flash
        ~cs_n:(Bits.to_bool !(pins.cs_n))
        ~sck:(Bits.to_bool !(pins.sck))
        ~mosi:(Bits.to_bool !(pins.mosi))
    in
    (* [corrupt_sample]: the controller sees MISO one cycle late *)
    i.miso := Bits.of_bool (if corrupt_sample then !previous_miso else miso);
    previous_miso := miso;
    Cyclesim.cycle_check sim;
    Cyclesim.cycle_before_clock_edge sim;
    let r = f () in
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    Int.incr cycles;
    r
  in
  let rec until f = if not (cycle f) then until f in
  let step () = cycle (fun () -> ()) in
  let word a =
    List.fold (List.range 0 4) ~init:0 ~f:(fun acc k -> acc lor (Char.to_int image.[a + k] lsl (8 * k)))
  in
  let errors = ref 0 in
  let addr = ref 0 in
  for _ = 1 to reads do
    (match Random.State.int rng 10 with
     | 0 -> addr := 4 * Random.State.int rng ((1 lsl 14) - 1)
     | 1 ->
       (* a write: accepted and ignored *)
       i.write := Bits.vdd;
       i.addr := Bits.of_int ~width:23 !addr;
       until (fun () -> Bits.to_bool !(o.ready));
       i.write := Bits.gnd
     | _ -> addr := !addr + 4);
    if !addr + 4 > String.length image then addr := 0;
    i.read := Bits.vdd;
    (* a byte or halfword address inside the word reads the whole word *)
    i.addr := Bits.of_int ~width:23 (!addr + Random.State.int rng 4);
    until (fun () -> Bits.to_bool !(o.ready));
    i.read := Bits.gnd;
    let data = ref 0 in
    until (fun () ->
      data := Bits.to_int !(o.rdata);
      Bits.to_bool !(o.rvalid));
    if !data <> word !addr
    then (
      Int.incr errors;
      if !errors <= 3 then printf "0x%06x: got %08x expected %08x\n" !addr !data (word !addr));
    for _ = 1 to Random.State.int rng 3 do
      step ()
    done
  done;
  printf
    "%d reads, %d transfers, %.1f cycles per read, %d errors, model errors: %s\n"
    reads
    flash.reads
    (Float.of_int !cycles /. Float.of_int reads)
    !errors
    (String.concat ~sep:"; " flash.errors)
;;

let%expect_test "flash window against the W25Q64 model" =
  run ~seed:1 ~reads:2000 ();
  [%expect {| 2000 reads, 406 transfers, 80.1 cycles per read, 0 errors, model errors: |}]
;;

let%expect_test "negative: sampling MISO a cycle late fails" =
  run ~corrupt_sample:true ~seed:2 ~reads:50 ();
  [%expect {|
    0x000004: got bf1c7b11 expected 7e39f622
    0x000008: got 77925a2f expected ee24b55e
    0x00000c: got 4b1ee705 expected 973cce0b
    50 reads, 13 transfers, 83.6 cycles per read, 50 errors, model errors:
    |}]
;;
