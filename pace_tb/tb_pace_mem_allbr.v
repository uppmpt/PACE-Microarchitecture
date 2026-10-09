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
// All branches + JAL test for top_pace_mem.
`timescale 1ns/1ps

module tb_pace_mem_allbr;
    reg clk = 0, rst_n = 0;
    wire [63:0]  imem_pc;
    reg  [191:0] imem_instr;
    reg  [3:0]   i_instr_count;
    wire         dram_req, dram_we;
    wire [63:0]  dram_addr, dram_wdata;
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
        $display("=== PACE all-branch test ===");
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h00000013;

        // Setup
        prog[0]  = 32'h00500093;  // addi x1, x0, 5
        prog[1]  = 32'h00500113;  // addi x2, x0, 5
        prog[2]  = 32'h00300193;  // addi x3, x0, 3
        prog[3]  = 32'h00700213;  // addi x4, x0, 7
        prog[4]  = 32'h00100293;  // addi x5, x0, 1
        prog[5]  = 32'hFFF00313;  // addi x6, x0, -1

        // T1: BEQ x1, x2, +8 (taken)
        prog[6]  = 32'h00208463;
        prog[7]  = 32'h06300A13;  // x20 = 99 (skip)
        prog[8]  = 32'h06300A93;  // x21 = 99 (skip)
        prog[9]  = 32'h00100A13;  // x20 = 1

        // T2: BNE x1, x2, +8 (not taken)
        prog[10] = 32'h00209463;
        prog[11] = 32'h01500A93;  // x21 = 21
        prog[12] = 32'h01600B13;  // x22 = 22
        prog[13] = 32'h01700B93;  // x23 = 23

        // T3: BEQ x3, x4, +8 (not taken)
        prog[14] = 32'h00418463;
        prog[15] = 32'h01800C13;  // x24 = 24
        prog[16] = 32'h01900C93;  // x25 = 25
        prog[17] = 32'h01A00D13;  // x26 = 26

        // T4: BNE x3, x4, +8 (taken)
        prog[18] = 32'h00419463;
        prog[19] = 32'h06300D93;  // skip
        prog[20] = 32'h06300E13;  // skip
        prog[21] = 32'h01B00D93;  // x27 = 27

        // T5: BLT x1, x4, +8 (taken, 5 < 7)
        prog[22] = 32'h0040C463;
        prog[23] = 32'h06300E13;  // skip
        prog[24] = 32'h06300E93;  // skip
        prog[25] = 32'h01C00E13;  // x28 = 28

        // T6: BGE x1, x4, +8 (not taken)
        prog[26] = 32'h0040D463;
        prog[27] = 32'h01D00E93;  // x29 = 29
        prog[28] = 32'h01E00F13;  // x30 = 30
        prog[29] = 32'h01F00F93;  // x31 = 31

        // T7: BLTU x5, x6, +8 (taken, 1 < huge unsigned)
        prog[30] = 32'h0062E463;
        prog[31] = 32'h06300393;  // skip
        prog[32] = 32'h06300413;  // skip
        prog[33] = 32'h00700393;  // x7 = 7

        // T8: BGEU x5, x6, +8 (not taken)
        prog[34] = 32'h0062F463;
        prog[35] = 32'h00800413;  // x8 = 8
        prog[36] = 32'h00900493;  // x9 = 9
        prog[37] = 32'h00A00513;  // x10 = 10

        // T9: JAL x11, +16 (skip 4)
        prog[38] = 32'h010005EF;
        prog[39] = 32'h06300613;  // skip
        prog[40] = 32'h06300693;  // skip
        prog[41] = 32'h06300713;  // skip
        prog[42] = 32'h00C00613;  // x12 = 12 (target)

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (500) @(posedge clk);

        $display("--- Branch results ---");
        dbg_rs = 5'd20; #5; $display("x20 = %0d (BEQ taken, expect 1)", dbg_arch_rd);
        dbg_rs = 5'd21; #5; $display("x21 = %0d (BNE not-taken, expect 21)", dbg_arch_rd);
        dbg_rs = 5'd22; #5; $display("x22 = %0d (expect 22)", dbg_arch_rd);
        dbg_rs = 5'd23; #5; $display("x23 = %0d (expect 23)", dbg_arch_rd);
        dbg_rs = 5'd24; #5; $display("x24 = %0d (BEQ not-taken, expect 24)", dbg_arch_rd);
        dbg_rs = 5'd25; #5; $display("x25 = %0d (expect 25)", dbg_arch_rd);
        dbg_rs = 5'd26; #5; $display("x26 = %0d (expect 26)", dbg_arch_rd);
        dbg_rs = 5'd27; #5; $display("x27 = %0d (BNE taken, expect 27)", dbg_arch_rd);
        dbg_rs = 5'd28; #5; $display("x28 = %0d (BLT taken, expect 28)", dbg_arch_rd);
        dbg_rs = 5'd29; #5; $display("x29 = %0d (BGE not-taken, expect 29)", dbg_arch_rd);
        dbg_rs = 5'd30; #5; $display("x30 = %0d (expect 30)", dbg_arch_rd);
        dbg_rs = 5'd31; #5; $display("x31 = %0d (expect 31)", dbg_arch_rd);
        dbg_rs = 5'd7;  #5; $display("x7  = %0d (BLTU taken, expect 7)", dbg_arch_rd);
        dbg_rs = 5'd8;  #5; $display("x8  = %0d (BGEU not-taken, expect 8)", dbg_arch_rd);
        dbg_rs = 5'd9;  #5; $display("x9  = %0d (expect 9)", dbg_arch_rd);
        dbg_rs = 5'd10; #5; $display("x10 = %0d (expect 10)", dbg_arch_rd);
        dbg_rs = 5'd11; #5; $display("x11 = %0d (JAL link, expect 156)", dbg_arch_rd);
        dbg_rs = 5'd12; #5; $display("x12 = %0d (JAL target, expect 12)", dbg_arch_rd);
        $display("final pc = %h", dbg_pcu_pc);
        $finish;
    end
endmodule
