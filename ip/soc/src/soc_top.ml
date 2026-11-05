(* The Linux SoC (issue #21): the rv32 core with M, A, S/U and Sv32, a boot
   ROM, CLINT, PLIC, 16550 UART, the SPI flash window and the SDRAM
   controller, at the addresses of Soc_model.Soc_map:

     0x0000_0000  boot ROM (LUTs; [boot_rom] words, aliased in 64 KiB)
     0x0200_0000  CLINT            0x0c00_0000  PLIC
     0x1000_0000  UART (16550)     0x2000_0000  SPI flash window (8 MiB)
     0x8000_0000  SDRAM (8 MiB)

   The decoder looks at the address bits that tell the regions apart (31,
   29, 28, 27, 25, in that order; anything else is the boot ROM). The core's
   bus protocol (#26) is passed to the SDRAM controller and the flash
   window; the ROM and the register-bus devices accept at once and answer
   in the next cycle. A register remembers which target owes read data.

   Interrupts: MSIP and MTIP from the CLINT, MEIP and SEIP from the PLIC's
   M and S contexts (the UART is source 1); the core's time CSR and Sstc
   use the CLINT's mtime. *)
open! Base
open! Hardcaml
open Signal

module Config = struct
  type t =
    { clock_hz : int
    ; baud : int
    ; boot_rom : int array (* words *)
    ; sdram : Sdram.Sdram_ctrl.Config.t
    ; tlb_entries : int
    }
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; uart_rx : 'a
    ; flash_miso : 'a
    ; sdram_dq_in : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uart_tx : 'a
    ; flash_cs_n : 'a
    ; flash_sck : 'a
    ; flash_mosi : 'a
    ; sdram_cmd : 'a [@bits 3]
    ; sdram_a : 'a [@bits 11]
    ; sdram_ba : 'a [@bits 2]
    ; sdram_dq_out : 'a [@bits 32]
    ; sdram_dq_oe : 'a
    ; sdram_ready : 'a (* initialisation done *)
    ; core : 'a Rv32.Core.O.t [@rtlprefix "core_"]
    ; irq : 'a [@bits 4] (* MSIP, MTIP, MEIP, SEIP: the core's, for benches *)
    ; mtime : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

module Target = struct
  let rom = 0
  let clint = 1
  let plic = 2
  let uart = 3
  let flash = 4
  let sdram = 5
end

let create (c : Config.t) scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let mem_ready = wire 1
  and mem_rvalid = wire 1
  and mem_rdata = wire 32
  and irq = wire 3
  and seip = wire 1
  and mtime = wire 64 in
  let core =
    Rv32.Core.hierarchical
      ~s:true
      ~m:true
      ~a:true
      ~zifencei:true
      ~dual_read:true
      ~fetch_overlap:true
      ~tlb_entries:c.tlb_entries
      ~base:Rv32i
      scope
      { Rv32.Core.I.clock = i.clock
      ; clear = i.clear
      ; mem_rdata
      ; mem_ready
      ; mem_rvalid
      ; irq
      ; seip
      ; mtime
      }
  in
  (* Bus bridge: the core's request is registered before it reaches the
     targets, and the core's ready only says whether the register is free.
     This cuts the combinational path core address -> decode -> target
     ready -> core state (34 MHz without it). One more cycle per access. *)
  let bridge_ready = wire 1 in
  let%hw req_valid =
    reg_fb spec ~width:1 ~f:(fun v ->
      mux2 v (mux2 bridge_ready gnd vdd) (core.mem_read |: core.mem_write))
  in
  (* the payload is captured whenever the register is free (no fan-out of
     the request decision onto ~100 enables); req_valid says if it is a
     request *)
  let take = ~:req_valid in
  let%hw req_write = reg spec ~enable:take core.mem_write in
  let%hw req_addr = reg spec ~enable:take core.mem_addr in
  let%hw req_wdata = reg spec ~enable:take core.mem_wdata in
  let%hw req_wmask = reg spec ~enable:take core.mem_wmask in
  let addr = req_addr in
  let target =
    mux2
      addr.:(31)
      (of_int ~width:3 Target.sdram)
      (mux2
         addr.:(29)
         (of_int ~width:3 Target.flash)
         (mux2
            addr.:(28)
            (of_int ~width:3 Target.uart)
            (mux2
               addr.:(27)
               (of_int ~width:3 Target.plic)
               (mux2 addr.:(25) (of_int ~width:3 Target.clint) (of_int ~width:3 Target.rom)))))
    -- "target"
  in
  let is t = target ==:. t in
  let read = req_valid &: ~:req_write
  and write = req_valid &: req_write in
  let bus t =
    { Regbus.I.clock = i.clock
    ; clear = i.clear
    ; read = read &: is t
    ; write = write &: is t
    ; addr = addr.:[23, 0]
    ; wdata = req_wdata
    ; wmask = req_wmask
    }
  in
  (* Boot ROM *)
  let rom_words = Array.length c.boot_rom in
  let rom_bits = Int.max 1 (Int.ceil_log2 rom_words) in
  let rom_data =
    reg
      spec
      ~enable:(read &: is Target.rom)
      (mux
         addr.:[rom_bits + 1, 2]
         (List.init (1 lsl rom_bits) ~f:(fun k ->
            of_int ~width:32 (if k < rom_words then c.boot_rom.(k) else 0))))
    -- "rom_data"
  in
  (* Register-bus devices *)
  let clint =
    Clint.hierarchical ~cycles_per_tick:(c.clock_hz / 1_000_000) scope (bus Target.clint)
  in
  let uart =
    Uart16550.hierarchical
      ~clocks_per_bit:(c.clock_hz / c.baud)
      scope
      (bus Target.uart)
      ~rx:i.uart_rx
  in
  let plic = Plic.create ~sources:1 scope (bus Target.plic) uart.irq in
  (* Flash window and SDRAM *)
  let flash =
    Spi_flash.Flash_window.hierarchical
      scope
      { Spi_flash.Flash_window.I.clock = i.clock
      ; clear = i.clear
      ; read = read &: is Target.flash
      ; write = write &: is Target.flash
      ; addr = addr.:[22, 0]
      ; miso = i.flash_miso
      }
  in
  let sdram =
    Sdram.Sdram_ctrl.hierarchical
      c.sdram
      scope
      { Sdram.Sdram_ctrl.I.clock = i.clock
      ; clear = i.clear
      ; read = read &: is Target.sdram
      ; write = write &: is Target.sdram
      ; addr = addr.:[22, 0]
      ; wdata = req_wdata
      ; wmask = req_wmask
      ; dq_in = i.sdram_dq_in
      }
  in
  (* Handshake *)
  let ready =
    mux2 (is Target.sdram) sdram.ready (mux2 (is Target.flash) flash.ready vdd) -- "bus_ready"
  in
  bridge_ready <== ready;
  mem_ready <== ~:req_valid;
  let accepted_read = read &: ready in
  let owner = reg spec ~enable:accepted_read target -- "read_owner" in
  let device_read =
    accepted_read &: ~:(is Target.sdram) &: ~:(is Target.flash)
  in
  let device_rvalid = reg spec device_read -- "device_rvalid" in
  let owner_is t = owner ==:. t in
  mem_rvalid
  <== (device_rvalid |: (owner_is Target.flash &: flash.rvalid) |: (owner_is Target.sdram &: sdram.rvalid));
  mem_rdata
  <== mux
        owner
        [ rom_data; clint.rdata; plic.rdata; uart.rdata; flash.rdata; sdram.rdata; zero 32; zero 32 ];
  irq <== (plic.irq.:(0) @: clint.mtip @: clint.msip);
  seip <== plic.irq.:(1);
  mtime <== clint.mtime;
  { O.uart_tx = uart.tx
  ; flash_cs_n = flash.cs_n
  ; flash_sck = flash.sck
  ; flash_mosi = flash.mosi
  ; sdram_cmd = sdram.cmd
  ; sdram_a = sdram.a
  ; sdram_ba = sdram.ba
  ; sdram_dq_out = sdram.dq_out
  ; sdram_dq_oe = sdram.dq_oe
  ; sdram_ready = sdram.init_done
  ; core
  ; irq = seip @: irq
  ; mtime
  }
;;

let hierarchical c scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"soc" (create c)
;;
