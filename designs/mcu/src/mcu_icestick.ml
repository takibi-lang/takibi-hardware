(* iCEstick top level for the MCU: RV32E, 4 KiB RAM (8 iCE40 block RAMs,
   plus 2 for the register file), 115200 baud at 12 MHz. No reset input
   and no program loader.

   Board bring-up aids (BUGS.md B-0014):
   - The core is held in reset for about 22 ms after configuration
     (Mcu.Startup; B-0014).
   - LEDs: D5 (green, centre) blinks from a free-running counter,
     independent of the CPU, proving the bitstream and clock run; D4 lights
     when the core has halted (trap); D1..D3 show LEDS bits 2..0 written by
     the firmware. *)
open! Base
open! Hardcaml
open Signal

let clock_hz = 12_000_000

let config =
  { Mcu.Config.base = Rv32e
  ; ram_bytes = 4096
  ; clocks_per_bit = clock_hz / 115_200
  ; counters = false
  ; zicsr = false
  ; dual_read = false
  ; fetch_overlap = false
  ; ma = false
  ; barrel_shift = false
  ; pipeline = false
  }
;;

module I = struct
  type 'a t =
    { clock : 'a
    ; uart_rx : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uart_tx : 'a
    ; led : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

let create scope (i : _ I.t) =
  let free = Reg_spec.create ~clock:i.clock () in
  let hold = Mcu.Startup.hold ~clock_hz scope ~clock:i.clock in
  let%hw heartbeat = reg_fb free ~width:23 ~f:(fun d -> d +:. 1) in
  let o =
    Mcu.hierarchical
      config
      scope
      { Mcu.I.clock = i.clock
      ; clear = hold
      ; uart_rx = i.uart_rx
      ; load_we = gnd
      ; load_addr = zero Mcu.max_word_bits
      ; load_data = zero 32
      }
  in
  { O.uart_tx = o.uart_tx
  ; led = concat_msb [ msb heartbeat; o.core.halted; o.leds.:[2, 0] ]
  }
;;

let circuit scope =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"top" (create scope)
;;
