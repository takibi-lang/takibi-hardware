(* Issue #10: the ECP5's JTAG from the fabric on the Colorlight i9, reached
   through the ext board's DAPLink with OpenOCD. JTAGG's ER1 (IR 0x32)
   selects a 32-bit register (Ecp5.Jtag_reg): a read returns 0xcafe in the
   upper half and the low half of the last value written; bit 0 of the
   written value lights the LED. *)
open! Base
open! Hardcaml
open Signal

module I = struct
  type 'a t = { clock : 'a } [@@deriving hardcaml]
end

module O = struct
  type 'a t = { led_n : 'a } [@@deriving hardcaml]
end

let create scope (i : _ I.t) =
  ignore i.clock;
  let jtdo1 = wire 1 in
  let outputs =
    Instantiation.create
      ()
      ~name:"JTAGG"
      ~instance:"jtagg"
      ~inputs:[ "JTDO1", jtdo1; "JTDO2", gnd ]
      ~outputs:
        [ "JTCK", 1; "JTDI", 1; "JSHIFT", 1; "JUPDATE", 1; "JRSTN", 1; "JCE1", 1; "JCE2", 1
        ; "JRTI1", 1; "JRTI2", 1 ]
  in
  let out n = Map.find_exn outputs n in
  let value = wire 32 in
  let r =
    Ecp5.Jtag_reg.create
      scope
      { Ecp5.Jtag_reg.I.jtck = out "JTCK"
      ; jtdi = out "JTDI"
      ; jshift = out "JSHIFT"
      ; jupdate = out "JUPDATE"
      ; jce1 = out "JCE1"
      ; jrstn = out "JRSTN"
      ; capture = of_int ~width:16 0xcafe @: value.:[15, 0]
      }
  in
  jtdo1 <== r.jtdo1;
  value <== r.value;
  { O.led_n = ~:(r.value.:(0)) }
;;

let circuit scope =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"top" (create scope)
;;
