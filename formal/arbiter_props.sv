// Formal properties of the SoC's bus arbiter (issue #9), proved with
// SymbiYosys (formal/arbiter.sby) on the Verilog that HardCaml generates
// for Soc.Arbiter (module arbiter; not edited). The inputs are free,
// constrained only by what the two cores and their bus bridges do.
module arbiter_props (
    input wire       clock,
    input wire [1:0] valid,
    input wire [1:0] write,
    input wire [1:0] sc,
    input wire [1:0] lock,
    input wire [1:0] core_sc,
    input wire       ready,
    input wire       rvalid
);
    reg init = 1'b1;
    always @(posedge clock) init <= 1'b0;

    wire       sel, sel_valid, read_busy, locked, lock_hart;
    wire [1:0] granted, snoop;
    wire       sc_block0, sc_block1;
    wire [1:0] sc_block = {sc_block1, sc_block0};
    arbiter dut (
        .clock(clock), .clear(init),
        .valid(valid), .write(write), .sc(sc), .lock(lock), .core_sc(core_sc),
        .ready(ready), .rvalid(rvalid),
        .sel(sel), .sel_valid(sel_valid), .granted(granted), .snoop(snoop),
        .sc_block0(sc_block0), .sc_block1(sc_block1), .read_busy(read_busy), .locked(locked),
        .lock_hart(lock_hart)
    );

    // An SC whose success a core has decided, until the bus grants its write.
    reg [1:0] sc_decided = 2'b00;
    genvar h;
    generate
        for (h = 0; h < 2; h = h + 1) begin : env
            // The bridge: a request stays, unchanged, until it is granted.
            always @(posedge clock)
                if (!init && $past(!init) && $past(valid[h] && !granted[h]))
                    assume (valid[h] && write[h] == $past(write[h]) &&
                            sc[h] == $past(sc[h]) && lock[h] == $past(lock[h]));
            // Flags: an SC is a write, an AMO's locking read a read.
            always @* assume (!(sc[h] && !write[h]) && !(lock[h] && write[h]));
            // A core decides an SC only when not blocked, and the decided
            // SC is its next request (it waits in Mem while the bridge is
            // busy, so the decision counts when the bridge is free).
            always @* assume (!core_sc[h] || !sc_block[h]);
            always @(posedge clock)
                if (!init && $past(!init) && $past(core_sc[h] && !valid[h]))
                    assume (valid[h] && write[h] && sc[h]);
            // ... and an SC write enters the bridge only that way.
            always @(posedge clock)
                if (!init && valid[h] && sc[h] && !$past(valid[h] && sc[h] && !granted[h]))
                    assume ($past(!init) && $past(core_sc[h] && !valid[h]));
            always @(posedge clock)
                if (init) sc_decided[h] <= 1'b0;
                else if (core_sc[h] && !valid[h]) sc_decided[h] <= 1'b1;
                else if (granted[h] && write[h] && sc[h]) sc_decided[h] <= 1'b0;
        end
    endgenerate
    // What the environment model implies in every reachable state (stated
    // for k-induction): an SC write is in its bridge exactly while it is
    // decided and not granted.
    always @* if (!init) begin
        assume (sc_decided[0] == (valid[0] && write[0] && sc[0]));
        assume (sc_decided[1] == (valid[1] && write[1] && sc[1]));
    end
    // Read data only for an outstanding read.
    always @* assume (!rvalid || read_busy);

    always @* if (!init) begin
        // Atomicity of LR/SC: no write of the other core between an SC's
        // decision and its write.
        assert (!(sc_decided[0] && granted[1] && write[1]));
        assert (!(sc_decided[1] && granted[0] && write[0]));
        // Lemma (needed by the induction, proved as well): a core never
        // holds a decided SC while the other one holds the AMO lock.
        assert (!(locked && sc_decided[!lock_hart]));
        // Lemma: the two cores never hold decided SCs at the same time.
        assert (sc_decided != 2'b11);
        // Atomicity of AMOs: while one core holds the lock, the other is
        // not granted anything.
        assert (!(locked && granted[!lock_hart]));
        // One transaction at a time.
        assert (!(read_busy && granted != 2'b00));
        // Grants only to valid requests, at most one.
        assert ((granted & ~valid) == 2'b00 && granted != 2'b11);
        // Something interesting is reachable: an SC decided while the other
        // core waits with a write, and an AMO holding the lock while the
        // other core waits.
        cover (sc_decided[0] && valid[1] && write[1]);
        cover (locked && valid[!lock_hart]);
    end
endmodule
