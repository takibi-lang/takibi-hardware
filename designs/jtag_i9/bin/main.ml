(* Prints the Verilog of the JTAG test design (issue #10). *)
open! Hardcaml

let () =
  let scope = Scope.create ~flatten_design:true () in
  Rtl.print Verilog (Jtag_i9.circuit scope)
;;
