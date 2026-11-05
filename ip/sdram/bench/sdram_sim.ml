(* The controller in Cyclesim against Sdram_model, driven with random
   requests through the core's bus protocol and checked against a
   reference memory. Used by the S1 tests. *)
open! Base
open! Hardcaml
module Ctrl = Sdram.Sdram_ctrl
module Sim = Cyclesim.With_interface (Ctrl.I) (Ctrl.O)

type result =
  { operations : int
  ; cycles : int
  ; data_errors : string list
  ; violations : string list
  ; refreshes : int
  ; reads : int
  ; writes : int
  }
[@@deriving sexp_of]

let run
  ?(model_clock_mhz = 50)
  ?model_read_latency
  ~(config : Ctrl.Config.t)
  ~clock_mhz
  ~operations
  ~seed
  ()
  =
  ignore clock_mhz;
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Ctrl.create config scope) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let model =
    Sdram_model.create
      ~clock_mhz:model_clock_mhz
      ~cas_latency:config.cas_latency
      ~read_latency:(Option.value model_read_latency ~default:config.read_latency)
      ()
  in
  let rng = Random.State.make [| seed |] in
  let reference = Hashtbl.create (module Int) in
  let data_errors = ref [] in
  (* Addresses: a few rows in every bank, so rows open and close. *)
  let random_addr () =
    let row = Random.State.int rng 4 * 0x2a5 land 0x7ff in
    let bank = Random.State.int rng 4 in
    let col = Random.State.int rng 256 in
    (row lsl 12) lor (bank lsl 10) lor (col lsl 2)
  in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let cycles = ref 0 in
  let step () =
    let dq =
      Sdram_model.step
        model
        ~cmd:(Bits.to_int !(o.cmd))
        ~a:(Bits.to_int !(o.a))
        ~ba:(Bits.to_int !(o.ba))
        ~dq_out:(Bits.to_int !(o.dq_out))
        ~dq_oe:(Bits.to_bool !(o.dq_oe))
    in
    i.dq_in := Bits.of_int ~width:32 (Option.value dq ~default:0xdead_beef);
    Cyclesim.cycle sim;
    Int.incr cycles
  in
  while not (Bits.to_bool !(o.init_done)) do
    step ()
  done;
  for _ = 1 to operations do
    (* idle cycles between requests, sometimes long enough for a refresh *)
    for _ = 1 to (if Random.State.int rng 50 = 0 then 300 else Random.State.int rng 3) do
      step ()
    done;
    let addr = random_addr () in
    let write = Random.State.bool rng in
    let wdata = Random.State.bits rng lor (Random.State.int rng 4 lsl 30) in
    let wmask = if Random.State.bool rng then 0xf else Random.State.int rng 16 in
    i.read := Bits.of_bool (not write);
    i.write := Bits.of_bool write;
    i.addr := Bits.of_int ~width:23 addr;
    i.wdata := Bits.of_int ~width:32 wdata;
    i.wmask := Bits.of_int ~width:4 wmask;
    while not (Bits.to_bool !(o.ready)) do
      step ()
    done;
    step ();
    i.read := Bits.gnd;
    i.write := Bits.gnd;
    let old = Hashtbl.find reference addr |> Option.value ~default:0 in
    if write
    then (
      let merged =
        List.fold (List.range 0 4) ~init:0 ~f:(fun acc k ->
          let src = if wmask land (1 lsl k) <> 0 then wdata else old in
          acc lor (src land (0xff lsl (8 * k))))
      in
      Hashtbl.set reference ~key:addr ~data:merged)
    else (
      while not (Bits.to_bool !(o.rvalid)) do
        step ()
      done;
      let got = Bits.to_int !(o.rdata) in
      if got <> old && List.length !data_errors < 5
      then
        data_errors
        := Printf.sprintf "read 0x%06x: got 0x%08x, expected 0x%08x" addr got old
           :: !data_errors)
  done;
  { operations
  ; cycles = !cycles
  ; data_errors = List.rev !data_errors
  ; violations = List.rev model.violations
  ; refreshes = model.refreshes
  ; reads = model.reads
  ; writes = model.writes
  }
;;
