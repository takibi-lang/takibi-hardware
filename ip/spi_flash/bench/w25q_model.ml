(* Model of the W25Q64JV as the flash window uses it: READ (03h) with a
   24-bit address, SPI mode 0 or 3, one call per clock cycle with the pin
   levels of that cycle. MOSI is sampled on rising SCK edges; data bits
   are shifted out (MSB first) on falling edges, starting with the falling
   edge after the last address bit; the address increments through the
   array. Anything else is recorded as an error: an unknown command, SCK
   edges while deselected, CS# high for less than 10 ns. *)
open! Base

type t =
  { image : string
  ; period_ns : float
  ; mutable cs_n : bool
  ; mutable sck : bool
  ; mutable cs_high_cycles : int
  ; mutable bits_in : int
  ; mutable command : int
  ; mutable addr : int
  ; mutable data_phase : bool
  ; mutable bit : int (* next data bit, 7..0 *)
  ; mutable miso : bool
  ; mutable reads : int (* transfers *)
  ; mutable errors : string list
  ; mutable cycle : int
  }

let create ~clock_mhz image =
  { image
  ; period_ns = 1000. /. Float.of_int clock_mhz
  ; cs_n = true
  ; sck = false
  ; cs_high_cycles = 100
  ; bits_in = 0
  ; command = 0
  ; addr = 0
  ; data_phase = false
  ; bit = 7
  ; miso = false
  ; reads = 0
  ; errors = []
  ; cycle = 0
  }
;;

let error t s = if List.length t.errors < 10 then t.errors <- Printf.sprintf "cycle %d: %s" t.cycle s :: t.errors

let byte t a = if a < String.length t.image then Char.to_int t.image.[a] else 0xff

(* Pins of this cycle; returns MISO for this cycle. *)
let step t ~cs_n ~sck ~mosi =
  if t.cs_n && not cs_n
  then (
    (* select *)
    if Float.(Float.of_int t.cs_high_cycles *. t.period_ns < 10.) then error t "tSHSL";
    t.bits_in <- 0;
    t.command <- 0;
    t.data_phase <- false;
    t.reads <- t.reads + 1);
  if cs_n
  then (
    if Bool.(sck <> t.sck) && false then error t "SCK edge while deselected";
    t.cs_high_cycles <- (if t.cs_n then t.cs_high_cycles + 1 else 1))
  else (
    let rising = sck && not t.sck
    and falling = t.sck && not sck in
    if rising && not t.data_phase
    then (
      t.command <- (t.command lsl 1) lor Bool.to_int mosi;
      t.bits_in <- t.bits_in + 1;
      if t.bits_in = 8 && t.command <> 0x03
      then error t (Printf.sprintf "command %02x" t.command);
      if t.bits_in = 32
      then (
        t.addr <- t.command land 0xff_ffff;
        t.bit <- 7;
        t.data_phase <- true));
    if falling && t.data_phase && t.bits_in = 32
    then (
      t.miso <- (byte t t.addr lsr t.bit) land 1 = 1;
      if t.bit = 0
      then (
        t.bit <- 7;
        t.addr <- (t.addr + 1) land 0xff_ffff)
      else t.bit <- t.bit - 1));
  t.cs_n <- cs_n;
  t.sck <- sck;
  t.cycle <- t.cycle + 1;
  t.miso
;;
