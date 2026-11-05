(* A 32-bit user data register behind the ECP5's JTAGG (ER1, IR 0x32),
   issue #10. Capture-DR loads [capture] for reading, Shift-DR shifts 32
   bits LSB first (as OpenOCD's drscan), Update-DR copies the bits shifted
   in to [value].

   JTAGG quirks (Tom Verbeure's analysis, as LiteX's ECP5 JTAG PHY and
   Hazard3 handle them; our first version that ignored them read back
   corrupted words on the board):
   - JTDI is TDI registered on the rising TCK edge: one cycle late, stale
     in the first Shift-DR cycle, the last bit arrives in the cycle after
     Shift-DR (Exit1-DR);
   - JTDO1 is sampled on the falling edge, so the logic runs on the falling
     edge (the inverted JTCK) and drives JTDO1 from its next state;
   - JCE1 is high in Capture-DR and Shift-DR while ER1 is selected; JUPDATE
     is high in Update-DR for any instruction. *)
open! Base
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { jtck : 'a
    ; jtdi : 'a
    ; jshift : 'a
    ; jupdate : 'a
    ; jce1 : 'a
    ; jrstn : 'a
    ; capture : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { jtdo1 : 'a
    ; value : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec =
    Reg_spec.override
      (Reg_spec.create ~clock:i.jtck ~clear:~:(i.jrstn) ())
      ~clock_edge:Falling
  in
  let shift_d = reg spec i.jshift -- "jtag_shift_d" in
  let first_shift = i.jshift &: ~:shift_d in
  let last_shift = ~:(i.jshift) &: shift_d in
  (* out: loaded in Capture-DR and again in the first shift cycle *)
  let tx = wire 32 in
  let tx_next =
    mux2
      ((i.jce1 &: ~:(i.jshift)) |: first_shift)
      i.capture
      (mux2 i.jshift (gnd @: tx.:[31, 1]) tx)
    -- "jtag_tx_next"
  in
  tx <== (reg spec tx_next -- "jtag_tx");
  (* in: the stale first JTDI is skipped, the last one taken in Exit1-DR *)
  let rx =
    reg_fb spec ~width:32 ~f:(fun rx ->
      mux2 ((i.jshift &: ~:first_shift) |: last_shift) (i.jtdi @: rx.:[31, 1]) rx)
    -- "jtag_rx"
  in
  let selected =
    reg_fb spec ~width:1 ~f:(fun s -> mux2 i.jce1 vdd (mux2 i.jupdate gnd s))
    -- "jtag_er1_selected"
  in
  let value = reg spec ~enable:(i.jupdate &: selected) rx -- "jtag_value" in
  { O.jtdo1 = tx_next.:(0); value }
;;
