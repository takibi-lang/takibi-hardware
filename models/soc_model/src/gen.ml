(* Text generated from Soc_map (issue #25): the device tree source and a C
   header for the boot ROM and the REPL, so that the hardware description,
   the model, the device tree and the software share one memory map. *)
open! Base
open Soc_map

let hex = Printf.sprintf "0x%x"

(* Memory reserved by the boot ROM (#9): its M-mode mailboxes (IPIs,
   remote fences, saved registers), at the top of the RAM. *)
let mailbox_bytes = 0x1000
let mailbox_base = ram_base + ram_bytes - mailbox_bytes

let cpu h =
  [ ""
  ; Printf.sprintf "    cpu%d: cpu@%d {" h h
  ; "      device_type = \"cpu\";"
  ; Printf.sprintf "      reg = <%d>;" h
  ; "      compatible = \"riscv\";"
  ; "      status = \"okay\";"
  ; "      mmu-type = \"riscv,sv32\";"
  ; Printf.sprintf
      "      riscv,isa = \"%s\";"
      (String.concat ~sep:"_" ("rv32ima" :: List.drop isa_extensions 3))
  ; "      riscv,isa-base = \"rv32i\";"
  ; Printf.sprintf
      "      riscv,isa-extensions = %s;"
      (String.concat ~sep:", " (List.map isa_extensions ~f:(Printf.sprintf "\"%s\"")))
  ; ""
  ; Printf.sprintf "      cpu%d_intc: interrupt-controller {" h
  ; "        #interrupt-cells = <1>;"
  ; "        interrupt-controller;"
  ; "        compatible = \"riscv,cpu-intc\";"
  ; "      };"
  ; "    };"
  ]
;;

let dts ?(harts = 1) () =
  String.concat
    ~sep:"\n"
    ([ "/* Generated from models/soc_model/src/soc_map.ml; do not edit. */"
    ; "/dts-v1/;"
    ; ""
    ; "/ {"
    ; "  #address-cells = <1>;"
    ; "  #size-cells = <1>;"
    ; "  compatible = \"takibi-hardware,soc\";"
    ; "  model = \"takibi-hardware Linux SoC (Colorlight i9)\";"
    ; ""
    ; "  chosen {"
    ; "    stdout-path = \"serial0\";"
    ; "  };"
    ; ""
    ; "  aliases {"
    ; "    serial0 = &uart0;"
    ; "  };"
    ; ""
    ; "  cpus {"
    ; "    #address-cells = <1>;"
    ; "    #size-cells = <0>;"
    ; Printf.sprintf "    timebase-frequency = <%d>;" timebase_hz
    ; ""
    ]
    @ List.concat_map (List.range 0 harts) ~f:cpu
    @ [ "  };"
    ; ""
    ; Printf.sprintf "  memory@%x {" ram_base
    ; "    device_type = \"memory\";"
    ; Printf.sprintf
        "    reg = <%s %s>;"
        (hex ram_base)
        (hex (ram_bytes - mailbox_bytes))
    ; "  };"
    ; ""
    ; "  soc {"
    ; "    #address-cells = <1>;"
    ; "    #size-cells = <1>;"
    ; "    compatible = \"simple-bus\";"
    ; "    ranges;"
    ; ""
    ; Printf.sprintf "    plic: interrupt-controller@%x {" plic_base
    ; "      compatible = \"sifive,plic-1.0.0\", \"riscv,plic0\";"
    ; Printf.sprintf "      reg = <%s %s>;" (hex plic_base) (hex plic_bytes)
    ; "      #address-cells = <0>;"
    ; "      #interrupt-cells = <1>;"
    ; "      interrupt-controller;"
    ; "      /* contexts 2h: M external (11), 2h + 1: S external (9) of hart h */"
    ; Printf.sprintf
        "      interrupts-extended = %s;"
        (String.concat
           ~sep:", "
           (List.init harts ~f:(fun h -> Printf.sprintf "<&cpu%d_intc 11>, <&cpu%d_intc 9>" h h)))
    ; Printf.sprintf "      riscv,ndev = <%d>;" plic_sources
    ; "    };"
    ; ""
    ; Printf.sprintf "    uart0: serial@%x {" uart_base
    ; "      compatible = \"ns16550a\";"
    ; Printf.sprintf "      reg = <%s %s>;" (hex uart_base) (hex uart_bytes)
    ; Printf.sprintf "      clock-frequency = <%d>;" system_clock_hz
    ; "      current-speed = <115200>;"
    ; "      reg-shift = <0>;"
    ; "      reg-io-width = <1>;"
    ; "      interrupt-parent = <&plic>;"
    ; Printf.sprintf "      interrupts = <%d>;" uart_irq
    ; "    };"
    ; "  };"
    ; "};"
    ; ""
    ])
;;

let header ?(harts = 1) () =
  let defs =
    [ "BOOT_ROM_BASE", boot_rom_base
    ; "CLINT_BASE", clint_base
    ; "PLIC_BASE", plic_base
    ; "UART_BASE", uart_base
    ; "FLASH_BASE", flash_base
    ; "RAM_BASE", ram_base
    ; "RAM_BYTES", ram_bytes
    ; "FLASH_DTB_OFFSET", flash_dtb_offset
    ; "FLASH_KERNEL_OFFSET", flash_kernel_offset
    ; "KERNEL_LOAD", kernel_load
    ; "TIMEBASE_HZ", timebase_hz
    ; "HARTS", harts
    ; "MAILBOX", mailbox_base
    ]
  in
  String.concat
    ~sep:"\n"
    ([ "/* Generated from models/soc_model/src/soc_map.ml; do not edit. */"
     ; "#ifndef SOC_MAP_H"
     ; "#define SOC_MAP_H"
     ]
     @ List.map defs ~f:(fun (n, v) -> Printf.sprintf "#define %s 0x%x" n v)
     @ [ "#endif"; "" ])
;;
