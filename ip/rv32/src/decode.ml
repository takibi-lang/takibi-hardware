(* Instruction classification and legality for RV32I and RV32E, with
   optional Zicsr, MRET and WFI ([~zicsr], issue #3), M ([~m]), A ([~a])
   and FENCE.I ([~zifencei]) (#5), SRET and SFENCE.VMA ([~s], #6); without a flag its instructions are
   illegal and its outputs are constant 0. An instruction is illegal if
   its encoding is not in the ISA or, for RV32E, if any register field it
   uses names x16..x31. test/test_decode.ml checks this against the golden
   model's decoder on every opcode/funct combination and random words. *)
open! Base
open! Hardcaml
open Signal

module I = struct
  type 'a t = { insn : 'a [@bits 32] } [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { lui : 'a
    ; auipc : 'a
    ; jal : 'a
    ; jalr : 'a
    ; branch : 'a
    ; load : 'a
    ; store : 'a
    ; op_imm : 'a
    ; op : 'a
    ; shift : 'a (* SLL/SRL/SRA and their immediate forms *)
    ; fence : 'a
    ; ecall : 'a
    ; ebreak : 'a
    ; csr : 'a (* CSRRW/S/C and the immediate forms *)
    ; csr_imm : 'a (* the immediate forms (funct3 bit 2) *)
    ; mret : 'a
    ; wfi : 'a
    ; mul : 'a (* MUL, MULH, MULHSU, MULHU *)
    ; div : 'a (* DIV, DIVU, REM, REMU *)
    ; lr : 'a
    ; sc : 'a
    ; amo : 'a (* AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU.W *)
    ; fence_i : 'a
    ; sret : 'a
    ; sfence_vma : 'a
    ; illegal : 'a
    }
  [@@deriving hardcaml]
end

let create
  ?(zicsr = false)
  ?(m = false)
  ?(a = false)
  ?(zifencei = false)
  ?(s = false)
  ~(base : Rv32_model.Isa.base)
  (i : _ I.t)
  =
  let x = i.insn in
  let opcode = x.:[6, 0] in
  let funct3 = x.:[14, 12] in
  let funct7 = x.:[31, 25] in
  let rd_hi = x.:(11) in
  let rs1_hi = x.:(19) in
  let rs2_hi = x.:(24) in
  let is code = opcode ==:. code in
  let f3_is l = List.map l ~f:(fun v -> funct3 ==:. v) |> reduce ~f:( |: ) in
  let lui = is 0b0110111 in
  let auipc = is 0b0010111 in
  let jal = is 0b1101111 in
  let jalr = is 0b1100111 &: (funct3 ==:. 0) in
  let branch = is 0b1100011 &: ~:(f3_is [ 2; 3 ]) in
  let load = is 0b0000011 &: f3_is [ 0; 1; 2; 4; 5 ] in
  let store = is 0b0100011 &: f3_is [ 0; 1; 2 ] in
  let shift_f3 = f3_is [ 1; 5 ] in
  (* SLLI/SRLI/SRAI: funct7 0000000, or 0100000 for SRAI (funct3 101). *)
  let shift_f7_ok =
    funct7 ==:. 0 |: ((funct7 ==:. 0b0100000) &: (funct3 ==:. 5))
  in
  let op_imm = is 0b0010011 &: (~:shift_f3 |: shift_f7_ok) in
  (* OP: funct7 0000000 for all, or 0100000 for SUB (000) and SRA (101). *)
  let op =
    is 0b0110011
    &: (funct7 ==:. 0 |: ((funct7 ==:. 0b0100000) &: f3_is [ 0; 5 ]))
  in
  let shift = (op_imm |: op) &: shift_f3 in
  let fence = is 0b0001111 &: (funct3 ==:. 0) in
  let ecall = x ==:. 0x00000073 in
  let ebreak = x ==:. 0x00100073 in
  let csr, csr_imm, mret, wfi =
    if zicsr
    then (
      let csr = is 0b1110011 &: ~:(f3_is [ 0; 4 ]) in
      csr, csr &: funct3.:(2), x ==:. 0x30200073, x ==:. 0x10500073)
    else gnd, gnd, gnd, gnd
  in
  let muldiv = if m then is 0b0110011 &: (funct7 ==:. 1) else gnd in
  let mul = muldiv &: ~:(funct3.:(2)) in
  let div = muldiv &: funct3.:(2) in
  let lr, sc, amo =
    if a
    then (
      let atomic = is 0b0101111 &: (funct3 ==:. 2) in
      let f5 = x.:[31, 27] in
      let f5_is l = List.map l ~f:(fun v -> f5 ==:. v) |> reduce ~f:( |: ) in
      ( atomic &: (f5 ==:. 0b00010) &: (x.:[24, 20] ==:. 0)
      , atomic &: (f5 ==:. 0b00011)
      , atomic
        &: f5_is
             [ 0b00001; 0b00000; 0b00100; 0b01100; 0b01000; 0b10000; 0b10100; 0b11000; 0b11100 ]
      ))
    else gnd, gnd, gnd
  in
  let sret, sfence_vma =
    if s
    then
      ( x ==:. 0x10200073
      , is 0b1110011 &: (funct7 ==:. 0b0001001) &: (x.:[11, 7] ==:. 0) &: (funct3 ==:. 0) )
    else gnd, gnd
  in
  let fence_i = if zifencei then is 0b0001111 &: (funct3 ==:. 1) else gnd in
  let uses_rd = lui |: auipc |: jal |: jalr |: load |: op_imm |: op |: csr |: muldiv |: lr |: sc |: amo in
  let uses_rs1 =
    jalr |: branch |: load |: store |: op_imm |: op |: (csr &: ~:csr_imm) |: muldiv |: lr |: sc
    |: amo |: sfence_vma
  in
  let uses_rs2 = branch |: store |: op |: muldiv |: sc |: amo |: sfence_vma in
  let bad_reg =
    match base with
    | Rv32i -> gnd
    | Rv32e -> (uses_rd &: rd_hi) |: (uses_rs1 &: rs1_hi) |: (uses_rs2 &: rs2_hi)
  in
  let known =
    lui |: auipc |: jal |: jalr |: branch |: load |: store |: op_imm |: op |: fence
    |: ecall |: ebreak |: csr |: mret |: wfi |: muldiv |: lr |: sc |: amo |: fence_i |: sret |: sfence_vma
  in
  { O.lui
  ; auipc
  ; jal
  ; jalr
  ; branch
  ; load
  ; store
  ; op_imm
  ; op
  ; shift
  ; fence
  ; ecall
  ; ebreak
  ; csr
  ; csr_imm
  ; mret
  ; wfi
  ; mul
  ; div
  ; lr
  ; sc
  ; amo
  ; fence_i
  ; sret
  ; sfence_vma
  ; illegal = ~:known |: bad_reg
  }
;;
