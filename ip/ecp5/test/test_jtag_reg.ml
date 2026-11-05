(* The ER1 user register (issue #10) against a model of the JTAGG as
   OpenOCD's `irscan 0x32; drscan 32 V` drives it: Capture-DR, 32 Shift-DR
   cycles, Exit1-DR, Update-DR. The model registers TDI (JTDI is one cycle
   late) and samples JTDO1 in each Shift-DR cycle. The simulation clock is
   the register's clock (the falling edge of TCK). *)
open! Base
open! Hardcaml
open Stdio
module J = Ecp5.Jtag_reg
module Sim = Cyclesim.With_interface (J.I) (J.O)

let%expect_test "drscan through the ER1 register" =
  let sim = Sim.create (J.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs ~clock_edge:Before sim in
  i.jrstn := Bits.vdd;
  let set (s : Bits.t ref) b = s := Bits.of_bool b in
  let tdi = ref false in
  (* one TCK period: JTDI shows the TDI of the previous period *)
  let tck ~ce1 ~shift ~update ~next_tdi f =
    set i.jce1 ce1;
    set i.jshift shift;
    set i.jupdate update;
    set i.jtdi !tdi;
    Cyclesim.cycle_check sim;
    Cyclesim.cycle_before_clock_edge sim;
    f ();
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    tdi := next_tdi
  in
  let nothing () = () in
  let drscan ~capture v =
    i.capture := Bits.of_int ~width:32 capture;
    let out = ref 0 in
    (* Capture-DR. The TAP samples TDI bit k at the rising edge that ends
       Shift-DR period k, so JTDI shows it in period k + 1 (bit 31 in
       Exit1-DR) and is stale in the first period. *)
    tck ~ce1:true ~shift:false ~update:false ~next_tdi:true nothing;
    for k = 0 to 31 do
      tck
        ~ce1:true
        ~shift:true
        ~update:false
        ~next_tdi:((v lsr k) land 1 = 1)
        (fun () -> if Bits.to_bool !(o.jtdo1) then out := !out lor (1 lsl k))
    done;
    (* Exit1-DR, Update-DR, Run-Test/Idle *)
    tck ~ce1:false ~shift:false ~update:false ~next_tdi:false nothing;
    tck ~ce1:false ~shift:false ~update:true ~next_tdi:false nothing;
    tck ~ce1:false ~shift:false ~update:false ~next_tdi:false nothing;
    !out
  in
  let value () = Bits.to_int !(o.value) in
  let a = drscan ~capture:0xcafe0000 0x1234_5678 in
  printf "out %08x value %08x\n" a (value ());
  let b = drscan ~capture:0xcafe5678 0xdead_beef in
  printf "out %08x value %08x\n" b (value ());
  (* an Update-DR of another instruction (JCE1 never high) changes nothing *)
  tck ~ce1:false ~shift:false ~update:true ~next_tdi:false nothing;
  printf "value after a foreign update %08x\n" (value ());
  [%expect {|
    out cafe0000 value 12345678
    out cafe5678 value deadbeef
    value after a foreign update deadbeef
    |}]
;;
