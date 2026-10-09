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
// TB for top_pace_mem: feeds a small ALU program and checks result.
`timescale 1ns/1ps

module tb_pace_mem_alu;
    reg clk = 0, rst_n = 0;
    wire [63:0] imem_pc;
    reg  [191:0] imem_instr;
    reg  [3:0]  i_instr_count;

    wire        dram_req, dram_we;
    wire [63:0] dram_addr, dram_wdata;
    reg  [511:0] dram_rdata;
    reg         dram_ready;

    wire        mmio_req, mmio_we;
    wire [63:0] mmio_addr, mmio_wdata;
    reg  [63:0] mmio_rdata;
    reg         mmio_ready;

    wire [63:0] dbg_arch_rd, dbg_pcu_pc, dbg_satp;
    wire        dbg_satp_en;
    reg  [4:0]  dbg_rs;

    integer cycle;

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

    // Instruction memory: 6 lanes. Only lane 0 gets real instr;
    // others = NOP (32'h00000013).
    reg [31:0] prog [0:15];
    always @(*) begin
        automatic integer word_idx;
        // imem_pc is byte address. Word index = pc / 4.
        // Build 6 lanes starting at pc/4.
        imem_instr[31:0]    = program_word(imem_pc);
        imem_instr[63:32]   = program_word(imem_pc + 4);
        imem_instr[95:64]   = program_word(imem_pc + 8);
        imem_instr[127:96]  = program_word(imem_pc + 12);
        imem_instr[159:128] = program_word(imem_pc + 16);
        imem_instr[191:160] = program_word(imem_pc + 20);
    end

    function [31:0] program_word;
        input [63:0] pc;
        integer idx;
        begin
            idx = pc >> 2;
            if (idx < 16) program_word = prog[idx];
            else          program_word = 32'h00000013;  // NOP
        end
    endfunction

    initial begin
        $display("=== PACE mem ALU TB ===");

        // Program (little-endian, at byte address 0)
        prog[0] = 32'h00500093;  // addi x1, x0, 5
        prog[1] = 32'h00300113;  // addi x2, x0, 3
        prog[2] = 32'h002081B3;  // add  x3, x1, x2  -> 8
        prog[3] = 32'h00000013;  // nop
        prog[4] = 32'h00000013;  // nop
        prog[5] = 32'h00000013;  // nop
        prog[6] = 32'h00000013;  // nop
        prog[7] = 32'h00000013;  // nop
        prog[8] = 32'h00000013;
        prog[9] = 32'h00000013;
        prog[10]= 32'h00000013;
        prog[11]= 32'h00000013;
        prog[12]= 32'h00000013;
        prog[13]= 32'h00000013;
        prog[14]= 32'h00000013;
        prog[15]= 32'h00000013;

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 1;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;

        // Run a while to let PCU compute values
        repeat (300) @(posedge clk);

        // Read x1, x2, x3
        dbg_rs = 5'd1; #10;
        $display("x1 = %0d (expect 5)", dbg_arch_rd);
        dbg_rs = 5'd2; #10;
        $display("x2 = %0d (expect 3)", dbg_arch_rd);
        dbg_rs = 5'd3; #10;
        $display("x3 = %0d (expect 8)", dbg_arch_rd);
        $display("final pc = %h", dbg_pcu_pc);

        $finish;
    end
endmodule
