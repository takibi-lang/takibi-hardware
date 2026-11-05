(* Prints the Verilog of Soc.Arbiter (module `arbiter`) for formal/arbiter.sby. *)
open! Hardcaml

let () =
  let module C = Circuit.With_interface (Soc.Arbiter.I) (Soc.Arbiter.O) in
  let scope = Scope.create ~flatten_design:true () in
  Rtl.print Verilog (C.create_exn ~name:"arbiter" (Soc.Arbiter.create scope))
;;
