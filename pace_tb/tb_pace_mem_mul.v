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
// M extension test: mul, div, divu, rem, remu.
`timescale 1ns/1ps
module tb_pace_mem_mul;
    reg clk = 0, rst_n = 0;
    wire [63:0]  imem_pc;
    reg  [191:0] imem_instr;
    reg  [3:0]   i_instr_count;
    wire         dram_req, dram_we;
    wire [63:0]  dram_addr, dram_wdata;
    wire [7:0]   dram_be;
    reg  [511:0] dram_rdata;
    reg          dram_ready;
    wire         mmio_req, mmio_we;
    wire [63:0]  mmio_addr, mmio_wdata;
    reg  [63:0]  mmio_rdata;
    reg          mmio_ready;
    wire [63:0]  dbg_arch_rd, dbg_pcu_pc, dbg_satp;
    wire         dbg_satp_en;
    reg  [4:0]   dbg_rs;
    reg [31:0] prog [0:63];

    top_pace_mem dut (
        .clk(clk), .rst_n(rst_n),
        .imem_pc(imem_pc), .imem_instr(imem_instr),
        .i_instr_count(i_instr_count),
        .dram_req(dram_req), .dram_we(dram_we),
        .dram_addr(dram_addr), .dram_wdata(dram_wdata),
        .dram_be(dram_be),
        .dram_rdata(dram_rdata), .dram_ready(dram_ready),
        .mmio_req(mmio_req), .mmio_we(mmio_we),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_rdata(mmio_rdata), .mmio_ready(mmio_ready),
        .i_mtip(1'b0), .i_msip(1'b0), .i_meip(1'b0),
        .i_seip(1'b0), .i_stip(1'b0), .i_ssip(1'b0),
        .dbg_rs(dbg_rs), .dbg_arch_rd(dbg_arch_rd),
        .dbg_pcu_pc(dbg_pcu_pc),
        .dbg_satp(dbg_satp), .dbg_satp_en(dbg_satp_en)
    );

    always #5 clk = ~clk;

    function [31:0] get_word;
        input [63:0] pc;
        integer idx;
        begin
            idx = pc >> 2;
            if (idx < 64) get_word = prog[idx];
            else          get_word = 32'h00000013;
        end
    endfunction

    always @(*) begin
        imem_instr[31:0]    = get_word(imem_pc);
        imem_instr[63:32]   = get_word(imem_pc + 4);
        imem_instr[95:64]   = get_word(imem_pc + 8);
        imem_instr[127:96]  = get_word(imem_pc + 12);
        imem_instr[159:128] = get_word(imem_pc + 16);
        imem_instr[191:160] = get_word(imem_pc + 20);
    end

    always @(posedge clk) begin
        dram_ready <= 0;
        if (dram_req) dram_ready <= 1;
    end

    initial begin
        integer i;
        $display("=== PACE M-extension test ===");
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h00000013;

        prog[0] = 32'h00600093;  // addi x1, x0, 6
        prog[1] = 32'h00700113;  // addi x2, x0, 7
        prog[2] = 32'h022081B3;  // mul  x3, x1, x2   → 42
        prog[3] = 32'h01400213;  // addi x4, x0, 20
        prog[4] = 32'h00300293;  // addi x5, x0, 3
        prog[5] = 32'h02524333;  // div  x6, x4, x5   → 6
        prog[6] = 32'h025253B3;  // divu x7, x4, x5   → 6
        prog[7] = 32'h02526433;  // rem  x8, x4, x5   → 2
        prog[8] = 32'h025274B3;  // remu x9, x4, x5   → 2

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (500) @(posedge clk);

        $display("--- results ---");
        dbg_rs=5'd3; #5; $display("x3 = %0d  (expect 42 — mul 6*7)", dbg_arch_rd);
        dbg_rs=5'd6; #5; $display("x6 = %0d  (expect 6 — div 20/3)", dbg_arch_rd);
        dbg_rs=5'd7; #5; $display("x7 = %0d  (expect 6 — divu 20/3)", dbg_arch_rd);
        dbg_rs=5'd8; #5; $display("x8 = %0d  (expect 2 — rem 20 %% 3)", dbg_arch_rd);
        dbg_rs=5'd9; #5; $display("x9 = %0d  (expect 2 — remu 20 %% 3)", dbg_arch_rd);
        $display("final pc = %h", dbg_pcu_pc);
        $finish;
    end
endmodule
