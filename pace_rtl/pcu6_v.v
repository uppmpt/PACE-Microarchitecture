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
module pcu6_v #(parameter HART_ID = 0) (
    input  wire        clk, rst_n,
    input  wire        stall, fetch_stall,
    input  wire [3:0]  shdw_wr_ready,
    input  wire [3:0]      instr_count,   // quantas lanes válidas (1..6)
    input  wire [6*32-1:0] instr_in,
    output wire [63:0] pc_out,
    output wire [5:0]        shadow_we,
    output wire [6*5-1:0]    shadow_rd,
    output wire [6*64-1:0]   shadow_data,
    output wire [5:0]        num_writes,
    output wire        br_valid, br_taken,
    output wire [63:0] br_target,
    input  wire        redirect_valid,
    input  wire [63:0] redirect_pc,
    input  wire        ext_wr_en,
    input  wire [4:0]  ext_wr_addr,
    input  wire [63:0] ext_wr_data,
    output wire [1:0]  dbg_priv,
    input  wire        i_mtip, i_msip, i_meip, i_seip, i_stip, i_ssip,
    input  wire        rh_discard,   // Runahead: descarta writes no shadow
    // Memory queue (para M-Core)
    output reg         mq_push_en,
    output reg  [2:0]  mq_push_op,
    output reg  [63:0] mq_push_addr,
    output reg  [63:0] mq_push_rs2,
    output reg  [4:0]  mq_push_rd,
    output reg  [2:0]  mq_push_funct3,
    output reg  [4:0]  mq_push_amo_f5,
    input  wire        mq_full,
    output wire [63:0] dbg_satp,
    output wire        dbg_satp_enable,
    output wire        dbg_flush_tlb,
    // Vector memory port (vle.v / vse.v)
    output reg         vmem_req,
    output reg         vmem_we,
    output reg  [63:0] vmem_addr,
    output reg  [63:0] vmem_wdata,
    input  wire [63:0] vmem_rdata,
    input  wire        vmem_ready,
    output wire        dbg_trap_taken,
    output wire [2:0]  dbg_advance,
    output wire        dbg_flush_fetch,
    output wire [63:0] dbg_new_pc,
    output wire [7:0]  dbg_vl,
    output wire [63:0] dbg_vtype,
    input  wire [4:0]  dbg_vrs,
    output wire [127:0] dbg_vrd
);
    // ============ 6 decoders ============
    wire [6*7-1:0]  d_opcode, d_funct7;
    wire [6*3-1:0]  d_funct3;
    wire [6*5-1:0]  d_rd, d_rs1, d_rs2;
    wire [6*64-1:0] d_imm;
    wire [6*3-1:0]  d_format;
    wire [6-1:0]    d_is_system, d_is_ecall, d_is_ebreak;
    wire [6-1:0]    d_is_mret, d_is_sret, d_is_csr;
    wire [6*12-1:0] d_csr_addr;
    wire [6-1:0]    d_is_vsetvli, d_is_vsetivli, d_is_vsetvl, d_is_vector;
    wire [6*6-1:0]  d_v_vm, d_v_funct6;

    genvar gi;
    generate
        for (gi = 0; gi < 6; gi = gi + 1) begin : g_dec
            decoder u_dec (
                .instr(instr_in[gi*32 +: 32]),
                .opcode(d_opcode[gi*7 +: 7]),
                .rd(d_rd[gi*5 +: 5]), .rs1(d_rs1[gi*5 +: 5]), .rs2(d_rs2[gi*5 +: 5]),
                .funct3(d_funct3[gi*3 +: 3]), .funct7(d_funct7[gi*7 +: 7]),
                .imm(d_imm[gi*64 +: 64]), .format(d_format[gi*3 +: 3]),
                .is_system(d_is_system[gi]), .is_ecall(d_is_ecall[gi]),
                .is_ebreak(d_is_ebreak[gi]), .is_mret(d_is_mret[gi]),
                .is_sret(d_is_sret[gi]), .is_csr(d_is_csr[gi]),
                .csr_addr(d_csr_addr[gi*12 +: 12]),
                .is_vsetvli(d_is_vsetvli[gi]), .is_vsetivli(d_is_vsetivli[gi]),
                .is_vsetvl(d_is_vsetvl[gi]), .is_vector(d_is_vector[gi]),
                .v_vm(d_v_vm[gi*6 +: 6]), .v_funct6(d_v_funct6[gi*6 +: 6])
            );
        end
    endgenerate

    // ============ classificação ============
    wire [5:0] is_alu, is_fpu, is_mem, is_br, is_sys, is_vecop, is_vcfg, is_vload, is_vstore, is_vec_all;
    wire [5:0] wr_this_lane;
    generate
        for (gi = 0; gi < 6; gi = gi + 1) begin : g_cls
            wire [6:0] opc = d_opcode[gi*7 +: 7];
            assign is_alu[gi]  = (opc == 7'b0110011) || (opc == 7'b0010011);
            assign is_fpu[gi]  = (opc == 7'b1010011);
            assign is_mem[gi]  = (opc == 7'b0000011) || (opc == 7'b0100011);
            assign is_br [gi]  = (opc == 7'b1100011) || (opc == 7'b1101111) || (opc == 7'b1100111);
            assign is_sys[gi]  = d_is_system[gi];
            assign is_vecop[gi]= d_is_vector[gi];
            assign is_vload[gi]  = (opc == 7'b0000111);   // vle.v (qualquer funct3)
            assign is_vstore[gi] = (opc == 7'b0100111);   // vse.v
            assign is_vec_all[gi] = is_vecop[gi] || is_vcfg[gi] || is_vload[gi] || is_vstore[gi];
            assign is_vcfg[gi] = d_is_vsetvli[gi] || d_is_vsetivli[gi] || d_is_vsetvl[gi];
            assign wr_this_lane[gi] = (is_alu[gi] || is_fpu[gi]) && (d_rd[gi*5 +: 5] != 5'd0);
        end
    endgenerate

    // ============ PCU regs ============
    reg [63:0] pcu_regs [0:31];
    wire [6*64-1:0] rs1_val, rs2_val;
    generate
        for (gi = 0; gi < 6; gi = gi + 1) begin : g_rr
            assign rs1_val[gi*64 +: 64] = (d_rs1[gi*5 +: 5] == 5'd0) ? 64'd0 : pcu_regs[d_rs1[gi*5 +: 5]];
            assign rs2_val[gi*64 +: 64] = (d_rs2[gi*5 +: 5] == 5'd0) ? 64'd0 : pcu_regs[d_rs2[gi*5 +: 5]];
        end
    endgenerate

    // ============ ALU cluster ============
    wire [5:0]     cluster_we;
    wire [6*5-1:0] cluster_rd;
    wire [6*64-1:0] cluster_result;

    alu_cluster #(.N(6)) u_cluster (
        .clk(clk), .rst_n(rst_n),
        .in_valid(wr_this_lane), .in_is_fpu(is_fpu),
        .in_opcode(d_opcode), .in_funct3(d_funct3), .in_funct7(d_funct7),
        .in_rs1(d_rs1), .in_rs2(d_rs2), .in_rd(d_rd),
        .in_rs1_val(rs1_val), .in_rs2_val(rs2_val), .in_imm(d_imm),
        .out_we(cluster_we), .out_rd(cluster_rd), .out_result(cluster_result)
    );

    // ============ Vector ============
    wire [127:0] v_rd1_0, v_rd2_0;
    wire [127:0] v_alu_result_0;
    wire [127:0] v0_mask_0 = 128'd0;
    reg  [4:0]   v_rs1_lane0, v_rs2_lane0, v_rd_lane0;
    reg          v_we_lane0;
    reg  [127:0] v_wd_lane0;
    reg  [3:0]   v_op_lane0;

    vector_rf #(.VLE(128)) u_vrf (
        .clk(clk), .rst_n(rst_n),
        .rs1(v_rs1_lane0), .rs2(v_rs2_lane0),
        .rd1(v_rd1_0), .rd2(v_rd2_0),
        .we(v_we_lane0), .rd(v_rd_lane0), .wd(v_wd_lane0),
        .dbg_rs(dbg_vrs), .dbg_rd(dbg_vrd)
    );

    v_alu #(.VLE(128), .SEW(64)) u_valu (
        .a(v_rd1_0), .b(v_rd2_0), .op(v_op_lane0),
        .mask(v0_mask_0), .mask_en(1'b0),
        .result(v_alu_result_0)
    );

    // ============ Vector CSRs ============
    wire [63:0] v_csr_rdata;
    reg         v_csr_we;
    reg  [11:0] v_csr_addr;
    reg  [63:0] v_csr_wdata;
    wire [7:0]  v_csr_vl;

    v_csr u_vcsr (
        .clk(clk), .rst_n(rst_n),
        .csr_access(1'b1), .csr_we(v_csr_we),
        .csr_addr(v_csr_addr), .csr_wdata(v_csr_wdata),
        .csr_op(2'b01), .csr_rdata(v_csr_rdata),
        .vl(v_csr_vl), .vtype(dbg_vtype)
    );
    assign dbg_vl = v_csr_vl;

    // ============ CSR + Trap ============
    wire [1:0] cur_priv;
    assign dbg_priv = cur_priv;

    wire        csr_req       = (d_is_csr[0] || is_vcfg[0] || d_is_mret[0] || d_is_sret[0] ||
                                 d_is_ecall[0] || d_is_ebreak[0]) && !pcu_stall_now;
    wire [1:0]  csr_op_pcu    = (d_funct3[0*3 +: 3] == 3'b001 || d_funct3[0*3 +: 3] == 3'b101) ? 2'b01 :
                                (d_funct3[0*3 +: 3] == 3'b010 || d_funct3[0*3 +: 3] == 3'b110) ? 2'b10 :
                                (d_funct3[0*3 +: 3] == 3'b011 || d_funct3[0*3 +: 3] == 3'b111) ? 2'b11 : 2'b00;
    wire        csr_use_imm   = d_funct3[0*3 + 2];
    wire [63:0] csr_wdata_pcu = csr_use_imm ? {59'b0, d_rs1[0*5 +: 5]} : rs1_val[0*64 +: 64];

    wire        exc_valid = (d_is_ecall[0] || d_is_ebreak[0]) && !pcu_stall_now;
    wire [63:0] exc_cause = d_is_ebreak[0] ? 64'd3 :
                            (cur_priv == 2'b11) ? 64'd11 :
                            (cur_priv == 2'b01) ? 64'd9  : 64'd8;

    wire [63:0] csr_rdata_std;
    wire [63:0] trap_pc_w;
    wire        trap_taken_w;
    wire [63:0] satp_w;
    wire        satp_en_w;
    wire        flush_tlb_w;

    csr_trap_unit #(.HART_ID(HART_ID)) u_csr_trap (
        .clk(clk), .rst_n(rst_n),
        .csr_req(csr_req),
        .is_system(d_is_system[0]),
        .is_csr(d_is_csr[0]),
        .is_ecall(d_is_ecall[0]),
        .is_ebreak(d_is_ebreak[0]),
        .is_mret(d_is_mret[0]),
        .is_sret(d_is_sret[0]),
        .csr_addr(d_csr_addr[0*12 +: 12]),
        .csr_op(csr_op_pcu),
        .csr_wdata(csr_wdata_pcu),
        .cur_pc(pc),
        .csr_rdata(csr_rdata_std),
        .exc_valid(exc_valid),
        .exc_cause(exc_cause),
        .exc_tval(64'd0),
        .trap_pc(trap_pc_w),
        .trap_taken(trap_taken_w),
        .cur_priv(cur_priv),
        .satp(satp_w),
        .satp_enable(satp_en_w),
        .flush_tlb(flush_tlb_w),
        .i_mtip(i_mtip), .i_msip(i_msip), .i_meip(i_meip),
        .i_seip(i_seip), .i_stip(i_stip), .i_ssip(i_ssip)
    );

    assign dbg_satp = satp_w;
    assign dbg_satp_enable = satp_en_w;
    assign dbg_flush_tlb = flush_tlb_w;
    assign dbg_trap_taken = trap_taken_w;
    assign dbg_advance   = advance_count;
    assign dbg_flush_fetch = trap_taken_w | (branch_pending && redirect_valid);
    assign dbg_new_pc    = trap_taken_w ? trap_pc_w : redirect_pc;

    wire [63:0] csr_rdata = (d_csr_addr[0*12 +: 12] >= 12'hC00) ? v_csr_rdata : csr_rdata_std;

    // ============ stall ============
    wire [5:0] wr_count_raw;
    assign wr_count_raw = {5'b0, wr_this_lane[0]} + {5'b0, wr_this_lane[1]} +
                          {5'b0, wr_this_lane[2]} + {5'b0, wr_this_lane[3]} +
                          {5'b0, wr_this_lane[4]} + {5'b0, wr_this_lane[5]};
    wire need_more_space = (wr_count_raw > {2'b0, shdw_wr_ready});
    wire pcu_stall_now = stall || fetch_stall || need_more_space || mq_stall;

    // ============ branches (lane 0) ============
    reg br_cond;
    always @(*) case (d_funct3[0*3 +: 3])
        3'b000: br_cond = (rs1_val[0*64 +: 64] == rs2_val[0*64 +: 64]);
        3'b001: br_cond = (rs1_val[0*64 +: 64] != rs2_val[0*64 +: 64]);
        3'b100: br_cond = ($signed(rs1_val[0*64 +: 64]) <  $signed(rs2_val[0*64 +: 64]));
        3'b101: br_cond = ($signed(rs1_val[0*64 +: 64]) >= $signed(rs2_val[0*64 +: 64]));
        3'b110: br_cond = (rs1_val[0*64 +: 64] <  rs2_val[0*64 +: 64]);
        3'b111: br_cond = (rs1_val[0*64 +: 64] >= rs2_val[0*64 +: 64]);
        default: br_cond = 1'b0;
    endcase

    wire is_jal_0  = (d_opcode[0*7 +: 7] == 7'b1101111);
    wire is_jalr_0 = (d_opcode[0*7 +: 7] == 7'b1100111);
    wire is_link_0 = (is_jal_0 || is_jalr_0) && (d_rd[0*5 +: 5] != 5'd0);
    wire [63:0] jalr_target = (rs1_val[0*64 +: 64] + d_imm[0*64 +: 64]) & ~64'd1;
    wire [63:0] ctrl_target = is_jalr_0 ? jalr_target : (pc + d_imm[0*64 +: 64]);
    wire ctrl_taken = is_jal_0 ? 1'b1 : (is_jalr_0 ? 1'b1 : br_cond);

    assign br_valid  = is_br[0];
    assign br_taken  = is_br[0] && ctrl_taken;
    assign br_target = ctrl_target;

    // ============ PC update ============
    reg [63:0] pc;
    assign pc_out = pc;

    reg branch_pending, wait_load;
    // advance = min(instr_count, lanes ALU/FPU consecutivas a partir de 0)
    // Instruções especiais (CSR, vector, mret, LOAD, BR) só processam na lane 0.
    wire [2:0] valid_cnt = (instr_count > 4'd6) ? 3'd6 : instr_count[2:0];
    wire [5:0] lane_valid;
    assign lane_valid[0] = (valid_cnt > 0);
    assign lane_valid[1] = (valid_cnt > 1);
    assign lane_valid[2] = (valid_cnt > 2);
    assign lane_valid[3] = (valid_cnt > 3);
    assign lane_valid[4] = (valid_cnt > 4);
    assign lane_valid[5] = (valid_cnt > 5);

    wire [5:0] alu_run;
    assign alu_run[0] = lane_valid[0] && (is_alu[0] || is_fpu[0]);
    assign alu_run[1] = alu_run[0] && lane_valid[1] && (is_alu[1] || is_fpu[1]);
    assign alu_run[2] = alu_run[1] && lane_valid[2] && (is_alu[2] || is_fpu[2]);
    assign alu_run[3] = alu_run[2] && lane_valid[3] && (is_alu[3] || is_fpu[3]);
    assign alu_run[4] = alu_run[3] && lane_valid[4] && (is_alu[4] || is_fpu[4]);
    assign alu_run[5] = alu_run[4] && lane_valid[5] && (is_alu[5] || is_fpu[5]);

    wire [2:0] advance_count = alu_run[5] ? 3'd6 :
                               alu_run[4] ? 3'd5 :
                               alu_run[3] ? 3'd4 :
                               alu_run[2] ? 3'd3 :
                               alu_run[1] ? 3'd2 :
                               alu_run[0] ? 3'd1 : 3'd1;
    wire is_load_0 = (d_opcode[0*7 +: 7] == 7'b0000011);
    wire is_lui_0   = (d_opcode[0*7 +: 7] == 7'b0110111);
    wire is_auipc_0 = (d_opcode[0*7 +: 7] == 7'b0010111);
    wire is_store_0 = (d_opcode[0*7 +: 7] == 7'b0100011);
    wire is_amo_0   = (d_opcode[0*7 +: 7] == 7'b0101111);
    wire is_mem_0   = is_load_0 || is_store_0 || is_amo_0;
    wire [4:0] amo_f5_0 = d_funct7[0*7 + 2 +: 5];
    wire is_lr_0 = is_amo_0 && (amo_f5_0 == 5'b00010);
    wire is_sc_0 = is_amo_0 && (amo_f5_0 == 5'b00011);
    wire is_amo_op_0 = is_amo_0 && !is_lr_0 && !is_sc_0;
    wire [2:0] mq_op_0 = is_load_0 ? 3'd0 :
                         is_store_0 ? 3'd1 :
                         is_lr_0 ? 3'd2 :
                         is_sc_0 ? 3'd3 : 3'd4;
    // Stall do PCU se a fila está cheia e a lane 0 é memória
    wire mq_stall = (is_load_0 || is_store_0 || is_amo_0) && mq_full;

    localparam VS_IDLE = 0, VS_EXEC = 1;
    localparam VS_LD_REQ = 2, VS_LD_WAIT = 3, VS_LD_MERGE = 4, VS_LD_WB = 5;
    localparam VS_ST_REQ = 6, VS_ST_WAIT = 7;
    reg [2:0] vld_state;
    reg [63:0] vld_base;
    reg [2:0]  vld_idx;
    reg [2:0]  vld_vl;
    reg [4:0]  vld_vd;
    reg [4:0]  vld_vs;
    reg v_state;
    reg [4:0] v_lat_rd, v_lat_rs1, v_lat_rs2;
    reg [3:0] v_lat_op;
    reg [5:0] v_lat_funct6;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 64'd0; branch_pending <= 0; wait_load <= 0;
            v_state <= VS_IDLE; v_we_lane0 <= 0; v_csr_we <= 0;
            for (k = 0; k < 32; k = k + 1) pcu_regs[k] <= 64'd0;
        end else begin
            v_we_lane0 <= 0;
            v_csr_we <= 0;
            mq_push_en <= 0;   // default pulso

            if (pcu_stall_now) begin
                if (ext_wr_en && ext_wr_addr != 5'd0)
                    pcu_regs[ext_wr_addr] <= ext_wr_data;
            end else if (wait_load) begin
                if (ext_wr_en && ext_wr_addr != 5'd0)
                    pcu_regs[ext_wr_addr] <= ext_wr_data;
                wait_load <= 0;
            end else if (trap_taken_w) begin
                pc <= trap_pc_w;
                branch_pending <= 0;
            end else if (branch_pending) begin
                if (redirect_valid) begin pc <= redirect_pc; branch_pending <= 0; end
            end else if (is_br[0]) begin
                branch_pending <= 1;
            end else if (is_load_0 || is_store_0 || is_amo_0) begin
                // LOAD/STORE/AMO: empurra pra fila
                mq_push_en    <= 1;
                mq_push_op    <= is_load_0  ? 3'd0 :
                                 is_store_0 ? 3'd1 :
                                 is_lr_0    ? 3'd2 :
                                 is_sc_0    ? 3'd3 : 3'd4;
                mq_push_addr  <= rs1_val[0*64 +: 64] + d_imm[0*64 +: 64];
                mq_push_rs2   <= rs2_val[0*64 +: 64];
                mq_push_rd    <= d_rd[0*5 +: 5];
                mq_push_funct3<= d_funct3[0*3 +: 3];
                mq_push_amo_f5<= amo_f5_0;
                pc            <= pc + 4;
            end else if (v_state == VS_EXEC) begin
                v_wd_lane0 <= v_alu_result_0;
                v_we_lane0 <= 1;
                v_state <= VS_IDLE;
            end else if (vld_state != 0) begin
                // ===== Vector load/store FSM =====
                case (vld_state)
                    3'd2: begin // VS_LD_REQ
                        vmem_req   <= 1;
                        vmem_we    <= 0;
                        vmem_addr  <= vld_base + {61'b0, vld_idx} * 8;
                        vld_state  <= 3'd3;
                    end
                    3'd3: begin // VS_LD_WAIT
                        if (vmem_ready) begin
                            vmem_req  <= 0;
                            vld_state <= 3'd4;
                        end
                    end
                    3'd4: begin // VS_LD_MERGE (idx++)
                        vld_idx <= vld_idx + 1;
                        if (vld_idx + 1 >= vld_vl)
                            vld_state <= 3'd5;
                        else
                            vld_state <= 3'd2;
                    end
                    3'd5: begin // VS_LD_WB
                        v_rd_lane0 <= vld_vd;
                        v_we_lane0 <= 1;
                        vld_state  <= 3'd0;
                        pc         <= pc + 4;
                    end
                    3'd6: begin // VS_ST_REQ
                        v_rs1_lane0 <= vld_vs;
                        // 1 ciclo pra RF leitura
                        vld_state <= 3'd7;
                    end
                    3'd7: begin // VS_ST_WAIT (request + wait)
                        vmem_req   <= 1;
                        vmem_we    <= 1;
                        vmem_addr  <= vld_base + {61'b0, vld_idx} * 8;
                        vmem_wdata <= v_rd1_0[vld_idx*64 +: 64];
                        if (vmem_ready) begin
                            vmem_req <= 0;
                            vld_idx  <= vld_idx + 1;
                            if (vld_idx + 1 >= vld_vl) begin
                                vld_state <= 3'd0;
                                pc <= pc + 4;
                            end else
                                vld_state <= 3'd6;
                        end
                    end
                endcase
            end else if (is_vload[0] && d_rd[0*5 +: 5] != 5'd0) begin
                vld_base  <= rs1_val[0*64 +: 64];
                vld_vd    <= d_rd[0*5 +: 5];
                vld_vl    <= (v_csr_vl > 8'd2) ? 3'd2 : {1'b0, v_csr_vl[1:0]};
                vld_idx   <= 0;
                vld_state <= 3'd2;
            end else if (is_vstore[0]) begin
                vld_base  <= rs1_val[0*64 +: 64];
                vld_vs    <= d_rs2[0*5 +: 5];  // vs3 = rs2 field
                vld_vl    <= (v_csr_vl > 8'd2) ? 3'd2 : {1'b0, v_csr_vl[1:0]};
                vld_idx   <= 0;
                vld_state <= 3'd6;
            end else if (is_vcfg[0]) begin
                v_csr_we <= 1;
                v_csr_addr <= 12'hC20;
                if (rs1_val[0*64 +: 64] == 0)
                    v_csr_wdata <= 64'd2;
                else if (rs1_val[0*64 +: 64] > 64'd2)
                    v_csr_wdata <= 64'd2;
                else
                    v_csr_wdata <= rs1_val[0*64 +: 64];
                pc <= pc + 4;
            end else if (is_vecop[0] && d_rd[0*5 +: 5] != 5'd0 && vld_state == 0) begin
                v_lat_rd  <= d_rd[0*5 +: 5];
                v_lat_rs1 <= d_rs1[0*5 +: 5];
                v_lat_rs2 <= d_rs2[0*5 +: 5];
                v_lat_funct6 <= d_v_funct6[0*6 +: 6];
                v_rs1_lane0 <= d_rs1[0*5 +: 5];
                v_rs2_lane0 <= d_rs2[0*5 +: 5];
                v_rd_lane0  <= d_rd[0*5 +: 5];
                case (d_v_funct6[0*6 +: 6])
                    6'b000000: v_op_lane0 <= 4'b0000;
                    6'b000010: v_op_lane0 <= 4'b0001;
                    6'b001001: v_op_lane0 <= 4'b0010;
                    6'b001010: v_op_lane0 <= 4'b0011;
                    6'b001011: v_op_lane0 <= 4'b0100;
                    default:   v_op_lane0 <= 4'b0000;
                endcase
                v_state <= VS_EXEC;
                pc <= pc + 4;
            end else if (d_is_csr[0]) begin
                // Qualquer CSR instr: escreve em rd se rd!=0, avança 1
                if (d_rd[0*5 +: 5] != 5'd0)
                    pcu_regs[d_rd[0*5 +: 5]] <= csr_rdata;
                pc <= pc + 4;
            end else if (d_is_mret[0]) begin
                pc <= u_csr_trap.mepc_o;
            end else if (d_is_sret[0]) begin
                pc <= u_csr_trap.sepc_o;
            end else if (is_lui_0) begin
                // LUI rd, imm → rd = imm << 12
                if (d_rd[0*5 +: 5] != 5'd0)
                    pcu_regs[d_rd[0*5 +: 5]] <= d_imm[0*64 +: 64];
                pc <= pc + 4;
            end else if (is_auipc_0) begin
                // AUIPC rd, imm → rd = pc + (imm << 12)
                if (d_rd[0*5 +: 5] != 5'd0)
                    pcu_regs[d_rd[0*5 +: 5]] <= pc + d_imm[0*64 +: 64];
                pc <= pc + 4;
            end else begin
                for (k = 0; k < 6; k = k + 1)
                    if ((k < valid_cnt) && wr_this_lane[k] && (d_rd[k*5 +: 5] != 5'd0))
                        pcu_regs[d_rd[k*5 +: 5]] <= cluster_result[k*64 +: 64];
                if (ext_wr_en && ext_wr_addr != 5'd0)
                    pcu_regs[ext_wr_addr] <= ext_wr_data;
                pc <= pc + {61'b0, advance_count} * 64'd4;
                if (is_load_0) wait_load <= 1;
            end
        end
    end

    // ===== Shadow output overrides =====
    // CSR reads e vector writes precisam ir pro shadow RF também
    wire csr_to_shadow = (d_is_csr[0] || is_vcfg[0]) && !pcu_stall_now &&
                         (d_rd[0*5 +: 5] != 5'd0) && !d_is_mret[0] && !d_is_sret[0];
    wire vec_to_shadow = (v_state == VS_EXEC);
    // MC escreve via ext_wr → injeta no Shadow RF (lane 5)
    wire ext_to_shadow = ext_wr_en && (ext_wr_addr != 5'd0);
    wire lane0_we_override = csr_to_shadow || vec_to_shadow || is_link_0;

    wire [63:0] lane0_data = csr_to_shadow ? csr_rdata :
                             vec_to_shadow ? v_alu_result_0 :
                         is_link_0     ? (pc + 64'd4) :
                             cluster_result[0*64 +: 64];
    wire [4:0]  lane0_rd   = vec_to_shadow ? v_lat_rd : d_rd[0*5 +: 5];

    // Se csr_to_shadow ou vec_to_shadow, lane 0 substitui
    wire [5:0]   final_shadow_we   = ext_to_shadow ? 6'b000001 :
                                     lane0_we_override ?
                                     {wr_this_lane[5:1], 1'b1} : wr_this_lane;
    wire [6*5-1:0] final_shadow_rd = ext_to_shadow ?
                                     {25'b0, ext_wr_addr} :
                                     lane0_we_override ?
                                     {d_rd[6*5-1:1*5], lane0_rd} : d_rd;
    wire [6*64-1:0] final_shadow_data = ext_to_shadow ?
                                        {320'b0, ext_wr_data} :
                                        lane0_we_override ?
                                        {cluster_result[6*64-1:1*64], lane0_data} : cluster_result;

    // Gate shadow_we: só lanes válidas
    wire [5:0] shadow_we_gated = {
        final_shadow_we[5] && (valid_cnt > 5),
        final_shadow_we[4] && (valid_cnt > 4),
        final_shadow_we[3] && (valid_cnt > 3),
        final_shadow_we[2] && (valid_cnt > 2),
        final_shadow_we[1] && (valid_cnt > 1),
        final_shadow_we[0]
    };
    assign shadow_we = rh_discard ? 6'b0 : shadow_we_gated;
    assign shadow_rd = final_shadow_rd;
    assign shadow_data = final_shadow_data;

    wire [5:0] wr_count_final = final_shadow_we;
    assign num_writes = wr_count_final[3:0];
endmodule
