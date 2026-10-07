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

module tb_uart;
    reg clk = 0, rst_n = 0;

    reg         req = 0, we = 0;
    reg  [63:0] addr = 0, wdata = 0;
    wire [63:0] rdata;
    wire        ready;

    wire        tx;
    reg         rx = 1;
    wire        irq;

    uart dut (
        .clk(clk), .rst_n(rst_n),
        .req(req), .we(we),
        .addr(addr), .wdata(wdata),
        .rdata(rdata), .ready(ready),
        .tx(tx), .rx(rx), .irq(irq)
    );

    always #5 clk = ~clk;

    localparam BITTIME = 16;

    task mmio_wr(input [63:0] a, input [63:0] d);
        begin
            @(posedge clk);
            addr <= a; wdata <= d; we <= 1; req <= 1;
            @(posedge clk);       // req visible, MMIO writes
            req <= 0; we <= 0;    // deassert
            repeat (3) @(posedge clk);
        end
    endtask

    task mmio_rd(input [63:0] a, output [63:0] d);
        begin
            @(posedge clk);
            addr <= a; we <= 0; req <= 1;
            @(posedge clk);       // req visible, MMIO reads
            req <= 0;
            repeat (3) @(posedge clk);
            d = rdata;
        end
    endtask

    task cap_tx(output [7:0] b);
        integer i;
        begin
            @(negedge tx);                     // start bit falling edge
            repeat (BITTIME + BITTIME/2) @(posedge clk);   // meio do primeiro data bit
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = tx;
                repeat (BITTIME) @(posedge clk);
            end
        end
    endtask

    task drive_rx(input [7:0] b);
        integer i;
        begin
            rx = 0;
            repeat (BITTIME) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i];
                repeat (BITTIME) @(posedge clk);
            end
            rx = 1;
            repeat (BITTIME) @(posedge clk);
        end
    endtask

    reg [7:0]  cap;
    reg [63:0] rd;
    integer    pass_cnt, fail_cnt;

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        $display("========================================");
        $display("  UART 16550A Testbench");
        $display("========================================");

        rst_n = 0;
        #100;
        rst_n = 1;
        repeat (30) @(posedge clk);

        // Test 1: LCR
        $display("\n--- Test 1: LCR write/read ---");
        mmio_wr(64'h03, 64'h03);
        mmio_rd(64'h03, rd);
        if (rd[7:0] == 8'h03) begin
            $display("  PASS: LCR = 0x%02x", rd[7:0]); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: LCR = 0x%02x (exp 0x03)", rd[7:0]); fail_cnt = fail_cnt + 1;
        end

        // Test 2: SCR
        $display("\n--- Test 2: SCR write/read ---");
        mmio_wr(64'h07, 64'hA5);
        mmio_rd(64'h07, rd);
        if (rd[7:0] == 8'hA5) begin
            $display("  PASS: SCR = 0x%02x", rd[7:0]); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: SCR = 0x%02x (exp 0xA5)", rd[7:0]); fail_cnt = fail_cnt + 1;
        end

        // Test 3: LSR after reset
        $display("\n--- Test 3: LSR ---");
        mmio_rd(64'h05, rd);
        $display("  LSR = 0x%02x (THRE=%b TEMT=%b DR=%b)", rd[7:0], rd[5], rd[6], rd[0]);
        if (rd[5] && rd[6]) begin
            $display("  PASS: THRE and TEMT set");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: THRE/TEMT not set");
            fail_cnt = fail_cnt + 1;
        end

        // Test 4: TX 'A' (0x41)
        $display("\n--- Test 4: TX 0x41 ('A') ---");
        fork
            mmio_wr(64'h00, 64'h41);
            cap_tx(cap);
        join
        if (cap == 8'h41) begin
            $display("  PASS: captured 0x%02x", cap); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: captured 0x%02x (exp 0x41)", cap); fail_cnt = fail_cnt + 1;
        end

        // Test 5: TX 0x55
        $display("\n--- Test 5: TX 0x55 ---");
        fork
            mmio_wr(64'h00, 64'h55);
            cap_tx(cap);
        join
        if (cap == 8'h55) begin
            $display("  PASS: captured 0x%02x", cap); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: captured 0x%02x (exp 0x55)", cap); fail_cnt = fail_cnt + 1;
        end

        // Test 6: RX 0xAA
        $display("\n--- Test 6: RX 0xAA ---");
        drive_rx(8'hAA);
        repeat (100) @(posedge clk);
        mmio_rd(64'h05, rd);
        $display("  LSR = 0x%02x (DR=%b)", rd[7:0], rd[0]);
        if (rd[0]) begin
            mmio_rd(64'h00, rd);
            $display("  RX = 0x%02x", rd[7:0]);
            if (rd[7:0] == 8'hAA) begin
                $display("  PASS"); pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: got 0x%02x (exp 0xAA)", rd[7:0]); fail_cnt = fail_cnt + 1;
            end
        end else begin
            $display("  FAIL: DR bit not set (RX never received)");
            fail_cnt = fail_cnt + 1;
        end

        $display("\n========================================");
        $display("  RESULT: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================");
        $finish;
    end

    initial begin
        #2000000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
