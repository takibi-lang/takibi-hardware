(* Other ECP5 primitives used by the board tops, instantiated so they
   appear in the Verilog for Yosys. (USRMCLK has no outputs, so a HardCaml
   circuit would drop it; it lives in designs/soc_i9/rtl/top.v.) *)
open! Base
open! Hardcaml
open Signal

(* ODDRX1F: [d0] in the first half of the [clock] period, [d1] in the
   second; d0 = 0, d1 = 1 gives the clock inverted, from an I/O register. *)
let oddr ~clock ~d0 ~d1 =
  let outputs =
    Instantiation.create
      ()
      ~name:"ODDRX1F"
      ~instance:"sdram_clock_oddr"
      ~inputs:[ "SCLK", clock; "RST", gnd; "D0", d0; "D1", d1 ]
      ~outputs:[ "Q", 1 ]
  in
  Map.find_exn outputs "Q"
;;
