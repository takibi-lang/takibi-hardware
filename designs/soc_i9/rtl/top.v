// Colorlight i9 v7.2 top level of the Linux SoC (issue #21): a hand-written
// shell around the generated module soc_board, for what HardCaml cannot
// express: the bidirectional SDRAM data pins (ECP5 BB) and USRMCLK, which
// drives the configuration clock pin (the SPI flash's SCK) from user logic
// and has no outputs. Nothing else belongs here.
module top (
    input  wire        clock,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        led_n,
    output wire        flash_cs_n,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        sdram_clk,
    output wire [10:0] sdram_a,
    output wire [1:0]  sdram_ba,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    inout  wire [31:0] sdram_dq
);
    wire [31:0] dq_in;
    wire [31:0] dq_out;
    wire        dq_oe;
    wire        flash_sck;

    genvar k;
    generate
        for (k = 0; k < 32; k = k + 1) begin : dq
            BB bb (.I(dq_out[k]), .T(~dq_oe), .O(dq_in[k]), .B(sdram_dq[k]));
        end
    endgenerate

    USRMCLK usrmclk (.USRMCLKI(flash_sck), .USRMCLKTS(1'b0));

    soc_board board (
        .clock(clock),
        .uart_rx(uart_rx),
        .flash_miso(flash_miso),
        .sdram_dq_in(dq_in),
        .uart_tx(uart_tx),
        .led_n(led_n),
        .flash_cs_n(flash_cs_n),
        .flash_mosi(flash_mosi),
        .flash_sck(flash_sck),
        .sdram_clk(sdram_clk),
        .sdram_a(sdram_a),
        .sdram_ba(sdram_ba),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),
        .sdram_dq_out(dq_out),
        .sdram_dq_oe(dq_oe)
    );
endmodule
