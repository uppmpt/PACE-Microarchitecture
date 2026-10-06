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
module pcu #(parameter RESET_PC = 64'd0) (
    input  wire        clk, rst_n,
    input  wire        stall, fetch_stall, shdw_wr_ready,
    output wire        pcu_valid,
    output wire [63:0] pc_out,
    input  wire [31:0] instr_in,
    output wire        shadow_we,
    output wire [4:0]  shadow_rd,
    output wire [63:0] shadow_data,
    output wire        shadow_exc,
    input  wire        ext_wr_en,
    input  wire [4:0]  ext_wr_addr,
    input  wire [63:0] ext_wr_data,
    output wire        br_valid, br_taken,
    output wire [63:0] br_target,
    input  wire        redirect_valid,
    input  wire [63:0] redirect_pc,
    input  wire        i_mtip, i_msip, i_meip, i_seip, i_stip, i_ssip,
    output wire [63:0] dbg_result,
    output wire [1:0]  dbg_priv
);
    reg [63:0] pc;
    assign pc_out = pc;
    assign dbg_priv = cur_priv;

    wire [6:0] d_opcode, d_funct7;
    wire [2:0] d_funct3;
    wire [4:0] d_rd, d_rs1, d_rs2;
    wire [63:0] d_imm;
    wire [2:0]  d_format;
    wire        d_is_sys, d_is_ecall, d_is_ebreak, d_is_mret, d_is_sret, d_is_csr;
    wire [11:0] d_csr_addr;

    decoder dec (
        .instr(instr_in),
        .opcode(d_opcode), .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2),
        .funct3(d_funct3), .funct7(d_funct7), .imm(d_imm), .format(d_format),
        .is_system(d_is_sys), .is_ecall(d_is_ecall), .is_ebreak(d_is_ebreak),
        .is_mret(d_is_mret), .is_sret(d_is_sret), .is_csr(d_is_csr),
        .csr_addr(d_csr_addr)
    );

    reg [63:0] pcu_regs [0:31];
    wire [63:0] rs1_val = (d_rs1 == 5'd0) ? 64'd0 : pcu_regs[d_rs1];
    wire [63:0] rs2_val = (d_rs2 == 5'd0) ? 64'd0 : pcu_regs[d_rs2];

    function [3:0] alu_ctrl;
        input [6:0] op; input [2:0] f3; input [6:0] f7;
        begin
            case (op)
                7'b0110011, 7'b0010011: case (f3)
                    3'b000: alu_ctrl = f7[5] ? 4'b0001 : 4'b0000;
                    3'b001: alu_ctrl = 4'b0101;
                    3'b010: alu_ctrl = 4'b1000;
                    3'b011: alu_ctrl = 4'b1001;
                    3'b100: alu_ctrl = 4'b0100;
                    3'b101: alu_ctrl = f7[5] ? 4'b0111 : 4'b0110;
                    3'b110: alu_ctrl = 4'b0011;
                    3'b111: alu_ctrl = 4'b0010;
                    default: alu_ctrl = 4'b0000;
                endcase
                default: alu_ctrl = 4'b0000;
            endcase
        end
    endfunction

    wire [63:0] alu_in1 = (d_opcode == 7'b0010011) ? d_imm : rs2_val;
    wire [3:0]  alu_op  = alu_ctrl(d_opcode, d_funct3, d_funct7);
    wire [63:0] alu_out;
    alu_rv64 alu (.in0_alu(rs1_val), .in1_alu(alu_in1), .opcd_alu(alu_op), .out_alu(alu_out));

    wire writes_rd_alu = ((d_opcode == 7'b0110011) || (d_opcode == 7'b0010011))
                         && (d_rd != 5'd0);
    wire is_load_instr = (d_opcode == 7'b0000011);

    // === Branches ===
    wire is_branch = (d_opcode == 7'b1100011);
    wire is_jal    = (d_opcode == 7'b1101111);
    wire is_jalr   = (d_opcode == 7'b1100111);
    wire is_ctrl   = is_branch || is_jal || is_jalr;

    reg br_cond;
    always @(*) case (d_funct3)
        3'b000: br_cond = (rs1_val == rs2_val);
        3'b001: br_cond = (rs1_val != rs2_val);
        3'b100: br_cond = ($signed(rs1_val) <  $signed(rs2_val));
        3'b101: br_cond = ($signed(rs1_val) >= $signed(rs2_val));
        3'b110: br_cond = (rs1_val <  rs2_val);
        3'b111: br_cond = (rs1_val >= rs2_val);
        default: br_cond = 1'b0;
    endcase

    wire [63:0] jalr_target = (rs1_val + d_imm) & ~64'd1;
    wire [63:0] ctrl_target = is_jalr ? jalr_target : (pc + d_imm);
    wire        ctrl_taken  = is_jal ? 1'b1 : (is_jalr ? 1'b1 : br_cond);

    assign br_valid  = is_ctrl;
    assign br_taken  = is_ctrl && ctrl_taken;
    assign br_target = ctrl_target;

    // === CSR + Trap ===
    wire [63:0] csr_rdata;
    wire        csr_illegal;
    wire [63:0] mstatus_o, mie_o, mip_o, mtvec_o, stvec_o;
    wire [63:0] medeleg_o, mideleg_o, mepc_o, sepc_o, mcause_o, scause_o;
    reg  [1:0]  cur_priv;

    wire [1:0] csr_op   = (d_funct3 == 3'b001 || d_funct3 == 3'b101) ? 2'b01 :   // W
                          (d_funct3 == 3'b010 || d_funct3 == 3'b110) ? 2'b10 :   // set
                          (d_funct3 == 3'b011 || d_funct3 == 3'b111) ? 2'b11 : 2'b00; // clear
    wire       csr_use_imm = d_funct3[2];   // CSRRWI/RSI/CI
    wire [63:0] csr_wdata_in = csr_use_imm ? {59'b0, d_rs1} : rs1_val;
    wire        csr_we_dec = d_is_csr && (d_rd != 5'd0 || csr_op == 2'b01);

    wire        trap_taken;
    wire [63:0] trap_pc, trap_cause, trap_tval;
    wire [1:0]  trap_priv;
    wire        trap_deleg;

    wire        exc_valid = d_is_ecall || d_is_ebreak;
    wire [63:0] exc_cause = d_is_ebreak ? 64'd3 :
                            (cur_priv == 2'b11) ? 64'd11 :  // ecall_M
                            (cur_priv == 2'b01) ? 64'd9  :  // ecall_S
                                                  64'd8;    // ecall_U
    wire [63:0] exc_tval  = 64'd0;

    csr_file u_csr (
        .clk(clk), .rst_n(rst_n),
        .csr_addr(d_csr_addr), .csr_we(csr_we_dec), .csr_op(csr_op),
        .csr_wdata(csr_wdata_in), .csr_rdata(csr_rdata),
        .priv_mode(cur_priv),
        .trap_enter(trap_taken), .trap_to_priv(trap_priv),
        .mret(d_is_mret && pcu_valid), .sret(d_is_sret && pcu_valid),
        .update_mepc(1'b0), .update_mcause(1'b0), .update_mtval(1'b0),
        .update_sepc(1'b0), .update_scause(1'b0), .update_stval(1'b0),
        .pc_val(pc), .cause_val(exc_cause), .tval_val(exc_tval),
        .deleg_to_s(trap_deleg),
        .i_mtip(i_mtip), .i_msip(i_msip), .i_meip(i_meip),
        .i_seip(i_seip), .i_stip(i_stip), .i_ssip(i_ssip),
        .mstatus_o(mstatus_o), .mie_o(mie_o), .mip_o(mip_o),
        .mtvec_o(mtvec_o), .stvec_o(stvec_o),
        .medeleg_o(medeleg_o), .mideleg_o(mideleg_o),
        .mepc_o(mepc_o), .sepc_o(sepc_o),
        .mcause_o(mcause_o), .scause_o(scause_o),
        .cur_priv_o()
    );

    trap_unit u_trap (
        .cur_priv(cur_priv), .mstatus(mstatus_o), .mie(mie_o), .mip(mip_o),
        .medeleg(medeleg_o), .mideleg(mideleg_o), .mtvec(mtvec_o), .stvec(stvec_o),
        .exc_valid(exc_valid && pcu_valid), .exc_cause(exc_cause),
        .exc_tval(exc_tval), .cur_pc(pc),
        .trap_taken(trap_taken), .trap_pc(trap_pc), .trap_cause(trap_cause),
        .trap_tval(trap_tval), .trap_to_priv(trap_priv), .deleg_to_s(trap_deleg)
    );

    // Cur priv follows CSR file
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cur_priv <= 2'b11;
        else if (d_is_mret && pcu_valid) cur_priv <= mstatus_o[12:11];
        else if (d_is_sret && pcu_valid) cur_priv <= {1'b0, mstatus_o[8]};
        else if (trap_taken) cur_priv <= trap_priv;
    end

    // === Stall / valid ===
    reg wait_load;
    reg branch_pending;
    wire is_trap_instr = d_is_mret || d_is_sret || d_is_ecall || d_is_ebreak;

    assign pcu_valid = rst_n && !stall && !fetch_stall && !wait_load && !branch_pending;

    // === PC update ===
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= RESET_PC; branch_pending <= 0; wait_load <= 0;
            for (integer k=0; k<32; k=k+1) pcu_regs[k] <= 0;
        end else if (stall || fetch_stall) begin
            if (ext_wr_en && ext_wr_addr != 0) pcu_regs[ext_wr_addr] <= ext_wr_data;
        end else if (wait_load) begin
            if (ext_wr_en && ext_wr_addr != 0) pcu_regs[ext_wr_addr] <= ext_wr_data;
            wait_load <= 0;
        end else if (trap_taken) begin
            pc <= trap_pc;
            branch_pending <= 0;
        end else if (branch_pending) begin
            if (redirect_valid) begin pc <= redirect_pc; branch_pending <= 0; end
        end else if (is_ctrl) begin
            branch_pending <= 1;
        end else if (is_trap_instr) begin
            // mret/sret/ecall/ebreak: no reg write, advance normally (or via trap)
            if (d_is_mret) pc <= mepc_o;
            else if (d_is_sret) pc <= sepc_o;
            else pc <= pc + 4;   // ecall/ebreak: trap_taken handles the redirect
            if (ext_wr_en && ext_wr_addr != 0) pcu_regs[ext_wr_addr] <= ext_wr_data;
        end else begin
            pc <= pc + 4;
            if (writes_rd_alu) pcu_regs[d_rd] <= alu_out;
            if (d_is_csr && d_rd != 5'd0) pcu_regs[d_rd] <= csr_rdata;
            if (ext_wr_en && ext_wr_addr != 0) pcu_regs[ext_wr_addr] <= ext_wr_data;
            if (is_load_instr) wait_load <= 1;
        end
    end

    // === Shadow write ===
    // CSR reads also write to shadow RF (result goes to rd)
    assign shadow_we   = (writes_rd_alu && !is_ctrl && pcu_valid) ||
                         (d_is_csr && d_rd != 5'd0 && pcu_valid);
    assign shadow_rd   = d_rd;
    assign shadow_data = d_is_csr ? csr_rdata : alu_out;
    assign shadow_exc  = exc_valid && pcu_valid;
    assign dbg_result  = alu_out;
endmodule
