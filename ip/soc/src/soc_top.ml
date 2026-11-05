(* The Linux SoC (issue #21): the rv32 core with M, A, S/U and Sv32, a boot
   ROM, CLINT, PLIC, 16550 UART, the SPI flash window and the SDRAM
   controller, at the addresses of Soc_model.Soc_map:

     0x0000_0000  boot ROM (LUTs; [boot_rom] words, aliased in 64 KiB)
     0x0200_0000  CLINT            0x0c00_0000  PLIC
     0x1000_0000  UART (16550)     0x2000_0000  SPI flash window (8 MiB)
     0x8000_0000  SDRAM (8 MiB), through a 32 KiB unified cache (#7, L8)

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
    ; harts : int (* 1 or 2 (#9) *)
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
    ; core1 : 'a Rv32.Core.O.t [@rtlprefix "core1_"] (* hart 1 (zeros with one) *)
    ; irq : 'a [@bits 4] (* MSIP, MTIP, MEIP, SEIP: the core's, for benches *)
    ; irq1 : 'a [@bits 4]
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
  let harts = c.harts in
  assert (harts >= 1 && harts <= 2);
  let sfx h n = if h = 0 then n else Printf.sprintf "%s%d" n h in
  let mem_rdata = wire 32
  and mtime = wire 64
  and snoop_addr = wire 32 in
  let per_hart () = Array.init harts ~f:(fun _ -> wire 1) in
  let mem_ready = per_hart ()
  and mem_rvalid = per_hart ()
  and seip = per_hart ()
  and snoop_valid = per_hart ()
  and sc_block = per_hart () in
  let irq = Array.init harts ~f:(fun _ -> wire 3) in
  let cores =
    Array.init harts ~f:(fun h ->
      Rv32.Core.hierarchical
        ~s:true
        ~m:true
        ~a:true
        ~zifencei:true
        ~dual_read:true
        ~fetch_overlap:true
        ~tlb_entries:c.tlb_entries
        ~barrel_shift:true
        ~base:Rv32i
        scope
        { Rv32.Core.I.clock = i.clock
        ; clear = i.clear
        ; mem_rdata
        ; mem_ready = mem_ready.(h)
        ; mem_rvalid = mem_rvalid.(h)
        ; irq = irq.(h)
        ; seip = seip.(h)
        ; mtime
        ; snoop_valid = snoop_valid.(h)
        ; snoop_addr
        ; sc_block = sc_block.(h)
        })
  in
  (* Bus bridges, one per core: the core's request is registered before it
     reaches the arbiter and the targets, and the core's ready only says
     whether its register is free. This cuts the combinational path core
     address -> decode -> target ready -> core state (34 MHz without it).
     One more cycle per access. The payload is captured whenever the
     register is free (no fan-out of the request decision onto ~100
     enables); req_valid says if it is a request. *)
  let granted = per_hart () in
  let bridges =
    Array.mapi cores ~f:(fun h core ->
      let valid =
        reg_fb spec ~width:1 ~f:(fun v ->
          mux2 v (mux2 granted.(h) gnd vdd) (core.mem_read |: core.mem_write))
        -- sfx h "req_valid"
      in
      let take = ~:valid in
      let r name x = reg spec ~enable:take x -- sfx h name in
      ( valid
      , r "req_write" core.mem_write
      , r "req_addr" core.mem_addr
      , r "req_wdata" core.mem_wdata
      , r "req_wmask" core.mem_wmask
      , r "req_sc" core.mem_sc
      , r "req_lock" core.mem_lock ))
  in
  let b_valid h = let v, _, _, _, _, _, _ = bridges.(h) in v
  and b_write h = let _, w, _, _, _, _, _ = bridges.(h) in w
  and b_sc h = let _, _, _, _, _, s, _ = bridges.(h) in s
  in
  (* Arbiter (#9, Arbiter: proved in formal/arbiter.sby) *)
  let bit2 f = (if harts > 1 then f 1 else gnd) @: f 0 in
  let arb_ready = wire 1
  and arb_rvalid = wire 1 in
  let arb =
    Arbiter.hierarchical
      scope
      { Arbiter.I.clock = i.clock
      ; clear = i.clear
      ; valid = bit2 b_valid
      ; write = bit2 b_write
      ; sc = bit2 b_sc
      ; lock = bit2 (fun h -> let _, _, _, _, _, _, l = bridges.(h) in l)
      ; core_sc = bit2 (fun h -> cores.(h).mem_sc)
      ; ready = arb_ready
      ; rvalid = arb_rvalid
      }
  in
  let sel = arb.sel
  and sel_valid = arb.sel_valid in
  let pick f = if harts = 1 then f 0 else mux2 sel (f 1) (f 0) in
  let field k h =
    let v, w, a, d, m, s, l = bridges.(h) in
    match k with
    | `Write -> w
    | `Addr -> a
    | `Wdata -> d
    | `Wmask -> m
    | `Sc -> s
    | `Lock -> l
    | `Valid -> v
  in
  let req_write = pick (field `Write) -- "req_write_sel" in
  let req_addr = pick (field `Addr) -- "req_addr_sel" in
  let req_wdata = pick (field `Wdata) in
  let req_wmask = pick (field `Wmask) in
  let req_valid = sel_valid in
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
    Clint.hierarchical ~harts ~cycles_per_tick:(c.clock_hz / 1_000_000) scope (bus Target.clint)
  in
  let uart =
    Uart16550.hierarchical
      ~clocks_per_bit:(c.clock_hz / c.baud)
      scope
      (bus Target.uart)
      ~rx:i.uart_rx
  in
  let plic = Plic.create ~contexts:(2 * harts) ~sources:1 scope (bus Target.plic) uart.irq in
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
  (* SDRAM behind the cache (#7, L8) *)
  let cache_o = Cache.O.Of_signal.wires () in
  let sdram =
    Sdram.Sdram_ctrl.hierarchical
      c.sdram
      scope
      { Sdram.Sdram_ctrl.I.clock = i.clock
      ; clear = i.clear
      ; read = cache_o.mem_read
      ; write = cache_o.mem_write
      ; burst = cache_o.mem_burst
      ; addr = cache_o.mem_addr
      ; wdata = cache_o.mem_wdata
      ; wmask = cache_o.mem_wmask
      ; dq_in = i.sdram_dq_in
      }
  in
  let cache =
    Cache.hierarchical
      scope
      { Cache.I.clock = i.clock
      ; clear = i.clear
      ; read = read &: is Target.sdram
      ; write = write &: is Target.sdram
      ; addr = addr.:[22, 0]
      ; wdata = req_wdata
      ; wmask = req_wmask
      ; mem_ready = sdram.ready
      ; mem_word_valid = sdram.word_valid
      ; mem_word_index = sdram.word_index
      ; mem_rdata = sdram.rdata
      ; mem_rvalid = sdram.rvalid
      }
  in
  Cache.O.Of_signal.assign cache_o cache;
  (* Handshake *)
  let ready =
    mux2 (is Target.sdram) cache.ready (mux2 (is Target.flash) flash.ready vdd) -- "bus_ready"
  in
  arb_ready <== ready;
  Array.iteri granted ~f:(fun h g -> g <== arb.granted.:(h));
  Array.iteri mem_ready ~f:(fun h w -> w <== ~:(b_valid h));
  let accepted_read = req_valid &: ready &: ~:req_write in
  let owner = reg spec ~enable:accepted_read target -- "read_owner" in
  let owner_hart = reg spec ~enable:accepted_read sel -- "read_owner_hart" in
  let device_read =
    accepted_read &: ~:(is Target.sdram) &: ~:(is Target.flash)
  in
  let device_rvalid = reg spec device_read -- "device_rvalid" in
  let owner_is t = owner ==:. t in
  let rvalid =
    (device_rvalid |: (owner_is Target.flash &: flash.rvalid) |: (owner_is Target.sdram &: cache.rvalid))
    -- "bus_rvalid"
  in
  arb_rvalid <== rvalid;
  Array.iteri mem_rvalid ~f:(fun h w -> w <== (rvalid &: (owner_hart ==:. h)));
  snoop_addr <== req_addr;
  Array.iteri snoop_valid ~f:(fun h w -> w <== arb.snoop.:(h));
  Array.iteri sc_block ~f:(fun h w -> w <== if h = 0 then arb.sc_block0 else arb.sc_block1);
  mem_rdata
  <== mux
        owner
        [ rom_data; clint.rdata; plic.rdata; uart.rdata; flash.rdata; cache.rdata; zero 32; zero 32 ];
  Array.iteri irq ~f:(fun h w ->
    w <== (plic.irq.:(2 * h) @: clint.mtip.:(h) @: clint.msip.:(h)));
  Array.iteri seip ~f:(fun h w -> w <== plic.irq.:((2 * h) + 1));
  mtime <== clint.mtime;
  let hart_irq h = if h < harts then seip.(h) @: irq.(h) else zero 4 in
  let core1 =
    if harts > 1 then cores.(1) else Rv32.Core.O.map Rv32.Core.O.port_widths ~f:(fun w -> zero w)
  in
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
  ; core = cores.(0)
  ; core1
  ; irq = hart_irq 0
  ; irq1 = hart_irq 1
  ; mtime
  }
;;

let hierarchical c scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"soc" (create c)
;;
