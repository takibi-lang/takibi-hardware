(* Colorlight i9 v7.2 board top for the Linux SoC (issue #21, L10): the
   HardCaml module `soc_board`, inside the hand-written Verilog shell
   rtl/top.v that holds what HardCaml cannot express: the bidirectional
   SDRAM data pins (BB) and USRMCLK (the flash clock, a primitive without
   outputs).

   Clock: 25 MHz oscillator -> PLL -> 50 MHz. The SoC is held in reset
   until the PLL locks and for 21 ms after (Mcu.Startup, B-0014).

   SDRAM I/O timing (board-level, EXPERIMENT switches below): the SDRAM
   clock is the system clock inverted through an ODDRX1F, so commands and
   write data launched on our rising edge are sampled by the SDRAM half a
   period later. With CAS latency 2 the read data is valid from about
   56 ns to 72 ns after the rising edge that launched READ; it is captured
   on our falling edge at 70 ns (a negative-edge register here) and handed
   to the controller at 80 ns: read_latency 3 in the controller's terms.
     EXPERIMENT=sdram-rise   capture on the rising edge at 60 ns instead
                             (read_latency 2)
     EXPERIMENT=sdram-clk    SDRAM clock in phase with ours (not inverted)

   LED (active low): blinks slowly while the SDRAM initialises or the
   boot ROM runs, steady on once the core has run in S-mode... kept
   simple: on = SDRAM initialised, fast blink = the core halted. *)
open! Base
open! Hardcaml
open Signal

let osc_mhz = 25
let clock_mhz = 50
let clock_hz = clock_mhz * 1_000_000
let baud = 115_200
let experiment = Sys.getenv "EXPERIMENT"
let is_experiment e = Option.equal String.equal experiment (Some e)
let capture_rising = is_experiment "sdram-rise"
let clock_in_phase = is_experiment "sdram-clk"

let config ~boot_rom =
  { Soc.Soc_top.Config.clock_hz
  ; baud
  ; boot_rom
  ; sdram =
      Sdram.Sdram_ctrl.Config.create
        ~clock_mhz
        ~cas_latency:2
        ~read_latency:(if capture_rising then 2 else 3)
        ()
  ; tlb_entries = 8
  }
;;

module I = struct
  type 'a t =
    { clock : 'a
    ; uart_rx : 'a
    ; flash_miso : 'a
    ; sdram_dq_in : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uart_tx : 'a
    ; led_n : 'a
    ; flash_cs_n : 'a
    ; flash_mosi : 'a
    ; flash_sck : 'a (* to USRMCLK in the shell *)
    ; sdram_clk : 'a
    ; sdram_a : 'a [@bits 11]
    ; sdram_ba : 'a [@bits 2]
    ; sdram_ras_n : 'a
    ; sdram_cas_n : 'a
    ; sdram_we_n : 'a
    ; sdram_dq_out : 'a [@bits 32]
    ; sdram_dq_oe : 'a
    }
  [@@deriving hardcaml]
end

(* Registers without a reset (power-up values for the generator). *)
let no_reset = [ "blink"; "pll_lock_meta"; "pll_lock_sync"; "sdram_dq_capture"; "led_q" ]

let create ~boot_rom scope (i : _ I.t) =
  let clock, locked = Ecp5.Pll.create ~fin_mhz:osc_mhz ~fout_mhz:clock_mhz ~clkin:i.clock in
  let clock = clock -- "sys_clock" in
  let free = Reg_spec.create ~clock () in
  let%hw pll_lock_meta = reg free locked in
  let%hw pll_lock_sync = reg free pll_lock_meta in
  let hold = Mcu.Startup.hold ~clock_hz scope ~clock |: ~:pll_lock_sync in
  let%hw blink = reg_fb free ~width:24 ~f:(fun d -> d +:. 1) in
  let%hw sdram_dq_capture =
    if capture_rising
    then i.sdram_dq_in
    else reg (Reg_spec.override (Reg_spec.create ~clock ()) ~clock_edge:Falling) i.sdram_dq_in
  in
  let soc =
    Soc.Soc_top.hierarchical
      (config ~boot_rom)
      scope
      { Soc.Soc_top.I.clock
      ; clear = hold
      ; uart_rx = i.uart_rx
      ; flash_miso = i.flash_miso
      ; sdram_dq_in = sdram_dq_capture
      }
  in
  let led =
    mux2 soc.core.halted blink.:(21) (mux2 soc.sdram_ready vdd (msb blink))
  in
  { O.uart_tx = soc.uart_tx
  ; led_n = (reg free ~:led -- "led_q")
  ; flash_cs_n = soc.flash_cs_n
  ; flash_mosi = soc.flash_mosi
  ; flash_sck = soc.flash_sck
  ; sdram_clk =
      (if clock_in_phase
       then Ecp5.Prims.oddr ~clock ~d0:vdd ~d1:gnd
       else Ecp5.Prims.oddr ~clock ~d0:gnd ~d1:vdd)
  ; sdram_a = soc.sdram_a
  ; sdram_ba = soc.sdram_ba
  ; sdram_ras_n = soc.sdram_cmd.:(2)
  ; sdram_cas_n = soc.sdram_cmd.:(1)
  ; sdram_we_n = soc.sdram_cmd.:(0)
  ; sdram_dq_out = soc.sdram_dq_out
  ; sdram_dq_oe = soc.sdram_dq_oe
  }
;;

let circuit ~boot_rom scope =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"soc_board" (create ~boot_rom scope)
;;
