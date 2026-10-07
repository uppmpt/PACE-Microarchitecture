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
module tb_pace_mem_workload;
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
    reg [31:0] prog [0:511];
    reg [7:0]  mem  [0:4095];
    integer i;

    integer total_cycles, cycles_after_reset;
    integer shdw_empty_cycles, shdw_partial_cycles, shdw_full_cycles;
    integer instr_retired, pcu_writes;

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
            if (idx < 512) get_word = prog[idx];
            else           get_word = 32'h00000013;
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

    // DRAM: byte-addressable, 1-cycle latency
    always @(posedge clk) begin
        dram_ready <= 0;
        if (dram_req) begin
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

    always @(posedge clk) begin
        total_cycles = total_cycles + 1;
        if (rst_n) begin
            cycles_after_reset = cycles_after_reset + 1;
            case (dut.shdw_rd_valid)
                4'b0000: shdw_empty_cycles   = shdw_empty_cycles   + 1;
                4'b1111: shdw_full_cycles    = shdw_full_cycles    + 1;
                default: shdw_partial_cycles = shdw_partial_cycles + 1;
            endcase
            instr_retired = instr_retired
                          + dut.rf_we[0] + dut.rf_we[1]
                          + dut.rf_we[2] + dut.rf_we[3];
            pcu_writes = pcu_writes
                       + dut.pcu_shdw_we[0] + dut.pcu_shdw_we[1]
                       + dut.pcu_shdw_we[2] + dut.pcu_shdw_we[3]
                       + dut.pcu_shdw_we[4] + dut.pcu_shdw_we[5];
        end
    end

    initial begin
        $display("=== PACE workload test (memory + branch) ===");
        for (i = 0; i < 512; i = i + 1) prog[i] = 32'h00000013;
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'h00;
        $readmemh("workload.hex", prog);

        total_cycles = 0;
        cycles_after_reset = 0;
        shdw_empty_cycles = 0;
        shdw_partial_cycles = 0;
        shdw_full_cycles = 0;
        instr_retired = 0;
        pcu_writes = 0;

        rst_n = 0;
        i_instr_count = 4'd3;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (3000) @(posedge clk);

        $display("--- WORKLOAD MEASUREMENT ---");
        $display("total cycles             : %0d", total_cycles);
        $display("cycles after reset       : %0d", cycles_after_reset);
        $display("shadow empty cycles      : %0d", shdw_empty_cycles);
        $display("shadow partial cycles    : %0d", shdw_partial_cycles);
        $display("shadow full cycles       : %0d", shdw_full_cycles);
        $display("instr retired (rf_we)    : %0d", instr_retired);
        $display("PCU writes to shadow     : %0d", pcu_writes);
        if (cycles_after_reset > 0) begin
            $display("IPC                      : %0d / %0d = %0d.%02d",
                     instr_retired, cycles_after_reset,
                     instr_retired / cycles_after_reset,
                     (instr_retired * 100 / cycles_after_reset) % 100);
            $display("shadow empty %%           : %0d%%", shdw_empty_cycles * 100 / cycles_after_reset);
            $display("shadow full %%            : %0d%%", shdw_full_cycles  * 100 / cycles_after_reset);
        end
        $display("mem[0x100..0x127] = %02x %02x %02x %02x ...",
                 mem[12'h100], mem[12'h101], mem[12'h102], mem[12'h103]);
        $display("final pc = %h", dbg_pcu_pc);
        $finish;
    end
endmodule
