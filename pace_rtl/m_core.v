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
module m_core (
    input  wire clk, rst_n,
    input  wire        mq_full,
    input  wire        mq_pop_valid,
    output wire        mq_pop_en,
    input  wire [2:0]  mq_op,
    input  wire [63:0] mq_addr,
    input  wire [63:0] mq_rs2,
    input  wire [4:0]  mq_rd,
    input  wire [2:0]  mq_funct3,
    input  wire [4:0]  mq_amo_f5,
    output wire        shadow_we,
    output wire [4:0]  shadow_rd,
    output wire [63:0] shadow_data,
    output wire        shadow_exc,
    output wire        ext_wr_en,
    output wire [4:0]  ext_wr_addr,
    output wire [63:0] ext_wr_data,
    output reg         mem_req, mem_we,
    output reg  [7:0]  mem_be,
    output reg  [63:0] mem_addr, mem_wdata,
    input  wire [63:0] mem_rdata,
    input  wire        mem_ready,
    // ===== Extension port: AMO/LR/SC =====
    output reg         amo_ext_req,
    output reg  [2:0]  amo_ext_op,      // 2=LR, 3=SC, 4=AMO
    output reg  [2:0]  amo_ext_funct3,  // .W vs .D + size
    output reg  [4:0]  amo_ext_funct5,  // AMO operation
    output reg  [63:0] amo_ext_addr,
    output reg  [63:0] amo_ext_rs2,
    output reg  [4:0]  amo_ext_rd,
    input  wire        amo_ext_ack,
    input  wire [63:0] amo_ext_result,
    input  wire [4:0]  dbg_rs,
    output wire [63:0] dbg_rd
);
    reg [63:0] regs [0:31];
    assign dbg_rd = (dbg_rs == 5'd0) ? 64'd0 : regs[dbg_rs];

    localparam OP_LD=3'd0, OP_ST=3'd1;

    reg [2:0]  lat_op;
    reg [63:0] lat_addr, lat_rs2;
    reg [4:0]  lat_rd;
    reg [2:0]  lat_funct3;
    reg        lat_is_ext;

    wire [63:0] ld_ext = (lat_funct3 == 3'b000) ? {{56{mem_rdata[7]}},  mem_rdata[7:0]}  :
                         (lat_funct3 == 3'b001) ? {{48{mem_rdata[15]}}, mem_rdata[15:0]} :
                         (lat_funct3 == 3'b010) ? {{32{mem_rdata[31]}}, mem_rdata[31:0]} :
                         (lat_funct3 == 3'b011) ? mem_rdata :
                         (lat_funct3 == 3'b100) ? {56'b0, mem_rdata[7:0]}  :
                         (lat_funct3 == 3'b101) ? {48'b0, mem_rdata[15:0]} :
                         (lat_funct3 == 3'b110) ? {32'b0, mem_rdata[31:0]} : mem_rdata;
    wire [7:0] st_be = (mq_funct3 == 3'b000) ? 8'h01 :
                       (mq_funct3 == 3'b001) ? 8'h03 :
                       (mq_funct3 == 3'b010) ? 8'h0F :
                                               8'hFF;
    // debug
    always @(posedge clk) if (mem_req && !mem_we) $display("[MC-LD] addr=%h f3=%h", mem_addr, lat_funct3);
    always @(posedge clk) if (mem_req && mem_we) $display("[MC-ST] addr=%h f3=%h be=%h wd=%h", mem_addr, mq_funct3, mem_be, mem_wdata);
    wire [63:0] st_ext = (mq_funct3 == 3'b000) ? {56'b0, mq_rs2[7:0]} :
                         (mq_funct3 == 3'b001) ? {48'b0, mq_rs2[15:0]} :
                         (mq_funct3 == 3'b010) ? {32'b0, mq_rs2[31:0]} : mq_rs2;

    localparam S_IDLE=0, S_LD=1, S_ST=2, S_EXT=3;
    reg [1:0] state;
    assign mq_pop_en = (state == S_IDLE) && mq_pop_valid;

    // Shadow write: LD normal ou extensão (AMO/LR/SC)
    assign shadow_we   = (state == S_LD && mem_ready) ||
                         (state == S_EXT && amo_ext_ack);
    assign shadow_rd   = lat_rd;
    assign shadow_data = (state == S_LD) ? ld_ext :
                         amo_ext_result;
    assign shadow_exc  = 1'b0;
    assign ext_wr_en   = shadow_we;
    assign ext_wr_addr = lat_rd;
    assign ext_wr_data = shadow_data;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            mem_req <= 0; mem_we <= 0; mem_addr <= 0; mem_wdata <= 0; mem_be <= 8'hFF;
            amo_ext_req <= 0;
            lat_op <= 0; lat_addr <= 0; lat_rs2 <= 0; lat_rd <= 0; lat_funct3 <= 0;
            for (k = 0; k < 32; k = k + 1) regs[k] <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    mem_req <= 0;
                    amo_ext_req <= 0;
                    if (mq_pop_valid) begin
                        lat_op     <= mq_op;
                        lat_addr   <= mq_addr;
                        lat_rs2    <= mq_rs2;
                        lat_rd     <= mq_rd;
                        lat_funct3 <= mq_funct3;
                        case (mq_op)
                            OP_LD: begin
                                mem_req <= 1; mem_we <= 0; mem_addr <= mq_addr;
                                state <= S_LD;
                            end
                            OP_ST: begin
                                mem_req <= 1; mem_we <= 1; mem_addr <= mq_addr;
                                mem_wdata <= st_ext;
                                mem_be <= st_be;
                                state <= S_ST;
                            end
                            default: begin
                                // AMO/LR/SC → extensão
                                amo_ext_req    <= 1;
                                amo_ext_op     <= mq_op;
                                amo_ext_funct3 <= mq_funct3;
                                amo_ext_funct5 <= mq_amo_f5;
                                amo_ext_addr   <= mq_addr;
                                amo_ext_rs2    <= mq_rs2;
                                amo_ext_rd     <= mq_rd;
                                state <= S_EXT;
                            end
                        endcase
                    end
                end
                S_LD: begin
                    if (mem_ready) begin
                        mem_req <= 0;
                        if (lat_rd != 5'd0) regs[lat_rd] <= ld_ext;
                        state <= S_IDLE;
                    end
                end
                S_ST: begin
                    if (mem_ready) begin
                        mem_req <= 0;
                        state <= S_IDLE;
                    end
                end
                S_EXT: begin
                    if (amo_ext_ack) begin
                        amo_ext_req <= 0;
                        if (lat_rd != 5'd0) regs[lat_rd] <= amo_ext_result;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
