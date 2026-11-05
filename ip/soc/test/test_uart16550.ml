(* The 16550 (issue #28) with directed sequences: the register file
   against the L0 model, Linux's 8250 setup, transmit through the FIFO
   (decoded from the line), the THRE and receive-data interrupts, receive
   into the FIFO and its overflow. *)
open! Base
open! Hardcaml
open Stdio
module D = Soc_model.Devices

module Io = struct
  type 'a t =
    { bus : 'a Soc.Regbus.I.t
    ; rx : 'a
    }
  [@@deriving hardcaml]
end

module Sim = Cyclesim.With_interface (Io) (Soc.Uart16550.O)

let clocks_per_bit = 8

let create () =
  let sim =
    Sim.create (fun (x : _ Io.t) ->
      Soc.Uart16550.create ~clocks_per_bit (Scope.create ~flatten_design:true ()) x.bus ~rx:x.rx)
  in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let line = Uart_bench.Uart_line.create ~clocks_per_bit in
  let trace = Queue.create () in
  let cycle () =
    i.rx := Bits.of_bool (Uart_bench.Uart_line.next line);
    Cyclesim.cycle sim;
    Queue.enqueue trace (Bits.to_bool !(o.tx))
  in
  i.bus.clear := Bits.vdd;
  i.rx := Bits.vdd;
  Cyclesim.cycle sim;
  i.bus.clear := Bits.gnd;
  let access ~write off v =
    i.bus.read := Bits.of_bool (not write);
    i.bus.write := Bits.of_bool write;
    i.bus.addr := Bits.of_int ~width:24 off;
    i.bus.wdata := Bits.of_int ~width:32 ((v land 0xff) lsl (8 * (off land 3)));
    cycle ();
    i.bus.read := Bits.gnd;
    i.bus.write := Bits.gnd;
    Bits.to_int !(o.rdata) land 0xff
  in
  let read off = access ~write:false off 0 in
  let write off v = ignore (access ~write:true off v : int) in
  let irq () = Bits.to_bool !(o.irq) in
  let decoded () =
    Uart_bench.Uart_decode.decode ~clocks_per_bit (Queue.to_array trace)
  in
  read, write, cycle, irq, line, decoded
;;

let%expect_test "16550: registers, setup, transmit, receive, interrupts" =
  let read, write, cycle, irq, line, decoded = create () in
  let model = D.Uart.create () in
  (* Linux's 8250 setup on both, then every register compared *)
  let both off v =
    write off v;
    D.Uart.store model off v
  in
  List.iter
    [ 3, 0x80; 0, 27; 1, 0; 3, 0x03; 2, 0x07; 4, 0x0b; 7, 0x5a; 1, 0x00 ]
    ~f:(fun (off, v) -> both off v);
  List.iter [ 0; 1; 2; 3; 4; 5; 6; 7 ] ~f:(fun off ->
    let hw = read off
    and m = D.Uart.load model off in
    printf "reg %d: hw %02x model %02x%s\n" off hw m (if hw = m then "" else "  DIFFERS"));
  write 3 0x80;
  printf "DLL %d DLM %d\n" (read 0) (read 1);
  write 3 0x03;
  (* transmit a burst into the FIFO, then wait for TEMT *)
  String.iter "Hello, 16550!\n" ~f:(fun c -> write 0 (Char.to_int c));
  printf "LSR while sending: %02x\n" (read 5);
  while read 5 land 0x40 = 0 do
    cycle ()
  done;
  for _ = 1 to 2 * clocks_per_bit do
    cycle ()
  done;
  printf "sent: %S\n" (decoded ());
  (* THRE interrupt *)
  write 1 0x02;
  (* (arguments are evaluated right to left: bind the irq first) *)
  let shown_irq = irq () in
  printf "ETBEI with the FIFO empty: irq %b IIR %02x\n" shown_irq (read 2);
  let shown_irq = irq () in
  printf "after the IIR read: irq %b IIR %02x\n" shown_irq (read 2);
  write 0 (Char.to_int 'x');
  printf "after a THR write: irq %b\n" (irq ());
  while not (irq ()) do
    cycle ()
  done;
  let shown_irq = irq () in
  printf "FIFO empty again: irq %b IIR %02x\n" shown_irq (read 2);
  write 1 0x00;
  (* receive *)
  Uart_bench.Uart_line.send line "abc";
  for _ = 1 to 40 * clocks_per_bit do
    cycle ()
  done;
  write 1 0x01;
  let lsr_ = read 5 in
  let shown_irq = irq () in
  printf "received: LSR %02x irq %b IIR %02x\n" lsr_ shown_irq (read 2);
  let got = String.init 3 ~f:(fun _ -> Char.of_int_exn (read 0)) in
  let lsr_ = read 5 in
  printf "RBR: %S, then LSR %02x irq %b\n" got lsr_ (irq ());
  (* overflow: 20 bytes in, 16 kept *)
  Uart_bench.Uart_line.send line "0123456789abcdefghij";
  for _ = 1 to 220 * clocks_per_bit do
    cycle ()
  done;
  let buf = Buffer.create 16 in
  while read 5 land 1 = 1 do
    Buffer.add_char buf (Char.of_int_exn (read 0))
  done;
  printf "after 20 bytes: %S\n" (Buffer.contents buf);
  [%expect {|
    reg 0: hw 00 model 00
    reg 1: hw 00 model 00
    reg 2: hw c1 model c1
    reg 3: hw 03 model 03
    reg 4: hw 0b model 0b
    reg 5: hw 60 model 60
    reg 6: hw b0 model b0
    reg 7: hw 5a model 5a
    DLL 27 DLM 0
    LSR while sending: 00
    sent: "Hello, 16550!\n"
    ETBEI with the FIFO empty: irq true IIR c2
    after the IIR read: irq false IIR c1
    after a THR write: irq false
    FIFO empty again: irq true IIR c2
    received: LSR 61 irq true IIR c4
    RBR: "abc", then LSR 60 irq false
    after 20 bytes: "0123456789abcdef"
    |}]
;;
