(* The SoC (Soc_top) in Cyclesim with models of everything on the board
   around it: the EM638325 SDRAM (Sdram_model, timing checked), the W25Q64
   flash (W25q_model) holding [flash], and the serial line (bytes typed
   into the receiver, the transmitter decoded). Every instruction the core
   retires is checked in lockstep with the golden model, which sees the
   boot ROM and the flash image and takes the device loads from the core.

   Inputs are typed when the UART output ends with [prompt] (or at once
   without a prompt), one byte at a time. *)
open! Base
open! Hardcaml
module Top = Soc.Soc_top
module Sim = Cyclesim.With_interface (Top.I) (Top.O)
module Map = Soc_model.Soc_map

type result =
  { cycles : int
  ; retired : int
  ; interrupts : int
  ; output : string
  ; mismatch : string option
  ; sdram_violations : string list
  ; flash_errors : string list
  ; halted : int option (* the core's trap code *)
  }
[@@deriving sexp_of]

let clock_hz = 50_000_000
let baud = 5_000_000 (* fast: 10 cycles per bit, for simulation *)

let config ~boot_rom =
  { Top.Config.clock_hz
  ; baud
  ; boot_rom
  ; sdram = Sdram.Sdram_ctrl.Config.create ~clock_mhz:50 ()
  ; tlb_entries = 8
  }
;;

(* A small incremental 8N1 decoder of the transmit line. *)
module Rx_decoder = struct
  type t =
    { clocks_per_bit : int
    ; mutable state : [ `Idle | `Bits of int * int * int ] (* cycle, bit, byte *)
    ; mutable prev : bool
    ; out : Buffer.t
    }

  let create ~clocks_per_bit = { clocks_per_bit; state = `Idle; prev = true; out = Buffer.create 256 }

  let step t line =
    (match t.state with
     | `Idle -> if t.prev && not line then t.state <- `Bits (0, 0, 0)
     | `Bits (c, bit, byte) ->
       let c = c + 1 in
       let mid k = c = (k * t.clocks_per_bit) + (t.clocks_per_bit / 2) in
       if bit < 8 && mid (bit + 1)
       then t.state <- `Bits (c, bit + 1, if line then byte lor (1 lsl bit) else byte)
       else if bit = 8 && mid 9
       then (
         Buffer.add_char t.out (Char.of_int_exn byte);
         t.state <- `Idle)
       else t.state <- `Bits (c, bit, byte));
    t.prev <- line
  ;;
end

let words_of_string s =
  Array.init ((String.length s + 3) / 4) ~f:(fun k ->
    List.fold (List.range 0 4) ~init:0 ~f:(fun acc b ->
      let i = (4 * k) + b in
      if i < String.length s then acc lor (Char.to_int s.[i] lsl (8 * b)) else acc))
;;

let run
  ?(input = "")
  ?prompt
  ?(until = fun (_ : string) -> false)
  ?(max_cycles = 1_000_000)
  ?(lockstep = true)
  ?(trace = fun (_ : Rv32_model.Machine.retire) -> ())
  ?(on_output = fun (_ : char) -> ())
  ?sim
  ~boot_rom
  ~flash
  ()
  =
  let sim =
    match sim with
    | Some sim -> sim
    | None -> Sim.create (Top.create (config ~boot_rom) (Scope.create ~flatten_design:true ()))
  in
  let i = Cyclesim.inputs sim in
  let pins = Cyclesim.outputs sim
  and o = Cyclesim.outputs ~clock_edge:Before sim in
  let sdram = Sdram_bench.Sdram_model.create ~clock_mhz:50 ~cas_latency:2 ~read_latency:3 () in
  let w25q = Spi_flash_bench.W25q_model.create ~clock_mhz:50 flash in
  let clocks_per_bit = clock_hz / baud in
  let line = Uart_bench.Uart_line.create ~clocks_per_bit in
  let decoder = Rx_decoder.create ~clocks_per_bit in
  let rom_bytes = 4 * Array.length boot_rom in
  let image_byte s off = if off < String.length s then Char.to_int s.[off] else 0xff in
  let io_image ~addr ~bytes =
    let read f = Some (List.fold (List.range 0 bytes) ~init:0 ~f:(fun acc k -> acc lor (f (addr + k) lsl (8 * k)))) in
    if addr < Map.boot_rom_bytes
    then
      read (fun a ->
        let a = a % rom_bytes in
        (boot_rom.(a / 4) lsr (8 * (a % 4))) land 0xff)
    else if addr >= Map.flash_base && addr < Map.flash_base + Map.flash_bytes
    then read (fun a -> image_byte flash (a - Map.flash_base))
    else None
  in
  let ls =
    Rv32_bench.Lockstep.create
      ~zicsr:true
      ~m:true
      ~a:true
      ~s:true
      ~is_io:(fun a -> a < Map.ram_base || a >= Map.ram_base + Map.ram_bytes)
      ~io_image
      ~mem_base:Map.ram_base
      ~base:Rv32i
      ~mem_bytes:Map.ram_bytes
      ~program:[]
      ()
  in
  ls.model.pc <- 0;
  let pending_input = ref (String.to_list input) in
  let irq_fetch = ref 0
  and time_fetch = ref 0 in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  (* the output, re-read only when it grew *)
  let out = ref "" in
  let stop = ref false in
  let rec loop cycle =
    if Buffer.length decoder.out <> String.length !out
    then (
      out := Buffer.contents decoder.out;
      on_output !out.[String.length !out - 1];
      if until !out then stop := true);
    let out = !out in
    if cycle >= max_cycles || !stop || Option.is_some ls.mismatch || Bits.to_bool !(pins.core.halted)
    then cycle
    else (
      (* the models see this cycle's (registered) pins *)
      let dq =
        Sdram_bench.Sdram_model.step
          sdram
          ~cmd:(Bits.to_int !(pins.sdram_cmd))
          ~a:(Bits.to_int !(pins.sdram_a))
          ~ba:(Bits.to_int !(pins.sdram_ba))
          ~dq_out:(Bits.to_int !(pins.sdram_dq_out))
          ~dq_oe:(Bits.to_bool !(pins.sdram_dq_oe))
      in
      i.sdram_dq_in := Bits.of_int ~width:32 (Option.value dq ~default:0);
      i.flash_miso
      := Bits.of_bool
           (Spi_flash_bench.W25q_model.step
              w25q
              ~cs_n:(Bits.to_bool !(pins.flash_cs_n))
              ~sck:(Bits.to_bool !(pins.flash_sck))
              ~mosi:(Bits.to_bool !(pins.flash_mosi)));
      (match !pending_input with
       | c :: rest
         when Uart_bench.Uart_line.idle line
              && Option.value_map prompt ~default:true ~f:(fun p -> String.is_suffix out ~suffix:p)
         ->
         Uart_bench.Uart_line.send line (String.of_char c);
         pending_input := rest
       | _ -> ());
      i.uart_rx := Bits.of_bool (Uart_bench.Uart_line.next line);
      Cyclesim.cycle_check sim;
      Cyclesim.cycle_before_clock_edge sim;
      let irq_now = Bits.to_int !(o.irq)
      and time_now = Bits.to_int !(o.mtime) in
      if lockstep
      then (
        let entry =
          Bits.to_bool !(o.core.retire_trap)
          && Bits.to_int !(o.core.retire_cause) land 0x8000_0000 <> 0
        in
        if Bits.to_bool !(o.core.retire) then trace (Rv32_bench.Lockstep.of_core o.core);
        if Bits.to_bool !(o.core.retire)
        then
          Rv32_bench.Lockstep.on_retire
            ~irq:irq_now
            ~irq_fetch:(if entry then irq_now else !irq_fetch)
            ~time:time_now
            ~time_fetch:(if entry then time_now else !time_fetch)
            ls
            o.core;
        if Bits.to_bool !(o.core.fetch)
        then (
          irq_fetch := irq_now;
          time_fetch := time_now));
      Cyclesim.cycle_at_clock_edge sim;
      Cyclesim.cycle_after_clock_edge sim;
      Rx_decoder.step decoder (Bits.to_bool !(pins.uart_tx));
      loop (cycle + 1))
  in
  let cycles = loop 0 in
  { cycles
  ; retired = ls.retired
  ; interrupts = ls.interrupts
  ; output = Buffer.contents decoder.out
  ; mismatch = ls.mismatch
  ; sdram_violations = List.rev sdram.violations
  ; flash_errors = List.rev w25q.errors
  ; halted = (if Bits.to_bool !(pins.core.halted) then Some (Bits.to_int !(pins.core.trap)) else None)
  }
;;
