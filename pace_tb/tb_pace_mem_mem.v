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
// Memory test for top_pace_mem (M-mode, MMU bypass path).
// Program: write 42 to DRAM[0x100], read back, mark done.
`timescale 1ns/1ps

module tb_pace_mem_mem;
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

    reg [7:0] mem [0:4095];   // 4 KB byte-addressable
    integer i, cycle;
    reg [31:0] prog [0:15];

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
            if (idx < 16) get_word = prog[idx];
            else          get_word = 32'h00000013;  // NOP
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

    // DRAM: 1-cycle latency, byte-addressable, 64-bit accesses
    always @(posedge clk) begin
        dram_ready <= 0;
        if (dram_req) begin
            if (dram_we) begin
                for (i = 0; i < 8; i = i + 1)
                    mem[dram_addr[11:0] + i] <= dram_wdata[i*8 +: 8];
            end else begin
                for (i = 0; i < 8; i = i + 1)
                    dram_rdata[i*8 +: 8] <= mem[dram_addr[11:0] + i];
            end
            dram_ready <= 1;
        end
    end

    initial begin
        $display("=== PACE mem memory test ===");

        prog[0]  = 32'h02A00093;  // addi x1, x0, 42
        prog[1]  = 32'h10103023;  // sd   x1, 0x100(x0)
        prog[2]  = 32'h10003103;  // ld   x2, 0x100(x0)
        prog[3]  = 32'h00100193;  // addi x3, x0, 1
        prog[4]  = 32'h00000013;
        prog[5]  = 32'h00000013;
        prog[6]  = 32'h00000013;
        prog[7]  = 32'h00000013;
        prog[8]  = 32'h00000013;
        prog[9]  = 32'h00000013;
        prog[10] = 32'h00000013;
        prog[11] = 32'h00000013;
        prog[12] = 32'h00000013;
        prog[13] = 32'h00000013;
        prog[14] = 32'h00000013;
        prog[15] = 32'h00000013;

        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'h00;

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (600) @(posedge clk);

        dbg_rs = 5'd1; #10;
        $display("x1 = %0d (expect 42)", dbg_arch_rd);
        dbg_rs = 5'd2; #10;
        $display("x2 = %0d (expect 42)", dbg_arch_rd);
        dbg_rs = 5'd3; #10;
        $display("x3 = %0d (expect 1)",  dbg_arch_rd);

        $display("mem[0x100..107] = %02x %02x %02x %02x %02x %02x %02x %02x",
                 mem[12'h100], mem[12'h101], mem[12'h102], mem[12'h103],
                 mem[12'h104], mem[12'h105], mem[12'h106], mem[12'h107]);
        $display("final pc = %h", dbg_pcu_pc);
        $finish;
    end
endmodule
