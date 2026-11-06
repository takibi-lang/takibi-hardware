(* Verilog generator for the Colorlight i9 Linux SoC (issue #21, L10).

     main.exe clock-mhz         the system clock, for the Makefile
     main.exe verilog BOOT.bin  module soc_board (and its submodules), with
                                the boot ROM contents

   As for the MCUs (Mcu_gen.Rtl_init, B-0014, B-0023): the core's register
   files start as zeros and the registers without a reset power up as 0. *)
open! Base
open! Hardcaml
open Stdio

let verilog boot =
  let boot_rom = Soc_bench.Soc_harness.words_of_string (In_channel.read_all boot) in
  let scope = Scope.create ~flatten_design:false () in
  let circuit = Soc_i9.circuit ~boot_rom scope in
  let buffer = Buffer.create 65536 in
  Rtl.output ~database:(Scope.circuit_database scope) ~output_mode:(To_buffer buffer) Verilog circuit;
  let regfiles = ref 0
  and zeroed = ref 0 in
  let no_reset = "boot_count" :: Soc_i9.no_reset in
  String.split_lines (Buffer.contents buffer)
  |> List.iter ~f:(fun line ->
    print_endline line;
    if Mcu_gen.Rtl_init.zero_register_file line then Int.incr regfiles;
    if Mcu_gen.Rtl_init.zero_register no_reset line then Int.incr zeroed);
  (* two per core (rs1, rs2 copies); each core is its own module (mhartid) *)
  let expected = 2 * Soc_i9.harts in
  if !regfiles <> expected
  then Printf.failwithf "expected %d register files, found %d" expected !regfiles ();
  if !zeroed <> List.length no_reset
  then Printf.failwithf "expected %d power-up registers, found %d" (List.length no_reset) !zeroed ()
;;

let () =
  match Sys.get_argv () with
  | [| _; "clock-mhz" |] -> printf "%d\n" Soc_i9.clock_mhz
  | [| _; "verilog"; boot |] -> verilog boot
  | _ ->
    eprintf "usage: main.exe clock-mhz | verilog BOOT.bin\n";
    Stdlib.exit 2
;;
