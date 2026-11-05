(* 16550 subset with 16-byte FIFOs (issue #28, Linux L7), register for
   register as Soc_model.Devices.Uart where timing does not matter:
   RBR/THR, IER (receive data and THR-empty interrupts), IIR (FIFO bits
   when FCR.0), FCR (FIFO enable; bits 1, 2 clear the receive / transmit
   FIFO), LCR (DLAB), MCR, LSR (DR, THRE, TEMT), MSR (DCD, DSR, CTS), SCR,
   divisor latches (stored; the baud rate is fixed by [clocks_per_bit]).
   Byte registers at offsets 0..7 (reg-shift 0); reads return the byte in
   every lane, writes take it from the addressed lane.

   Unlike the model, transmission takes time: THR writes go into a 16-byte
   FIFO (Linux's 8250 driver writes up to 16 bytes per THRE interrupt for a
   16550A) and LSR.THRE is "FIFO empty". The THRE interrupt is raised when
   the FIFO becomes empty and when IER.ETBEI is set while it is empty;
   reading IIR while it is the reported source, or writing THR, clears it.
   The FIFOs hold 17 bytes (16 + the showahead output register); received
   bytes beyond that are dropped. *)
open! Base
open! Hardcaml
open Signal

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; irq : 'a
    ; tx : 'a
    }
  [@@deriving hardcaml]
end

let create ~clocks_per_bit scope (i : _ Regbus.I.t) ~rx =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let reg ?(clear_to = 0) name w =
    let spec = Reg_spec.override spec ~clear_to:(of_int ~width:w clear_to) in
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let ier = reg "ier" 4 in
  let lcr = reg "lcr" 8 in
  let mcr = reg "mcr" 8 in
  let scr = reg "scr" 8 in
  let dll = reg "dll" 8 in
  let dlm = reg "dlm" 8 in
  let fcr0 = reg "fcr0" 1 in
  let thre_pending = reg ~clear_to:1 "thre_pending" 1 in
  let rdata = reg "rdata" 32 in
  let off = i.addr.:[2, 0] in
  let lane = i.addr.:[1, 0] in
  let wbyte = mux lane (List.init 4 ~f:(fun k -> i.wdata.:[(8 * k) + 7, 8 * k])) -- "wbyte" in
  let dlab = lcr.value.:(7) in
  let at r = off ==:. r in
  let rd r = i.read &: at r and wr r = i.write &: at r in
  (* Receiver and its FIFO *)
  let receiver =
    Uart.Uart_rx.hierarchical ~clocks_per_bit scope { Uart.Uart_rx.I.clock = i.clock; clear = i.clear; rx }
  in
  let fcr_write = wr 2 in
  let rx_pop = (rd 0 &: ~:dlab) -- "rx_pop" in
  let rx_fifo =
    Fifo.create
      ~showahead:true
      ~capacity:16
      ~clock:i.clock
      ~clear:(i.clear |: (fcr_write &: wbyte.:(1)))
      ~wr:receiver.valid
      ~d:receiver.data
      ~rd:rx_pop
      ()
  in
  let rx_ready = ~:(rx_fifo.empty) -- "rx_ready" in
  (* Transmitter and its FIFO *)
  let tx_pop = wire 1 in
  let tx_push = (wr 0 &: ~:dlab) -- "tx_push" in
  let tx_fifo =
    Fifo.create
      ~showahead:true
      ~capacity:16
      ~clock:i.clock
      ~clear:(i.clear |: (fcr_write &: wbyte.:(2)))
      ~wr:tx_push
      ~d:wbyte
      ~rd:tx_pop
      ()
  in
  let tx_empty = tx_fifo.empty -- "tx_empty" in
  let transmitter =
    Uart.Uart_tx.hierarchical
      ~clocks_per_bit
      scope
      { Uart.Uart_tx.I.clock = i.clock; clear = i.clear; data_valid = ~:tx_empty; data = tx_fifo.q }
  in
  tx_pop <== (~:tx_empty &: transmitter.ready);
  let empty_prev = reg ~clear_to:1 "tx_empty_prev" 1 in
  let iir =
    mux2 fcr0.value (of_int ~width:8 0xc0) (zero 8)
    |: mux2
         (ier.value.:(0) &: rx_ready)
         (of_int ~width:8 0x04)
         (mux2 (ier.value.:(1) &: thre_pending.value) (of_int ~width:8 0x02) (of_int ~width:8 0x01))
    -- "iir"
  in
  let lsr_ =
    uresize (tx_empty &: transmitter.ready) 1 @: tx_empty @: zero 4 @: rx_ready |> Fn.flip uresize 8
  in
  let read_byte =
    mux
      off
      [ mux2 dlab dll.value (mux2 rx_ready rx_fifo.q (zero 8))
      ; mux2 dlab dlm.value (uresize ier.value 8)
      ; iir
      ; lcr.value
      ; mcr.value
      ; lsr_
      ; of_int ~width:8 0xb0
      ; scr.value
      ]
    -- "read_byte"
  in
  let thre_set =
    (tx_empty &: ~:(empty_prev.value))
    |: (wr 1 &: ~:dlab &: wbyte.:(1) &: ~:(ier.value.:(1)) &: tx_empty)
  in
  let thre_clear = (rd 2 &: (iir.:[3, 0] ==:. 0x2)) |: tx_push in
  Always.(
    compile
      [ empty_prev <-- tx_empty
      ; when_ thre_set [ thre_pending <-- vdd ]
      ; when_ thre_clear [ thre_pending <-- gnd ]
      ; when_ i.read [ rdata <-- repeat read_byte 4 ]
      ; when_ (wr 0 &: dlab) [ dll <-- wbyte ]
      ; when_ (wr 1) [ if_ dlab [ dlm <-- wbyte ] [ ier <-- wbyte.:[3, 0] ] ]
      ; when_ fcr_write [ fcr0 <-- wbyte.:(0) ]
      ; when_ (wr 3) [ lcr <-- wbyte ]
      ; when_ (wr 4) [ mcr <-- wbyte ]
      ; when_ (wr 7) [ scr <-- wbyte ]
      ]);
  { O.rdata = rdata.value; irq = ~:(iir.:(0)); tx = transmitter.tx }
;;

let hierarchical ~clocks_per_bit scope (i : _ Regbus.I.t) ~rx =
  let module I = struct
    type 'a t =
      { bus : 'a Regbus.I.t [@rtlprefix "bus_"]
      ; rx : 'a
      }
    [@@deriving hardcaml]
  end
  in
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ~scope
    ~name:"uart16550"
    (fun scope (x : _ I.t) -> create ~clocks_per_bit scope x.bus ~rx:x.rx)
    { I.bus = i; rx }
;;
