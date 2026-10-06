// CSR/trap test for top_pace_mem.
// Tests csrw/csrr, mtvec setup, ecall trap, mcause/mepc read, mret return.
`timescale 1ns/1ps
module tb_pace_mem_csr;
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
    reg [31:0] prog [0:127];

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
            if (idx < 128) get_word = prog[idx];
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

    always @(posedge clk) begin
        dram_ready <= 0;
        if (dram_req) dram_ready <= 1;
    end

    initial begin
        integer i;
        $display("=== PACE CSR/trap test ===");
        for (i = 0; i < 128; i = i + 1) prog[i] = 32'h00000013;

        // --- Main program (starts at 0x0) ---
        prog[0]  = 32'h10000093;  // addi x1, x0, 0x100      → x1 = 0x100 (handler)
        prog[1]  = 32'h30509073;  // csrw mtvec, x1          → mtvec = 0x100
        prog[2]  = 32'h04200113;  // addi x2, x0, 0x42       → x2 = 0x42
        prog[3]  = 32'h34011073;  // csrw mscratch, x2       → mscratch = 0x42
        prog[4]  = 32'h340021F3;  // csrr x3, mscratch       → x3 = 0x42
        prog[5]  = 32'h00100213;  // addi x4, x0, 1          → x4 = 1 (before ecall)
        prog[6]  = 32'h00000073;  // ecall                    → TRAP
        prog[7]  = 32'h00200293;  // addi x5, x0, 2          → x5 = 2 (after return)
        prog[8]  = 32'h00300313;  // addi x6, x0, 3          → x6 = 3 (end)

        // --- Handler at 0x100 (word index 64) ---
        prog[64] = 32'h342023F3;  // csrr x7, mcause         → x7 = 11 (ecall_M)
        prog[65] = 32'h34102473;  // csrr x8, mepc           → x8 = ecall pc
        prog[66] = 32'h00440413;  // addi x8, x8, 4          → x8 = ecall pc + 4
        prog[67] = 32'h34141073;  // csrw mepc, x8           → mepc = x8
        prog[68] = 32'h30200073;  // mret                    → return

        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 0;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;
        repeat (1000) @(posedge clk);

        $display("--- results ---");
        dbg_rs=5'd3; #5; $display("x3 = %h  (expect 0000000000000042 — mscratch read)", dbg_arch_rd);
        dbg_rs=5'd4; #5; $display("x4 = %h  (expect 0000000000000001 — before ecall)", dbg_arch_rd);
        dbg_rs=5'd5; #5; $display("x5 = %h  (expect 0000000000000002 — after mret)", dbg_arch_rd);
        dbg_rs=5'd6; #5; $display("x6 = %h  (expect 0000000000000003 — end)", dbg_arch_rd);
        dbg_rs=5'd7; #5; $display("x7 = %h  (expect 000000000000000b — mcause ecall_M)", dbg_arch_rd);
        $display("final pc = %h", dbg_pcu_pc);
        $finish;
    end
endmodule
