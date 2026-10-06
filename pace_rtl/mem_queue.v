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
module mem_queue #(parameter DEPTH=8) (
    input  wire        clk, rst_n,
    // Push (from PCU, lane 0)
    input  wire        push_en,
    input  wire [2:0]  push_op,      // 0=LD 1=ST 2=LR 3=SC 4=AMO
    input  wire [63:0] push_addr,
    input  wire [63:0] push_rs2,
    input  wire [4:0]  push_rd,
    input  wire [2:0]  push_funct3,
    input  wire [4:0]  push_amo_f5,
    output wire        push_ready,   // not full
    output wire        full,
    // Pop (to MC)
    input  wire        pop_en,
    output wire [2:0]  pop_op,
    output wire [63:0] pop_addr,
    output wire [63:0] pop_rs2,
    output wire [4:0]  pop_rd,
    output wire [2:0]  pop_funct3,
    output wire [4:0]  pop_amo_f5,
    output wire        pop_valid
);
    reg [2:0]  op_r   [0:DEPTH-1];
    reg [63:0] addr_r [0:DEPTH-1];
    reg [63:0] rs2_r  [0:DEPTH-1];
    reg [4:0]  rd_r   [0:DEPTH-1];
    reg [2:0]  f3_r   [0:DEPTH-1];
    reg [4:0]  amof_r [0:DEPTH-1];
    reg [3:0]  head, tail, count;

    assign full       = (count == DEPTH[3:0]);
    assign push_ready = ~full;
    assign pop_valid  = (count != 0);
    // debug counters
    reg [15:0] dbg_pushes, dbg_pops, dbg_drops;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dbg_pushes<=0; dbg_pops<=0; dbg_drops<=0; end
        else begin
            if (push_en && push_ready) dbg_pushes <= dbg_pushes + 1;
            if (push_en && !push_ready) dbg_drops <= dbg_drops + 1;
            if (pop_en && pop_valid) dbg_pops <= dbg_pops + 1;
        end
    end

    assign pop_op    = op_r   [head];
    assign pop_addr  = addr_r [head];
    assign pop_rs2   = rs2_r  [head];
    assign pop_rd    = rd_r   [head];
    assign pop_funct3= f3_r   [head];
    assign pop_amo_f5= amof_r [head];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= 0; tail <= 0; count <= 0;
        end else begin
            if (push_en && !push_ready) $display("[MQ-DROP] op=%h addr=%h f3=%h count=%h", push_op, push_addr, push_funct3, count);
            if (push_en && push_ready) begin
                op_r   [tail] <= push_op;
                addr_r [tail] <= push_addr;
                rs2_r  [tail] <= push_rs2;
                rd_r   [tail] <= push_rd;
                f3_r   [tail] <= push_funct3;
                amof_r [tail] <= push_amo_f5;
                tail <= (tail + 1'b1) & (DEPTH[3:0] - 1'b1);
            end
            if (pop_en && pop_valid) begin
                head <= (head + 1'b1) & (DEPTH[3:0] - 1'b1);
            end
            // count
            if (push_en && push_ready && !(pop_en && pop_valid))
                count <= count + 1'b1;
            else if (!(push_en && push_ready) && pop_en && pop_valid)
                count <= count - 1'b1;
        end
    end
endmodule
