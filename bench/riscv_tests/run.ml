(* Run riscv-tests images (built by build.sh) on the golden model and read
   the result each test writes to `tohost`: 1 = pass, (n << 1) | 1 = test
   case n failed. Issue #25: the independent check of the model's A (and
   later privilege and virtual-memory) behaviour.

     run.exe DIR...          on the golden model
     run.exe --core DIR...   on the core, memory with random wait states, (i9 configuration with M, A and
                             S/U modes), in lockstep with the model (#5,
                             #6; `p` and `v` tests) *)
open! Base
open Stdio
module M = Rv32_model.Machine

let mem_bytes = 1 lsl 20

let words_of_file path =
  let s = In_channel.read_all path in
  List.init ((String.length s + 3) / 4) ~f:(fun k ->
    List.fold (List.range 0 4) ~init:0 ~f:(fun acc b ->
      let i = (4 * k) + b in
      if i < String.length s then acc lor (Char.to_int s.[i] lsl (8 * b)) else acc))
;;

let run_core dir name ~tohost =
  let r =
    Rv32_bench.Core_harness.run
      ~zicsr:true
      ~dual_read:true
      ~fetch_overlap:true
      ~m:true
      ~a:true
      ~s:true
      ~base:Rv32i
      ~mem_base:0x8000_0000
      ~mem_bytes
      ~max_cycles:5_000_000
      ~wait_states:(Random.State.make [| String.hash name |])
      ~stop_on_write:tohost
      (words_of_file (dir ^ "/" ^ name ^ ".bin"))
  in
  let result =
    match r.mismatch, r.stop_value with
    | Some m, _ -> Error ("lockstep: " ^ m)
    | None, Some 1 -> Ok ()
    | None, Some v -> Error (Printf.sprintf "test case %d failed" (v lsr 1))
    | None, None ->
      Error
        (Printf.sprintf
           "did not finish (trap %s)"
           (Option.value_map r.trap ~default:"none" ~f:Int.to_string))
  in
  r.retired, result
;;

let core = ref false

(* Tests the core cannot run yet, with the reason (printed as SKIP). *)
let core_skips : (string * string) list = []

let run_test dir name =
  let tohost =
    Int.of_string ("0x" ^ String.strip (In_channel.read_all (dir ^ "/" ^ name ^ ".tohost")))
  in
  (* tohost is watched as a physical I/O location: the `v` environment
     writes it through a kernel virtual mapping. Reads return 0 (the host
     has consumed the previous value). *)
  let result = ref None in
  let io =
    { M.is_io = (fun pa -> pa = tohost || pa = tohost + 4)
    ; load = (fun ~addr:_ ~bytes:_ -> 0)
    ; store =
        (fun ~addr ~bytes:_ ~value ->
          if addr = tohost && value <> 0 && Option.is_none !result
          then
            result
              := Some
                   (if value = 1
                    then Ok ()
                    else Error (Printf.sprintf "test case %d failed" (value lsr 1))))
    }
  in
  if !core
  then (
    let n, result = run_core dir name ~tohost in
    (match result with
     | Ok () -> printf "PASS %-24s %6d instructions (core)\n" name n
     | Error e -> printf "FAIL %-24s %s (core)\n" name e);
    Result.is_ok result)
  else (
  let t =
    M.create ~io ~s:true ~m:true ~a:true ~zifencei:true ~mem_base:0x8000_0000 ~base:Rv32i ~mem_bytes ()
  in
  M.load_program t (words_of_file (dir ^ "/" ^ name ^ ".bin"));
  let rec go n =
    match !result with
    | Some r -> n, r
    | None when n > 5_000_000 -> n, Error "did not finish"
    | None ->
      (match M.step t with
       | Ok _ -> go (n + 1)
       | Error trap ->
         n, Error ("trap without handler: " ^ Sexp.to_string (M.sexp_of_trap trap)))
  in
  let n, result = go 0 in
  (match result with
   | Ok () -> printf "PASS %-24s %6d instructions\n" name n
   | Error e -> printf "FAIL %-24s %s\n" name e);
  Result.is_ok result)
;;

let () =
  let dirs =
    match Sys.get_argv () |> Array.to_list |> List.tl_exn with
    | "--core" :: dirs ->
      core := true;
      dirs
    | dirs -> dirs
  in
  let skipped_here =
    if !core
    then List.map core_skips ~f:(fun (n, why) -> n ^ ": " ^ why)
    else []
  in
  let names =
    List.concat_map dirs ~f:(fun dir ->
      Stdlib.Sys.readdir dir
      |> Array.to_list
      |> List.filter_map ~f:(String.chop_suffix ~suffix:".bin")
      |> List.filter ~f:(fun n ->
        not (!core && List.Assoc.mem core_skips ~equal:String.equal n))
      |> List.sort ~compare:String.compare
      |> List.map ~f:(fun n -> dir, n))
  in
  let passed = List.count names ~f:(fun (d, n) -> run_test d n) in
  let skipped =
    List.concat_map dirs ~f:(fun dir ->
      let f = dir ^ "/skipped.txt" in
      if Stdlib.Sys.file_exists f
      then In_channel.read_lines f |> List.filter ~f:(Fn.non String.is_empty)
      else [])
    @ skipped_here
  in
  List.iter skipped ~f:(printf "SKIP %s\n");
  printf "riscv-tests: %d/%d passed, %d skipped\n" passed (List.length names) (List.length skipped);
  if passed <> List.length names then Stdlib.exit 1
;;
