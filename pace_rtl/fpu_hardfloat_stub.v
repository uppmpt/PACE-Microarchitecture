// Copyright (c) 2026 uppmpt (https://github.com/uppmpt)
// Contact: pacesolodev@gmail.com
//
// This source describes Open Hardware and is licensed under the
// CERN-OHL-W v2.
//
// TEMPORARY STUB for missing Berkeley HardFloat / CNRV-FPU modules.
// Allows Verilator to elaborate fpu_arith.v without external IP.
// FPU operations return zero — NOT functionally correct.
// Replace with a real FPU implementation. See open issue.

`timescale 1ns/1ps

module R5FP_add #(
    parameter EXP_W = 8,
    parameter SIG_W = 23
) (
    input  wire [SIG_W+EXP_W:0] a,
    input  wire [SIG_W+EXP_W:0] b,
    output wire [EXP_W-1:0]     zExp,
    output wire [EXP_W-1:0]     tailZeroCnt,
    output wire [5:0]           zStatus,
    output wire [SIG_W+3:0]     zSig,
    output wire                 zSign
);
    assign zExp        = {EXP_W{1'b0}};
    assign tailZeroCnt = {EXP_W{1'b0}};
    assign zStatus     = 6'b0;
    assign zSig        = {(SIG_W+4){1'b0}};
    assign zSign       = 1'b0;
endmodule

module R5FP_mul #(
    parameter EXP_W = 8,
    parameter SIG_W = 23
) (
    input  wire [SIG_W+EXP_W:0] a,
    input  wire [SIG_W+EXP_W:0] b,
    output wire [EXP_W-1:0]     zExp,
    output wire [EXP_W-1:0]     tailZeroCnt,
    output wire [5:0]           zStatus,
    output wire [2*SIG_W+2:0]   zSig,
    output wire                 toInf,
    output wire                 zSign
);
    assign zExp        = {EXP_W{1'b0}};
    assign tailZeroCnt = {EXP_W{1'b0}};
    assign zStatus     = 6'b0;
    assign zSig        = {(2*SIG_W+3){1'b0}};
    assign toInf       = 1'b0;
    assign zSign       = 1'b0;
endmodule

module R5FP_postproc #(
    parameter I_SIG_W = 27,
    parameter SIG_W = 23,
    parameter EXP_W = 8
) (
    input  wire [EXP_W-1:0]     aExp,
    input  wire [5:0]           aStatus,
    input  wire [I_SIG_W-1:0]   aSig,
    input  wire                 aSign,
    input  wire                 specialTiny,
    input  wire                 zToInf,
    input  wire [2:0]           rnd,
    input  wire [EXP_W-1:0]     tailZeroCnt,
    output wire [SIG_W+EXP_W:0] z,
    output wire [7:0]           zStatus
);
    assign z       = {(SIG_W+EXP_W+1){1'b0}};
    assign zStatus = 8'b0;
endmodule
