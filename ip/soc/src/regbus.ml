(* The register bus of the SoC's peripherals (issue #28): one request per
   cycle, [read]/[write] with a byte offset, 32-bit data with lane-aligned
   bytes and a byte mask; a read's data is registered and valid in the
   next cycle (the core's protocol with ready = 1 and rvalid = the read
   delayed by one cycle). Read side effects (UART RBR, PLIC claim) happen
   in the request cycle. *)
open! Hardcaml

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; read : 'a
    ; write : 'a
    ; addr : 'a [@bits 24] (* offset inside the device *)
    ; wdata : 'a [@bits 32]
    ; wmask : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end
