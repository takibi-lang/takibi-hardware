(* Multi-cycle RV32I / RV32E core ([~base]).

   Cycles per instruction: Fetch, Decode, Read_rs2, Execute (4); loads add
   one (Load); shifts add 1 + shamt (Shift, one bit per cycle, to save the
   area of a barrel shifter). With [~dual_read:true] (issue #4, the ECP5
   MCU) the register file has a second copy, so Decode reads rs1 and rs2
   together and Read_rs2 is skipped: 3 cycles per instruction. With
   [~fetch_overlap:true] (#4) an instruction that does not use the memory
   bus fetches its successor in Execute, at the exact next pc (branches
   are resolved there), and the core goes straight to Decode: 2 cycles
   with dual_read. Not after CSR instructions and MRET (they may change
   the interrupt enables) and not when an interrupt would be taken at
   this boundary (it is then taken in Fetch as before). The [fetch]
   output marks the cycle where the interrupt decision for the next
   boundary is made: Fetch, or the overlapping Execute.

   M and A ([~m], [~a]; #5, the Linux SoC): multiplication takes one extra
   cycle (Mul: the 33 x 33 product is registered at the end of Execute);
   division and remainder are restoring, one bit per cycle (Div, 32
   cycles); LR.W is a load that sets the reservation; SC.W writes in
   Execute if the reservation holds for its address (rd = 0) and
   otherwise only sets rd = 1; every SC.W and every trap or interrupt
   entry clears the reservation, as in Rv32_model.Machine. AMOs read in
   Execute, register the old value in Amo and compute and write in
   Amo_write (block RAM output -> ALU -> block RAM input in one cycle
   missed 50 MHz, B-0024). FENCE.I ([~zifencei]) is a no-op (no
   caches).

   Memory bus (issue #26, Linux L4): a request ([mem_read] or [mem_write]
   with [mem_addr], [mem_wdata], [mem_wmask]) is held until the memory
   accepts it with [mem_ready] in the same cycle; read data comes later,
   in a cycle with [mem_rvalid], at the earliest the cycle after the
   acceptance. At most one read is outstanding, and the core issues no
   request while it waits for read data. A write is done when accepted. A
   read request that has not been accepted may be withdrawn (the
   overlapped fetch of [~fetch_overlap] falls back to Fetch, and an
   interrupt taken in Fetch replaces the fetch); a write never is. Block
   RAM: [mem_ready] = 1 and [mem_rvalid] = [mem_read] delayed by one
   cycle, which gives the cycle counts of the original one-cycle bus.
   Writes carry a byte-lane mask and lane-aligned data.

   The register file is a 32 x 32 (RV32I) or 16 x 32 (RV32E) block RAM with
   a registered read port. x0 is
   never written, so it reads as the BRAM's initial zero; reads and writes
   never happen in the same cycle (reads in Decode/Read_rs2, writes in
   Execute/Shift/Load), which makes the RAM's no_rw_check attribute safe.

   On ECALL, EBREAK, an illegal instruction or a misaligned access/target
   the core stops in Halted without changing state, like the golden model.

   With [~barrel_shift:true] (#4, #23) shifts complete in Execute through
   a barrel shifter instead of one bit per cycle in Shift.

   With [~zicsr:true] (issue #3; the ECP5 MCU) the core also has the Zicsr
   instructions, MRET, WFI (a no-op), the machine-mode CSRs of
   Rv32_model.Machine (same implementation choices), mcycle/minstret, and
   interrupts from [irq] (bit 0 software, 1 timer, 2 external). Once
   mtvec <> 0 a trap enters the handler instead of halting; interrupts are
   taken in Fetch, at an instruction boundary, with priority external >
   software > timer. Trap and interrupt entries retire with [retire_trap]
   and the mcause in [retire_cause]. Without Zicsr all of this is constant
   and synthesis removes it.

   With [~s:true] (implies Zicsr; issue #6, Linux L2) the core has user
   and supervisor modes as Rv32_model.Machine with [~s] (same implementation
   choices): medeleg/mideleg, the S-mode CSRs and views (sstatus, sie, sip),
   SRET, SFENCE.VMA (a no-op until there is a TLB), mstatus MPRV/SUM/MXR/
   TVM/TW/TSR, mcounteren/scounteren, Sstc (stimecmp against the [time]
   input, the CLINT's mtime), SEIP from [seip] (the PLIC's S context), and
   the PMP and trigger CSRs reading zero, and writable mcycle/minstret. Interrupts are taken in the
   model's priority order MEI, MSI, MTI, SEI, SSI, STI, when the target
   mode's vector is non-zero.

   Sv32 ([~s]; #6, Linux L3): instruction and data TLBs, direct-mapped
   with [tlb_entries] entries each (registers), indexed by the low VPN
   bits; an entry holds a 4 KiB page or a 4 MiB superpage with the PTE's
   R/W/X/U/A/D bits. Permissions, A and D are checked on every access
   against the current privilege, SUM and MXR (MPRV/MPP for data). A miss,
   or a hit that would fault, walks the page table (Ptw_l1, Ptw_l1_data,
   Ptw_l1_check, Ptw_l0, Ptw_l0_data, Ptw_l0_check: each PTE is registered
   before it is checked; PTE addresses are concatenations, no adder) and then either
   fills the TLB and retries or raises the page fault: a fault is always
   decided on the PTE in memory, so a PTE whose A/D bits software has just
   set (Svade) is seen without an SFENCE.VMA. SFENCE.VMA and satp writes
   flush both TLBs. While fetches are translated, fetch_overlap is off.

   The retire_* outputs describe each completed instruction in the same terms
   as Rv32_model.Machine.retire; they exist for lockstep testing and are
   removed by synthesis when unconnected. *)
open! Base
open! Hardcaml
open Signal

module Trap = struct
  let none = 0
  let ecall = 1
  let ebreak = 2
  let illegal = 3
  let misaligned_fetch = 4
  let misaligned_access = 5
  let page_fault = 6
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; mem_rdata : 'a [@bits 32]
    ; mem_ready : 'a (* the request is accepted *)
    ; mem_rvalid : 'a (* read data on mem_rdata *)
    ; irq : 'a [@bits 3] (* software, timer, external; Zicsr only *)
    ; seip : 'a (* supervisor external interrupt (PLIC); [~s] only *)
    ; mtime : 'a [@bits 64]
      (* CLINT mtime: time/timeh and Sstc; [~s] only ("time" is a Verilog keyword) *)
    ; snoop_valid : 'a (* another core's write, as the bus grants it (#9) *)
    ; snoop_addr : 'a [@bits 32] (* its physical address *)
    ; sc_block : 'a (* another core has a write the bus has not granted yet *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { mem_addr : 'a [@bits 32]
    ; mem_read : 'a
    ; mem_write : 'a
    ; mem_wdata : 'a [@bits 32]
    ; mem_wmask : 'a [@bits 4]
    ; halted : 'a
    ; trap : 'a [@bits 3]
    ; retire : 'a
    ; retire_pc : 'a [@bits 32]
    ; retire_insn : 'a [@bits 32]
    ; retire_rd_we : 'a
    ; retire_rd : 'a [@bits 5]
    ; retire_rd_value : 'a [@bits 32]
    ; retire_mem_we : 'a
    ; retire_mem_addr : 'a [@bits 32]
    ; retire_mem_size : 'a [@bits 2] (* 0: byte, 1: half, 2: word *)
    ; retire_mem_value : 'a [@bits 32]
    ; retire_next_pc : 'a [@bits 32]
    ; retire_trap : 'a (* trap or interrupt entry (Zicsr) *)
    ; retire_cause : 'a [@bits 32] (* its mcause *)
    ; csr_mcycle : 'a [@bits 64] (* the counters, for the lockstep bench *)
    ; csr_minstret : 'a [@bits 64]
    ; fetch : 'a (* in Fetch, where interrupts are taken (bench only) *)
    ; mem_sc : 'a (* the write is an SC (the SoC's arbiter grants it first) *)
    ; mem_lock : 'a (* the read is an AMO's: keep the bus until its write *)
    ; reservation_lost : 'a (* a snooped write ended the reservation (bench) *)
    }
  [@@deriving hardcaml]
end

module Tlb_entry = struct
  type t =
    { valid : Always.Variable.t
    ; tag : Always.Variable.t (* VPN; VPN[1] only for a superpage *)
    ; ppn : Always.Variable.t (* PPN bits 19..0 (32-bit physical addresses) *)
    ; super : Always.Variable.t
    ; perm : Always.Variable.t (* D A U X W R *)
    }
end

module State = struct
  type t =
    | Fetch
    | Decode
    | Read_rs2
    | Execute
    | Shift
    | Load
    | Mul
    | Div
    | Amo
    | Amo_write
    | Mem
    | Ptw_l1
    | Ptw_l1_data
    | Ptw_l1_check
    | Ptw_l0
    | Ptw_l0_data
    | Ptw_l0_check
    | Halted
  [@@deriving sexp_of, compare ~localize, enumerate]
end

let create
  ?(zicsr = false)
  ?(dual_read = false)
  ?(fetch_overlap = false)
  ?m:(ext_m = false)
  ?a:(ext_a = false)
  ?(zifencei = false)
  ?(s = false)
  ?(tlb_entries = 8)
  ?(barrel_shift = false)
  ?(reset_pc = 0)
  ~(base : Rv32_model.Isa.base) scope (i : _ I.t) =
  let zicsr = zicsr || s in
  let reg_bits = Int.ceil_log2 (Rv32_model.Isa.num_regs base) in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = Always.State_machine.create (module State) spec in
  ignore (sm.current -- "state" : Signal.t);
  (* [reset_pc]: where execution starts (0 for the MCUs). *)
  let%hw_var pc =
    Always.Variable.reg
      ~width:32
      (if reset_pc = 0
       then spec
       else Reg_spec.override spec ~clear_to:(Signal.of_int ~width:32 reset_pc))
  in
  let%hw_var ir_reg = Always.Variable.reg ~width:32 spec in
  let%hw_var rs1_value = Always.Variable.reg ~width:32 spec in
  let%hw_var shift_value = Always.Variable.reg ~width:32 spec in
  let%hw_var shift_count = Always.Variable.reg ~width:5 spec in
  let%hw_var load_offset = Always.Variable.reg ~width:2 spec in
  let%hw_var trap = Always.Variable.reg ~width:3 spec in
  let ir = ir_reg.value in
  let%hw rd = ir.:[7 + reg_bits - 1, 7] in
  let%hw funct3 = ir.:[14, 12] in
  let%hw alt = ir.:(30) in
  (* Register file. *)
  let%hw_var rf_we = Always.Variable.wire ~default:gnd in
  let%hw_var rf_wdata = Always.Variable.wire ~default:(zero 32) in
  let rs1_field x = x.:[15 + reg_bits - 1, 15]
  and rs2_field x = x.:[20 + reg_bits - 1, 20] in
  let regfile ~name raddr =
    (Ram.create
       ~name
       ~attributes:[ Rtl_attribute.create "no_rw_check" ]
       ~collision_mode:Read_before_write
       ~size:(Rv32_model.Isa.num_regs base)
       ~write_ports:
         [| { write_clock = i.clock
            ; write_address = rd
            ; write_enable = rf_we.value
            ; write_data = rf_wdata.value
            }
         |]
       ~read_ports:[| { read_clock = i.clock; read_address = raddr; read_enable = vdd } |]
       ()).(0)
  in
  let a, b =
    if dual_read
    then (
      (* Both copies are written together; after Decode their addresses
         come from ir, so the outputs hold through Execute. *)
      let%hw rf_raddr = mux2 (sm.is Decode) (rs1_field i.mem_rdata) (rs1_field ir) in
      let%hw rf_raddr_rs2 = mux2 (sm.is Decode) (rs2_field i.mem_rdata) (rs2_field ir) in
      let%hw rf_rdata = regfile ~name:"regfile" rf_raddr in
      let%hw rf_rdata_rs2 = regfile ~name:"regfile_rs2" rf_raddr_rs2 in
      rf_rdata, rf_rdata_rs2)
    else (
      let%hw rf_raddr = mux2 (sm.is Decode) (rs1_field i.mem_rdata) (rs2_field ir) in
      (* In Read_rs2 the RAM output is rs1; in Execute it is rs2. *)
      let%hw rf_rdata = regfile ~name:"regfile" rf_raddr in
      rs1_value.value, rf_rdata)
  in
  let dec =
    Decode.create ~zicsr ~m:ext_m ~a:ext_a ~zifencei ~s ~base { Decode.I.insn = ir }
    |> Decode.O.Of_signal.apply_names ~prefix:"dec_"
  in
  let%hw imm = (Imm.create { Imm.I.insn = ir }).imm in
  let%hw alu_b = mux2 (dec.op |: dec.branch) b imm in
  let alu =
    Alu.create { Alu.I.a; b = alu_b; funct3; alt = dec.op &: alt }
    |> Alu.O.Of_signal.apply_names ~prefix:"alu_"
  in
  (* One adder for every address: pc-relative (JAL, branches, AUIPC) or
     register-relative (JALR, loads, stores). *)
  let%hw atomic = dec.lr |: dec.sc |: dec.amo in
  let%hw mem_op = dec.load |: dec.store |: atomic in
  (* Atomics address rs1 itself (no immediate). *)
  let%hw agu = mux2 (dec.jalr |: mem_op) a pc.value +: mux2 atomic (zero 32) imm in
  (* With [~s] a load, store or atomic accesses memory in Mem, at the
     address registered at the end of Execute (timing: the adder no longer
     feeds the data TLB in the same cycle). *)
  let%hw_var maddr = Always.Variable.reg ~width:32 spec in
  let%hw daddr = if s then maddr.value else agu in
  let%hw pc_plus4 = pc.value +:. 4 in
  let%hw jump_target =
    mux2 dec.jalr (agu.:[31, 1] @: gnd) agu
  in
  let%hw taken = dec.jal |: dec.jalr |: (dec.branch &: alu.branch_taken) in
  let%hw next_pc = mux2 taken jump_target pc_plus4 in
  let%hw size = funct3.:[1, 0] in
  let%hw misaligned_mem =
    (size ==:. 1 &: agu.:(0)) |: (size ==:. 2 &: (agu.:[1, 0] <>:. 0))
  in
  (* [~barrel_shift] (#4, #23): shifts complete in Execute *)
  let%hw shift_result =
    if barrel_shift
    then (
      let by = (mux2 dec.op b imm).:[4, 0] in
      mux2
        (funct3 ==:. 1)
        (log_shift sll a by)
        (mux2 alt (log_shift sra a by) (log_shift srl a by)))
    else zero 32
  in
  let%hw exec_result =
    mux2
      dec.lui
      imm
      (mux2
         dec.auipc
         agu
         (mux2
            (dec.jal |: dec.jalr)
            pc_plus4
            (if barrel_shift then mux2 dec.shift shift_result alu.result else alu.result)))
  in
  (* Store lanes. *)
  let%hw lane = daddr.:[1, 0] in
  let%hw store_mask =
    mux
      size
      [ binary_to_onehot lane |> Fn.flip uresize 4
      ; mux2 lane.:(1) (of_string "1100") (of_string "0011")
      ; of_string "1111"
      ; of_string "1111"
      ]
  in
  let%hw store_data =
    mux size [ repeat b.:[7, 0] 4; repeat b.:[15, 0] 2; b; b ]
  in
  (* Load extraction. *)
  let%hw loaded =
    let shifted =
      mux load_offset.value (List.init 4 ~f:(fun k -> srl i.mem_rdata (8 * k)))
    in
    let byte = shifted.:[7, 0] and half = shifted.:[15, 0] in
    mux
      funct3
      [ sresize byte 32
      ; sresize half 32
      ; shifted
      ; shifted
      ; uresize byte 32
      ; uresize half 32
      ; shifted
      ; shifted
      ]
  in
  let%hw shifted_once =
    mux2
      (funct3 ==:. 1)
      (sll shift_value.value 1)
      (mux2 alt (sra shift_value.value 1) (srl shift_value.value 1))
  in
  (* Machine-mode CSRs (Zicsr), and the S-mode state ([~s]). Without
     Zicsr no handler can be installed, so none of this logic is reachable
     and synthesis removes it; without [~s] the S-mode registers are never
     read (the [sv] values below are constants). *)
  let%hw_var mstatus_mie = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_mpie = Always.Variable.reg ~width:1 spec in
  (* mie and mip in their CSR layout (bits 1, 3, 5, 7, 9, 11). *)
  let irq_mask = if s then 0xaaa else 0x888 in
  let%hw_var mie = Always.Variable.reg ~width:12 spec in
  let%hw_var mtvec = Always.Variable.reg ~width:32 spec in
  let%hw_var mscratch = Always.Variable.reg ~width:32 spec in
  let%hw_var mepc = Always.Variable.reg ~width:32 spec in
  let%hw_var mcause = Always.Variable.reg ~width:32 spec in
  let%hw_var mtval = Always.Variable.reg ~width:32 spec in
  let%hw_var mcycle = Always.Variable.reg ~width:64 spec in
  let%hw_var minstret = Always.Variable.reg ~width:64 spec in
  let%hw_var retired_pending = Always.Variable.reg ~width:1 spec in
  let%hw_var priv_reg =
    Always.Variable.reg ~width:2 (Reg_spec.override spec ~clear_to:(of_int ~width:2 3))
  in
  let%hw_var mstatus_sie = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_spie = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_spp = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_mpp = Always.Variable.reg ~width:2 spec in
  let%hw_var mstatus_mprv = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_sum = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_mxr = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_tvm = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_tw = Always.Variable.reg ~width:1 spec in
  let%hw_var mstatus_tsr = Always.Variable.reg ~width:1 spec in
  let%hw_var mip_sw = Always.Variable.reg ~width:12 spec in
  let%hw_var medeleg = Always.Variable.reg ~width:16 spec in
  let%hw_var mideleg = Always.Variable.reg ~width:12 spec in
  let%hw_var mcounteren = Always.Variable.reg ~width:3 spec in
  let%hw_var scounteren = Always.Variable.reg ~width:3 spec in
  let%hw_var menvcfg_stce = Always.Variable.reg ~width:1 spec in
  let%hw_var stvec = Always.Variable.reg ~width:32 spec in
  let%hw_var sscratch = Always.Variable.reg ~width:32 spec in
  let%hw_var sepc = Always.Variable.reg ~width:32 spec in
  let%hw_var scause = Always.Variable.reg ~width:32 spec in
  let%hw_var stval = Always.Variable.reg ~width:32 spec in
  let%hw_var satp = Always.Variable.reg ~width:32 spec in
  let%hw_var stimecmp =
    Always.Variable.reg ~width:64 (Reg_spec.override spec ~clear_to:(ones 64))
  in
  (* S-mode state as read: constants without [~s]. *)
  let sv (v : Always.Variable.t) = if s then v.value else zero (width v.value) in
  let%hw priv = if s then priv_reg.value else of_int ~width:2 3 in
  let%hw tvm = sv mstatus_tvm
  and tw = sv mstatus_tw
  and tsr = sv mstatus_tsr
  and sie = sv mstatus_sie
  and stce = sv menvcfg_stce in
  let%hw priv_m = priv ==:. 3
  and priv_s = priv ==:. 1
  and priv_u = priv ==:. 0 in
  let bit_at v idx = mux idx (bits_lsb (uresize v (1 lsl width idx))) in
  (* mip: MSIP, MTIP, MEIP (and SEIP) from the inputs, SSIP/STIP/SEIP as
     written by software, STIP from Sstc. *)
  let spread3 v = v.:(2) @: zero 3 @: v.:(1) @: zero 3 @: v.:(0) @: zero 3 in
  let%hw stip_sstc = if s then stce &: (i.mtime >=: stimecmp.value) else gnd in
  let%hw mip =
    if not zicsr
    then zero 12
    else if not s
    then spread3 i.irq
    else
      spread3 i.irq
      |: (uresize i.seip 3 @: zero 9)
      |: (mip_sw.value &: mux2 stce (of_int ~width:12 0x202) (of_int ~width:12 0x222))
      |: (uresize stip_sstc 7 @: zero 5)
  in
  (* The interrupt to take at this boundary: pending and enabled, enabled
     for its target mode, in the priority order MEI, MSI, MTI, SEI, SSI,
     STI, and only when the target mode's vector is set. *)
  let%hw pend = mip &: mie.value in
  let%hw s_irq_en = priv_u |: (priv_s &: sie) in
  let%hw m_irq_en = ~:priv_m |: mstatus_mie.value in
  let irq_cands =
    List.map [ 11; 3; 7; 9; 1; 5 ] ~f:(fun code ->
      let deleg = if s then (sv mideleg).:(code) else gnd in
      pend.:(code) &: mux2 deleg s_irq_en m_irq_en, code, deleg)
  in
  let%hw irq_valid =
    if zicsr then List.map irq_cands ~f:(fun (c, _, _) -> c) |> reduce ~f:( |: ) else gnd
  in
  let irq_code, irq_deleg =
    List.fold_right
      irq_cands
      ~init:(of_int ~width:5 0, gnd)
      ~f:(fun (c, code, deleg) (code_acc, deleg_acc) ->
        mux2 c (of_int ~width:5 code) code_acc, mux2 c deleg deleg_acc)
  in
  let%hw irq_code = irq_code in
  let%hw irq_deleg = irq_deleg in
  let%hw irq_vec = mux2 irq_deleg (sv stvec) mtvec.value in
  let%hw irq_due = irq_valid &: (irq_vec <>:. 0) in
  let%hw take_irq = irq_due &: sm.is Fetch in
  let csr_addr = ir.:[31, 20] in
  let%hw csr_src = mux2 dec.csr_imm (uresize ir.:[19, 15] 32) a in
  let%hw csr_writes = (funct3.:[1, 0] ==:. 1) |: (ir.:[19, 15] <>:. 0) in
  let csr_read_only = csr_addr.:[11, 10] ==:. 3 in
  let place l =
    List.fold l ~init:(zero 32) ~f:(fun acc (pos, x) -> acc |: sll (uresize x 32) pos)
  in
  let%hw mstatus_value =
    if s
    then
      place
        [ 1, mstatus_sie.value
        ; 3, mstatus_mie.value
        ; 5, mstatus_spie.value
        ; 7, mstatus_mpie.value
        ; 8, mstatus_spp.value
        ; 11, mstatus_mpp.value
        ; 17, mstatus_mprv.value
        ; 18, mstatus_sum.value
        ; 19, mstatus_mxr.value
        ; 20, mstatus_tvm.value
        ; 21, mstatus_tw.value
        ; 22, mstatus_tsr.value
        ]
    else place [ 3, mstatus_mie.value; 7, mstatus_mpie.value ] |: of_int ~width:32 0x1800
  in
  let sstatus_mask = 0x000c_0122 in
  let misa =
    if s
    then (
      let ext c = 1 lsl (Char.to_int c - Char.to_int 'A') in
      (1 lsl 30)
      lor ext (match base with Rv32i -> 'I' | Rv32e -> 'E')
      lor (if ext_m then ext 'M' else 0)
      lor (if ext_a then ext 'A' else 0)
      lor ext 'S'
      lor ext 'U')
    else 0
  in
  let csrs =
    let lo v = v.:[31, 0]
    and hi v = v.:[63, 32] in
    [ 0x300, mstatus_value
    ; 0x304, uresize mie.value 32
    ; 0x305, mtvec.value
    ; 0x340, mscratch.value
    ; 0x341, mepc.value
    ; 0x342, mcause.value
    ; 0x343, mtval.value
    ; 0x344, uresize mip 32
    ; 0xb00, lo mcycle.value
    ; 0xc00, lo mcycle.value
    ; 0xb80, hi mcycle.value
    ; 0xc80, hi mcycle.value
    ; 0xb02, lo minstret.value
    ; 0xc02, lo minstret.value
    ; 0xb82, hi minstret.value
    ; 0xc82, hi minstret.value
    ; 0x301, of_int ~width:32 misa
    ; 0xf11, zero 32
    ; 0xf12, zero 32
    ; 0xf13, zero 32
    ; 0xf14, zero 32
    ]
    @
    if not s
    then []
    else
      [ 0xc01, lo i.mtime
      ; 0xc81, hi i.mtime
      ; 0x302, uresize medeleg.value 32
      ; 0x303, uresize mideleg.value 32
      ; 0x306, uresize mcounteren.value 32
      ; 0x30a, zero 32
      ; 0x31a, uresize menvcfg_stce.value 32 |> Fn.flip sll 31
      ; 0x100, mstatus_value &: of_int ~width:32 sstatus_mask
      ; 0x104, uresize (mie.value &: mideleg.value) 32
      ; 0x144, uresize (mip &: mideleg.value) 32
      ; 0x105, stvec.value
      ; 0x106, uresize scounteren.value 32
      ; 0x10a, zero 32
      ; 0x140, sscratch.value
      ; 0x141, sepc.value
      ; 0x142, scause.value
      ; 0x143, stval.value
      ; 0x180, satp.value
      ; 0x14d, lo stimecmp.value
      ; 0x15d, hi stimecmp.value
      ]
  in
  let csr_hit addr = csr_addr ==:. addr in
  (* PMP (no entries) and debug triggers (none) read zero. *)
  let%hw csr_zero_range =
    if s
    then
      (csr_addr >=:. 0x3a0 &: (csr_addr <=:. 0x3ef))
      |: (csr_addr >=:. 0x7a0 &: (csr_addr <=:. 0x7a5))
    else gnd
  in
  let%hw csr_exists =
    List.map csrs ~f:(fun (addr, _) -> csr_hit addr) |> reduce ~f:( |: ) |: csr_zero_range
  in
  let%hw csr_old =
    List.map csrs ~f:(fun (addr, v) -> repeat (csr_hit addr) 32 &: v) |> reduce ~f:( |: )
  in
  let%hw csr_new =
    mux funct3.:[1, 0] [ csr_old; csr_src; csr_old |: csr_src; csr_old &: ~:csr_src ]
  in
  (* Access below the CSR's privilege, counters not enabled below M, satp
     with TVM and stimecmp without STCE/TM in S. *)
  let%hw csr_denied =
    if not s
    then gnd
    else (
      let counter =
        csr_addr.:[11, 5] ==:. (0xc00 lsr 5) |: (csr_addr.:[11, 5] ==:. (0xc80 lsr 5))
      in
      let cbit v = bit_at v csr_addr.:[4, 0] in
      (csr_addr.:[9, 8] >: priv)
      |: (counter
          &: ~:priv_m
          &: ~:(cbit mcounteren.value &: (priv_s |: cbit scounteren.value)))
      |: (csr_hit 0x180 &: priv_s &: tvm)
      |: ((csr_hit 0x14d |: csr_hit 0x15d)
          &: priv_s
          &: ~:(stce &: mcounteren.value.:(1))))
  in
  let%hw csr_illegal =
    dec.csr &: (~:csr_exists |: csr_denied |: (csr_writes &: csr_read_only))
  in
  (* MRET below M, SRET in U (or S with TSR), SFENCE.VMA in U (or S with
     TVM), WFI in U (or S with TW). *)
  let%hw priv_illegal =
    (dec.mret &: ~:priv_m)
    |: (dec.sret &: (priv_u |: (priv_s &: tsr)))
    |: (dec.sfence_vma &: (priv_u |: (priv_s &: tvm)))
    |: (if s then dec.wfi &: (priv_u |: (priv_s &: tw)) else gnd)
  in
  (* Sv32 (see the header). *)
  let%hw satp_mode = if s then satp.value.:(31) else gnd in
  let%hw data_priv = mux2 (sv mstatus_mprv) mstatus_mpp.value priv in
  let%hw fetch_xlate = satp_mode &: ~:priv_m in
  let%hw data_xlate = satp_mode &: (data_priv <>:. 3) in
  let tlb_bits = Int.ceil_log2 tlb_entries in
  if s && (tlb_entries < 2 || 1 lsl tlb_bits <> tlb_entries)
  then raise_s [%message "tlb_entries must be a power of 2, at least 2" (tlb_entries : int)];
  let make_tlb prefix =
    Array.init (if s then tlb_entries else 0) ~f:(fun k ->
      let r field width =
        let v = Always.Variable.reg ~width spec in
        ignore (v.value -- Printf.sprintf "%s%d_%s" prefix k field : Signal.t);
        v
      in
      { Tlb_entry.valid = r "valid" 1
      ; tag = r "tag" 20
      ; ppn = r "ppn" 20
      ; super = r "super" 1
      ; perm = r "perm" 6
      })
  in
  let itlb = make_tlb "itlb" in
  let dtlb = make_tlb "dtlb" in
  let tlb_index va = va.:[12 + tlb_bits - 1, 12] in
  (* [perm]: D A U X W R (PTE bits 7, 6, 4..1). *)
  let perm_of_pte pte = pte.:(7) @: pte.:(6) @: pte.:[4, 1] in
  let perm_ok ~perm ~is_fetch ~is_store ~eff =
    let r = perm.:(0)
    and w = perm.:(1)
    and x = perm.:(2)
    and u = perm.:(3)
    and a = perm.:(4)
    and d = perm.:(5) in
    let permitted = mux2 is_fetch x (mux2 is_store w (r |: (x &: sv mstatus_mxr))) in
    let user_ok = mux2 (eff ==:. 0) u (~:u |: (~:is_fetch &: sv mstatus_sum)) in
    permitted &: user_ok &: a &: (~:is_store |: d)
  in
  (* Lookup: (usable, physical address). *)
  let lookup tlb va ~is_fetch ~is_store ~eff =
    if not s
    then gnd, va
    else (
      let idx = tlb_index va in
      let sel f = mux idx (Array.to_list tlb |> List.map ~f:(fun e -> (f e : Always.Variable.t).value)) in
      let valid = sel (fun e -> e.Tlb_entry.valid)
      and tag = sel (fun e -> e.tag)
      and ppn = sel (fun e -> e.ppn)
      and super = sel (fun e -> e.super)
      and perm = sel (fun e -> e.perm) in
      let hit = valid &: mux2 super (tag.:[19, 10] ==: va.:[31, 22]) (tag ==: va.:[31, 12]) in
      ( hit &: perm_ok ~perm ~is_fetch ~is_store ~eff
      , mux2 super (ppn.:[19, 10] @: va.:[21, 0]) (ppn @: va.:[11, 0]) ))
  in
  let%hw data_store = dec.store |: dec.sc |: dec.amo in
  let itlb_ok, itlb_pa = lookup itlb pc.value ~is_fetch:vdd ~is_store:gnd ~eff:priv in
  let dtlb_ok, dtlb_pa = lookup dtlb daddr ~is_fetch:gnd ~is_store:data_store ~eff:data_priv in
  let%hw itlb_ok = itlb_ok in
  let%hw dtlb_ok = dtlb_ok in
  let%hw fetch_pa = mux2 fetch_xlate itlb_pa pc.value in
  let%hw data_pa = mux2 data_xlate dtlb_pa daddr in
  let%hw fetch_ready = ~:fetch_xlate |: itlb_ok in
  let%hw data_ready = ~:data_xlate |: dtlb_ok in
  (* The page-table walk: the virtual address and the kind of access
     (0 fetch, 1 load, 2 store/AMO). *)
  let%hw_var walk_va = Always.Variable.reg ~width:32 spec in
  let%hw_var walk_kind = Always.Variable.reg ~width:2 spec in
  let%hw_var walk_pte = Always.Variable.reg ~width:32 spec in
  let%hw walk_fetch = walk_kind.value ==:. 0 in
  let%hw walk_store = walk_kind.value ==:. 2 in
  let%hw walk_eff = mux2 walk_fetch priv data_priv in
  (* the PTE is registered (walk_pte) and checked in the next state *)
  let pte = walk_pte.value in
  let%hw pte_invalid = ~:(pte.:(0)) |: (~:(pte.:(1)) &: pte.:(2)) in
  let%hw pte_leaf = pte.:(1) |: pte.:(3) in
  let%hw pte_perm_ok =
    perm_ok ~perm:(perm_of_pte pte) ~is_fetch:walk_fetch ~is_store:walk_store ~eff:walk_eff
  in
  let%hw ptw_l1_addr = (if s then satp.value.:[19, 0] else zero 20) @: walk_va.value.:[31, 22] @: zero 2 in
  let%hw ptw_l0_addr = walk_pte.value.:[29, 10] @: walk_va.value.:[21, 12] @: zero 2 in
  let%hw walk_cause =
    mux2 walk_fetch (of_int ~width:5 12) (mux2 walk_store (of_int ~width:5 15) (of_int ~width:5 13))
  in
  let tlb_flush =
    Array.to_list itlb @ Array.to_list dtlb
    |> List.map ~f:(fun e -> Always.(e.Tlb_entry.valid <-- gnd))
  in
  let tlb_fill ~super =
    let fill tlb =
      Array.to_list tlb
      |> List.mapi ~f:(fun k e ->
        Always.(
          when_
            (tlb_index walk_va.value ==:. k)
            [ e.Tlb_entry.valid <-- vdd
            ; e.tag <-- walk_va.value.:[31, 12]
            ; e.ppn <-- pte.:[29, 10]
            ; e.super <-- super
            ; e.perm <-- perm_of_pte pte
            ]))
    in
    Always.[ if_ walk_fetch (fill itlb) (fill dtlb) ]
  in
  (* Outputs driven from the state machine. *)
  let%hw_var mem_read = Always.Variable.wire ~default:gnd in
  let%hw_var mem_write = Always.Variable.wire ~default:gnd in
  let%hw_var retire = Always.Variable.wire ~default:gnd in
  let%hw_var retire_next_pc = Always.Variable.wire ~default:pc_plus4 in
  let%hw_var writes_rd = Always.Variable.wire ~default:gnd in
  let%hw_var retire_trap = Always.Variable.wire ~default:gnd in
  let%hw_var retire_cause = Always.Variable.wire ~default:(zero 32) in
  let%hw_var retire_irq = Always.Variable.wire ~default:gnd in
  let%hw_var fetch_fault = Always.Variable.wire ~default:gnd in
  let%hw_var overlapping = Always.Variable.wire ~default:gnd in
  let%hw overlap_ok =
    if fetch_overlap
    then
      ~:(mem_op |: dec.csr |: dec.mret |: dec.sret |: dec.sfence_vma |: irq_due |: dec.mul
         |: dec.div |: fetch_xlate)
    else gnd
  in
  (* M: the product (registered) and the divider. *)
  let%hw_var mul_result = Always.Variable.reg ~width:32 spec in
  let%hw_var div_quot = Always.Variable.reg ~width:32 spec in
  let%hw_var div_rem = Always.Variable.reg ~width:32 spec in
  let%hw_var div_count = Always.Variable.reg ~width:6 spec in
  let%hw_var div_neg_q = Always.Variable.reg ~width:1 spec in
  let%hw_var div_neg_r = Always.Variable.reg ~width:1 spec in
  let%hw product =
    if ext_m
    then (
      let a_signed = funct3 ==:. 1 |: (funct3 ==:. 2) in
      let b_signed = funct3 ==:. 1 in
      let ext s x = mux2 s (msb x) gnd @: x in
      let p = ext a_signed a *+ ext b_signed b in
      mux2 (funct3 ==:. 0) p.:[31, 0] p.:[63, 32])
    else zero 32
  in
  let div_signed = ~:(funct3.:(0)) in
  let abs_if neg x = mux2 neg (negate x) x in
  (* 33 bits: twice a remainder below an unsigned divisor up to 2^32 - 1. *)
  let%hw div_divisor = abs_if (div_signed &: msb b) b in
  let%hw div_step_rem = div_rem.value @: div_quot.value.:(31) in
  let%hw div_step_sub = (gnd @: div_step_rem) -: (zero 2 @: div_divisor) in
  (* A: the reservation and the AMO result. *)
  let%hw_var reservation_valid = Always.Variable.reg ~width:1 spec in
  let%hw_var reservation_addr = Always.Variable.reg ~width:32 spec in
  (* Several cores (#9): the reservation also holds the physical address,
     and another core's write to that word (snooped when the bus grants
     it) ends it. An SC decides only while no other core has an ungranted
     write ([sc_block]), and the SoC grants an SC's write before others, so
     no write can come between the decision and the SC's own write. *)
  let%hw_var reservation_pa = Always.Variable.reg ~width:32 spec in
  let%hw reservation_kill =
    if ext_a
    then
      i.snoop_valid
      &: reservation_valid.value
      &: (i.snoop_addr.:[31, 2] ==: reservation_pa.value.:[31, 2])
    else gnd
  in
  let%hw_var lr_set = Always.Variable.wire ~default:gnd in
  let%hw sc_ok =
    reservation_valid.value &: (reservation_addr.value ==: daddr) &: ~:reservation_kill
  in
  let%hw_var amo_old = Always.Variable.reg ~width:32 spec in
  let%hw amo_new =
    if ext_a
    then (
      let old = amo_old.value in
      let lt_s = old <+ b
      and lt_u = old <: b in
      mux
        ir.:[31, 27]
        (List.init 32 ~f:(fun f5 ->
           match f5 with
           | 0b00001 -> b
           | 0b00000 -> old +: b
           | 0b00100 -> old ^: b
           | 0b01100 -> old &: b
           | 0b01000 -> old |: b
           | 0b10000 -> mux2 lt_s old b
           | 0b10100 -> mux2 lt_s b old
           | 0b11000 -> mux2 lt_u old b
           | 0b11100 -> mux2 lt_u b old
           | _ -> b)))
    else zero 32
  in
  (* Trap entry, to S-mode when [deleg]. [cause] is the full mcause value. *)
  let enter_trap ~cause ~tval ~deleg =
    let cause_bits n = cause.:(31) @: zero (31 - n) @: cause.:[n - 1, 0] in
    Always.
      [ reservation_valid <-- gnd
      ; retire <-- vdd
      ; retire_trap <-- vdd
      ; retire_cause <-- cause
      ; if_
          deleg
          (if s
           then
             [ retire_next_pc <-- stvec.value
             ; sepc <-- pc.value
             ; scause <-- cause_bits 5
             ; stval <-- tval
             ; mstatus_spp <-- priv.:(0)
             ; mstatus_spie <-- mstatus_sie.value
             ; mstatus_sie <-- gnd
             ; priv_reg <--. 1
             ; pc <-- stvec.value
             ]
           else [])
          ([ retire_next_pc <-- mtvec.value
           ; mepc <-- pc.value
           ; mcause <-- cause_bits (if s then 5 else 4)
           ; mtval <-- tval
           ; mstatus_mpie <-- mstatus_mie.value
           ; mstatus_mie <-- gnd
           ; pc <-- mtvec.value
           ]
           @ if s then [ mstatus_mpp <-- priv; priv_reg <--. 3 ] else [])
      ; sm.set_next Fetch
      ]
  in
  (* A synchronous trap with exception code [cause] (5 bits): enter the
     handler (S-mode if delegated) if its vector is set, else halt. *)
  let halt ~cause ?(tval = zero 32) code =
    let deleg = if s then ~:priv_m &: bit_at (sv medeleg) cause else gnd in
    let vec = mux2 deleg (sv stvec) mtvec.value in
    Always.
      [ if_
          (if zicsr then vec <>:. 0 else gnd)
          (enter_trap ~cause:(uresize cause 32) ~tval ~deleg)
          [ trap <--. code; sm.set_next Halted ]
      ]
  in
  let code n = of_int ~width:5 n in
  let csr_write () =
    let w addr stmts = Always.when_ (csr_hit addr) stmts in
    let v = csr_new in
    let set_mstatus ~mask =
      let m n = mask land (1 lsl n) <> 0 in
      let b n (r : Always.Variable.t) = if m n then [ Always.(r <-- v.:(n)) ] else [] in
      List.concat
        [ b 1 mstatus_sie
        ; b 3 mstatus_mie
        ; b 5 mstatus_spie
        ; b 7 mstatus_mpie
        ; b 8 mstatus_spp
        ; (if m 11
           then [ Always.(when_ (v.:[12, 11] <>:. 2) [ mstatus_mpp <-- v.:[12, 11] ]) ]
           else [])
        ; b 17 mstatus_mprv
        ; b 18 mstatus_sum
        ; b 19 mstatus_mxr
        ; b 20 mstatus_tvm
        ; b 21 mstatus_tw
        ; b 22 mstatus_tsr
        ]
    in
    let c12 n = of_int ~width:12 n in
    Always.(
      [ w 0x300 (set_mstatus ~mask:(if s then 0x007e_19aa else 0x88))
      ; w 0x304 [ mie <-- (v.:[11, 0] &: c12 irq_mask) ]
      ; w 0x305 [ mtvec <-- v.:[31, 2] @: zero 2 ]
      ; w 0x340 [ mscratch <-- v ]
      ; w 0x341 [ mepc <-- v.:[31, 2] @: zero 2 ]
      ; w
          0x342
          [ mcause
            <-- (if s
                 then v.:(31) @: zero 26 @: v.:[4, 0]
                 else v.:(31) @: zero 27 @: v.:[3, 0])
          ]
      ; w 0x343 [ mtval <-- v ]
      ]
      @
      if not s
      then []
      else
        [ w 0x344 [ mip_sw <-- (v.:[11, 0] &: c12 0x222) ]
        ; w 0x302 [ medeleg <-- (v.:[15, 0] &: of_int ~width:16 0xb3ff) ]
        ; w 0x303 [ mideleg <-- (v.:[11, 0] &: c12 0x222) ]
        ; w 0x306 [ mcounteren <-- v.:[2, 0] ]
        ; w 0x31a [ menvcfg_stce <-- v.:(31) ]
        ; w 0x100 (set_mstatus ~mask:sstatus_mask)
        ; w
            0x104
            [ mie <-- (mie.value &: ~:(mideleg.value) |: (v.:[11, 0] &: mideleg.value)) ]
        ; w
            0x144
            [ mip_sw
              <-- (mip_sw.value &: c12 (lnot 2 land 0xfff)
                   |: (v.:[11, 0] &: mideleg.value &: c12 2))
            ]
        ; w 0x105 [ stvec <-- v.:[31, 2] @: zero 2 ]
        ; w 0x106 [ scounteren <-- v.:[2, 0] ]
        ; w 0x140 [ sscratch <-- v ]
        ; w 0x141 [ sepc <-- v.:[31, 2] @: zero 2 ]
        ; w 0x142 [ scause <-- v.:(31) @: zero 26 @: v.:[4, 0] ]
        ; w 0x143 [ stval <-- v ]
        ; w 0x180 ((satp <-- (v &: of_int ~width:32 0x803f_ffff)) :: tlb_flush)
        ; (* Counter writes (S only, as Linux-class software expects them
             writable): the written value is what the next instruction
             reads, so they override this cycle's increment. *)
          w 0xb00 [ mcycle <-- mcycle.value.:[63, 32] @: v ]
        ; w 0xb80 [ mcycle <-- v @: mcycle.value.:[31, 0] ]
        ; (* the writing instruction does not count (its delayed increment
             is dropped) *)
          w 0xb02 [ minstret <-- minstret.value.:[63, 32] @: v; retired_pending <-- gnd ]
        ; w 0xb82 [ minstret <-- v @: minstret.value.:[31, 0]; retired_pending <-- gnd ]
        ; w 0x14d [ stimecmp <-- stimecmp.value.:[63, 32] @: v ]
        ; w 0x15d [ stimecmp <-- v @: stimecmp.value.:[31, 0] ]
        ])
  in
  let complete ~result ~next =
    Always.
      [ retire <-- vdd
      ; retire_next_pc <-- next
      ; rf_wdata <-- result
      ; rf_we <-- (writes_rd.value &: (rd <>:. 0))
      ; pc <-- next
      ; sm.set_next Fetch
      ]
  in
  (* After a walk: retry the access (Fetch, or Execute for data), or
     raise the page fault. A fetch fault retires with instruction 0, as in
     the model. *)
  let walk_retry = Always.[ if_ walk_fetch [ sm.set_next Fetch ] [ sm.set_next Mem ] ] in
  let walk_fault =
    Always.(
      (fetch_fault <-- walk_fetch)
      :: halt ~cause:walk_cause ~tval:walk_va.value Trap.page_fault)
  in
  (* A load, store or atomic at [daddr]: in Execute without [~s], in Mem
     with it. A TLB miss (or a hit that would fault) walks the table first. *)
  let mem_path =
    Always.
      [ if_
          ~:data_ready
          [ walk_va <-- daddr
          ; walk_kind <-- mux2 data_store (of_int ~width:2 2) (of_int ~width:2 1)
          ; sm.set_next Ptw_l1
          ]
          [ if_
              (dec.load |: dec.lr)
              [ mem_read <-- vdd
              ; load_offset <-- lane
              ; when_
                  dec.lr
                  [ reservation_valid <-- vdd
                  ; reservation_addr <-- daddr
                  ; reservation_pa <-- data_pa
                  ; lr_set <-- vdd
                  ]
              ; sm.set_next Load
              ]
              [ if_
                  (dec.sc &: i.sc_block)
                  [ (* wait until the other cores' writes are granted *) ]
                  [ when_ (dec.store |: (dec.sc &: sc_ok)) [ mem_write <-- vdd ]
                  ; when_ dec.sc [ reservation_valid <-- gnd ]
                  ; if_
                      dec.amo
                      [ mem_read <-- vdd; sm.set_next Amo ]
                      (complete ~result:(uresize ~:sc_ok 32) ~next:pc_plus4)
                  ]
              ]
          ]
      ]
  in
  Always.(
    compile
      [ when_ reservation_kill [ reservation_valid <-- gnd ]
      ; (if zicsr
         then
           proc
             [ mcycle <-- mcycle.value +:. 1
             ; (* the increment is applied one cycle after the retirement
                  (timing: the retire decision no longer feeds a 64-bit
                  carry chain). The next instruction reads minstret in its
                  Execute, at least two cycles later, so no CSR read can
                  see the difference; a counter write in the same cycle
                  wins, as before. *)
               retired_pending <-- (retire.value &: ~:(retire_trap.value))
             ; minstret <-- minstret.value +: uresize retired_pending.value 64
             ]
         else proc [ mcycle <--. 0; minstret <--. 0 ])
      ; sm.switch
          [ ( Fetch
            , [ if_
                  take_irq
                  ((retire_irq <-- vdd)
                   :: enter_trap
                        ~cause:(vdd @: zero 26 @: irq_code)
                        ~tval:(zero 32)
                        ~deleg:irq_deleg)
                  [ if_
                      fetch_ready
                      [ mem_read <-- vdd; when_ i.mem_ready [ sm.set_next Decode ] ]
                      [ walk_va <-- pc.value; walk_kind <--. 0; sm.set_next Ptw_l1 ]
                  ]
              ] )
          ; ( Decode
            , [ when_
                  i.mem_rvalid
                  [ ir_reg <-- i.mem_rdata
                  ; sm.set_next (if dual_read then Execute else Read_rs2)
                  ]
              ] )
          ; Read_rs2, [ rs1_value <-- b; sm.set_next Execute ]
          ; ( Execute
            , [ writes_rd
                <-- (dec.lui |: dec.auipc |: dec.jal |: dec.jalr |: dec.load |: dec.op_imm
                     |: dec.op |: dec.csr |: dec.mul |: dec.div |: atomic)
              ; if_
                  (dec.illegal |: csr_illegal |: priv_illegal)
                  (halt ~cause:(code 2) ~tval:ir Trap.illegal)
                  [ if_
                      dec.ecall
                      (halt ~cause:(code 8 +: uresize priv 5) Trap.ecall)
                      [ if_
                          dec.ebreak
                          (halt ~cause:(code 3) Trap.ebreak)
                          [ if_
                              (taken &: next_pc.:(1))
                              (halt ~cause:(code 0) ~tval:next_pc Trap.misaligned_fetch)
                              [ if_
                                  (mem_op &: misaligned_mem)
                                  [ if_
                                      (dec.store |: dec.sc |: dec.amo)
                                      (halt ~cause:(code 6) ~tval:agu Trap.misaligned_access)
                                      (halt ~cause:(code 4) ~tval:agu Trap.misaligned_access)
                                  ]
                                  [ if_
                                      mem_op
                                      (if s
                                       then [ maddr <-- agu; sm.set_next Mem ]
                                       else mem_path)
                                      [ if_
                                          (if barrel_shift then gnd else dec.shift)
                                          [ shift_value <-- a
                                          ; shift_count
                                            <-- (mux2 dec.op b imm).:[4, 0]
                                          ; sm.set_next Shift
                                          ]
                                          [ when_
                                              dec.mret
                                              ([ mstatus_mie <-- mstatus_mpie.value
                                               ; mstatus_mpie <-- vdd
                                               ]
                                               @
                                               if s
                                               then
                                                 [ priv_reg <-- mstatus_mpp.value
                                                 ; when_
                                                     (mstatus_mpp.value <>:. 3)
                                                     [ mstatus_mprv <-- gnd ]
                                                 ; mstatus_mpp <--. 0
                                                 ]
                                               else [])
                                          ; when_
                                              dec.sret
                                              (if s
                                               then
                                                 [ priv_reg <-- gnd @: mstatus_spp.value
                                                 ; mstatus_sie <-- mstatus_spie.value
                                                 ; mstatus_spie <-- vdd
                                                 ; mstatus_spp <-- gnd
                                                 ; mstatus_mprv <-- gnd
                                                 ]
                                               else [])
                                          ; when_ (dec.csr &: csr_writes) (csr_write ())
                                          ; when_ dec.sfence_vma tlb_flush
                                          ; proc
                                              (complete
                                                 ~result:(mux2 dec.csr csr_old exec_result)
                                                 ~next:
                                                   (mux2
                                                      dec.mret
                                                      mepc.value
                                                      (mux2 dec.sret (sv sepc) next_pc)))
                                          ; when_
                                              overlap_ok
                                              [ mem_read <-- vdd
                                              ; (* not accepted: withdraw, fetch
                                                   again from Fetch *)
                                                when_
                                                  i.mem_ready
                                                  [ overlapping <-- vdd; sm.set_next Decode ]
                                              ]
                                          ; (* Multi-cycle M instructions do not
                                               complete here: undo the completion
                                               and go to their state. *)
                                            when_
                                              (dec.mul |: dec.div)
                                              [ retire <-- gnd
                                              ; rf_we <-- gnd
                                              ; pc <-- pc.value
                                              ; sm.set_next Fetch
                                              ]
                                          ; when_
                                              dec.mul
                                              [ mul_result <-- product; sm.set_next Mul ]
                                          ; when_
                                              dec.div
                                              [ div_quot <-- abs_if (div_signed &: msb a) a
                                              ; div_rem <--. 0
                                              ; div_count <--. 32
                                              ; div_neg_q
                                                <-- (div_signed &: (msb a ^: msb b) &: (b <>:. 0))
                                              ; div_neg_r <-- (div_signed &: msb a)
                                              ; sm.set_next Div
                                              ]
                                          ]
                                      ]
                                  ]
                              ]
                          ]
                      ]
                  ]
              ] )
          ; Mem, (writes_rd <-- (dec.load |: atomic)) :: mem_path
          ; ( Shift
            , [ writes_rd <-- vdd
              ; if_
                  (shift_count.value ==:. 0)
                  (complete ~result:shift_value.value ~next:pc_plus4)
                  [ shift_value <-- shifted_once
                  ; shift_count <-- shift_count.value -:. 1
                  ]
              ] )
          ; ( Load
            , [ writes_rd <-- vdd; when_ i.mem_rvalid (complete ~result:loaded ~next:pc_plus4) ]
            )
          ; ( Mul
            , [ writes_rd <-- vdd; proc (complete ~result:mul_result.value ~next:pc_plus4) ] )
          ; ( Div
            , [ writes_rd <-- vdd
              ; if_
                  (div_count.value ==:. 0)
                  (complete
                     ~result:
                       (mux2
                          funct3.:(1)
                          (abs_if div_neg_r.value div_rem.value)
                          (abs_if div_neg_q.value div_quot.value))
                     ~next:pc_plus4)
                  [ div_count <-- div_count.value -:. 1
                  ; if_
                      (msb div_step_sub)
                      [ div_rem <-- div_step_rem.:[31, 0]
                      ; div_quot <-- div_quot.value.:[30, 0] @: gnd
                      ]
                      [ div_rem <-- div_step_sub.:[31, 0]
                      ; div_quot <-- div_quot.value.:[30, 0] @: vdd
                      ]
                  ]
              ] )
          ; ( Amo
            , [ when_ i.mem_rvalid [ amo_old <-- i.mem_rdata; sm.set_next Amo_write ] ] )
          ; ( Amo_write
            , [ writes_rd <-- vdd
              ; mem_write <-- vdd
              ; when_ i.mem_ready (complete ~result:amo_old.value ~next:pc_plus4)
              ] )
          ; Ptw_l1, [ mem_read <-- vdd; when_ i.mem_ready [ sm.set_next Ptw_l1_data ] ]
          ; ( Ptw_l1_data
            , [ when_ i.mem_rvalid [ walk_pte <-- i.mem_rdata; sm.set_next Ptw_l1_check ] ] )
          ; ( Ptw_l1_check
            , [ if_
                  (pte_invalid
                   |: (pte_leaf &: (pte.:[19, 10] <>:. 0))
                   |: (pte_leaf &: ~:pte_perm_ok))
                  walk_fault
                  [ if_ pte_leaf (tlb_fill ~super:vdd @ walk_retry) [ sm.set_next Ptw_l0 ] ]
              ] )
          ; Ptw_l0, [ mem_read <-- vdd; when_ i.mem_ready [ sm.set_next Ptw_l0_data ] ]
          ; ( Ptw_l0_data
            , [ when_ i.mem_rvalid [ walk_pte <-- i.mem_rdata; sm.set_next Ptw_l0_check ] ] )
          ; ( Ptw_l0_check
            , [ if_
                  (pte_invalid |: ~:pte_leaf |: ~:pte_perm_ok)
                  walk_fault
                  (tlb_fill ~super:gnd @ walk_retry)
              ] )
          ; Halted, []
          ]
      ; (* A load, store or atomic that Execute issues and the memory does
           not accept: nothing happens, Execute repeats with the request
           held. (The overlapped fetch withdraws instead, above.) *)
        when_
          ((sm.is Execute |: sm.is Mem)
           &: (mem_write.value |: (mem_read.value &: mem_op))
           &: ~:(i.mem_ready))
          [ retire <-- gnd
          ; rf_we <-- gnd
          ; pc <-- pc.value
          ; reservation_valid <-- (reservation_valid.value &: ~:reservation_kill)
          ; reservation_addr <-- reservation_addr.value
          ; reservation_pa <-- reservation_pa.value
          ; sm.set_next Execute
          ]
      ]);
  let%hw mem_addr =
    if s
    then
      mux2
        (sm.is Fetch)
        fetch_pa
        (mux2
           (sm.is Ptw_l1)
           ptw_l1_addr
           (mux2
              (sm.is Ptw_l0)
              ptw_l0_addr
              (if fetch_overlap then mux2 (sm.is Execute) next_pc data_pa else data_pa)))
    else
      mux2
        (sm.is Fetch)
        pc.value
        (if fetch_overlap then mux2 mem_op agu next_pc else agu)
  in
  { O.mem_addr
  ; mem_read = mem_read.value
  ; mem_write = mem_write.value
  ; mem_wdata = mux2 (sm.is Amo_write) amo_new store_data
  ; mem_wmask = store_mask
  ; halted = sm.is Halted
  ; trap = trap.value
  ; retire = retire.value
  ; retire_pc = pc.value
  ; retire_insn = mux2 (retire_irq.value |: fetch_fault.value) (zero 32) ir
  ; retire_rd_we = rf_we.value
  ; retire_rd = uresize rd 5
  ; retire_rd_value = rf_wdata.value
  ; retire_mem_we = mem_write.value
  ; retire_mem_addr = daddr
  ; retire_mem_size = size
  ; retire_mem_value = mux2 (sm.is Amo_write) amo_new b
  ; retire_next_pc = retire_next_pc.value
  ; retire_trap = retire_trap.value
  ; retire_cause = retire_cause.value
  ; csr_mcycle = mcycle.value
  ; csr_minstret = minstret.value
  ; fetch = sm.is Fetch |: overlapping.value
  ; mem_sc = mem_write.value &: dec.sc &: (sm.is Execute |: sm.is Mem)
  ; mem_lock = mem_read.value &: dec.amo &: (sm.is Execute |: sm.is Mem)
  ; reservation_lost = reservation_kill &: ~:(lr_set.value)
  }
;;

let hierarchical
  ?zicsr
  ?dual_read
  ?fetch_overlap
  ?m
  ?a
  ?zifencei
  ?s
  ?tlb_entries
  ?barrel_shift
  ?reset_pc
  ~base
  scope
  =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ~scope
    ~name:"rv32_core"
    (create
       ?zicsr
       ?dual_read
       ?fetch_overlap
       ?m
       ?a
       ?zifencei
       ?s
       ?tlb_entries
       ?barrel_shift
       ?reset_pc
       ~base)
;;
