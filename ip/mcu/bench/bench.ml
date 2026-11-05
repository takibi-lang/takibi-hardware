(* MCU testbench shared by Cyclesim (S1) and Verilator (S2): load a firmware
   image through the load port, type [input] on the UART, collect everything
   the MCU prints, and check every retired instruction against the golden
   model.

   The MCU has a one-byte receive buffer, so the typist waits for each key's
   echo (and for the "> " prompt after Enter, and before the first key)
   before typing the next one. *)
open! Base
open! Hardcaml

let clocks_per_bit = 4

(* Simulation configurations: the boards' ISA and RAM, a fast UART. *)
let icestick =
  { Mcu.Config.base = Rv32e; ram_bytes = 4096; clocks_per_bit; counters = false; zicsr = false; dual_read = false; fetch_overlap = false; ma = false; barrel_shift = false; pipeline = false }
;;

(* The i9 MCU as designs/mcu_i9 builds it: the pipelined core (#4) *)
let i9 = { Mcu.Config.base = Rv32i; ram_bytes = 65536; clocks_per_bit; counters = false; zicsr = true; dual_read = true; fetch_overlap = true; ma = true; barrel_shift = false; pipeline = true }

(* ... and with the multi-cycle core, as before #4 *)
let i9_multicycle = { i9 with pipeline = false }
let create config scope = Mcu.create config scope

let words_of_image image =
  let n = (String.length image + 3) / 4 in
  List.init n ~f:(fun k ->
    List.fold (List.range 0 4) ~init:0 ~f:(fun acc b ->
      let idx = (4 * k) + b in
      if idx < String.length image
      then acc lor (Char.to_int image.[idx] lsl (8 * b))
      else acc))
;;

type result =
  { output : string
  ; leds : int
  ; retired : int
  ; interrupts : int
  ; cycles : int
  ; trap : int option
  ; mismatch : string option
  }

let run
  (config : Mcu.Config.t)
  (sim : (_ Mcu.I.t, _ Mcu.O.t) Cyclesim.t)
  ~image
  ~input
  ?(quiet_cycles = 10 * clocks_per_bit)
  ?(on_cycle = fun (_ : int) -> ())
  ~cycles
  ()
  =
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let program = words_of_image image in
  (* Load the image with the core held in reset. *)
  i.clear := Bits.vdd;
  i.uart_rx := Bits.vdd;
  List.iteri program ~f:(fun k w ->
    i.load_we := Bits.vdd;
    i.load_addr := Bits.of_int ~width:Mcu.max_word_bits k;
    i.load_data := Bits.of_int ~width:32 w;
    Cyclesim.cycle sim);
  i.load_we := Bits.gnd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let lockstep =
    Rv32_bench.Lockstep.create
      ~is_io:(fun a -> a land 0x1000_0000 <> 0)
      ~zicsr:config.zicsr
      ~m:config.ma
      ~a:config.ma
      ~base:config.base
      ~mem_bytes:config.ram_bytes
      ~program
      ()
  in
  let line = Uart_bench.Uart_line.create ~clocks_per_bit in
  let monitor = Uart_bench.Uart_monitor.create ~clocks_per_bit in
  let output = Buffer.create 128 in
  let pending = ref (String.to_list input) in
  let quiet = ref 0 in
  let expect = ref "> " in
  let sent_at = ref 0 in
  let ready () =
    let since = Buffer.length output - !sent_at in
    String.is_suffix (Buffer.To_string.sub output ~pos:!sent_at ~len:since) ~suffix:!expect
  in
  let trap = ref None in
  let cycle = ref 0 in
  let irq_fetch = ref 0 in
  while !cycle < cycles && Option.is_none !trap && Option.is_none lockstep.mismatch do
    (* Type the next key once the previous one was echoed and the MCU has
       been quiet for a while. *)
    (match !pending with
     | c :: rest
       when ready () && !quiet >= quiet_cycles && Uart_bench.Uart_line.idle line ->
       Uart_bench.Uart_line.send line (String.of_char c);
       pending := rest;
       expect := if Char.equal c '\r' || Char.equal c '\n' then "> " else String.of_char c;
       sent_at := Buffer.length output
     | _ -> ());
    i.uart_rx := Bits.of_bool (Uart_bench.Uart_line.next line);
    Cyclesim.cycle sim;
    on_cycle !cycle;
    let irq = Bits.to_int !(o.irq) in
    (* the pipeline decides at commit, in the cycle of the retirement or
       before it *)
    if config.pipeline && Bits.to_bool !(o.core.fetch) then irq_fetch := irq;
    let boundary_irq =
      if Bits.to_bool !(o.core.retire_trap)
         && Bits.to_int !(o.core.retire_cause) land 0x8000_0000 <> 0
      then irq
      else !irq_fetch
    in
    if Bits.to_bool !(o.core.fetch) then irq_fetch := irq;
    if Bits.to_bool !(o.core.halted)
    then (
      let code = Bits.to_int !(o.core.trap) in
      Rv32_bench.Lockstep.on_halt lockstep ~trap:code;
      trap := Some code)
    else if Bits.to_bool !(o.core.retire)
    then Rv32_bench.Lockstep.on_retire ~irq ~irq_fetch:boundary_irq lockstep o.core;
    (match Uart_bench.Uart_monitor.step monitor (Bits.to_bool !(o.uart_tx)) with
     | Some c ->
       Buffer.add_char output c;
       quiet := 0
     | None -> Int.incr quiet);
    Int.incr cycle
  done;
  { output = Buffer.contents output
  ; leds = Bits.to_int !(o.leds)
  ; retired = lockstep.retired
  ; interrupts = lockstep.interrupts
  ; cycles = !cycle
  ; trap = !trap
  ; mismatch = lockstep.mismatch
  }
;;

let firmware path = Stdio.In_channel.read_all path
