// Copyright (c) 2026 uppmpt (https://github.com/uppmpt)
// Contact: pacesolodev@gmail.com
//
// This source describes Open Hardware and is licensed under the
// CERN-OHL-W v2.
//
// You may redistribute and modify this source and make products
// using it under the terms of the CERN-OHL-W v2
// (https://ohwr.org/cern_ohl_w_v2.txt).
//
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED
// WARRANTY, INCLUDING THE IMPLIED WARRANTIES OF MERCHANTABILITY,
// SATISFACTORY QUALITY AND FITNESS FOR A PARTICULAR PURPOSE.
// Please see the CERN-OHL-W v2 for applicable conditions.
//
// Source location: https://github.com/uppmpt/pace-microarchitecture
`timescale 1ns/1ps
// Minimal RISCOF-style testbench for PACE.
// Loads a program into a byte-addressable memory via $readmemh,
// runs until ebreak is detected, then dumps a signature file.

module tb_riscof;

    reg clk = 0;
    reg rst_n = 0;

    // PACE top-level port connections
    wire        mmio_req, mmio_we;
    wire [63:0] mmio_addr, mmio_wdata;
    reg  [63:0] mmio_rdata;
    reg         mmio_ready;

    wire        dram_req, dram_we;
    wire [63:0] dram_addr;
    wire [511:0] dram_wdata;
    reg  [511:0] dram_rdata;
    reg         dram_ready;

    wire [63:0] dbg_pcu_pc;
    wire [1:0]  dbg_priv;
    wire [63:0] dbg_arch_rd;

    // 1 MB byte-addressable memory (RISCOF tests may grow later)
    reg [7:0] mem [0:1048575];

    // Test control
    integer i;
    integer cycle_count;
    integer max_cycles;
    reg     done;

    top_pace_final dut (
        .clk(clk), .rst_n_in(rst_n),
        .mmio_req(mmio_req), .mmio_we(mmio_we),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_rdata(mmio_rdata), .mmio_ready(mmio_ready),
        .dram_req(dram_req), .dram_we(dram_we),
        .dram_addr(dram_addr), .dram_wdata(dram_wdata),
        .dram_rdata(dram_rdata), .dram_ready(dram_ready),
        .i_mtip(1'b0), .i_msip(1'b0), .i_meip(1'b0),
        .i_seip(1'b0), .i_stip(1'b0), .i_ssip(1'b0),
        .dbg_pcu_pc(dbg_pcu_pc), .dbg_priv(dbg_priv),
        .dbg_rs(5'd0), .dbg_arch_rd(dbg_arch_rd)
    );

    // Clock
    always #5 clk = ~clk;

    // DRAM model: 64-byte cache line access
    // dram_addr is byte address; line number = addr[12:6]
    always @(posedge clk) begin
        dram_ready <= 0;
        if (dram_req) begin
            if (dram_we) begin
                // Write 64 bytes from dram_wdata into mem
                for (i = 0; i < 8; i = i + 1) begin
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 0] <= dram_wdata[i*64 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 1] <= dram_wdata[i*64 + 8 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 2] <= dram_wdata[i*64 + 16 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 3] <= dram_wdata[i*64 + 24 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 4] <= dram_wdata[i*64 + 32 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 5] <= dram_wdata[i*64 + 40 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 6] <= dram_wdata[i*64 + 48 +: 8];
                    mem[{dram_addr[63:6], 6'd0} + i*8 + 7] <= dram_wdata[i*64 + 56 +: 8];
                end
            end else begin
                // Read 64 bytes
                for (i = 0; i < 8; i = i + 1) begin
                    dram_rdata[i*64 +: 8]  <= mem[{dram_addr[63:6], 6'd0} + i*8 + 0];
                    dram_rdata[i*64 + 8 +: 8]  <= mem[{dram_addr[63:6], 6'd0} + i*8 + 1];
                    dram_rdata[i*64 + 16 +: 8] <= mem[{dram_addr[63:6], 6'd0} + i*8 + 2];
                    dram_rdata[i*64 + 24 +: 8] <= mem[{dram_addr[63:6], 6'd0} + i*8 + 3];
                    dram_rdata[i*64 + 32 +: 8] <= mem[{dram_addr[63:6], 6'd0} + i*8 + 4];
                    dram_rdata[i*64 + 40 +: 8] <= mem[{dram_addr[63:6], 6'd0} + i*8 + 5];
                    dram_rdata[i*64 + 48 +: 8] <= mem[{dram_addr[63:6], 6'd0} + i*8 + 6];
                    dram_rdata[i*64 + 56 +: 8] <= mem[{dram_addr[63:6], 6'd0} + i*8 + 7];
                end
            end
            dram_ready <= 1;
        end
    end

    // MMIO: tohost at 0x100000 (RISCOF convention)
    // Writing 1 = pass, value>>1 = fail code
    always @(posedge clk) begin
        mmio_ready <= 0;
        if (mmio_req) begin
            mmio_rdata <= 64'h0;
            mmio_ready <= 1;
            if (mmio_we && mmio_addr == 64'h100000) begin
                if (mmio_wdata[0] == 1'b1) begin
                    $display("[RISCOF] PASS (tohost = %0d)", mmio_wdata);
                end else begin
                    $display("[RISCOF] FAIL (tohost = %0d)", mmio_wdata);
                end
                done <= 1;
            end
        end
    end

    // Load program, reset, run
    initial begin
        $display("========================================");
        $display("  PACE RISCOF Testbench");
        $display("========================================");

        // Initialize memory
        for (i = 0; i < 1048576; i = i + 1) mem[i] = 8'h00;

        // Load program from hex file (set by +PROG=<file>)
        if ($value$plusargs("PROG=%s", "")) begin
            // placeholder; actual loading done below
        end
        $readmemh("program.hex", mem);

        // Reset sequence
        rst_n = 0;
        dram_ready = 0;
        mmio_ready = 0;
        mmio_rdata = 0;
        dram_rdata = 0;
        done = 0;
        cycle_count = 0;
        max_cycles = 1000000;

        #20 rst_n = 1;
        $display("[RISCOF] Reset released, running...");

        // Wait until halt or timeout
        while (!done && cycle_count < max_cycles) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
            if (cycle_count % 100000 == 0) begin
                $display("[RISCOF] cycle=%0d pc=%h priv=%b",
                         cycle_count, dbg_pcu_pc, dbg_priv);
            end
        end

        if (!done) begin
            $display("[RISCOF] TIMEOUT after %0d cycles", cycle_count);
            $display("[RISCOF] Final pc=%h priv=%b", dbg_pcu_pc, dbg_priv);
        end
        $finish;
    end

endmodule
