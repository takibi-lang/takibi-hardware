(* Minimal RV32I encoder, so tests can be written without an external
   RISC-V toolchain. Register numbers are plain ints (x0..x31); whether
   x16..x31 are legal (RV32E) is the decoder's business. *)

let check_reg r = if r < 0 || r > 31 then invalid_arg (Printf.sprintf "no register x%d" r)

let check_imm v ~bits ~what =
  let lo = -(1 lsl (bits - 1))
  and hi = (1 lsl (bits - 1)) - 1 in
  if v < lo || v > hi then invalid_arg (Printf.sprintf "%s out of range: %d" what v)
;;

let field v ~hi ~lo = (v land ((1 lsl (hi - lo + 1)) - 1)) lsl lo

let r_type ~funct7 ~funct3 ~opcode rd rs1 rs2 =
  List.iter check_reg [ rd; rs1; rs2 ];
  field funct7 ~hi:31 ~lo:25
  lor field rs2 ~hi:24 ~lo:20
  lor field rs1 ~hi:19 ~lo:15
  lor field funct3 ~hi:14 ~lo:12
  lor field rd ~hi:11 ~lo:7
  lor opcode
;;

let i_type ~funct3 ~opcode rd rs1 imm =
  List.iter check_reg [ rd; rs1 ];
  check_imm imm ~bits:12 ~what:"I-immediate";
  field imm ~hi:31 ~lo:20
  lor field rs1 ~hi:19 ~lo:15
  lor field funct3 ~hi:14 ~lo:12
  lor field rd ~hi:11 ~lo:7
  lor opcode
;;

let s_type ~funct3 rs2 rs1 imm =
  List.iter check_reg [ rs1; rs2 ];
  check_imm imm ~bits:12 ~what:"S-immediate";
  field (imm lsr 5) ~hi:31 ~lo:25
  lor field rs2 ~hi:24 ~lo:20
  lor field rs1 ~hi:19 ~lo:15
  lor field funct3 ~hi:14 ~lo:12
  lor field imm ~hi:11 ~lo:7
  lor 0b0100011
;;

let b_type ~funct3 rs1 rs2 offset =
  List.iter check_reg [ rs1; rs2 ];
  check_imm offset ~bits:13 ~what:"branch offset";
  if offset land 1 <> 0 then invalid_arg "odd branch offset";
  field (offset lsr 12) ~hi:31 ~lo:31
  lor field (offset lsr 5) ~hi:30 ~lo:25
  lor field rs2 ~hi:24 ~lo:20
  lor field rs1 ~hi:19 ~lo:15
  lor field funct3 ~hi:14 ~lo:12
  lor field (offset lsr 1) ~hi:11 ~lo:8
  lor field (offset lsr 11) ~hi:7 ~lo:7
  lor 0b1100011
;;

let u_type ~opcode rd imm =
  check_reg rd;
  field (imm lsr 12) ~hi:31 ~lo:12 lor field rd ~hi:11 ~lo:7 lor opcode
;;

let lui rd imm = u_type ~opcode:0b0110111 rd imm
let auipc rd imm = u_type ~opcode:0b0010111 rd imm

let jal rd offset =
  check_reg rd;
  check_imm offset ~bits:21 ~what:"jump offset";
  field (offset lsr 20) ~hi:31 ~lo:31
  lor field (offset lsr 1) ~hi:30 ~lo:21
  lor field (offset lsr 11) ~hi:20 ~lo:20
  lor field (offset lsr 12) ~hi:19 ~lo:12
  lor field rd ~hi:11 ~lo:7
  lor 0b1101111
;;

let jalr rd rs1 offset = i_type ~funct3:0 ~opcode:0b1100111 rd rs1 offset
let beq = b_type ~funct3:0b000
let bne = b_type ~funct3:0b001
let blt = b_type ~funct3:0b100
let bge = b_type ~funct3:0b101
let bltu = b_type ~funct3:0b110
let bgeu = b_type ~funct3:0b111
let lb rd rs1 off = i_type ~funct3:0b000 ~opcode:0b0000011 rd rs1 off
let lh rd rs1 off = i_type ~funct3:0b001 ~opcode:0b0000011 rd rs1 off
let lw rd rs1 off = i_type ~funct3:0b010 ~opcode:0b0000011 rd rs1 off
let lbu rd rs1 off = i_type ~funct3:0b100 ~opcode:0b0000011 rd rs1 off
let lhu rd rs1 off = i_type ~funct3:0b101 ~opcode:0b0000011 rd rs1 off
let sb rs2 rs1 off = s_type ~funct3:0b000 rs2 rs1 off
let sh rs2 rs1 off = s_type ~funct3:0b001 rs2 rs1 off
let sw rs2 rs1 off = s_type ~funct3:0b010 rs2 rs1 off
let addi rd rs1 imm = i_type ~funct3:0b000 ~opcode:0b0010011 rd rs1 imm
let slti rd rs1 imm = i_type ~funct3:0b010 ~opcode:0b0010011 rd rs1 imm
let sltiu rd rs1 imm = i_type ~funct3:0b011 ~opcode:0b0010011 rd rs1 imm
let xori rd rs1 imm = i_type ~funct3:0b100 ~opcode:0b0010011 rd rs1 imm
let ori rd rs1 imm = i_type ~funct3:0b110 ~opcode:0b0010011 rd rs1 imm
let andi rd rs1 imm = i_type ~funct3:0b111 ~opcode:0b0010011 rd rs1 imm

let shift_imm ~funct7 ~funct3 rd rs1 shamt =
  if shamt < 0 || shamt > 31 then invalid_arg (Printf.sprintf "shamt out of range: %d" shamt);
  i_type ~funct3 ~opcode:0b0010011 rd rs1 ((funct7 lsl 5) lor shamt)
;;

let slli = shift_imm ~funct7:0 ~funct3:0b001
let srli = shift_imm ~funct7:0 ~funct3:0b101

(* funct7 0100000 makes the raw 12-bit field 0x400 + shamt, which overflows
   the signed I-immediate check; encode it directly instead. *)
let srai rd rs1 shamt =
  shift_imm ~funct7:0 ~funct3:0b101 rd rs1 shamt lor (0b0100000 lsl 25)
;;
let op ?(funct7 = 0) funct3 = r_type ~funct7 ~funct3 ~opcode:0b0110011
let add = op 0b000
let sub = op ~funct7:0b0100000 0b000
let sll = op 0b001
let slt = op 0b010
let sltu = op 0b011
let xor = op 0b100
let srl = op 0b101
let sra = op ~funct7:0b0100000 0b101
let or_ = op 0b110
let and_ = op 0b111
(* M extension *)
let mul = op ~funct7:1 0b000
let mulh = op ~funct7:1 0b001
let mulhsu = op ~funct7:1 0b010
let mulhu = op ~funct7:1 0b011
let div = op ~funct7:1 0b100
let divu = op ~funct7:1 0b101
let rem = op ~funct7:1 0b110
let remu = op ~funct7:1 0b111

(* A extension (.W, aq = rl = 0); address in rs1. *)
let atomic funct5 rd rs1 rs2 = r_type ~funct7:(funct5 lsl 2) ~funct3:0b010 ~opcode:0b0101111 rd rs1 rs2
let lr_w rd rs1 = atomic 0b00010 rd rs1 0
let sc_w rd rs1 rs2 = atomic 0b00011 rd rs1 rs2
let amoswap_w = atomic 0b00001
let amoadd_w = atomic 0b00000
let amoxor_w = atomic 0b00100
let amoand_w = atomic 0b01100
let amoor_w = atomic 0b01000
let amomin_w = atomic 0b10000
let amomax_w = atomic 0b10100
let amominu_w = atomic 0b11000
let amomaxu_w = atomic 0b11100
let fence_i = 0x0000100f

let ecall = 0x00000073
let ebreak = 0x00100073
let nop = addi 0 0 0

(* Load an arbitrary 32-bit constant with lui + addi. *)
let li rd value =
  let value = value land 0xffff_ffff in
  let lo = Isa.sign_extend (value land 0xfff) ~width:12 in
  let hi = (value - lo) land 0xffff_ffff in
  [ lui rd hi; addi rd rd lo ]
;;

(* Zicsr and privileged instructions. *)
let csr_type ~funct3 rd rs1_or_uimm csr =
  check_reg rd;
  if csr < 0 || csr > 0xfff then invalid_arg "csr out of range";
  field csr ~hi:31 ~lo:20
  lor field rs1_or_uimm ~hi:19 ~lo:15
  lor field funct3 ~hi:14 ~lo:12
  lor field rd ~hi:11 ~lo:7
  lor 0b1110011
;;

let csrrw rd csr rs1 = check_reg rs1; csr_type ~funct3:0b001 rd rs1 csr
let csrrs rd csr rs1 = check_reg rs1; csr_type ~funct3:0b010 rd rs1 csr
let csrrc rd csr rs1 = check_reg rs1; csr_type ~funct3:0b011 rd rs1 csr

let csr_imm ~funct3 rd csr uimm =
  if uimm < 0 || uimm > 31 then invalid_arg "uimm out of range";
  csr_type ~funct3 rd uimm csr
;;

let csrrwi = csr_imm ~funct3:0b101
let csrrsi = csr_imm ~funct3:0b110
let csrrci = csr_imm ~funct3:0b111
let csrr rd csr = csrrs rd csr 0
let csrw csr rs1 = csrrw 0 csr rs1
let mret = 0x30200073
let wfi = 0x10500073
let sret = 0x10200073

let sfence_vma rs1 rs2 =
  r_type ~funct7:0b0001001 ~funct3:0 ~opcode:0b1110011 0 rs1 rs2
;;

module Csr = struct
  let mstatus = 0x300
  let misa = 0x301
  let mie = 0x304
  let mtvec = 0x305
  let mscratch = 0x340
  let mepc = 0x341
  let mcause = 0x342
  let mtval = 0x343
  let mip = 0x344
  let mcycle = 0xb00
  let minstret = 0xb02
  let cycle = 0xc00
  let mhartid = 0xf14
  let medeleg = 0x302
  let mideleg = 0x303
  let mcounteren = 0x306
  let menvcfgh = 0x31a
  let sstatus = 0x100
  let sie = 0x104
  let stvec = 0x105
  let scounteren = 0x106
  let sscratch = 0x140
  let sepc = 0x141
  let scause = 0x142
  let stval = 0x143
  let sip = 0x144
  let stimecmp = 0x14d
  let stimecmph = 0x15d
  let satp = 0x180
  let time = 0xc01
  let timeh = 0xc81
  let instret = 0xc02
end
