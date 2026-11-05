(* The hardware decoder must classify every instruction word exactly as the
   golden model's decoder does. Checked on every (opcode, funct3, funct7)
   combination with register fields x0/x15/x16/x31, plus random words. *)
open! Base
open! Hardcaml
open Stdio
module Isa = Rv32_model.Isa
module Sim = Cyclesim.With_interface (Rv32.Decode.I) (Rv32.Decode.O)

let base = ref Isa.Rv32e
let zicsr = ref false
let ma = ref false
let sv = ref false

(* Classes in the order of Decode.O, as the model sees them. *)
let model_class w =
  match Isa.decode ~zicsr:!zicsr ~m:!ma ~a:!ma ~zifencei:!ma ~s:!sv ~base:!base w with
  | Lui _ -> "lui"
  | Auipc _ -> "auipc"
  | Jal _ -> "jal"
  | Jalr _ -> "jalr"
  | Branch _ -> "branch"
  | Load _ -> "load"
  | Store _ -> "store"
  | Op_imm _ -> "op_imm"
  | Op _ -> "op"
  | Fence -> "fence"
  | Fence_i -> "fence_i"
  | Ecall -> "ecall"
  | Ebreak -> "ebreak"
  | Csr _ -> "csr"
  | Mret -> "mret"
  | Sret -> "sret"
  | Sfence_vma _ -> "sfence_vma"
  | Wfi -> "wfi"
  | Mul_div { op = Mul | Mulh | Mulhsu | Mulhu; _ } -> "mul"
  | Mul_div _ -> "div"
  | Lr _ -> "lr"
  | Sc _ -> "sc"
  | Amo _ -> "amo"
  | Illegal _ -> "illegal"
;;

let hw_class (o : Bits.t ref Rv32.Decode.O.t) =
  let set =
    Rv32.Decode.O.(
      to_list (map2 port_names o ~f:(fun n b -> n, Bits.to_bool !b)))
    |> List.filter_map ~f:(fun (n, b) ->
      Option.some_if (b && not (List.mem [ "shift"; "csr_imm" ] n ~equal:String.equal)) n)
  in
  match set with
  | [ c ] -> c
  | [ c; "illegal" ] -> "illegal (also " ^ c ^ ")"
  | l -> "(" ^ String.concat ~sep:" " l ^ ")"
;;

let check_decoder ?(z = false) ?(with_ma = false) ?(with_s = false) b =
  base := b;
  zicsr := z || with_s;
  ma := with_ma;
  sv := with_s;
  let sim =
    Sim.create (Rv32.Decode.create ~zicsr:(z || with_s) ~m:with_ma ~a:with_ma ~zifencei:with_ma ~s:with_s ~base:b)
  in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  let checked = ref 0 in
  let mismatches = ref 0 in
  let check w =
    i.insn := Bits.of_int ~width:32 w;
    Cyclesim.cycle sim;
    let hw = hw_class o in
    let hw = if String.is_prefix hw ~prefix:"illegal" then "illegal" else hw in
    Int.incr checked;
    if not (String.equal hw (model_class w))
    then (
      Int.incr mismatches;
      if !mismatches <= 5 then printf "0x%08x: hw %s, model %s\n" w hw (model_class w))
  in
  let regs = [ 0; 15; 16; 31 ] in
  for opcode = 0 to 127 do
    for funct3 = 0 to 7 do
      (* funct7 values: base, SUB/SRA, M, all ones, and every A-extension
         funct5 (bits 31..27), with and without aq/rl. *)
      let amo_f5 = [ 0b00001; 0b00010; 0b00011; 0b00100; 0b01000; 0b01100; 0b10000; 0b10100; 0b11000; 0b11100 ] in
      List.iter
        ([ 0; 0b0100000; 0b0000001; 0b1111111; 0b0001001; 0b0001000; 0b0011000 ]
         @ List.map amo_f5 ~f:(fun f -> f lsl 2)
         @ List.map amo_f5 ~f:(fun f -> (f lsl 2) lor 3))
        ~f:(fun funct7 ->
        List.iter regs ~f:(fun rd ->
          List.iter regs ~f:(fun rs1 ->
            List.iter regs ~f:(fun rs2 ->
              check
                ((funct7 lsl 25)
                 lor (rs2 lsl 20)
                 lor (rs1 lsl 15)
                 lor (funct3 lsl 12)
                 lor (rd lsl 7)
                 lor opcode)))))
    done
  done;
  List.iter
    [ 0x00000073; 0x00100073; 0x00200073; 0x10000073; 0x30200073; 0x10500073; 0x10200073; 0x12000073; 0x12f78073; 0x12000873 ]
    ~f:check;
  let rng = Random.State.make [| 42 |] in
  for _ = 1 to 100_000 do
    check (Random.State.bits rng lor (Random.State.int rng 4 lsl 30))
  done;
  printf
    "%s%s%s%s: checked %d words, %d mismatches\n"
    (Sexp.to_string (Isa.sexp_of_base b))
    (if z then "+zicsr" else "")
    (if with_ma then "+m+a+zifencei" else "")
    (if with_s then "+s" else "")
    !checked
    !mismatches
;;

let%expect_test "decoder agrees with the model" =
  check_decoder Rv32e;
  check_decoder Rv32i;
  check_decoder ~z:true Rv32e;
  check_decoder ~z:true Rv32i;
  check_decoder ~z:true ~with_ma:true Rv32i;
  check_decoder ~with_ma:true ~with_s:true Rv32i;
  check_decoder ~with_s:true Rv32e;
  [%expect
    {|
    Rv32e: checked 1869482 words, 0 mismatches
    Rv32i: checked 1869482 words, 0 mismatches
    Rv32e+zicsr: checked 1869482 words, 0 mismatches
    Rv32i+zicsr: checked 1869482 words, 0 mismatches
    Rv32i+zicsr+m+a+zifencei: checked 1869482 words, 0 mismatches
    Rv32i+m+a+zifencei+s: checked 1869482 words, 0 mismatches
    Rv32e+s: checked 1869482 words, 0 mismatches
    |}]
;;
