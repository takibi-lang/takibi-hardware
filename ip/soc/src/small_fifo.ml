(* A small first-in first-out queue in registers, every flip-flop named
   (HardCaml's Fifo leaves its registers anonymous, which `make names`
   rejects). [depth] entries (a power of 2) of [width] bits; [q] shows the
   oldest entry (show-ahead); a write when full and a read when empty are
   ignored; [clear] empties it. *)
open! Base
open! Hardcaml
open Signal

type t =
  { q : Signal.t
  ; empty : Signal.t
  ; full : Signal.t
  }

let create ~name ~depth scope ~clock ~clear ~wr ~d ~rd =
  let ( -- ) = Scope.naming scope in
  let bits = Int.ceil_log2 depth in
  assert (1 lsl bits = depth);
  let spec = Reg_spec.create ~clock ~clear () in
  let n s = Printf.sprintf "%s_%s" name s in
  let count = wire (bits + 1) in
  let empty = (count ==:. 0) -- n "empty" in
  let full = (count ==:. depth) -- n "full" in
  let push = wr &: ~:full in
  let pop = rd &: ~:empty in
  let wr_ptr = reg_fb spec ~width:bits ~f:(fun p -> mux2 push (p +:. 1) p) -- n "wr_ptr" in
  let rd_ptr = reg_fb spec ~width:bits ~f:(fun p -> mux2 pop (p +:. 1) p) -- n "rd_ptr" in
  count
  <== (reg spec (mux2 (push &: ~:pop) (count +:. 1) (mux2 (pop &: ~:push) (count -:. 1) count))
       -- n "count");
  let mem =
    List.init depth ~f:(fun k ->
      reg spec ~enable:(push &: (wr_ptr ==:. k)) d -- n (Printf.sprintf "entry%d" k))
  in
  { q = mux rd_ptr mem -- n "q"; empty; full }
;;
