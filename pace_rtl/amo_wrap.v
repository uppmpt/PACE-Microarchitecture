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
// AMO wrapper: adapts m_core's level-held req to atomic_unit's pulse req,
// and muxes the SC return value (0/1) instead of the loaded data.
module amo_wrap (
    input  wire        clk, rst_n,

    input  wire        req_in,
    input  wire [2:0]  op,         // 2=LR, 3=SC, 4=AMO
    input  wire [2:0]  funct3,     // .W=010, .D=011
    input  wire [4:0]  funct5,     // AMO opcode
    input  wire [63:0] addr,
    input  wire [63:0] rs2,
    input  wire [4:0]  rd,
    output reg         ack,
    output reg  [63:0] result,

    output wire        mem_req,
    output wire        mem_we,
    output wire [63:0] mem_addr,
    output wire [63:0] mem_wdata,
    input  wire [63:0] mem_rdata,
    input  wire        mem_ready
);

    localparam OP_LR  = 3'd2;
    localparam OP_SC  = 3'd3;
    localparam OP_AMO = 3'd4;

    wire is_lr   = (op == OP_LR);
    wire is_sc   = (op == OP_SC);
    wire is_amo  = (op == OP_AMO);
    wire is_word = (funct3 == 3'b010);

    reg req_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) req_r <= 1'b0;
        else        req_r <= req_in;

    wire req_pulse = req_in && !req_r;
    always @(posedge clk) if (req_in || req_pulse || au_done)
        $display("[AMO] t=%0t req_in=%b req_pulse=%b op=%h addr=%h ack=%b done=%b",
                 $time, req_in, req_pulse, op, addr, ack, au_done);

    wire [63:0] au_rd_val;
    wire        au_sc_success;
    wire        au_done;

    atomic_unit u_au (
        .clk(clk), .rst_n(rst_n),
        .req(req_pulse),
        .is_lr(is_lr), .is_sc(is_sc), .is_amo(is_amo),
        .amo_op(funct5),
        .is_word(is_word),
        .addr(addr),
        .rs2_val(rs2),
        .rd_val(au_rd_val),
        .sc_success(au_sc_success),
        .done(au_done),
        .mem_req(mem_req), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    always @(*)
        result = is_sc ? {63'b0, au_sc_success} : au_rd_val;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) ack <= 1'b0;
        else        ack <= au_done;

endmodule
