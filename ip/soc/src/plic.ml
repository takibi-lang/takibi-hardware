(* PLIC, SiFive layout (issue #28, Linux L7): [sources] level-triggered
   sources (1..sources), [contexts] contexts (0: M, 1: S of hart 0).
   priority at 4*source, pending at 0x1000, enables at 0x2000 + 0x80*ctx,
   threshold and claim/complete at 0x200000 + 0x1000*ctx; priorities and
   thresholds are 3 bits. A source is pending while its level is high and
   it is not in service; a claim (read) takes the highest-priority enabled
   pending source above the threshold (lowest number on a tie) into
   service, a complete (write of its number) ends the service. [contexts]
   (default 2, up to 8 for 4 harts: #9). Register
   for register as Soc_model.Devices.Plic. *)
open! Base
open! Hardcaml
open Signal

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; irq : 'a [@bits 8] (* per context: 2h M, 2h + 1 S of hart h *)
    }
  [@@deriving hardcaml]
end

let create ?(contexts = 2) ~sources scope (i : _ Regbus.I.t) (level : Signal.t) =
  assert (contexts <= 8);
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let reg name w =
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let n = sources + 1 in
  (* bit 0 unused (source 0 does not exist) *)
  let priority = Array.init n ~f:(fun s -> reg (Printf.sprintf "priority%d" s) 3) in
  let pending = reg "pending" n in
  let claimed = reg "claimed" n in
  let enable = Array.init contexts ~f:(fun c -> reg (Printf.sprintf "enable%d" c) n) in
  let threshold = Array.init contexts ~f:(fun c -> reg (Printf.sprintf "threshold%d" c) 3) in
  let rdata = reg "rdata" 32 in
  let level = (level @: gnd) -- "level" in
  let off = i.addr.:[21, 0] in
  (* The best source of context [c]: (valid, number). *)
  let best c =
    List.fold
      (List.range 1 n)
      ~init:(gnd, zero 5, zero 3)
      ~f:(fun (valid, num, prio) s ->
        let p = priority.(s).value in
        let ok =
          pending.value.:(s)
          &: enable.(c).value.:(s)
          &: (p >: threshold.(c).value)
          &: (~:valid |: (p >: prio))
        in
        mux2 ok vdd valid, mux2 ok (of_int ~width:5 s) num, mux2 ok p prio)
  in
  let bests = Array.init contexts ~f:(fun c -> best c) in
  let ctx_of_claim = (off.:[21, 12] -:. 0x200) -- "ctx" in
  let in_ctx_region = (off >=:. 0x20_0000 &: (off <:. 0x20_0000 + (0x1000 * contexts))) -- "in_ctx" in
  let sub = off.:[11, 0] in
  let claim_read c = i.read &: in_ctx_region &: (ctx_of_claim ==:. c) &: (sub ==:. 4) in
  let complete_write = i.write &: in_ctx_region &: (sub ==:. 4) in
  let claim_bits =
    List.init contexts ~f:(fun c ->
      let valid, num, _ = bests.(c) in
      mux2 (claim_read c &: valid) (binary_to_onehot num |> Fn.flip uresize n) (zero n))
    |> reduce ~f:( |: )
    |> fun x -> x -- "claim_bits"
  in
  let complete_bits =
    mux2
      (complete_write &: (i.wdata >=:. 1) &: (i.wdata <=:. sources))
      (binary_to_onehot i.wdata.:[4, 0] |> Fn.flip uresize n)
      (zero n)
    -- "complete_bits"
  in
  let claimed_next = (claimed.value |: claim_bits) &: ~:complete_bits in
  let pending_next = (pending.value &: ~:claim_bits) |: (level &: ~:claimed_next) in
  let read_value =
    let prio_read =
      List.fold (List.range 1 n) ~init:(zero 32) ~f:(fun acc s ->
        mux2 (off ==:. 4 * s) (uresize priority.(s).value 32) acc)
    in
    let enable_read =
      List.fold (List.range 0 contexts) ~init:(zero 32) ~f:(fun acc c ->
        mux2 (off ==:. 0x2000 + (0x80 * c)) (uresize enable.(c).value 32) acc)
    in
    let ctx_read =
      List.fold (List.range 0 contexts) ~init:(zero 32) ~f:(fun acc c ->
        let _, num, _ = bests.(c) in
        mux2
          (in_ctx_region &: (ctx_of_claim ==:. c))
          (mux2
             (sub ==:. 0)
             (uresize threshold.(c).value 32)
             (mux2 (sub ==:. 4) (uresize num 32) (zero 32)))
          acc)
    in
    mux2
      (off <:. 0x1000)
      prio_read
      (mux2 (off ==:. 0x1000) (uresize pending.value 32) (mux2 (off <:. 0x20_0000) enable_read ctx_read))
  in
  Always.(
    compile
      ([ pending <-- pending_next
       ; claimed <-- claimed_next
       ; when_ i.read [ rdata <-- read_value ]
       ]
       @ List.map (List.range 1 n) ~f:(fun s ->
         when_ (i.write &: (off ==:. 4 * s)) [ priority.(s) <-- i.wdata.:[2, 0] ])
       @ List.map (List.range 0 contexts) ~f:(fun c ->
         when_
           (i.write &: (off ==:. 0x2000 + (0x80 * c)))
           [ enable.(c) <-- (i.wdata.:[n - 1, 0] &: ~:(of_int ~width:n 1)) ])
       @ List.map (List.range 0 contexts) ~f:(fun c ->
         when_
           (i.write &: in_ctx_region &: (ctx_of_claim ==:. c) &: (sub ==:. 0))
           [ threshold.(c) <-- i.wdata.:[2, 0] ])));
  { O.rdata = rdata.value
  ; irq = uresize (concat_lsb (Array.to_list (Array.map bests ~f:(fun (v, _, _) -> v)))) 8
  }
;;
