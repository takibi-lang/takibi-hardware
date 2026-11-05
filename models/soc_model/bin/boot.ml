(* Boot the Linux SoC model (issue #25):

     boot.exe BOOT.bin SOC.dtb IMAGE [--max N] [--input TEXT] [--until TEXT]

   The flash image gets the DTB and the kernel Image at Soc_map's offsets;
   the boot ROM starts at 0. UART output is printed as it appears. Stops
   at an unhandled trap, after N instructions (default 2e9), or once the
   output contains TEXT (--until). --input is typed line by line: when the
   output ends with "> " (the REPL prompt), the next line up to and
   including its \r is typed, one character per 20,000 instructions. *)
open! Base
open Stdio
module Soc = Soc_model.Soc
module Map = Soc_model.Soc_map

let () =
  let args = Sys.get_argv () |> Array.to_list |> List.tl_exn in
  let max = ref 2_000_000_000
  and harts = ref 1
  and input = ref ""
  and until = ref None in
  let rec parse = function
    | "--harts" :: n :: rest ->
      harts := Int.of_string n;
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
      eprintf "usage: boot.exe BOOT.bin SOC.dtb IMAGE [--max N] [--input TEXT] [--until TEXT]\n";
      Stdlib.exit 2
  in
  let read = In_channel.read_all in
  let flash = Bytes.make Map.flash_bytes '\xff' in
  let put off s = Bytes.From_string.blit ~src:s ~src_pos:0 ~dst:flash ~dst_pos:off ~len:(String.length s) in
  put Map.flash_dtb_offset (read dtb);
  put Map.flash_kernel_offset (read image);
  let soc = Soc.create ~harts:!harts ~boot_rom:(read boot) ~flash:(Bytes.to_string flash) () in
  let printed = ref 0 in
  let pending = ref (String.to_list !input) in
  let next_key = ref 0 in
  let typing = ref false (* inside a line, after its prompt *) in
  let t0 = Unix.gettimeofday () in
  let finish msg =
    let dt = Unix.gettimeofday () -. t0 in
    eprintf
      "\n[boot] %s after %d instructions, %d interrupts, %.1f s (%.1f MIPS), pc=%x priv=%d\n"
      msg
      soc.retired
      soc.interrupts
      dt
      (Float.of_int soc.retired /. dt /. 1e6)
      soc.machine.pc
      soc.machine.priv
  in
  let rec go () =
    if soc.retired >= !max
    then finish "instruction limit"
    else (
      match Soc.step soc with
      | Error trap ->
        finish ("unhandled trap " ^ Sexp.to_string (Rv32_model.Machine.sexp_of_trap trap));
        Stdlib.exit 1
      | Ok _ ->
        (* Look at the output only when it grew (or a key is due). *)
        let len = Buffer.length soc.uart.output in
        let key_due = !typing && (not (List.is_empty !pending)) && soc.retired >= !next_key in
        if len = !printed && not key_due
        then go ()
        else (
          let out = Soc.output soc in
          if len > !printed
          then (
            Out_channel.output_string stdout (String.drop_prefix out !printed);
            Out_channel.flush stdout;
            printed := len);
          if (not !typing) && len > 0 && String.is_suffix out ~suffix:"> " then typing := true;
          (match !pending with
           | c :: rest when !typing && soc.retired >= !next_key ->
             Soc.receive soc (String.of_char c);
             pending := rest;
             next_key := soc.retired + 20_000;
             if Char.equal c '\r' then typing := false
           | _ -> ());
          match !until with
          | Some u when String.is_substring out ~substring:u -> finish "done"
          | _ -> go ()))
  in
  go ()
;;
