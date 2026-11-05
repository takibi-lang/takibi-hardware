(* gen.exe dts|header [HARTS]: print the device tree source or the C
   header, for HARTS harts (default 1; #9). *)
let () =
  let harts n = int_of_string n in
  match Sys.argv with
  | [| _; "dts" |] -> print_string (Soc_model.Gen.dts ())
  | [| _; "dts"; n |] -> print_string (Soc_model.Gen.dts ~harts:(harts n) ())
  | [| _; "header" |] -> print_string (Soc_model.Gen.header ())
  | [| _; "header"; n |] -> print_string (Soc_model.Gen.header ~harts:(harts n) ())
  | _ ->
    prerr_endline "usage: gen.exe dts|header [HARTS]";
    exit 2
;;
