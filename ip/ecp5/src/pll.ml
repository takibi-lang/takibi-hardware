(* ECP5 PLL (EHXPLLL) for the i9 system clock: fout = fin * CLKFB_DIV /
   CLKI_DIV, taken from CLKOP = VCO / CLKOP_DIV, with the VCO inside
   400..800 MHz. [settings] searches the dividers like Yosys's ecppll and
   fails if the frequency cannot be made exactly; the attributes are
   ecppll's defaults for the loop filter. *)
open! Base
open! Hardcaml
open Signal

type settings =
  { clki_div : int
  ; clkfb_div : int
  ; clkop_div : int
  }

let settings ~fin_mhz ~fout_mhz =
  let candidates =
    List.concat_map (List.range 1 129) ~f:(fun clki_div ->
      List.concat_map (List.range 1 81) ~f:(fun clkfb_div ->
        if fin_mhz * clkfb_div <> fout_mhz * clki_div
        then []
        else
          List.filter_map (List.range 1 129) ~f:(fun clkop_div ->
            let vco = fout_mhz * clkop_div in
            if vco >= 400 && vco <= 800 then Some { clki_div; clkfb_div; clkop_div } else None)))
  in
  (* Prefer the VCO closest to the middle of its range, as ecppll does. *)
  match
    List.min_elt candidates ~compare:(fun a b ->
      Int.compare (abs ((fout_mhz * a.clkop_div) - 600)) (abs ((fout_mhz * b.clkop_div) - 600)))
  with
  | Some s -> s
  | None -> Printf.failwithf "PLL: cannot make %d MHz from %d MHz" fout_mhz fin_mhz ()
;;

(* Returns the output clock and the (asynchronous) lock flag. *)
let create ~fin_mhz ~fout_mhz ~clkin =
  let s = settings ~fin_mhz ~fout_mhz in
  let p name v = Parameter.create ~name ~value:v in
  let str name v = p name (String v) and int name v = p name (Int v) in
  let clkfb = wire 1 in
  let outputs =
    Instantiation.create
      ()
      ~name:"EHXPLLL"
      ~instance:"pll"
      ~attributes:
        [ Rtl_attribute.create ~value:(String (Int.to_string fin_mhz)) "FREQUENCY_PIN_CLKI"
        ; Rtl_attribute.create ~value:(String (Int.to_string fout_mhz)) "FREQUENCY_PIN_CLKOP"
        ; Rtl_attribute.create ~value:(String "12") "ICP_CURRENT"
        ; Rtl_attribute.create ~value:(String "8") "LPF_RESISTOR"
        ; Rtl_attribute.create ~value:(String "1") "MFG_ENABLE_FILTEROPAMP"
        ; Rtl_attribute.create ~value:(String "2") "MFG_GMCREF_SEL"
        ]
      ~parameters:
        [ str "PLLRST_ENA" "DISABLED"
        ; str "INTFB_WAKE" "DISABLED"
        ; str "STDBY_ENABLE" "DISABLED"
        ; str "DPHASE_SOURCE" "DISABLED"
        ; str "OUTDIVIDER_MUXA" "DIVA"
        ; str "OUTDIVIDER_MUXB" "DIVB"
        ; str "OUTDIVIDER_MUXC" "DIVC"
        ; str "OUTDIVIDER_MUXD" "DIVD"
        ; int "CLKI_DIV" s.clki_div
        ; str "CLKOP_ENABLE" "ENABLED"
        ; int "CLKOP_DIV" s.clkop_div
        ; int "CLKOP_CPHASE" ((s.clkop_div / 2) - 1)
        ; int "CLKOP_FPHASE" 0
        ; str "FEEDBK_PATH" "CLKOP"
        ; int "CLKFB_DIV" s.clkfb_div
        ]
      ~inputs:
        [ "RST", gnd
        ; "STDBY", gnd
        ; "CLKI", clkin
        ; "CLKFB", clkfb
        ; "PHASESEL0", gnd
        ; "PHASESEL1", gnd
        ; "PHASEDIR", vdd
        ; "PHASESTEP", vdd
        ; "PHASELOADREG", vdd
        ; "PLLWAKESYNC", gnd
        ; "ENCLKOP", gnd
        ]
      ~outputs:[ "CLKOP", 1; "LOCK", 1 ]
  in
  let clkop = Map.find_exn outputs "CLKOP" in
  clkfb <== clkop;
  clkop, Map.find_exn outputs "LOCK"
;;
