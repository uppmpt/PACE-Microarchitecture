// Minimal wrapper TB for top_pace_mem.
// Feeds NOPs, drives DRAM/MMIO ready, observes PC.
`timescale 1ns/1ps

module tb_pace_mem_min;
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

    // Instruction memory: always return NOPs
    always @(*) begin
        imem_instr = {6{32'h00000013}};
    end

    initial begin
        $display("=== PACE mem minimal TB ===");
        rst_n = 0;
        i_instr_count = 4'd1;
        dbg_rs = 5'd0;
        dram_rdata = 512'd0;
        dram_ready = 1;
        mmio_rdata = 64'd0;
        mmio_ready = 1;

        #30 rst_n = 1;

        for (cycle = 0; cycle < 200; cycle = cycle + 1) begin
            @(posedge clk);
            if (cycle % 20 == 0) begin
                $display("cycle=%0d pc=%h satp_en=%b",
                         cycle, dbg_pcu_pc, dbg_satp_en);
            end
        end

        $display("=== DONE, final pc=%h ===", dbg_pcu_pc);
        $finish;
    end
endmodule
