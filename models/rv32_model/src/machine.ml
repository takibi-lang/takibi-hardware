(* Architectural state and single-step execution of RV32I / RV32E, with
   optional Zicsr and machine-mode traps and interrupts, M, A, Zifencei,
   and supervisor/user mode with Sv32 ([s]).
   [step] returns a retirement record describing exactly what one
   instruction changed. The CPU core will emit the same record so the two can
   be compared instruction by instruction (lockstep).

   Traps (with [zicsr]): while the target trap vector (mtvec, or stvec for
   a trap delegated to S-mode) is 0 no handler is installed and a trap
   stops the machine ([step] returns [Error]), as without Zicsr; otherwise
   the trap enters the handler and [step] returns a retirement record whose
   [trap] field holds the cause value. Interrupts enter the handler through
   [interrupt], at an instruction boundary chosen by the caller;
   [pending_interrupt] says which one the machine would take.

   Implementation choices (the core makes the same ones):
   - mtvec/stvec are direct mode only; mepc/sepc and the vectors' bits 1..0
     read as zero.
   - mcause keeps bit 31 and bits 3..0 (WLRL), bits 4..0 with [s] (page
     fault causes are 12..15, but the WLRL field matches the core's).
   - Without [s]: mstatus has MIE and MPIE only, MPP reads as 3 (M-mode
     only); mie/mip have MSIE/MSIP (bit 3), MTIE/MTIP (7), MEIE/MEIP (11);
     mip is read only and comes from [csr_input].
   - mcycle, minstret (and h, and the user-level aliases) are read through
     [csr_input]; the model does not store them, so a write to a machine
     counter only affects what [csr_input] returns (the core's counters in
     lockstep; writable with [s] there). Standalone runs read zero.
   - misa, mvendorid, marchid, mimpid, mhartid read as 0 (misa reports the
     extensions with [s]). Other CSRs are illegal, as are writes to
     read-only CSRs (address bits 11..10 = 3) and accesses from a lower
     privilege than the address requires (bits 9..8).
   - With [s]: no PMP entries and no debug triggers; their CSRs
     (pmpcfg*, pmpaddr*, tselect, tdata1-3, tcontrol...) read as zero and
     ignore writes, so software may program them without trapping.

   M and A extensions ([m], [a]; issue #25):
   - Division by zero and signed overflow give the results the spec
     defines (no trap).
   - One hart: aq/rl are ignored. LR.W sets a reservation on its address;
     SC.W succeeds (writes, rd = 0) only if the reservation is valid for
     the same address, otherwise rd = 1 and nothing is written; every
     SC.W clears the reservation, and so does every trap entry. AMOs and
     LR/SC must be word aligned (misaligned -> store/AMO misaligned, cause
     6; LR -> load misaligned, cause 4).

   Supervisor mode ([s], implies [zicsr]; issue #25, for Linux, #21):
   - Privilege M/S/U; medeleg/mideleg (ecall from M cannot be delegated;
     only the S-level interrupts SSI, STI, SEI can), sstatus/sie/sip as
     views, stvec, sscratch, sepc, scause, stval, satp, SRET, SFENCE.VMA
     (no TLB in the model: a no-op), WFI as a no-op (illegal in U, and in
     S with mstatus.TW).
   - mstatus: SIE, MIE, SPIE, MPIE, SPP, MPP (0, 1 or 3), MPRV, SUM, MXR,
     TVM, TW, TSR.
   - mip: MSIP, MTIP, MEIP and SEIP from [csr_input]; SSIP and SEIP also
     writable by M (SSIP by S through sip); STIP writable by M unless Sstc
     is enabled (menvcfgh.STCE), in which case it is (time >= stimecmp).
   - Sstc: stimecmp/stimecmph (S-mode access needs STCE and
     mcounteren.TM), time/timeh from [csr_input] (CLINT mtime).
   - mcounteren/scounteren gate cycle, time and instret below M.
   - Sv32 translation for fetches and data accesses below M (data: MPRV
     uses MPP), A/D bits by trapping (Svade: a page fault when A is clear,
     or D for a store), superpages must be aligned. Page table entries are
     read from RAM only.
   - Physical memory: RAM of [mem_bytes] at [mem_base]; everything [io]
     claims is I/O; anything else is an access fault (model only: the
     machine stops). *)

open Sexplib0.Sexp_conv
open Ppx_compare_lib.Builtin

type access =
  | Fetch
  | Load
  | Store
[@@deriving sexp_of, equal]

type trap =
  | Ecall
  | Ebreak
  | Illegal_instruction of int
  | Misaligned_fetch of int
  | Misaligned_access of int
  | Access_fault of int
  | Page_fault of access * int
[@@deriving sexp_of, equal]

type retire =
  { pc : int
  ; insn : int
  ; rd_write : (int * int) option (* register, value *)
  ; mem_write : (int * int * int) option (* address, bytes, value *)
  ; next_pc : int
  ; trap : int option (* cause, when the record is a trap or interrupt entry *)
  }
[@@deriving sexp_of, equal]

(* Memory-mapped I/O. Accesses for which [is_io addr] holds bypass RAM:
   [load ~addr ~bytes] returns the raw value (before sign extension),
   [store ~addr ~bytes ~value] performs the write. Addresses are physical. *)
type io =
  { is_io : int -> bool
  ; load : addr:int -> bytes:int -> int
  ; store : addr:int -> bytes:int -> value:int -> unit
  }

let no_io =
  { is_io = (fun _ -> false)
  ; load = (fun ~addr:_ ~bytes:_ -> 0)
  ; store = (fun ~addr:_ ~bytes:_ ~value:_ -> ())
  }
;;

type t =
  { base : Isa.base
  ; zicsr : bool
  ; m : bool
  ; a : bool
  ; zifencei : bool
  ; s : bool
  ; mem_base : int
  ; mutable reservation : int option (* LR.W address *)
  ; regs : int array
  ; mutable pc : int
  ; mem : Bytes.t
  ; io : io
  ; csr_input : int -> int (* mip, the counters and time, by CSR address *)
  ; mutable priv : int (* 3 M, 1 S, 0 U *)
  ; mutable mstatus_mie : bool
  ; mutable mstatus_mpie : bool
  ; mutable mstatus_sie : bool
  ; mutable mstatus_spie : bool
  ; mutable mstatus_spp : int
  ; mutable mstatus_mpp : int
  ; mutable mstatus_mprv : bool
  ; mutable mstatus_sum : bool
  ; mutable mstatus_mxr : bool
  ; mutable mstatus_tvm : bool
  ; mutable mstatus_tw : bool
  ; mutable mstatus_tsr : bool
  ; mutable mie : int
  ; mutable mip_sw : int (* SSIP, STIP, SEIP as written by software *)
  ; mutable mtvec : int
  ; mutable mscratch : int
  ; mutable mepc : int
  ; mutable mcause : int
  ; mutable mtval : int
  ; mutable medeleg : int
  ; mutable mideleg : int
  ; mutable mcounteren : int
  ; mutable scounteren : int
  ; mutable menvcfg_stce : bool
  ; mutable stvec : int
  ; mutable sscratch : int
  ; mutable sepc : int
  ; mutable scause : int
  ; mutable stval : int
  ; mutable satp : int
  ; mutable stimecmp : int * int (* lo, hi *)
  }

let mask32 v = v land 0xffff_ffff
let signed32 v = Isa.sign_extend v ~width:32

let create
  ?(io = no_io)
  ?(zicsr = false)
  ?(m = false)
  ?(a = false)
  ?(zifencei = false)
  ?(s = false)
  ?(mem_base = 0)
  ?(csr_input = fun _ -> 0)
  ~base
  ~mem_bytes
  ()
  =
  { base
  ; zicsr = zicsr || s
  ; m
  ; a
  ; zifencei
  ; s
  ; mem_base
  ; reservation = None
  ; regs = Array.make (Isa.num_regs base) 0
  ; pc = mem_base
  ; mem = Bytes.make mem_bytes '\000'
  ; io
  ; csr_input
  ; priv = 3
  ; mstatus_mie = false
  ; mstatus_mpie = false
  ; mstatus_sie = false
  ; mstatus_spie = false
  ; mstatus_spp = 0
  ; mstatus_mpp = (if s then 0 else 3)
  ; mstatus_mprv = false
  ; mstatus_sum = false
  ; mstatus_mxr = false
  ; mstatus_tvm = false
  ; mstatus_tw = false
  ; mstatus_tsr = false
  ; mie = 0
  ; mip_sw = 0
  ; mtvec = 0
  ; mscratch = 0
  ; mepc = 0
  ; mcause = 0
  ; mtval = 0
  ; medeleg = 0
  ; mideleg = 0
  ; mcounteren = 0
  ; scounteren = 0
  ; menvcfg_stce = false
  ; stvec = 0
  ; sscratch = 0
  ; sepc = 0
  ; scause = 0
  ; stval = 0
  ; satp = 0
  ; stimecmp = 0xffff_ffff, 0xffff_ffff
  }
;;

(* Interrupt bits: SSI 1, MSI 3, STI 5, MTI 7, SEI 9, MEI 11. *)
let irq_mask t = if t.s then 0xaaa else 0x888
let s_irqs = 0x222
let bool_bit b n = if b then 1 lsl n else 0

let time t =
  (* 64-bit, as two 32-bit halves compared lexicographically *)
  mask32 (t.csr_input 0xc81), mask32 (t.csr_input 0xc01)
;;

let mip t =
  let hw = t.csr_input 0x344 land (if t.s then 0xa88 else 0x888) in
  if not t.s
  then hw
  else (
    let sw = t.mip_sw land (if t.menvcfg_stce then 0x202 else 0x222) in
    let stip =
      if t.menvcfg_stce
      then (
        let th, tl = time t in
        let cl, ch = t.stimecmp in
        bool_bit (th > ch || (th = ch && tl >= cl)) 5)
      else 0
    in
    hw lor sw lor stip)
;;

let cause_mask t = if t.s then 0x8000_001f else 0x8000_000f

let mstatus t =
  bool_bit t.mstatus_sie 1
  lor bool_bit t.mstatus_mie 3
  lor bool_bit t.mstatus_spie 5
  lor bool_bit t.mstatus_mpie 7
  lor (t.mstatus_spp lsl 8)
  lor (t.mstatus_mpp lsl 11)
  lor bool_bit t.mstatus_mprv 17
  lor bool_bit t.mstatus_sum 18
  lor bool_bit t.mstatus_mxr 19
  lor bool_bit t.mstatus_tvm 20
  lor bool_bit t.mstatus_tw 21
  lor bool_bit t.mstatus_tsr 22
;;

let sstatus_mask = 0x000c_0122 (* SIE, SPIE, SPP, SUM, MXR *)

let set_mstatus t v ~mask =
  let bit n = v land (1 lsl n) <> 0 in
  let m n = mask land (1 lsl n) <> 0 in
  if m 1 then t.mstatus_sie <- bit 1;
  if m 3 then t.mstatus_mie <- bit 3;
  if m 5 then t.mstatus_spie <- bit 5;
  if m 7 then t.mstatus_mpie <- bit 7;
  if m 8 then t.mstatus_spp <- Bool.to_int (bit 8);
  if m 11
  then (
    match (v lsr 11) land 3 with
    | 2 -> () (* reserved: keep the old value *)
    | mpp -> t.mstatus_mpp <- mpp);
  if m 17 then t.mstatus_mprv <- bit 17;
  if m 18 then t.mstatus_sum <- bit 18;
  if m 19 then t.mstatus_mxr <- bit 19;
  if m 20 then t.mstatus_tvm <- bit 20;
  if m 21 then t.mstatus_tw <- bit 21;
  if m 22 then t.mstatus_tsr <- bit 22
;;

let misa t =
  if not t.s
  then 0
  else (
    let ext c = 1 lsl (Char.code c - Char.code 'A') in
    (1 lsl 30)
    lor ext (match t.base with Rv32i -> 'I' | Rv32e -> 'E')
    lor (if t.m then ext 'M' else 0)
    lor (if t.a then ext 'A' else 0)
    lor ext 'S'
    lor ext 'U')
;;

let is_counter csr = (csr >= 0xc00 && csr <= 0xc1f) || (csr >= 0xc80 && csr <= 0xc9f)

(* CSR access: [None] if the CSR does not exist or the current privilege
   may not access it. *)
let csr_read t csr =
  let allowed =
    (csr lsr 8) land 3 <= t.priv
    && ((not (is_counter csr))
        || t.priv = 3
        || (let bit = 1 lsl (csr land 0x1f) in
            t.mcounteren land bit <> 0 && (t.priv = 1 || t.scounteren land bit <> 0)))
  in
  let lo_hi_time csr = mask32 (t.csr_input csr) in
  if not allowed
  then None
  else (
    match csr with
    | 0x300 -> Some (if t.s then mstatus t else mstatus t lor (3 lsl 11))
    | 0x304 -> Some t.mie
    | 0x305 -> Some t.mtvec
    | 0x340 -> Some t.mscratch
    | 0x341 -> Some t.mepc
    | 0x342 -> Some t.mcause
    | 0x343 -> Some t.mtval
    | 0x344 -> Some (mip t)
    | 0xb00 | 0xb02 | 0xb80 | 0xb82 | 0xc00 | 0xc02 | 0xc80 | 0xc82 ->
      Some (mask32 (t.csr_input csr))
    | 0x301 -> Some (misa t)
    | 0xf11 | 0xf12 | 0xf13 | 0xf14 -> Some 0
    | _ when not t.s -> None
    | 0xc01 | 0xc81 -> Some (lo_hi_time csr)
    | 0x302 -> Some t.medeleg
    | 0x303 -> Some t.mideleg
    | 0x306 -> Some t.mcounteren
    | 0x30a -> Some 0
    | 0x31a -> Some (bool_bit t.menvcfg_stce 31)
    | 0x100 -> Some (mstatus t land sstatus_mask)
    | 0x104 -> Some (t.mie land t.mideleg)
    | 0x144 -> Some (mip t land t.mideleg)
    | 0x105 -> Some t.stvec
    | 0x106 -> Some t.scounteren
    | 0x10a -> Some 0 (* senvcfg *)
    | _ when (csr >= 0x3a0 && csr <= 0x3ef) || (csr >= 0x7a0 && csr <= 0x7a5) ->
      Some 0 (* PMP (no entries) and debug triggers (none): read zero *)
    | 0x140 -> Some t.sscratch
    | 0x141 -> Some t.sepc
    | 0x142 -> Some t.scause
    | 0x143 -> Some t.stval
    | 0x180 -> if t.priv = 1 && t.mstatus_tvm then None else Some t.satp
    | 0x14d | 0x15d ->
      if t.priv = 1 && not (t.menvcfg_stce && t.mcounteren land 2 <> 0)
      then None
      else Some (if csr = 0x14d then fst t.stimecmp else snd t.stimecmp)
    | _ -> None)
;;

let csr_write t csr v =
  match csr with
  | 0x300 -> set_mstatus t v ~mask:(if t.s then 0x007e_19aa else 0x88)
  | 0x304 -> t.mie <- v land irq_mask t
  | 0x305 -> t.mtvec <- v land lnot 3
  | 0x340 -> t.mscratch <- v
  | 0x341 -> t.mepc <- v land lnot 3
  | 0x342 -> t.mcause <- v land cause_mask t
  | 0x343 -> t.mtval <- v
  | 0x344 when t.s -> t.mip_sw <- v land 0x222
  | 0x302 -> t.medeleg <- v land 0xb3ff
  | 0x303 -> t.mideleg <- v land s_irqs
  | 0x306 -> t.mcounteren <- v land 7
  | 0x31a -> t.menvcfg_stce <- v land (1 lsl 31) <> 0
  | 0x100 -> set_mstatus t v ~mask:sstatus_mask
  | 0x104 -> t.mie <- (t.mie land lnot t.mideleg) lor (v land t.mideleg)
  | 0x144 -> t.mip_sw <- (t.mip_sw land lnot 2) lor (v land t.mideleg land 2)
  | 0x105 -> t.stvec <- v land lnot 3
  | 0x106 -> t.scounteren <- v land 7
  | 0x140 -> t.sscratch <- v
  | 0x141 -> t.sepc <- v land lnot 3
  | 0x142 -> t.scause <- v land 0x8000_001f
  | 0x143 -> t.stval <- v
  | 0x180 -> t.satp <- v land 0x803f_ffff (* MODE, PPN; ASID not implemented *)
  | 0x14d -> t.stimecmp <- v, snd t.stimecmp
  | 0x15d -> t.stimecmp <- fst t.stimecmp, v
  | _ -> () (* counters, misa, menvcfg, senvcfg: writes ignored *)
;;

let read_only csr = (csr lsr 10) land 3 = 3

(* Where a trap with [cause] taken now would go: true for S-mode. *)
let delegated t ~cause =
  let interrupt = cause land 0x8000_0000 <> 0 in
  let code = cause land 0x1f in
  t.s && t.priv <= 1 && (if interrupt then t.mideleg else t.medeleg) land (1 lsl code) <> 0
;;

let trap_vector t ~cause = if delegated t ~cause then t.stvec else t.mtvec

(* Enter the trap handler: the state change of a trap or interrupt. *)
let enter_trap t ~cause ~tval =
  t.reservation <- None;
  if delegated t ~cause
  then (
    t.sepc <- t.pc land lnot 3;
    t.scause <- cause land 0x8000_001f;
    t.stval <- mask32 tval;
    t.mstatus_spp <- t.priv;
    t.mstatus_spie <- t.mstatus_sie;
    t.mstatus_sie <- false;
    t.priv <- 1;
    t.pc <- t.stvec)
  else (
    t.mepc <- t.pc land lnot 3;
    t.mcause <- cause land cause_mask t;
    t.mtval <- mask32 tval;
    if t.s then t.mstatus_mpp <- t.priv;
    t.mstatus_mpie <- t.mstatus_mie;
    t.mstatus_mie <- false;
    t.priv <- 3;
    t.pc <- t.mtvec)
;;

let reg t r = if r = 0 then 0 else t.regs.(r)
let pc t = t.pc

(* [at] is an offset into the RAM. *)
let load_program t ?(at = 0) words =
  List.iteri
    (fun k w -> Bytes.set_int32_le t.mem (at + (4 * k)) (Int32.of_int (mask32 w)))
    words
;;

let size = function
  | Isa.Byte -> 1
  | Half -> 2
  | Word -> 4
;;

(* Physical RAM access ([pa] inside the RAM). *)
let read t pa n =
  let off = pa - t.mem_base in
  let rec go k acc =
    if k < 0 then acc else go (k - 1) ((acc lsl 8) lor Char.code (Bytes.get t.mem (off + k)))
  in
  go (n - 1) 0
;;

let write t pa n v =
  let off = pa - t.mem_base in
  for k = 0 to n - 1 do
    Bytes.set t.mem (off + k) (Char.chr ((v lsr (8 * k)) land 0xff))
  done
;;

let in_ram t pa n = pa >= t.mem_base && pa + n <= t.mem_base + Bytes.length t.mem

(* Sv32: translate [va] for [access]; [Ok pa] or the page fault. *)
let translate t ~access va =
  let eff = if access = Fetch || not t.mstatus_mprv then t.priv else t.mstatus_mpp in
  if (not t.s) || eff = 3 || t.satp land 0x8000_0000 = 0
  then Ok va
  else (
    let fault = Error (Page_fault (access, va)) in
    let rec walk level table =
      let vpn = if level = 1 then (va lsr 22) land 0x3ff else (va lsr 12) land 0x3ff in
      let pte_addr = table + (4 * vpn) in
      if not (in_ram t pte_addr 4)
      then Error (Access_fault pte_addr)
      else (
        let pte = read t pte_addr 4 in
        let bit n = pte land (1 lsl n) <> 0 in
        let v = bit 0
        and r = bit 1
        and w = bit 2
        and x = bit 3
        and u = bit 4
        and a = bit 6
        and d = bit 7 in
        let ppn = pte lsr 10 in
        if (not v) || ((not r) && w)
        then fault
        else if not (r || x)
        then if level = 0 then fault else walk 0 (ppn lsl 12)
        else (
          let permitted =
            match access with
            | Fetch -> x
            | Load -> r || (x && t.mstatus_mxr)
            | Store -> w
          in
          let user_ok =
            if eff = 0 then u else (not u) || (access <> Fetch && t.mstatus_sum)
          in
          if (not permitted) || (not user_ok) || (not a) || (access = Store && not d)
          then fault
          else if level = 1 && ppn land 0x3ff <> 0
          then fault (* misaligned superpage *)
          else if level = 1
          then Ok (((ppn lsr 10) lsl 22) lor (va land 0x3f_ffff))
          else Ok ((ppn lsl 12) lor (va land 0xfff))))
    in
    walk 1 ((t.satp land 0x3f_ffff) lsl 12))
;;

(* Check alignment, translate, and check the physical address. *)
let access_addr t ~access va n =
  if va mod n <> 0
  then (
    match access with
    | Fetch -> Error (Misaligned_fetch va)
    | Load | Store -> Error (Misaligned_access va))
  else (
    match translate t ~access va with
    | Error e -> Error e
    | Ok pa -> if t.io.is_io pa || in_ram t pa n then Ok pa else Error (Access_fault pa))
;;

let load_pa t pa n = if t.io.is_io pa then t.io.load ~addr:pa ~bytes:n else read t pa n

let alu (op : Isa.alu) a b =
  let sh = b land 31 in
  mask32
    (match op with
     | Add -> a + b
     | Sub -> a - b
     | Sll -> a lsl sh
     | Slt -> if signed32 a < signed32 b then 1 else 0
     | Sltu -> if a < b then 1 else 0
     | Xor -> a lxor b
     | Srl -> a lsr sh
     | Sra -> signed32 a asr sh
     | Or -> a lor b
     | And -> a land b)
;;

(* The 64-bit product of two 32-bit unsigned values as (hi, lo), in
   16-bit limbs so that nothing overflows a 63-bit OCaml int. *)
let mul_u32 a b =
  let al = a land 0xffff
  and ah = a lsr 16
  and bl = b land 0xffff
  and bh = b lsr 16 in
  let ll = al * bl
  and lh = al * bh
  and hl = ah * bl
  and hh = ah * bh in
  let mid = (ll lsr 16) + (lh land 0xffff) + (hl land 0xffff) in
  let lo = (ll land 0xffff) lor ((mid land 0xffff) lsl 16) in
  let hi = hh + (lh lsr 16) + (hl lsr 16) + (mid lsr 16) in
  mask32 hi, lo
;;

(* Upper 32 bits of a x b where a and/or b are signed: the unsigned
   product, corrected by subtracting b (resp. a) when a (resp. b) is
   negative (two's complement identity). *)
let mulh_mixed ~a_signed ~b_signed a b =
  let hi, _ = mul_u32 a b in
  let hi = if a_signed && a land 0x8000_0000 <> 0 then hi - b else hi in
  let hi = if b_signed && b land 0x8000_0000 <> 0 then hi - a else hi in
  mask32 hi
;;

let mul_div (op : Isa.mul_op) a b =
  let sa = signed32 a
  and sb = signed32 b in
  match op with
  | Mul -> snd (mul_u32 a b)
  | Mulh -> mulh_mixed ~a_signed:true ~b_signed:true a b
  | Mulhsu -> mulh_mixed ~a_signed:true ~b_signed:false a b
  | Mulhu -> fst (mul_u32 a b)
  | Div ->
    if b = 0
    then 0xffff_ffff
    else if sa = -0x8000_0000 && sb = -1
    then a
    else mask32 (sa / sb)
  | Divu -> if b = 0 then 0xffff_ffff else a / b
  | Rem ->
    if b = 0 then a else if sa = -0x8000_0000 && sb = -1 then 0 else mask32 (sa mod sb)
  | Remu -> if b = 0 then a else a mod b
;;

let amo (op : Isa.amo_op) old v =
  mask32
    (match op with
     | Amoswap -> v
     | Amoadd -> old + v
     | Amoxor -> old lxor v
     | Amoand -> old land v
     | Amoor -> old lor v
     | Amomin -> if signed32 old <= signed32 v then old else v
     | Amomax -> if signed32 old >= signed32 v then old else v
     | Amominu -> if old <= v then old else v
     | Amomaxu -> if old >= v then old else v)
;;

let taken (cond : Isa.branch) a b =
  match cond with
  | Beq -> a = b
  | Bne -> a <> b
  | Blt -> signed32 a < signed32 b
  | Bge -> signed32 a >= signed32 b
  | Bltu -> a < b
  | Bgeu -> a >= b
;;

let decode t insn =
  Isa.decode ~zicsr:t.zicsr ~m:t.m ~a:t.a ~zifencei:t.zifencei ~s:t.s ~base:t.base insn
;;

(* The cause and tval of a synchronous trap ([store]: the faulting access
   is a store or AMO). [None]: model-only (outside the RAM). *)
let cause_of t ~store = function
  | Misaligned_fetch a -> Some (0, a)
  | Illegal_instruction w -> Some (2, w)
  | Ebreak -> Some (3, 0)
  | Misaligned_access a -> Some ((if store then 6 else 4), a)
  | Ecall -> Some ((match t.priv with 0 -> 8 | 1 -> 9 | _ -> 11), 0)
  | Page_fault (Fetch, a) -> Some (12, a)
  | Page_fault (Load, a) -> Some (13, a)
  | Page_fault (Store, a) -> Some (15, a)
  | Access_fault _ -> None
;;

(* Execute one instruction without trap handling. On a trap the state is
   left unchanged. Retirement records report virtual addresses for memory
   writes (what the program computed). *)
let execute t : (retire, trap) result =
  let ( let* ) = Result.bind in
  let pc = t.pc in
  let* fetch_pa = access_addr t ~access:Fetch pc 4 in
  let insn = load_pa t fetch_pa 4 in
  let r = reg t in
  let seq = mask32 (pc + 4) in
  let jump target = if target land 3 <> 0 then Error (Misaligned_fetch target) else Ok target in
  let illegal = Error (Illegal_instruction insn) in
  (* Pending memory write: (virtual, physical, bytes, value). *)
  let* rd_write, mem_write, next_pc =
    match decode t insn with
    | Lui { rd; imm } -> Ok (Some (rd, mask32 imm), None, seq)
    | Auipc { rd; imm } -> Ok (Some (rd, mask32 (pc + imm)), None, seq)
    | Jal { rd; offset } ->
      let* target = jump (mask32 (pc + offset)) in
      Ok (Some (rd, seq), None, target)
    | Jalr { rd; rs1; offset } ->
      let* target = jump (mask32 (r rs1 + offset) land lnot 1) in
      Ok (Some (rd, seq), None, target)
    | Branch { cond; rs1; rs2; offset } ->
      if taken cond (r rs1) (r rs2)
      then
        let* target = jump (mask32 (pc + offset)) in
        Ok (None, None, target)
      else Ok (None, None, seq)
    | Load { width; unsigned; rd; rs1; offset } ->
      let addr = mask32 (r rs1 + offset) in
      let n = size width in
      let* pa = access_addr t ~access:Load addr n in
      let v = load_pa t pa n in
      let v = if unsigned then v else mask32 (Isa.sign_extend v ~width:(8 * n)) in
      Ok (Some (rd, v), None, seq)
    | Store { width; rs1; rs2; offset } ->
      let addr = mask32 (r rs1 + offset) in
      let n = size width in
      let* pa = access_addr t ~access:Store addr n in
      let v = r rs2 land ((1 lsl (8 * n)) - 1) in
      Ok (None, Some (addr, pa, n, v), seq)
    | Op_imm { op; rd; rs1; imm } -> Ok (Some (rd, alu op (r rs1) (mask32 imm)), None, seq)
    | Op { op; rd; rs1; rs2 } -> Ok (Some (rd, alu op (r rs1) (r rs2)), None, seq)
    | Fence | Fence_i -> Ok (None, None, seq) (* no caches in the model *)
    | Wfi ->
      if t.s && (t.priv = 0 || (t.priv = 1 && t.mstatus_tw))
      then illegal
      else Ok (None, None, seq)
    | Mret ->
      if t.priv < 3
      then illegal
      else (
        t.mstatus_mie <- t.mstatus_mpie;
        t.mstatus_mpie <- true;
        if t.s
        then (
          t.priv <- t.mstatus_mpp;
          if t.mstatus_mpp <> 3 then t.mstatus_mprv <- false;
          t.mstatus_mpp <- 0);
        Ok (None, None, t.mepc))
    | Sret ->
      if t.priv = 0 || (t.priv = 1 && t.mstatus_tsr)
      then illegal
      else (
        t.priv <- t.mstatus_spp;
        t.mstatus_sie <- t.mstatus_spie;
        t.mstatus_spie <- true;
        t.mstatus_spp <- 0;
        t.mstatus_mprv <- false;
        Ok (None, None, t.sepc))
    | Sfence_vma _ ->
      if t.priv = 0 || (t.priv = 1 && t.mstatus_tvm) then illegal else Ok (None, None, seq)
    | Csr { op; rd; src; csr } ->
      let src_value, src_zero =
        match src with
        | Csr_reg rs -> r rs, rs = 0
        | Csr_imm u -> u, u = 0
      in
      let writes =
        match op with
        | Csrrw -> true
        | Csrrs | Csrrc -> not src_zero
      in
      (match csr_read t csr with
       | None -> illegal
       | Some _ when writes && read_only csr -> illegal
       | Some old ->
         if writes
         then
           csr_write
             t
             csr
             (match op with
              | Csrrw -> src_value
              | Csrrs -> old lor src_value
              | Csrrc -> old land lnot src_value);
         Ok (Some (rd, old), None, seq))
    | Mul_div { op; rd; rs1; rs2 } -> Ok (Some (rd, mul_div op (r rs1) (r rs2)), None, seq)
    | Lr { rd; rs1 } ->
      let addr = r rs1 in
      let* pa = access_addr t ~access:Load addr 4 in
      let v = load_pa t pa 4 in
      t.reservation <- Some addr;
      Ok (Some (rd, v), None, seq)
    | Sc { rd; rs1; rs2 } ->
      let addr = r rs1 in
      let* pa = access_addr t ~access:Store addr 4 in
      let ok = Option.equal Int.equal t.reservation (Some addr) in
      t.reservation <- None;
      if ok
      then Ok (Some (rd, 0), Some (addr, pa, 4, r rs2), seq)
      else Ok (Some (rd, 1), None, seq)
    | Amo { op; rd; rs1; rs2 } ->
      let addr = r rs1 in
      let* pa = access_addr t ~access:Store addr 4 in
      let old = load_pa t pa 4 in
      Ok (Some (rd, old), Some (addr, pa, 4, amo op old (r rs2)), seq)
    | Ecall -> Error Ecall
    | Ebreak -> Error Ebreak
    | Illegal _ -> illegal
  in
  (* Writes to x0 are discarded and not reported. *)
  let rd_write = Option.bind rd_write (fun (rd, v) -> if rd = 0 then None else Some (rd, v)) in
  Option.iter (fun (rd, v) -> t.regs.(rd) <- v) rd_write;
  Option.iter
    (fun (_, pa, n, v) ->
      if t.io.is_io pa then t.io.store ~addr:pa ~bytes:n ~value:v else write t pa n v)
    mem_write;
  t.pc <- next_pc;
  let mem_write = Option.map (fun (va, _, n, v) -> va, n, v) mem_write in
  Ok { pc; insn; rd_write; mem_write; next_pc; trap = None }
;;

(* Execute one instruction, entering the trap handler on a trap when Zicsr
   is enabled and a handler is installed (the target vector <> 0). *)
let step t : (retire, trap) result =
  match execute t with
  | Ok r -> Ok r
  | Error e when t.zicsr ->
    let pc = t.pc in
    let insn =
      match translate t ~access:Fetch pc with
      | Ok pa when pc land 3 = 0 && (t.io.is_io pa || in_ram t pa 4) -> load_pa t pa 4
      | _ -> 0
    in
    let store =
      match decode t insn with
      | Store _ | Sc _ | Amo _ -> true
      | _ -> false
    in
    (match cause_of t ~store e with
     | None -> Error e
     | Some (cause, tval) when trap_vector t ~cause <> 0 ->
       enter_trap t ~cause ~tval;
       Ok { pc; insn; rd_write = None; mem_write = None; next_pc = t.pc; trap = Some cause }
     | Some _ -> Error e)
  | Error e -> Error e
;;

(* The interrupt the machine would take now, if any: pending and enabled
   (mip & mie), globally enabled for its target mode, in the priority
   order MEI, MSI, MTI, SEI, SSI, STI. *)
let pending_interrupt t =
  if not t.zicsr
  then None
  else (
    let pend = mip t land t.mie in
    List.find_opt
      (fun code ->
        pend land (1 lsl code) <> 0
        &&
        if t.s && t.mideleg land (1 lsl code) <> 0
        then t.priv < 1 || (t.priv = 1 && t.mstatus_sie)
        else t.priv < 3 || t.mstatus_mie)
      [ 11; 3; 7; 9; 1; 5 ])
;;

(* Take an interrupt with exception code [code] (7: machine timer, 11:
   machine external, ...) at the current instruction boundary. Fails if
   the machine would not take it: Zicsr off, no handler, interrupts
   disabled or the source not enabled in mie. Pending state is the
   caller's business (it comes from the hardware). *)
let interrupt t ~code : (retire, string) result =
  let cause = 0x8000_0000 lor code in
  let enabled =
    if t.s && t.mideleg land (1 lsl code) <> 0
    then t.priv < 1 || (t.priv = 1 && t.mstatus_sie)
    else t.priv < 3 || t.mstatus_mie
  in
  if not t.zicsr
  then Error "interrupt without Zicsr"
  else if trap_vector t ~cause = 0
  then Error "interrupt with no handler (mtvec = 0)"
  else if not enabled
  then Error "interrupt while mstatus.MIE = 0"
  else if t.mie land (1 lsl code) = 0
  then Error (Printf.sprintf "interrupt %d not enabled in mie" code)
  else (
    let pc = t.pc in
    enter_trap t ~cause ~tval:0;
    Ok { pc; insn = 0; rd_write = None; mem_write = None; next_pc = t.pc; trap = Some cause })
;;

(* Run until a trap or [max_steps] retirements; return the trace and the
   trap (None if the step limit was hit). *)
let run ?(max_steps = 10_000) t =
  let rec go n acc =
    if n = max_steps
    then List.rev acc, None
    else (
      match step t with
      | Ok r -> go (n + 1) (r :: acc)
      | Error trap -> List.rev acc, Some trap)
  in
  go 0 []
;;
