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
// Load/Store width test: sb/sh/sw/sd + lb/lbu/lh/lhu/lw/lwu/ld
`timescale 1ns/1ps
module tb_pace_mem_ldst;
    reg clk = 0, rst_n = 0;
    wire [63:0]  imem_pc;
    reg  [191:0] imem_instr;
    reg  [3:0]   i_instr_count;
    wire         dram_req, dram_we;
    wire [63:0]  dram_addr, dram_wdata;
    reg  [511:0] dram_rdata;
    wire [7:0]   dram_be;
    reg          dram_ready;
    wire         mmio_req, mmio_we;
    wire [63:0]  mmio_addr, mmio_wdata;
    reg  [63:0]  mmio_rdata;
    reg          mmio_ready;
    wire [63:0]  dbg_arch_rd, dbg_pcu_pc, dbg_satp;
    wire         dbg_satp_en;
    reg  [4:0]   dbg_rs;
    reg [31:0] prog [0:31];
    reg [7:0] mem [0:4095];
    integer i;

    top_pace_mem dut (
        .clk(clk), .rst_n(rst_n),
        .imem_pc(imem_pc), .imem_instr(imem_instr),
        .i_instr_count(i_instr_count),
        .dram_req(dram_req), .dram_we(dram_we),
        .dram_addr(dram_addr), .dram_wdata(dram_wdata),
        .dram_rdata(dram_rdata), .dram_ready(dram_ready),
        .dram_be(dram_be),
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
            if (idx < 32) get_word = prog[idx];
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
        if (dram_req) begin
            if (dram_we) $display("[WR] addr=%h be=%h wdata=%h", dram_addr, dram_be, dram_wdata);
            if (dram_we) begin
                for (i = 0; i < 8; i = i + 1)
                    if (dram_be[i]) mem[dram_addr[11:0] + i] <= dram_wdata[i*8 +: 8];
            end else begin
                for (i = 0; i < 8; i = i + 1)
                    dram_rdata[i*8 +: 8] <= mem[dram_addr[11:0] + i];
            end
            dram_ready <= 1;
        end
    end

    initial begin
        $display("=== PACE LD/ST width test ===");
        for (i = 0; i < 32; i = i + 1) prog[i] = 32'h00000013;
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'h00;

        prog[0]  = 32'h10000093;  // addi x1, x0, 0x100   base
        prog[1]  = 32'hFFF00113;  // addi x2, x0, -1
        prog[2]  = 32'h02A00193;  // addi x3, x0, 42
        prog[3]  = 32'h00308023;  // sd x3, 0(x1)
        prog[4]  = 32'h0000B203;  // ld x4, 0(x1)        → 42
        prog[5]  = 32'h00100293;  // addi x5, x0, 1      marker
        prog[6]  = 32'h0020B423;  // sd x2, 8(x1)        all 1s
        prog[7]  = 32'h00808303;  // lb x6, 8(x1)        → -1
        prog[8]  = 32'h0080C383;  // lbu x7, 8(x1)       → 255
        prog[9]  = 32'h00809403;  // lh x8, 8(x1)        → -1
        prog[10] = 32'h0080D483;  // lhu x9, 8(x1)       → 65535
        prog[11] = 32'h0080A503;  // lw x10, 8(x1)       → -1
        prog[12] = 32'h0080E583;  // lwu x11, 8(x1)      → 0xFFFFFFFF
        prog[13] = 32'h0020B823;  // sd x2, 16(x1)       all 1s
        prog[14] = 32'h00700613;  // addi x12, x0, 7
        prog[15] = 32'h00C0A823;  // sw x12, 16(x1)
        prog[16] = 32'h0100A683;  // lw x13, 16(x1)      → 7
        prog[17] = 32'h0140A703;  // lw x14, 20(x1)      → -1
        prog[18] = 32'h0020BC23;  // sd x2, 24(x1)       all 1s
        prog[19] = 32'h00900793;  // addi x15, x0, 9
        prog[20] = 32'h00F09C23;  // sh x15, 24(x1)
        prog[21] = 32'h01809803;  // lh x16, 24(x1)      → 9
        prog[22] = 32'h01A09883;  // lh x17, 26(x1)      → -1
        prog[23] = 32'h0220B023;  // sd x2, 32(x1)       all 1s
        prog[24] = 32'h00500913;  // addi x18, x0, 5
        prog[25] = 32'h03208023;  // sb x18, 32(x1)
        prog[26] = 32'h02008983;  // lb x19, 32(x1)      → 5
        prog[27] = 32'h02108A03;  // lb x20, 33(x1)      → -1

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (2000) @(posedge clk);

        $display("--- results (expected in comment) ---");
        dbg_rs=5'd4;  #5; $display("x4  = %h  (000000000000002a)", dbg_arch_rd);
        dbg_rs=5'd6;  #5; $display("x6  = %h  (ffffffffffffffff)", dbg_arch_rd);
        dbg_rs=5'd7;  #5; $display("x7  = %h  (00000000000000ff)", dbg_arch_rd);
        dbg_rs=5'd8;  #5; $display("x8  = %h  (ffffffffffffffff)", dbg_arch_rd);
        dbg_rs=5'd9;  #5; $display("x9  = %h  (000000000000ffff)", dbg_arch_rd);
        dbg_rs=5'd10; #5; $display("x10 = %h  (ffffffffffffffff)", dbg_arch_rd);
        dbg_rs=5'd11; #5; $display("x11 = %h  (00000000ffffffff)", dbg_arch_rd);
        dbg_rs=5'd13; #5; $display("x13 = %h  (0000000000000007)", dbg_arch_rd);
        dbg_rs=5'd14; #5; $display("x14 = %h  (ffffffffffffffff)", dbg_arch_rd);
        dbg_rs=5'd16; #5; $display("x16 = %h  (0000000000000009)", dbg_arch_rd);
        dbg_rs=5'd17; #5; $display("x17 = %h  (ffffffffffffffff)", dbg_arch_rd);
        dbg_rs=5'd19; #5; $display("x19 = %h  (0000000000000005)", dbg_arch_rd);
        dbg_rs=5'd20; #5; $display("x20 = %h  (ffffffffffffffff)", dbg_arch_rd);
        $display("final pc = %h", dbg_pcu_pc);
        $display("[MQ] pushes=%%0d pops=%%0d drops=%%0d", dut.u_mq.dbg_pushes, dut.u_mq.dbg_pops, dut.u_mq.dbg_drops);
        $finish;
    end
endmodule
