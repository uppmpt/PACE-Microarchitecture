// JALR test for top_pace_mem.
// jalr x2, x1, 0  → jumps to x1, link = pc+4 into x2
`timescale 1ns/1ps

module tb_pace_mem_jalr;
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
        $display("=== PACE JALR test ===");
        for (i = 0; i < 16; i = i + 1) prog[i] = 32'h00000013;

        // Test: jalr x2, x1, 0
        prog[0] = 32'h02000093;  // addi x1, x0, 32       → x1 = 32 (target addr)
        prog[1] = 32'h00008167;  // jalr x2, x1, 0        → x2 = 8 (link), PC = 32
        prog[2] = 32'h06300193;  // addi x3, x0, 99       → SKIPPED
        prog[3] = 32'h06300213;  // addi x4, x0, 99       → SKIPPED
        prog[4] = 32'h00000013;
        prog[5] = 32'h00000013;
        prog[6] = 32'h00000013;
        prog[7] = 32'h00000013;
        prog[8] = 32'h03700293;  // addi x5, x0, 55       → x5 = 55 (target)

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (300) @(posedge clk);

        dbg_rs = 5'd1; #5; $display("x1 = %0d (expect 32)", dbg_arch_rd);
        dbg_rs = 5'd2; #5; $display("x2 = %0d (expect 8 — link)", dbg_arch_rd);
        dbg_rs = 5'd3; #5; $display("x3 = %0d (expect 0 — skipped)", dbg_arch_rd);
        dbg_rs = 5'd4; #5; $display("x4 = %0d (expect 0 — skipped)", dbg_arch_rd);
        dbg_rs = 5'd5; #5; $display("x5 = %0d (expect 55 — target)", dbg_arch_rd);
        $display("final pc = %h", dbg_pcu_pc);
        $finish;
    end
endmodule
