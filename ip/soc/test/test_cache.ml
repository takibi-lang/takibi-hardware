(* The cache (issue #7, L8) in front of the SDRAM controller and the SDRAM
   model: random reads and writes (full and partial) with locality, so
   there are hits, misses, conflict evictions and writes to cached and
   uncached lines, checked against a reference memory. A small cache
   (1 KiB) makes conflicts frequent. *)
open! Base
open! Hardcaml
open Stdio
module Ctrl = Sdram.Sdram_ctrl

module Io = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; read : 'a
    ; write : 'a
    ; addr : 'a [@bits 23]
    ; wdata : 'a [@bits 32]
    ; wmask : 'a [@bits 4]
    ; dq_in : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module Out = struct
  type 'a t =
    { cache : 'a Soc.Cache.O.t [@rtlprefix "c_"]
    ; sdram : 'a Ctrl.O.t [@rtlprefix "s_"]
    }
  [@@deriving hardcaml]
end

module Sim = Cyclesim.With_interface (Io) (Out)

let config = Ctrl.Config.create ~clock_mhz:50 ()

let create (x : _ Io.t) =
  let scope = Scope.create ~flatten_design:true () in
  let c_o = Soc.Cache.O.Of_signal.wires () in
  let sdram =
    Ctrl.create
      config
      scope
      { Ctrl.I.clock = x.clock
      ; clear = x.clear
      ; read = c_o.mem_read
      ; write = c_o.mem_write
      ; burst = c_o.mem_burst
      ; addr = c_o.mem_addr
      ; wdata = c_o.mem_wdata
      ; wmask = c_o.mem_wmask
      ; dq_in = x.dq_in
      }
  in
  let cache =
    Soc.Cache.create
      ~size:1024
      scope
      { Soc.Cache.I.clock = x.clock
      ; clear = x.clear
      ; read = x.read
      ; write = x.write
      ; addr = x.addr
      ; wdata = x.wdata
      ; wmask = x.wmask
      ; mem_ready = sdram.ready
      ; mem_word_valid = sdram.word_valid
      ; mem_word_index = sdram.word_index
      ; mem_rdata = sdram.rdata
      ; mem_rvalid = sdram.rvalid
      }
  in
  Soc.Cache.O.Of_signal.assign c_o cache;
  { Out.cache; sdram }
;;

let%expect_test "cache + SDRAM controller + SDRAM model, random traffic" =
  let sim = Sim.create create in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim
  and pins = Cyclesim.outputs sim in
  let model = Sdram_bench.Sdram_model.create ~clock_mhz:50 ~cas_latency:2 ~read_latency:3 () in
  let rng = Random.State.make [| 5 |] in
  let reference = Hashtbl.create (module Int) in
  let errors = ref 0 in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let cycle f =
    let dq =
      Sdram_bench.Sdram_model.step
        model
        ~cmd:(Bits.to_int !(pins.sdram.cmd))
        ~a:(Bits.to_int !(pins.sdram.a))
        ~ba:(Bits.to_int !(pins.sdram.ba))
        ~dq_out:(Bits.to_int !(pins.sdram.dq_out))
        ~dq_oe:(Bits.to_bool !(pins.sdram.dq_oe))
    in
    i.dq_in := Bits.of_int ~width:32 (Option.value dq ~default:0);
    Cyclesim.cycle_check sim;
    Cyclesim.cycle_before_clock_edge sim;
    let r = f () in
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    r
  in
  let rec until f = if not (cycle f) then until f in
  (* a few hot regions (4 KiB apart: they conflict in a 1 KiB cache) *)
  let addr () =
    let region = [| 0x0; 0x1000; 0x2000; 0x40000 |].(Random.State.int rng 4) in
    region + (4 * Random.State.int rng 64)
  in
  let operations = 5000 in
  for _ = 1 to operations do
    let a = addr () in
    let write = Random.State.int rng 3 = 0 in
    let wdata = Random.State.bits rng in
    let wmask = if Random.State.bool rng then 0xf else 1 + Random.State.int rng 15 in
    i.read := Bits.of_bool (not write);
    i.write := Bits.of_bool write;
    i.addr := Bits.of_int ~width:23 a;
    i.wdata := Bits.of_int ~width:32 wdata;
    i.wmask := Bits.of_int ~width:4 wmask;
    until (fun () -> Bits.to_bool !(o.cache.ready));
    i.read := Bits.gnd;
    i.write := Bits.gnd;
    let old = Hashtbl.find reference a |> Option.value ~default:0 in
    if write
    then
      Hashtbl.set
        reference
        ~key:a
        ~data:
          (List.fold (List.range 0 4) ~init:0 ~f:(fun acc k ->
             acc lor ((if wmask land (1 lsl k) <> 0 then wdata else old) land (0xff lsl (8 * k)))))
    else (
      let got = ref 0 in
      until (fun () ->
        got := Bits.to_int !(o.cache.rdata);
        Bits.to_bool !(o.cache.rvalid));
      if !got <> old
      then (
        Int.incr errors;
        if !errors <= 3 then printf "read 0x%06x: got %08x expected %08x\n" a !got old))
  done;
  let hits = Bits.to_int !(o.cache.hits)
  and misses = Bits.to_int !(o.cache.misses) in
  printf
    "%d operations, %d errors, %d hits, %d misses, SDRAM violations: %d\n"
    operations
    !errors
    hits
    misses
    (List.length model.violations);
  [%expect {| 5000 operations, 0 errors, 773 hits, 2561 misses, SDRAM violations: 0 |}]
;;
