(* The SoC (Soc_top) in Cyclesim with models of everything on the board
   around it: the EM638325 SDRAM (Sdram_model, timing checked), the W25Q64
   flash (W25q_model) holding [flash], and the serial line (bytes typed
   into the receiver, the transmitter decoded). Every instruction the core
   retires is checked in lockstep with the golden model, which sees the
   boot ROM and the flash image and takes the device loads from the core.

   Input is typed line by line: when the UART output ends with [prompt]
   (or at once without a prompt), the next line up to and including its
   '\r' is typed, one byte every [key_interval] cycles (the simulated line
   runs at 5 Mbaud; typing at that rate overruns the 16-byte receive FIFO
   while the kernel is busy, which a person at 115200 baud never does). *)
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

let config ?(harts = 1) ~boot_rom () =
  { Top.Config.clock_hz
  ; baud
  ; boot_rom
  ; sdram = Sdram.Sdram_ctrl.Config.create ~clock_mhz:50 ()
  ; tlb_entries = 8
  ; harts
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
  ?(key_interval = 20_000)
  ?prompt
  ?(until = fun (_ : string) -> false)
  ?(max_cycles = 1_000_000)
  ?(lockstep = true)
  ?(trace = fun (_ : Rv32_model.Machine.retire) -> ())
  ?(harts = 1)
  ?(on_output = fun (_ : char) -> ())
  ?sim
  ~boot_rom
  ~flash
  ()
  =
  let sim =
    match sim with
    | Some sim -> sim
    | None ->
      Sim.create (Top.create (config ~harts ~boot_rom ()) (Scope.create ~flatten_design:true ()))
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
  (* one golden model per hart, sharing the RAM; with two harts data
     loads take the core's values (the other core's writes race with
     them) *)
  let make_ls ?shared_mem hartid =
    let ls =
      Rv32_bench.Lockstep.create
        ~zicsr:true
        ~m:true
        ~a:true
        ~s:true
        ~is_io:(fun a -> a < Map.ram_base || a >= Map.ram_base + Map.ram_bytes)
        ~io_image
        ~mem_base:Map.ram_base
        ~hartid
        ?shared_mem
        ~data_loads_from_core:(harts > 1)
        ~base:Rv32i
        ~mem_bytes:Map.ram_bytes
        ~program:[]
        ()
    in
    ls.model.pc <- 0;
    ls
  in
  let ls0 = make_ls 0 in
  let lss =
    Array.init harts ~f:(fun h -> if h = 0 then ls0 else make_ls ~shared_mem:ls0.model.mem h)
  in
  let pending_input = ref (String.to_list input) in
  let typing = ref false (* inside a line, after its prompt *)
  and next_key = ref 0 in
  let irq_fetch = Array.create ~len:harts 0
  and time_fetch = Array.create ~len:harts 0 in
  let mismatch () = Array.find_map lss ~f:(fun l -> l.mismatch) in
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
    if cycle >= max_cycles
       || !stop
       || Option.is_some (mismatch ())
       || Bits.to_bool !(pins.core.halted)
       || Bits.to_bool !(pins.core1.halted)
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
       | c :: rest when cycle >= !next_key && Uart_bench.Uart_line.idle line ->
         if (not !typing)
            && Option.value_map prompt ~default:true ~f:(fun p -> String.is_suffix out ~suffix:p)
         then typing := true;
         if !typing
         then (
           Uart_bench.Uart_line.send line (String.of_char c);
           pending_input := rest;
           next_key := cycle + key_interval;
           if Char.equal c '\r' then typing := false)
       | _ -> ());
      i.uart_rx := Bits.of_bool (Uart_bench.Uart_line.next line);
      Cyclesim.cycle_check sim;
      Cyclesim.cycle_before_clock_edge sim;
      let time_now = Bits.to_int !(o.mtime) in
      if lockstep
      then
        Array.iteri lss ~f:(fun h ls ->
          let core = if h = 0 then o.core else o.core1 in
          let irq_now = Bits.to_int !(if h = 0 then o.irq else o.irq1) in
          if Bits.to_bool !(core.reservation_lost) then Rv32_bench.Lockstep.reservation_lost ls;
          let entry =
            Bits.to_bool !(core.retire_trap)
            && Bits.to_int !(core.retire_cause) land 0x8000_0000 <> 0
          in
          if h = 0 && Bits.to_bool !(core.retire) then trace (Rv32_bench.Lockstep.of_core core);
          if Bits.to_bool !(core.retire)
          then
            Rv32_bench.Lockstep.on_retire
              ~irq:irq_now
              ~irq_fetch:(if entry then irq_now else irq_fetch.(h))
              ~time:time_now
              ~time_fetch:(if entry then time_now else time_fetch.(h))
              ls
              core;
          if Bits.to_bool !(core.fetch)
          then (
            irq_fetch.(h) <- irq_now;
            time_fetch.(h) <- time_now));
      Cyclesim.cycle_at_clock_edge sim;
      Cyclesim.cycle_after_clock_edge sim;
      Rx_decoder.step decoder (Bits.to_bool !(pins.uart_tx));
      loop (cycle + 1))
  in
  let cycles = loop 0 in
  { cycles
  ; retired = Array.sum (module Int) lss ~f:(fun l -> l.retired)
  ; interrupts = Array.sum (module Int) lss ~f:(fun l -> l.interrupts)
  ; output = Buffer.contents decoder.out
  ; mismatch = mismatch ()
  ; sdram_violations = List.rev sdram.violations
  ; flash_errors = List.rev w25q.errors
  ; halted = (if Bits.to_bool !(pins.core.halted) then Some (Bits.to_int !(pins.core.trap)) else None)
  }
;;
