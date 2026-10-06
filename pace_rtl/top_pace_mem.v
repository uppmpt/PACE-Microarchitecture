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
module top_pace_mem #(parameter HART_ID = 0) (
    input  wire clk, rst_n,
    input  wire [3:0] i_instr_count,
    output wire [63:0] imem_pc,
    input  wire [6*32-1:0] imem_instr,
    // DRAM (backing)
    output wire        dram_req, dram_we,
    output wire [63:0] dram_addr,
    output wire [511:0] dram_wdata,
    output wire [7:0]   dram_be,
    input  wire [511:0] dram_rdata,
    input  wire        dram_ready,
    // MMIO
    output wire        mmio_req, mmio_we,
    output wire [63:0] mmio_addr, mmio_wdata,
    input  wire [63:0] mmio_rdata,
    input  wire        mmio_ready,
    input  wire i_mtip, i_msip, i_meip, i_seip, i_stip, i_ssip,
    input  wire [4:0] dbg_rs,
    output wire [63:0] dbg_arch_rd,
    output wire [63:0] dbg_pcu_pc,
    output wire [63:0] dbg_satp,
    output wire dbg_satp_en
);
    // ===== Boot =====
    wire rst_n_pcu, rst_n_ao, boot_done;
    boot_sequencer #(.SCOUT_AHEAD_CYCLES(16)) u_boot (
        .clk(clk), .rst_n(rst_n),
        .rst_n_pcu(rst_n_pcu), .rst_n_ao(rst_n_ao), .boot_done(boot_done)
    );

    // ===== PCU I/O =====
    wire [63:0] pcu_pc;
    wire [5:0]  pcu_shdw_we;
    wire [6*5-1:0] pcu_shdw_rd;
    wire [6*64-1:0] pcu_shdw_data;
    wire        pcu_br_v, pcu_br_t;
    wire [63:0] pcu_br_tgt;
    wire        redir_v;
    wire [63:0] redir_pc;
    wire [7:0]  pcu_vl;
    wire [63:0] pcu_vtype;
    wire [1:0]  priv_mode;
    wire [63:0] satp_w;
    wire        satp_en_w;
    wire        flush_tlb_w;
    wire        trap_taken_w;
    wire [2:0]  adv;
    wire        flush_fetch;
    wire [63:0] new_pc;

    // ===== MC I/O =====
    wire        mc_shdw_we, mc_shdw_exc;
    wire [4:0]  mc_shdw_rd;
    wire [63:0] mc_shdw_data;
    wire        mc_ext_wr_en;
    wire [4:0]  mc_ext_wr_addr;
    wire [63:0] mc_ext_wr_data;
    wire        mc_req, mc_we;
    wire [63:0] mc_addr, mc_wdata, mc_rdata;
    wire        mc_ready;
    wire        mc_page_fault;
    wire [63:0] mc_fault_cause, mc_fault_va;

    // ===== Mem Queue =====
    wire        mq_push_en, mq_full;
    wire [2:0]  mq_push_op;
    wire [63:0] mq_push_addr, mq_push_rs2;
    wire [4:0]  mq_push_rd, mq_push_amo_f5;
    wire [2:0]  mq_push_funct3;
    wire        mq_pop_en, mq_pop_valid;
    wire [2:0]  mq_op;
    wire [63:0] mq_addr, mq_rs2;
    wire [4:0]  mq_rd, mq_amo_f5;
    wire [2:0]  mq_funct3;

    // ===== L1d <-> L2 =====
    wire        l1d_l2_req, l1d_l2_we, l1d_l2_ready;
    wire [63:0] l1d_l2_addr, l1d_l2_wdata;
    wire [511:0] l1d_l2_rdata;
    wire        l1d_pte_req, l1d_pte_ready;
    wire [63:0] l1d_pte_addr, l1d_pte_rdata;

    // ===== L2 DRAM port =====
    wire        l2_dram_req, l2_dram_we;
    wire [63:0] l2_dram_addr;
    wire [511:0] l2_dram_wdata;
    wire [511:0] l2_dram_rdata;
    wire        l2_dram_ready;

    wire [511:0] l2_p1_rdata;
    wire        l2_p1_ready;

    // ===== Bypass: M-mode bare → MC direto pra DRAM =====
    wire mmu_bypass = !(satp_en_w && (priv_mode != 2'b11));
    wire mc_dram_req = mc_req && mmu_bypass;
    wire [7:0] mc_be;
    wire l1d_req     = mc_req && !mmu_bypass;
    wire [63:0] l1d_rdata;
    wire        l1d_ready;

    // MC ready/rdata: mux entre bypass e L1d
    assign mc_ready = mmu_bypass ? dram_ready : l1d_ready;
    assign mc_rdata = mmu_bypass ? dram_rdata[63:0] : l1d_rdata;

    // DRAM port mux: MC-direct tem prioridade
    assign dram_req   = mc_dram_req | l2_dram_req;
    assign dram_we    = mc_dram_req ? mc_we : l2_dram_we;
    assign dram_addr  = mc_dram_req ? mc_addr : l2_dram_addr;
    assign dram_wdata = mc_dram_req ? {448'b0, mc_wdata} : l2_dram_wdata;
    assign dram_be    = mc_dram_req ? mc_be : 8'hFF;
    assign l2_dram_rdata = dram_rdata;

    // ===== Instâncias =====
    mem_queue #(.DEPTH(8)) u_mq (
        .clk(clk), .rst_n(rst_n_pcu),
        .push_en(mq_push_en), .push_op(mq_push_op),
        .push_addr(mq_push_addr), .push_rs2(mq_push_rs2),
        .push_rd(mq_push_rd), .push_funct3(mq_push_funct3),
        .push_amo_f5(mq_push_amo_f5),
        .push_ready(), .full(mq_full),
        .pop_en(mq_pop_en), .pop_op(mq_op),
        .pop_addr(mq_addr), .pop_rs2(mq_rs2),
        .pop_rd(mq_rd), .pop_funct3(mq_funct3),
        .pop_amo_f5(mq_amo_f5),
        .pop_valid(mq_pop_valid)
    );

    pcu6_v #(.HART_ID(HART_ID)) u_pcu (
        .clk(clk), .rst_n(rst_n_pcu),
        .stall(1'b0), .fetch_stall(1'b0), .shdw_wr_ready(4'd6),
        .instr_count(i_instr_count), .instr_in(imem_instr),
        .pc_out(pcu_pc),
        .shadow_we(pcu_shdw_we), .shadow_rd(pcu_shdw_rd),
        .shadow_data(pcu_shdw_data), .num_writes(),
        .br_valid(pcu_br_v), .br_taken(pcu_br_t), .br_target(pcu_br_tgt),
        .redirect_valid(redir_v), .redirect_pc(redir_pc),
        .ext_wr_en(mc_ext_wr_en), .ext_wr_addr(mc_ext_wr_addr), .ext_wr_data(mc_ext_wr_data),
        .dbg_priv(priv_mode), .dbg_satp(satp_w), .dbg_satp_enable(satp_en_w),
        .dbg_flush_tlb(flush_tlb_w), .dbg_trap_taken(trap_taken_w),
        .dbg_advance(adv), .dbg_flush_fetch(flush_fetch), .dbg_new_pc(new_pc),
        .i_mtip(i_mtip), .i_msip(i_msip), .i_meip(i_meip),
        .i_seip(i_seip), .i_stip(i_stip), .i_ssip(i_ssip),
        .dbg_vl(pcu_vl), .dbg_vtype(pcu_vtype), .dbg_vrs(5'd0), .dbg_vrd(),
        .mq_push_en(mq_push_en), .mq_push_op(mq_push_op),
        .mq_push_addr(mq_push_addr), .mq_push_rs2(mq_push_rs2),
        .mq_push_rd(mq_push_rd), .mq_push_funct3(mq_push_funct3),
        .mq_push_amo_f5(mq_push_amo_f5), .mq_full(mq_full),
        .vmem_req(), .vmem_we(), .vmem_addr(), .vmem_wdata(),
        .vmem_rdata(64'd0), .vmem_ready(1'b0)
    );
    assign imem_pc = pcu_pc;

    b_core u_bc (
        .clk(clk), .rst_n(rst_n_pcu),
        .br_valid(pcu_br_v), .br_taken(pcu_br_t),
        .br_target(pcu_br_tgt), .br_pc(pcu_pc),
        .redirect_valid(redir_v), .redirect_pc(redir_pc)
    );

    m_core u_mc (
        .clk(clk), .rst_n(rst_n_pcu),
        .mq_full(mq_full), .mq_pop_valid(mq_pop_valid), .mq_pop_en(mq_pop_en),
        .mq_op(mq_op), .mq_addr(mq_addr), .mq_rs2(mq_rs2),
        .mq_rd(mq_rd), .mq_funct3(mq_funct3), .mq_amo_f5(mq_amo_f5),
        .shadow_we(mc_shdw_we), .shadow_rd(mc_shdw_rd),
        .shadow_data(mc_shdw_data), .shadow_exc(mc_shdw_exc),
        .ext_wr_en(mc_ext_wr_en), .ext_wr_addr(mc_ext_wr_addr),
        .ext_wr_data(mc_ext_wr_data),
        .mem_req(mc_req), .mem_we(mc_we),
        .mem_addr(mc_addr), .mem_wdata(mc_wdata),
        .mem_be(mc_be),
        .mem_rdata(mc_rdata), .mem_ready(mc_ready),
        .dbg_rs(5'd0), .dbg_rd()
    );

    wire [6*72-1:0] pcu_shdw_pack;
    genvar gk;
    generate
        for (gk = 0; gk < 6; gk = gk + 1) begin : g_pack
            assign pcu_shdw_pack[gk*72 +: 72] =
                {3'b0, pcu_shdw_rd[gk*5 +: 5], pcu_shdw_data[gk*64 +: 64]};
        end
    endgenerate

    wire [3:0] shdw_wr_ready;
    wire [4*72-1:0] shdw_rd_data;
    wire [3:0] shdw_rd_valid;
    wire [3:0] ao_rd_en;

    shadow_rf_multi #(.DEPTH(32), .DATA_WIDTH(72), .N_READ(4), .N_WRITE(6)) u_shdw (
        .clk(clk), .rst_n(rst_n_pcu),
        .wr_en(pcu_shdw_we), .wr_data(pcu_shdw_pack), .wr_exception(6'b0),
        .wr_ready(shdw_wr_ready), .wr_full(),
        .rd_en(ao_rd_en), .rd_data(shdw_rd_data),
        .rd_valid(shdw_rd_valid), .rd_empty(),
        .dbg_wr_ptr(), .dbg_rd_ptr()
    );

    wire [3:0] rf_we;
    wire [4*5-1:0] rf_rd;
    wire [4*64-1:0] rf_wd;

    ao_core_multi #(.N_AO(4)) u_ao (
        .clk(clk), .rst_n(rst_n_ao),
        .shdw_data(shdw_rd_data), .shdw_valid(shdw_rd_valid),
        .shdw_rd_en(ao_rd_en),
        .rf_we(rf_we), .rf_rd(rf_rd), .rf_wd(rf_wd)
    );

    register_file_multi #(.N_WRITE(4)) u_arf (
        .clk(clk), .rst_n(rst_n_ao),
        .we(rf_we), .rd(rf_rd), .wd(rf_wd),
        .rs1(5'd0), .rs2(5'd0), .rd1(), .rd2(),
        .dbg_rs(dbg_rs), .dbg_rd(dbg_arch_rd)
    );

    l1d_mmu u_l1d (
        .clk(clk), .rst_n(rst_n_pcu),
        .cpu_req(l1d_req), .cpu_we(mc_we),
        .cpu_addr_va(mc_addr), .cpu_wdata(mc_wdata),
        .cpu_rdata(l1d_rdata), .cpu_ready(l1d_ready),
        .flush(flush_tlb_w), .priv(priv_mode), .asid(9'd0),
        .satp_ppn(satp_w[43:0]), .satp_enable(satp_en_w),
        .l2_req(l1d_l2_req), .l2_we(l1d_l2_we),
        .l2_addr(l1d_l2_addr), .l2_wdata(l1d_l2_wdata),
        .l2_rdata(l1d_l2_rdata), .l2_ready(l1d_l2_ready),
        .mmio_req(mmio_req), .mmio_we(mmio_we),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_rdata(mmio_rdata), .mmio_ready(mmio_ready),
        .pte_req(l1d_pte_req), .pte_addr(l1d_pte_addr),
        .pte_rdata(l1d_pte_rdata), .pte_ready(l1d_pte_ready),
        .page_fault(mc_page_fault),
        .fault_cause(mc_fault_cause), .fault_va(mc_fault_va)
    );

    // L2 arbiter: p1 = PTE ou L1d line
    wire pte_sel = l1d_pte_req;
    wire [63:0] l2_p1_addr = pte_sel ? l1d_pte_addr : l1d_l2_addr;
    wire        l2_p1_req  = pte_sel ? l1d_pte_req  : l1d_l2_req;
    wire        l2_p1_we   = pte_sel ? 1'b0         : l1d_l2_we;
    wire [511:0] l2_p1_wdata = {448'b0, l1d_l2_wdata[63:0]};

    l2 u_l2 (
        .clk(clk), .rst_n(rst_n_pcu),
        .p0_req(1'b0), .p0_addr(64'd0), .p0_rdata(), .p0_ready(),
        .p1_req(l2_p1_req), .p1_we(l2_p1_we),
        .p1_addr(l2_p1_addr), .p1_wdata(l2_p1_wdata),
        .p1_rdata(l2_p1_rdata), .p1_ready(l2_p1_ready),
        .mem_req(l2_dram_req), .mem_we(l2_dram_we),
        .mem_addr(l2_dram_addr), .mem_wdata(l2_dram_wdata),
        .mem_rdata(l2_dram_rdata), .mem_ready(l2_dram_ready)
    );

    assign l2_dram_ready = dram_ready;
    assign l1d_l2_rdata = !pte_sel ? l2_p1_rdata : 512'd0;
    assign l1d_l2_ready = !pte_sel ? l2_p1_ready : 1'b0;
    assign l1d_pte_rdata = pte_sel ? l2_p1_rdata[63:0] : 64'd0;
    assign l1d_pte_ready = pte_sel ? l2_p1_ready : 1'b0;

    assign dbg_pcu_pc = pcu_pc;
    assign dbg_satp = satp_w;
    assign dbg_satp_en = satp_en_w;
endmodule
