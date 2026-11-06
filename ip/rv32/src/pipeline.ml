(* A pipelined RV32I core with M, A, Zifencei and the machine-mode Zicsr of
   Core (issue #4): four in-order stages,

     IF  fetch through the instruction port (one request per cycle when
         the memory allows: a new request may go out in the cycle the
         previous one's data arrives); a two-entry queue decouples it
     ID  decode, read the register file (asynchronous, distributed RAM),
         bypassing the value the commit stage writes in this cycle
     EX  ALU, shifts (barrel), branch and jump resolution (predicted not
         taken: a taken one redirects fetch, 2 bubbles), address
         generation, multiply (one extra cycle) and divide (32 cycles);
         operands bypass the commit stage's result
     C   commit: the only stage with architectural side effects: data
         memory (loads, stores, LR/SC, AMOs through the data port), CSRs,
         MRET, traps and interrupts, the register write and the retire
         outputs

   Everything that changes the instruction stream other than branches and
   jumps (traps, interrupts, MRET, FENCE.I) is handled in C, which then
   flushes the younger stages and redirects fetch. Interrupts are taken in
   C before an instruction starts there: the trap entry replaces it and it
   is fetched again after the handler. The [core.fetch] output marks those
   decision cycles (the lockstep bench samples irq there).

   Machine-mode CSRs, traps and halting (no handler: mtvec = 0) follow
   Core without [~s]: writes to the counters are ignored, mcause keeps bit
   31 and bits 3..0.

   Ports: [core.mem_*] is the data port and [imem_*] the instruction port,
   both with Core's request/ready, rvalid protocol (#26). *)
open! Base
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; mem_rdata : 'a [@bits 32]
    ; mem_ready : 'a
    ; mem_rvalid : 'a
    ; imem_rdata : 'a [@bits 32]
    ; imem_ready : 'a
    ; imem_rvalid : 'a
    ; irq : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { core : 'a Core.O.t [@rtlprefix "core_"]
    ; imem_addr : 'a [@bits 32]
    ; imem_read : 'a
    }
  [@@deriving hardcaml]
end

let create ?(reset_pc = 0) ~base scope (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let reg_bits = Int.ceil_log2 (Rv32_model.Isa.num_regs base) in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let r ?(clear_to = 0) name w =
    let spec = Reg_spec.override spec ~clear_to:(of_int ~width:w clear_to) in
    let (v : Always.Variable.t) = Always.Variable.reg ~width:w spec in
    ignore (v.value -- name : Signal.t);
    v
  in
  let w name ~default =
    let (v : Always.Variable.t) = Always.Variable.wire ~default in
    ignore (v.value -- name : Signal.t);
    v
  in
  let decode insn =
    Decode.create ~zicsr:true ~m:true ~a:true ~zifencei:true ~base { Decode.I.insn }
  in
  (* ---------------------------------------------------------------- *)
  (* Pipeline registers *)
  let halted = r "halted" 1 in
  let trap_code = r "trap_code" 3 in
  let pc_f = r ~clear_to:reset_pc "pc_f" 32 in
  let inflight = r "f_inflight" 1 in
  let inflight_pc = r "f_inflight_pc" 32 in
  (* the outstanding fetch belongs to a path a redirect has left: its data
     is dropped (one request at a time, so one flag) *)
  let inflight_stale = r "f_inflight_stale" 1 in
  (* fetch queue: two entries *)
  let q0_valid = r "q0_valid" 1
  and q0_pc = r "q0_pc" 32
  and q0_insn = r "q0_insn" 32
  and q1_valid = r "q1_valid" 1
  and q1_pc = r "q1_pc" 32
  and q1_insn = r "q1_insn" 32 in
  (* EX *)
  let ex_valid = r "ex_valid" 1
  and ex_pc = r "ex_pc" 32
  and ex_insn = r "ex_insn" 32
  and ex_a = r "ex_a" 32
  and ex_b = r "ex_b" 32
  and ex_busy = r "ex_busy" 1 (* multi-cycle M operation in progress *)
  and mul_result = r "mul_result" 32
  and div_quot = r "div_quot" 32
  and div_rem = r "div_rem" 32
  and div_count = r "div_count" 6
  and div_neg_q = r "div_neg_q" 1
  and div_neg_r = r "div_neg_r" 1 in
  (* C *)
  let c_valid = r "c_valid" 1
  and c_pc = r "c_pc" 32
  and c_insn = r "c_insn" 32
  and c_result = r "c_result" 32 (* ALU, link, LUI/AUIPC, M result *)
  and c_addr = r "c_addr" 32 (* data address *)
  and c_store = r "c_store" 32 (* rs2 *)
  and c_src = r "c_src" 32 (* CSR source (rs1 or zimm) *)
  and c_next = r "c_next" 32 (* the next pc *)
  and c_trap = r "c_trap" 1
  and c_cause = r "c_cause" 4
  and c_tval = r "c_tval" 32
  and c_step = r "c_step" 2 (* 0: not started, 1: read issued, 2: AMO write *)
  and c_amo_old = r "c_amo_old" 32 in
  (* CSRs *)
  let mstatus_mie = r "mstatus_mie" 1
  and mstatus_mpie = r "mstatus_mpie" 1
  and mie = r "mie" 12
  and mtvec = r "mtvec" 32
  and mscratch = r "mscratch" 32
  and mepc = r "mepc" 32
  and mcause = r "mcause" 32
  and mtval = r "mtval" 32
  and mcycle = r "mcycle" 64
  and minstret = r "minstret" 64
  and reservation_valid = r "reservation_valid" 1
  and reservation_addr = r "reservation_addr" 32 in
  (* Combinational controls, set by the stages below *)
  let flush = w "flush" ~default:gnd (* C: drop EX, ID, fetch *)
  and flush_target = w "flush_target" ~default:(zero 32)
  and redirect = w "redirect" ~default:gnd (* EX: drop ID and fetch *)
  and redirect_target = w "redirect_target" ~default:(zero 32)
  and c_done = w "c_done" ~default:gnd (* C is empty or finishes now *)
  and rf_we = w "rf_we" ~default:gnd
  and rf_wdata = w "rf_wdata" ~default:(zero 32)
  and retire = w "retire" ~default:gnd
  and retire_trap = w "retire_trap" ~default:gnd
  and retire_irq = w "retire_irq" ~default:gnd
  and retire_cause = w "retire_cause" ~default:(zero 32)
  and retire_next = w "retire_next" ~default:(zero 32)
  and retire_mem_we = w "retire_mem_we" ~default:gnd
  and retire_mem_value = w "retire_mem_value" ~default:(zero 32)
  and dmem_read = w "dmem_read" ~default:gnd
  and dmem_write = w "dmem_write" ~default:gnd
  and dmem_wdata = w "dmem_wdata" ~default:(zero 32)
  and decision = w "decision" ~default:gnd in
  (* ---------------------------------------------------------------- *)
  (* C: decode and data *)
  let cd = decode c_insn.value in
  let c_rd = c_insn.value.:[7 + reg_bits - 1, 7] in
  let c_funct3 = c_insn.value.:[14, 12] in
  let c_size = c_funct3.:[1, 0] in
  let c_atomic = cd.lr |: cd.sc |: cd.amo in
  let c_writes_rd =
    cd.lui |: cd.auipc |: cd.jal |: cd.jalr |: cd.load |: cd.op_imm |: cd.op |: cd.csr |: cd.mul
    |: cd.div |: c_atomic
  in
  let lane = c_addr.value.:[1, 0] in
  let store_mask =
    mux
      c_size
      [ binary_to_onehot lane |> Fn.flip uresize 4
      ; mux2 lane.:(1) (of_string "1100") (of_string "0011")
      ; of_string "1111"
      ; of_string "1111"
      ]
  in
  let store_data =
    let b = c_store.value in
    mux c_size [ repeat b.:[7, 0] 4; repeat b.:[15, 0] 2; b; b ]
  in
  let loaded =
    let shifted = mux lane (List.init 4 ~f:(fun k -> srl i.mem_rdata (8 * k))) in
    let byte = shifted.:[7, 0]
    and half = shifted.:[15, 0] in
    mux
      c_funct3
      [ sresize byte 32
      ; sresize half 32
      ; shifted
      ; shifted
      ; uresize byte 32
      ; uresize half 32
      ; shifted
      ; shifted
      ]
    -- "c_loaded"
  in
  (* CSRs (as Core without S) *)
  let csr_addr = c_insn.value.:[31, 20] in
  let csr_hit a = csr_addr ==:. a in
  let spread3 v = v.:(2) @: zero 3 @: v.:(1) @: zero 3 @: v.:(0) @: zero 3 in
  let mip = spread3 i.irq in
  let lo v = v.:[31, 0]
  and hi v = v.:[63, 32] in
  let csrs =
    [ ( 0x300
      , uresize (mstatus_mpie.value @: zero 3 @: mstatus_mie.value @: zero 3) 32
        |: of_int ~width:32 0x1800 )
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
    ; 0x301, zero 32
    ; 0xf11, zero 32
    ; 0xf12, zero 32
    ; 0xf13, zero 32
    ; 0xf14, zero 32
    ]
  in
  let csr_exists = List.map csrs ~f:(fun (a, _) -> csr_hit a) |> reduce ~f:( |: ) in
  let csr_old =
    (List.map csrs ~f:(fun (a, v) -> repeat (csr_hit a) 32 &: v) |> reduce ~f:( |: ))
    -- "csr_old"
  in
  let csr_src = c_src.value in
  let csr_writes = (c_funct3.:[1, 0] ==:. 1) |: (c_insn.value.:[19, 15] <>:. 0) in
  let csr_new =
    mux c_funct3.:[1, 0] [ csr_old; csr_src; csr_old |: csr_src; csr_old &: ~:csr_src ]
  in
  let csr_illegal =
    cd.csr &: (~:csr_exists |: (csr_writes &: (csr_addr.:[11, 10] ==:. 3)))
  in
  let sc_ok = reservation_valid.value &: (reservation_addr.value ==: c_addr.value) in
  let amo_new =
    let old = c_amo_old.value
    and b = c_store.value in
    let lt_s = old <+ b
    and lt_u = old <: b in
    mux
      c_insn.value.:[31, 27]
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
         | _ -> b))
  in
  let irq_pending = i.irq &: (mie.value.:(11) @: mie.value.:(7) @: mie.value.:(3)) in
  let irq_due =
    (mtvec.value <>:. 0) &: mstatus_mie.value &: (irq_pending <>:. 0) -- "irq_due"
  in
  let irq_code =
    mux2
      irq_pending.:(2)
      (of_int ~width:4 11)
      (mux2 irq_pending.:(0) (of_int ~width:4 3) (of_int ~width:4 7))
  in
  (* the value C writes to rd when it finishes now *)
  let c_wb_nonload =
    mux2 cd.csr csr_old (mux2 cd.sc (uresize ~:sc_ok 32) c_result.value) -- "c_wb_nonload"
  in
  let c_wb_value =
    mux2 (cd.load |: cd.lr) loaded (mux2 cd.amo c_amo_old.value c_wb_nonload) -- "c_wb_value"
  in
  (* ---------------------------------------------------------------- *)
  (* EX *)
  let xd = decode ex_insn.value in
  let rs1_of x = x.:[15 + reg_bits - 1, 15]
  and rs2_of x = x.:[20 + reg_bits - 1, 20]
  and rd_of x = x.:[7 + reg_bits - 1, 7] in
  let bypass_c ~rs v =
    mux2
      (rf_we.value &: (c_rd ==: rs) &: (rs <>:. 0))
      rf_wdata.value
      v
  in
  (* Operands: C's result is forwarded to the ALU, except a value C loads
     from memory (timing: RAM output -> ALU -> branch -> fetch address was
     the critical path); that one only goes into ex_a/ex_b, and EX waits a
     cycle for it (a load-use bubble). *)
  let c_loads = cd.load |: cd.lr |: cd.amo in
  let ex_dep =
    c_valid.value
    &: c_writes_rd
    &: (c_rd <>:. 0)
    &: (c_rd ==: rs1_of ex_insn.value |: (c_rd ==: rs2_of ex_insn.value))
  in
  let a_next = bypass_c ~rs:(rs1_of ex_insn.value) ex_a.value -- "ex_a_next" in
  let b_next = bypass_c ~rs:(rs2_of ex_insn.value) ex_b.value -- "ex_b_next" in
  let bypass_alu ~rs v =
    mux2
      (rf_we.value &: ~:c_loads &: (c_rd ==: rs) &: (rs <>:. 0))
      c_wb_nonload
      v
  in
  let a = bypass_alu ~rs:(rs1_of ex_insn.value) ex_a.value -- "ex_a_fwd" in
  let b = bypass_alu ~rs:(rs2_of ex_insn.value) ex_b.value -- "ex_b_fwd" in
  (* EX needs C's result and does not have it in [a]/[b] this cycle *)
  let ex_needs_c = ex_dep &: (~:(c_done.value) |: c_loads) -- "ex_needs_c" in
  let x_funct3 = ex_insn.value.:[14, 12] in
  let x_alt = ex_insn.value.:(30) in
  let x_imm = (Imm.create { Imm.I.insn = ex_insn.value }).imm in
  let alu =
    Alu.create
      { Alu.I.a; b = mux2 (xd.op |: xd.branch) b x_imm; funct3 = x_funct3; alt = xd.op &: x_alt }
  in
  let x_atomic = xd.lr |: xd.sc |: xd.amo in
  let x_mem = xd.load |: xd.store |: x_atomic in
  let agu = mux2 (xd.jalr |: x_mem) a ex_pc.value +: mux2 x_atomic (zero 32) x_imm -- "agu" in
  let x_plus4 = ex_pc.value +:. 4 in
  let x_target = mux2 xd.jalr (agu.:[31, 1] @: gnd) agu in
  let x_taken = xd.jal |: xd.jalr |: (xd.branch &: alu.branch_taken) in
  let x_next = mux2 x_taken x_target x_plus4 -- "ex_next" in
  let shamt = (mux2 xd.op b x_imm).:[4, 0] in
  let shift_result =
    mux2
      (x_funct3 ==:. 1)
      (log_shift sll a shamt)
      (mux2 x_alt (log_shift sra a shamt) (log_shift srl a shamt))
  in
  let x_result =
    mux2
      xd.lui
      x_imm
      (mux2
         xd.auipc
         agu
         (mux2 (xd.jal |: xd.jalr) x_plus4 (mux2 xd.shift shift_result alu.result)))
  in
  let x_size = x_funct3.:[1, 0] in
  let x_misaligned_mem =
    x_mem &: ((x_size ==:. 1 &: agu.:(0)) |: (x_size ==:. 2 &: (agu.:[1, 0] <>:. 0)))
  in
  let x_misaligned_target = x_taken &: x_next.:(1) in
  (* M *)
  let product =
    let a_signed = x_funct3 ==:. 1 |: (x_funct3 ==:. 2) in
    let b_signed = x_funct3 ==:. 1 in
    let ext s x = mux2 s (msb x) gnd @: x in
    (* from the operand registers, not the forwarded values (timing: C ->
       forward -> MULT18X18D was the critical path); a multiplication or
       division waits while C writes one of its sources *)
    let p = ext a_signed ex_a.value *+ ext b_signed ex_b.value in
    mux2 (x_funct3 ==:. 0) p.:[31, 0] p.:[63, 32]
  in
  let div_signed = ~:(x_funct3.:(0)) in
  let abs_if neg x = mux2 neg (negate x) x in
  let div_divisor = abs_if (div_signed &: msb ex_b.value) ex_b.value in
  let div_step_rem = div_rem.value @: div_quot.value.:(31) in
  let div_step_sub = (gnd @: div_step_rem) -: (zero 2 @: div_divisor) in
  let div_result =
    mux2
      x_funct3.:(1)
      (abs_if div_neg_r.value div_rem.value)
      (abs_if div_neg_q.value div_quot.value)
  in
  (* EX is ready to hand its instruction to C *)
  let ex_finished =
    mux2
      xd.mul
      ex_busy.value
      (mux2 xd.div (ex_busy.value &: (div_count.value ==:. 0)) vdd)
  in
  let c_free = ~:(c_valid.value) |: c_done.value in
  (* (no ~flush here: a flush empties EX and C anyway, below; timing) *)
  let ex_advance =
    ex_valid.value &: ex_finished &: c_free &: ~:ex_needs_c &: ~:(halted.value)
    -- "ex_advance"
  in
  (* ---------------------------------------------------------------- *)
  (* ID (the head of the fetch queue) *)
  let id_valid = q0_valid.value in
  let id_insn = q0_insn.value in
  let ex_free = ~:(ex_valid.value) |: ex_advance in
  let id_advance =
    id_valid &: ex_free &: ~:(redirect.value) &: ~:(halted.value) -- "id_advance"
  in
  (* register file: two asynchronous read ports, written by C *)
  let rf_read ~name addr =
    (multiport_memory
       ~name
       (Rv32_model.Isa.num_regs base)
       ~write_ports:
         [| { write_clock = i.clock
            ; write_address = c_rd
            ; write_enable = rf_we.value
            ; write_data = rf_wdata.value
            }
         |]
       ~read_addresses:[| addr |]).(0)
  in
  let id_rs1 = rs1_of id_insn
  and id_rs2 = rs2_of id_insn in
  (* two copies, written together (named as Core's, so the generators
     zero them: B-0014) *)
  let id_operand ~name rs =
    mux2 (rs ==:. 0) (zero 32) (bypass_c ~rs (rf_read ~name rs))
  in
  let id_a = id_operand ~name:"regfile" id_rs1 -- "id_a"
  and id_b = id_operand ~name:"regfile_rs2" id_rs2 -- "id_b" in
  ignore rd_of;
  (* ---------------------------------------------------------------- *)
  (* IF *)
  let consume = id_advance in
  let response = inflight.value &: i.imem_rvalid in
  let response_ok = response &: ~:(inflight_stale.value) in
  (* queue entries after this cycle; a new request needs one free slot
     for its data (a request may go out in the cycle the previous one's
     data arrives; a redirect empties the queue) *)
  let entries_after =
    uresize q0_valid.value 3 +: uresize q1_valid.value 3 +: uresize response 3
    -: uresize consume 3
  in
  (* A flush from C redirects fetch one cycle later (flush_q; timing: the
     trap decision no longer reaches the fetch address and the queue). No
     request goes out in the flush cycle. *)
  let flush_q = reg spec flush.value -- "flush_q" in
  let flush_target_q = reg spec flush_target.value -- "flush_target_q" in
  let can_request =
    (~:(inflight.value) |: response)
    &: (redirect.value |: flush_q |: (entries_after <:. 2))
    &: ~:(flush.value)
    &: ~:(halted.value)
  in
  let fetch_pc =
    mux2 flush_q flush_target_q (mux2 redirect.value redirect_target.value pc_f.value)
  in
  let request = can_request in
  let accepted = request &: i.imem_ready in
  ignore rd_of;
  Always.(
    compile
      [ mcycle <-- mcycle.value +:. 1
      ; minstret <-- minstret.value +: uresize (retire.value &: ~:(retire_trap.value)) 64
      ; (* ---- C ---- *)
        when_
          (c_valid.value &: ~:(halted.value))
          [ (* a trap: enter the handler or halt *)
            (let enter ~cause ~tval ~irq =
               [ if_
                   (mtvec.value <>:. 0)
                   [ retire <-- vdd
                   ; retire_trap <-- vdd
                   ; retire_irq <-- irq
                   ; retire_cause <-- cause
                   ; retire_next <-- mtvec.value
                   ; mepc <-- c_pc.value
                   ; mcause <-- (cause.:(31) @: zero 27 @: cause.:[3, 0])
                   ; mtval <-- tval
                   ; mstatus_mpie <-- mstatus_mie.value
                   ; mstatus_mie <-- gnd
                   ; reservation_valid <-- gnd
                   ; flush <-- vdd
                   ; flush_target <-- mtvec.value
                   ; c_done <-- vdd
                   ; c_step <--. 0
                   ]
                   [ halted <-- vdd ]
               ]
             in
             if_
               ((c_step.value ==:. 0) &: irq_due)
               ((decision <-- vdd)
                :: enter ~cause:(vdd @: zero 27 @: irq_code) ~tval:(zero 32) ~irq:vdd)
               [ when_ (c_step.value ==:. 0) [ decision <-- vdd ]
               ; if_
                   (c_trap.value |: csr_illegal)
                   (List.concat
                      [ [ when_
                            (~:(mtvec.value <>:. 0))
                            [ trap_code
                              <-- mux2
                                    csr_illegal
                                    (of_int ~width:3 Core.Trap.illegal)
                                    (mux
                                       c_cause.value
                                       (List.init 16 ~f:(fun k ->
                                          of_int
                                            ~width:3
                                            (match k with
                                             | 0 -> Core.Trap.misaligned_fetch
                                             | 2 -> Core.Trap.illegal
                                             | 3 -> Core.Trap.ebreak
                                             | 4 | 6 -> Core.Trap.misaligned_access
                                             | 11 -> Core.Trap.ecall
                                             | _ -> 0))))
                            ]
                        ]
                      ; enter
                          ~cause:
                            (uresize (mux2 csr_illegal (of_int ~width:4 2) c_cause.value) 32)
                          ~tval:(mux2 csr_illegal c_insn.value c_tval.value)
                          ~irq:gnd
                      ])
                   [ (* execute *)
                     if_
                       (cd.load |: cd.lr |: cd.amo)
                       [ if_
                           (c_step.value ==:. 0)
                           [ dmem_read <-- vdd; when_ i.mem_ready [ c_step <--. 1 ] ]
                           [ if_
                               (c_step.value ==:. 1)
                               [ when_
                                   i.mem_rvalid
                                   (if_
                                      cd.amo
                                      [ c_amo_old <-- i.mem_rdata; c_step <--. 2 ]
                                      [ c_done <-- vdd
                                      ; c_step <--. 0
                                      ; when_
                                          cd.lr
                                          [ reservation_valid <-- vdd
                                          ; reservation_addr <-- c_addr.value
                                          ]
                                      ]
                                    :: [])
                               ]
                               [ (* AMO write *)
                                 dmem_write <-- vdd
                               ; dmem_wdata <-- amo_new
                               ; retire_mem_we <-- vdd
                               ; retire_mem_value <-- amo_new
                               ; when_ i.mem_ready [ c_done <-- vdd; c_step <--. 0 ]
                               ]
                           ]
                       ]
                       [ if_
                           (cd.store |: (cd.sc &: sc_ok))
                           [ dmem_write <-- vdd
                           ; dmem_wdata <-- store_data
                           ; retire_mem_we <-- vdd
                           ; retire_mem_value <-- c_store.value
                           ; when_
                               i.mem_ready
                               [ c_done <-- vdd
                               ; when_ cd.sc [ reservation_valid <-- gnd ]
                               ]
                           ]
                           [ c_done <-- vdd; when_ cd.sc [ reservation_valid <-- gnd ] ]
                       ]
                   ; when_
                       c_done.value
                       [ retire <-- vdd
                       ; retire_next <-- mux2 cd.mret mepc.value c_next.value
                       ; rf_we <-- (c_writes_rd &: (c_rd <>:. 0))
                       ; rf_wdata <-- c_wb_value
                       ; (* CSR writes, MRET; flushes for MRET and FENCE.I *)
                         when_
                           (cd.csr &: csr_writes)
                           [ when_
                               (csr_hit 0x300)
                               [ mstatus_mie <-- csr_new.:(3); mstatus_mpie <-- csr_new.:(7) ]
                           ; when_
                               (csr_hit 0x304)
                               [ mie <-- (csr_new.:[11, 0] &: of_int ~width:12 0x888) ]
                           ; when_ (csr_hit 0x305) [ mtvec <-- csr_new.:[31, 2] @: zero 2 ]
                           ; when_ (csr_hit 0x340) [ mscratch <-- csr_new ]
                           ; when_ (csr_hit 0x341) [ mepc <-- csr_new.:[31, 2] @: zero 2 ]
                           ; when_
                               (csr_hit 0x342)
                               [ mcause <-- csr_new.:(31) @: zero 27 @: csr_new.:[3, 0] ]
                           ; when_ (csr_hit 0x343) [ mtval <-- csr_new ]
                           ]
                       ; when_
                           cd.mret
                           [ mstatus_mie <-- mstatus_mpie.value
                           ; mstatus_mpie <-- vdd
                           ; flush <-- vdd
                           ; flush_target <-- mepc.value
                           ]
                       ; when_
                           cd.fence_i
                           [ flush <-- vdd; flush_target <-- c_next.value ]
                       ]
                   ]
               ])
          ]
      ; when_ (c_done.value |: ~:(c_valid.value)) [ c_valid <-- gnd ]
      ; (* ---- EX ---- *)
        (* the operands as forwarded now (a multi-cycle operation keeps
           using them) *)
        when_ ex_valid.value [ ex_a <-- a_next; ex_b <-- b_next ]
      ; (* a multiplication or division starts once its operands are
           there (not waiting for C) *)
        when_
          (ex_valid.value &: ~:(ex_busy.value) &: ~:ex_dep)
          [ when_ xd.mul [ mul_result <-- product; ex_busy <-- vdd ]
          ; when_
              xd.div
              [ div_quot <-- abs_if (div_signed &: msb ex_a.value) ex_a.value
              ; div_rem <--. 0
              ; div_count <--. 32
              ; div_neg_q
                <-- (div_signed &: (msb ex_a.value ^: msb ex_b.value) &: (ex_b.value <>:. 0))
              ; div_neg_r <-- (div_signed &: msb ex_a.value)
              ; ex_busy <-- vdd
              ]
          ]
      ; when_
          (ex_valid.value &: ex_busy.value &: xd.div &: (div_count.value <>:. 0))
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
      ; when_
          ex_advance
          [ c_valid <-- vdd
          ; c_pc <-- ex_pc.value
          ; c_insn <-- ex_insn.value
          ; c_result
            <-- mux2 xd.mul mul_result.value (mux2 xd.div div_result x_result)
          ; c_addr <-- agu
          ; c_store <-- b
          ; c_src
            <-- mux2 xd.csr_imm (uresize ex_insn.value.:[19, 15] 32) a
          ; c_next <-- x_next
          ; c_step <--. 0
          ; c_trap <-- (xd.illegal |: xd.ecall |: xd.ebreak |: x_misaligned_target |: x_misaligned_mem)
          ; c_cause
            <-- mux2
                  xd.illegal
                  (of_int ~width:4 2)
                  (mux2
                     xd.ecall
                     (of_int ~width:4 11)
                     (mux2
                        xd.ebreak
                        (of_int ~width:4 3)
                        (mux2
                           x_misaligned_target
                           (of_int ~width:4 0)
                           (mux2
                              (xd.store |: xd.sc |: xd.amo)
                              (of_int ~width:4 6)
                              (of_int ~width:4 4)))))
          ; c_tval
            <-- mux2
                  xd.illegal
                  ex_insn.value
                  (mux2 x_misaligned_target x_next (mux2 x_misaligned_mem agu (zero 32)))
          ; ex_busy <-- gnd
          ; (* a taken branch or jump redirects fetch *)
            when_
              (x_taken &: ~:x_misaligned_target &: ~:(xd.illegal))
              [ redirect <-- vdd; redirect_target <-- x_target ]
          ]
      ; when_ (ex_advance |: ~:(ex_valid.value)) [ ex_valid <-- gnd ]
      ; (* ---- ID -> EX ---- *)
        when_
          id_advance
          [ ex_valid <-- vdd
          ; ex_pc <-- q0_pc.value
          ; ex_insn <-- id_insn
          ; ex_a <-- id_a
          ; ex_b <-- id_b
          ; ex_busy <-- gnd
          ]
      ; (* ---- IF ---- *)
        (* queue: pop the head when ID takes it, push a fresh response *)
        (let push_pc = inflight_pc.value
         and push_insn = i.imem_rdata in
         let after_pop_valid0 = mux2 consume q1_valid.value q0_valid.value
         and after_pop_pc0 = mux2 consume q1_pc.value q0_pc.value
         and after_pop_insn0 = mux2 consume q1_insn.value q0_insn.value
         and after_pop_valid1 = mux2 consume gnd q1_valid.value in
         proc
           [ q0_valid <-- after_pop_valid0
           ; q0_pc <-- after_pop_pc0
           ; q0_insn <-- after_pop_insn0
           ; q1_valid <-- after_pop_valid1
           ; when_
               response_ok
               [ if_
                   after_pop_valid0
                   [ q1_valid <-- vdd; q1_pc <-- push_pc; q1_insn <-- push_insn ]
                   [ q0_valid <-- vdd; q0_pc <-- push_pc; q0_insn <-- push_insn ]
               ]
           ])
      ; when_ response [ inflight <-- gnd ]
      ; when_
          accepted
          [ inflight <-- vdd
          ; inflight_pc <-- fetch_pc
          ; inflight_stale <-- gnd
          ; pc_f <-- fetch_pc +:. 4
          ]
      ; (* redirects: EX (branches) and C (traps, MRET, FENCE.I) *)
        when_
          (redirect.value |: flush.value |: flush_q)
          [ q0_valid <-- gnd
          ; q1_valid <-- gnd
          ; when_ (~:accepted) [ pc_f <-- fetch_pc ]
          ; when_ (inflight.value &: ~:response) [ inflight_stale <-- vdd ]
          ]
      ; when_ flush.value [ ex_valid <-- gnd; c_valid <-- gnd ]
      ]);
  let core =
    { Core.O.mem_addr = c_addr.value
    ; mem_read = dmem_read.value
    ; mem_write = dmem_write.value
    ; mem_wdata = dmem_wdata.value
    ; mem_wmask = store_mask
    ; halted = halted.value
    ; trap = trap_code.value
    ; retire = retire.value
    ; retire_pc = c_pc.value
    ; retire_insn = mux2 retire_irq.value (zero 32) c_insn.value
    ; retire_rd_we = rf_we.value
    ; retire_rd = uresize c_rd 5
    ; retire_rd_value = rf_wdata.value
    ; retire_mem_we = retire_mem_we.value
    ; retire_mem_addr = c_addr.value
    ; retire_mem_size = c_size
    ; retire_mem_value = retire_mem_value.value
    ; retire_next_pc = retire_next.value
    ; retire_trap = retire_trap.value
    ; retire_cause = retire_cause.value
    ; csr_mcycle = mcycle.value
    ; csr_minstret = minstret.value
    ; fetch = decision.value
    ; mem_sc = gnd
    ; mem_lock = gnd
    ; retire_load = mux2 cd.amo c_amo_old.value rf_wdata.value
    ; reservation_lost = gnd
    }
  in
  { O.core; imem_addr = fetch_pc; imem_read = request }
;;

let hierarchical ?reset_pc ~base scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"rv32_pipeline" (create ?reset_pc ~base)
;;
