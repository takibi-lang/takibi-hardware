(* L9 (issue #29): boot Linux on the SoC RTL, with the board models
   (SDRAM, flash, serial line) around it.

     main.exe BOOT.bin SOC.dtb IMAGE [--verilator] [--no-lockstep]
              [--max CYCLES] [--input TEXT] [--until TEXT]

   The flash image holds the device tree and the kernel at Soc_map's
   offsets. By default the SoC runs in Cyclesim; --verilator compiles it
   with Verilator (minutes, then much faster). Every retired instruction is
   checked against the golden model unless --no-lockstep. --input is typed
   after each REPL prompt "> ". The UART output is printed as it appears.
   Exit status 0 when --until was seen (or no --until), with no lockstep
   mismatch and no SDRAM/flash protocol error. *)
open! Base
open Stdio
module Top = Soc.Soc_top
module H = Soc_bench.Soc_harness
module Map = Soc_model.Soc_map
module V = Hardcaml_verilator.With_interface (Top.I) (Top.O)

let () =
  let args = Sys.get_argv () |> Array.to_list |> List.tl_exn in
  let verilator = ref false
  and lockstep = ref true
  and max = ref 2_000_000_000
  and input = ref ""
  and until = ref None in
  let rec parse = function
    | "--verilator" :: rest ->
      verilator := true;
      parse rest
    | "--no-lockstep" :: rest ->
      lockstep := false;
      parse rest
    | "--max" :: n :: rest ->
      max := Int.of_string n;
      parse rest
    | "--input" :: s :: rest ->
      input := Stdlib.Scanf.unescaped s;
      parse rest
    | "--until" :: s :: rest ->
      until := Some s;
      parse rest
    | x :: rest -> x :: parse rest
    | [] -> []
  in
  let boot, dtb, image =
    match parse args with
    | [ b; d; i ] -> b, d, i
    | _ ->
      eprintf "usage: main.exe BOOT.bin SOC.dtb IMAGE [options]\n";
      Stdlib.exit 2
  in
  let read = In_channel.read_all in
  let flash = Bytes.make Map.flash_bytes '\xff' in
  let put off s =
    Bytes.From_string.blit ~src:s ~src_pos:0 ~dst:flash ~dst_pos:off ~len:(String.length s)
  in
  put Map.flash_dtb_offset (read dtb);
  put Map.flash_kernel_offset (read image);
  let boot_rom = H.words_of_string (read boot) in
  let sim =
    if !verilator
    then (
      let t0 = Unix.gettimeofday () in
      let sim =
        V.create
          ~verilator_config:Testlib.Verilator_config.config
          ~clock_names:[ "clock" ]
          (Top.create (H.config ~boot_rom) (Hardcaml.Scope.create ~flatten_design:true ()))
      in
      eprintf "[sim] Verilator model built in %.0f s\n%!" (Unix.gettimeofday () -. t0);
      Some sim)
    else None
  in
  let t0 = Unix.gettimeofday () in
  let r =
    H.run
      ?sim
      ~boot_rom
      ~flash:(Bytes.to_string flash)
      ~input:!input
      ~prompt:"> "
      ~until:(fun out ->
        match !until with
        | Some u -> String.is_substring out ~substring:u
        | None -> false)
      ~max_cycles:!max
      ~lockstep:!lockstep
      ~on_output:(fun c ->
        Out_channel.output_char stdout c;
        Out_channel.flush stdout)
      ()
  in
  let dt = Unix.gettimeofday () -. t0 in
  eprintf
    "\n[sim] %d cycles (%.2f s at 50 MHz), %d instructions in lockstep, %d interrupts, %.0f s (%.2f Mcycles/s)\n"
    r.cycles
    (Float.of_int r.cycles /. 50e6)
    r.retired
    r.interrupts
    dt
    (Float.of_int r.cycles /. dt /. 1e6);
  Option.iter r.mismatch ~f:(eprintf "[sim] LOCKSTEP MISMATCH: %s\n");
  List.iter r.sdram_violations ~f:(eprintf "[sim] SDRAM: %s\n");
  List.iter r.flash_errors ~f:(eprintf "[sim] flash: %s\n");
  Option.iter r.halted ~f:(eprintf "[sim] core halted, trap %d\n");
  let reached =
    Option.value_map !until ~default:true ~f:(fun u -> String.is_substring r.output ~substring:u)
  in
  if reached
     && Option.is_none r.mismatch
     && List.is_empty r.sdram_violations
     && List.is_empty r.flash_errors
  then eprintf "[sim] OK\n"
  else (
    eprintf "[sim] FAIL\n";
    Stdlib.exit 1)
;;
