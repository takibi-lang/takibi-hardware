(* Colorlight i9 v7.2 (Lattice ECP5 LFE5U-45F) top level for the MCU:
   RV32I + Zicsr (CSRs, interrupts, mcycle/minstret), 64 KiB RAM, a
   50 MHz system clock from the 25 MHz oscillator through the ECP5 PLL
   (Pll; EXPERIMENT=no-pll runs from the 25 MHz pin directly), 115200
   baud through the ext board's DAPLink USB serial port, LED D2.

   Pins (designs/mcu_i9/colorlight_i9.lpf) follow wuxx/Colorlight-FPGA-Projects:
   clock P3, UART TX J17 / RX H18 (as on the i5 ext board), LED D2 on L2.
   The LED is driven active low, as on the other Colorlight modules.

   Bring-up aids (B-0014; docs/BRINGUP_I9.md):
   - the MCU is held in reset until the PLL reports lock (synchronised)
     and for about 21 ms after that (Mcu.Startup; EXPERIMENT=no-hold
     shortens the latter);
   - the single LED shows the state: slow blink = clock and bitstream run
     but the firmware has not started; steady on = firmware started (crt0
     sets LEDS bit 0); fast blink = the core halted (trap). *)
open! Base
open! Hardcaml
open Signal

let osc_mhz = 25

(* The system clock: the one setting the PLL, nextpnr (--freq, through
   `main.exe clock-mhz`), the UART divider, the start-up hold and the
   testbenches follow. Chosen below the estimated Fmax with a margin
   (issue #23). *)
let use_pll = not (Option.equal String.equal (Sys.getenv "EXPERIMENT") (Some "no-pll"))
let clock_mhz = if use_pll then 50 else osc_mhz
let clock_hz = clock_mhz * 1_000_000

let config =
  { Mcu.Config.base = Rv32i
  ; ram_bytes = 65536
  ; clocks_per_bit = clock_hz / 115_200
  ; counters = false
  ; zicsr = true
  ; dual_read = true
  ; fetch_overlap = true
  ; ma = true
  ; barrel_shift = false (* evaluated for #23: CPI 2.69 -> 2.67, +449 LUTs *)
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
    ; led_n : 'a
    }
  [@@deriving hardcaml]
end

(* Registers without a reset, for the generator's power-up values. *)
let no_reset = [ "blink"; "pll_lock_meta"; "pll_lock_sync" ]

let create scope (i : _ I.t) =
  let clock, locked =
    if use_pll
    then Ecp5.Pll.create ~fin_mhz:osc_mhz ~fout_mhz:clock_mhz ~clkin:i.clock
    else i.clock, vdd
  in
  let clock = clock -- "sys_clock" in
  let free = Reg_spec.create ~clock () in
  (* LOCK comes from the PLL, asynchronous to its output clock. *)
  let%hw pll_lock_meta = reg free locked in
  let%hw pll_lock_sync = reg free pll_lock_meta in
  let hold = Mcu.Startup.hold ~clock_hz scope ~clock |: ~:pll_lock_sync in
  let%hw blink = reg_fb free ~width:24 ~f:(fun d -> d +:. 1) in
  let o =
    Mcu.hierarchical
      config
      scope
      { Mcu.I.clock = clock
      ; clear = hold
      ; uart_rx = i.uart_rx
      ; load_we = gnd
      ; load_addr = zero Mcu.max_word_bits
      ; load_data = zero 32
      }
  in
  let started = o.leds.:(0) in
  let led = mux2 o.core.halted blink.:(21) (mux2 started vdd (msb blink)) in
  { O.uart_tx = o.uart_tx; led_n = ~:led }
;;

let circuit scope =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"top" (create scope)
;;
