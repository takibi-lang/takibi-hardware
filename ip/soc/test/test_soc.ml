(* The SoC (issue #21) in Cyclesim with the board models, in lockstep with
   the golden model: a boot-ROM program uses the SDRAM (words and bytes,
   the latter read-modify-write), the flash window, the UART, a CLINT timer
   interrupt and a UART receive interrupt through the PLIC. *)
open! Base
open Stdio
module A = Rv32_model.Asm
module C = Rv32_model.Asm.Csr
module H = Soc_bench.Soc_harness
module Map = Soc_model.Soc_map

(* Print the byte in x[r] (polling LSR.THRE); uses x30, x31. *)
let putc r =
  A.li 31 Map.uart_base
  @ [ A.lbu 30 31 5; A.andi 30 30 0x20; A.beq 30 0 (-8); A.sb r 31 0 ]
;;

let puts s = List.concat_map (String.to_list s) ~f:(fun c -> A.li 29 (Char.to_int c) @ putc 29)

let program =
  let handler_at = 0x400 in
  let main =
    puts "SoC\n"
    (* SDRAM: words and bytes; the lockstep compares every loaded value *)
    @ A.li 1 Map.ram_base
    @ A.li 2 0x1234_5678
    @ [ A.sw 2 1 0; A.sw 2 1 0x400; A.lw 3 1 0 ]
    @ A.li 2 0xab
    @ [ A.sb 2 1 1; A.lw 4 1 0; A.lbu 5 1 1; A.sh 2 1 0x402; A.lw 6 1 0x400 ]
    @ A.li 7 (Map.ram_base + 0x7f_fffc)
    @ [ A.sw 1 7 0; A.lw 8 7 0 ]
    (* flash: sequential and random words *)
    @ A.li 9 Map.flash_base
    @ [ A.lw 10 9 0; A.lw 11 9 4; A.lw 12 9 8; A.lw 13 9 0x100; A.lbu 14 9 0x101 ]
    @ puts "mem\n"
    (* timer interrupt: mtimecmp = mtime + 20 *)
    @ A.li 1 handler_at
    @ [ A.csrw C.mtvec 1 ]
    @ A.li 15 (Map.clint_base + 0xbff8)
    @ [ A.lw 16 15 0; A.addi 16 16 20 ]
    @ A.li 17 (Map.clint_base + 0x4000)
    @ [ A.sw 16 17 0; A.sw 0 17 4 ]
    @ A.li 1 0x880 (* MTIE, MEIE *)
    @ [ A.csrw C.mie 1; A.addi 20 0 0; A.csrrsi 0 C.mstatus 8 ]
    @ [ A.beq 20 0 (-0) ] (* wait for the handler: x20 <> 0 *)
    @ puts "timer\n"
    (* UART receive interrupt through the PLIC (source 1, context 0) *)
    @ A.li 18 Map.plic_base
    @ A.li 1 1
    @ [ A.sw 1 18 4 ] (* priority 1 *)
    @ A.li 19 (Map.plic_base + 0x2000)
    @ A.li 1 2
    @ [ A.sw 1 19 0 ] (* enable source 1 for context 0 *)
    @ A.li 19 (Map.plic_base + 0x20_0000)
    @ [ A.sw 0 19 0 ] (* threshold 0 *)
    @ A.li 31 Map.uart_base
    @ A.li 1 1
    @ [ A.sb 1 31 1 ] (* IER: receive data *)
    @ puts ">"
    @ [ A.addi 21 0 0; A.beq 21 0 (-0) ] (* wait for the echo *)
    @ puts "\nok\n"
    (* wait for TEMT: the transmitter has sent everything *)
    @ A.li 31 Map.uart_base
    @ [ A.lbu 30 31 5; A.andi 30 30 0x40; A.beq 30 0 (-8) ]
    @ [ A.csrw C.mtvec 0; A.ebreak ]
  in
  let handler =
    [ A.csrr 22 C.mcause; A.andi 22 22 0xf; A.addi 23 0 7; A.bne 22 23 32 ]
    (* timer: mtimecmp high = -1, flag *)
    @ A.li 24 (Map.clint_base + 0x4004)
    @ A.li 25 (-1)
    @ [ A.sw 25 24 0; A.addi 20 0 1; A.mret ]
    (* external: claim, read RBR, echo, complete, flag *)
    @ A.li 24 (Map.plic_base + 0x20_0004)
    @ [ A.lw 26 24 0 ]
    @ A.li 27 Map.uart_base
    @ [ A.lbu 28 27 0 ]
    @ putc 28
    @ [ A.sw 26 24 0; A.addi 21 0 1; A.mret ]
  in
  (* fix the busy-wait branches: beq x, x0, 0 loops on itself *)
  let n = List.length main in
  assert (4 * n <= handler_at);
  Array.of_list (main @ List.init ((handler_at / 4) - n) ~f:(fun _ -> A.nop) @ handler)
;;

let%expect_test "SoC: memories, UART, timer and PLIC interrupts, in lockstep" =
  let flash = String.init 4096 ~f:(fun k -> Char.of_int_exn ((k * 7) land 0xff)) in
  let r =
    H.run
      ~boot_rom:program
      ~flash
      ~input:"Z"
      ~prompt:">"
      ~max_cycles:200_000
      ()
  in
  printf
    "output %S\nhalted %s, retired %d, interrupts %d, cycles>0 %b\nmismatch %s\nsdram %s\nflash %s\n"
    r.output
    (Option.value_map r.halted ~default:"no" ~f:Int.to_string)
    r.retired
    r.interrupts
    (r.cycles > 0)
    (Option.value r.mismatch ~default:"none")
    (String.concat ~sep:"; " r.sdram_violations)
    (String.concat ~sep:"; " r.flash_errors);
  [%expect {|
    output "SoC\nmem\ntimer\n>Z\nok\n"
    halted 2, retired 1269, interrupts 2, cycles>0 true
    mismatch none
    sdram
    flash
    |}]
;;
