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
// UART 16550A — compatível com Linux serial driver
// Registradores padrão (offsets de 8 bits da base MMIO):
//   0x00: RBR/THR (read/write, DLAB=0) | DLL (DLAB=1)
//   0x01: IER (DLAB=0) | DLM (DLAB=1)
//   0x02: IIR (read) | FCR (write)
//   0x03: LCR
//   0x04: MCR
//   0x05: LSR
//   0x06: MSR
//   0x07: SCR (scratch)
//
// Clock: assume clk = 16 * baud * divisor (oversampling 16x)
module uart (
    input  wire        clk, rst_n,
    // Barramento MMIO (word de 64 bits, só 8 bits válidos)
    input  wire        req, we,
    input  wire [63:0] addr, wdata,
    output reg  [63:0] rdata,
    output reg         ready,
    // Serial
    output reg         tx,          // saída serial
    input  wire        rx,          // entrada serial
    // Interrupt
    output reg         irq
);
    wire [7:0] off = addr[7:0];

    // ================ Registradores ================
    reg [7:0]  dll, dlm;                // divisor latch
    reg [7:0]  ier;                     // interrupt enable
    reg [7:0]  fcr;                     // FIFO control
    reg [7:0]  lcr;                     // line control
    reg [7:0]  mcr;                     // modem control
    reg [7:0]  scr;                     // scratch
    reg [7:0]  msr;                     // modem status

    // ================ Status & controle ================
    wire dlab     = lcr[7];
    wire fifo_en  = fcr[0];
    wire [1:0] word_len = lcr[1:0];     // 00=5, 01=6, 10=7, 11=8 bits
    wire stop_bits = lcr[2];            // 0=1 stop, 1=2 (ou 1.5 se WL=5)
    wire parity_en = lcr[3];
    wire parity_odd = lcr[4];
    wire parity_stick = lcr[5];
    wire break_ctrl = lcr[6];

    // ================ FIFOs (16 bytes cada) ================
    reg [7:0] tx_fifo [0:15];
    reg [4:0] tx_wr_ptr, tx_rd_ptr, tx_count;
    reg [7:0] rx_fifo [0:15];
    reg [4:0] rx_wr_ptr, rx_rd_ptr, rx_count;

    wire tx_fifo_full  = (tx_count >= 5'd16);
    wire tx_fifo_empty = (tx_count == 0);
    wire rx_fifo_full  = (rx_count >= 5'd16);
    wire rx_fifo_empty = (rx_count == 0);

    // ================ Baud rate generator ================
    reg [15:0] baud_counter;
    wire [15:0] divisor = {dlm, dll};
    wire baud_tick = (divisor != 0) && (baud_counter == 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) baud_counter <= 0;
        else if (divisor == 0) baud_counter <= 0;
        else if (baud_counter >= divisor - 1) baud_counter <= 0;
        else baud_counter <= baud_counter + 1;
    end

    // Sample counter: 16x oversampling
    reg [3:0] sample_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_cnt <= 0;
        else if (baud_tick) sample_cnt <= sample_cnt + 1;
    end
    wire sample_tick = baud_tick && (sample_cnt == 4'd15);

    // ================ TX ================
    reg [10:0] tx_shift;   // start + 8 data + parity + stop = 11 bits        // start + 8 data + stop (+parity)
    reg [3:0] tx_bit_idx;
    reg [3:0] tx_bits_total;
    reg       tx_busy;

    wire [3:0] tx_data_bits = (word_len == 2'b00) ? 4'd5 :
                              (word_len == 2'b01) ? 4'd6 :
                              (word_len == 2'b10) ? 4'd7 : 4'd8;
    wire [3:0] tx_total = 4'd1 + tx_data_bits + (parity_en ? 4'd1 : 4'd0) + (stop_bits ? 4'd2 : 4'd1);

    function [7:0] parity_calc;
        input [10:0] data;
        input [3:0] nbits;
        input odd;
        integer i;
        reg p;
        begin
            p = 0;
            for (i = 0; i < 8; i = i + 1)
                if (i < nbits) p = p ^ data[i + 1];  // data começa em bit 1
            parity_calc = odd ? ~p : p;
        end
    endfunction

    wire [7:0] tx_parity = parity_calc({3'b0, tx_fifo[tx_rd_ptr]}, tx_data_bits, parity_odd);

    // TX FSM
    localparam TX_IDLE = 0, TX_START = 1, TX_DATA = 2, TX_PARITY = 3, TX_STOP = 4;
    reg [2:0] tx_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
            tx <= 1;
            tx_bit_idx <= 0;
            tx_shift <= 11'h7FF;
            tx_busy <= 0;
            tx_rd_ptr <= 0;
        end else if (sample_tick) begin
            case (tx_state)
                TX_IDLE: begin
                    tx <= 1;
                    if (!tx_fifo_empty) begin
                        // Monta o frame (sempre 8 data bits no shift, mascara na transmissão)
                        tx_shift[0] <= 0;   // start
                        tx_shift[8:1] <= tx_fifo[tx_rd_ptr];
                        tx_shift[9] <= tx_parity;
                        tx_shift[10] <= 1;  // stop
                        tx_bit_idx <= 0;
                        tx_state <= TX_START;
                        tx_busy <= 1;
                    end
                end
                TX_START: begin
                    tx <= tx_shift[0];
                    tx_bit_idx <= 1;
                    tx_state <= TX_DATA;
                end
                TX_DATA: begin
                    tx <= tx_shift[tx_bit_idx];
                    if (tx_bit_idx == tx_data_bits) begin
                        tx_state <= parity_en ? TX_PARITY : TX_STOP;
                        tx_bit_idx <= parity_en ? 4'd0 : 4'd1;
                    end else begin
                        tx_bit_idx <= tx_bit_idx + 1;
                    end
                end
                TX_PARITY: begin
                    tx <= tx_shift[tx_data_bits + 1];
                    tx_bit_idx <= 1;
                    tx_state <= TX_STOP;
                end
                TX_STOP: begin
                    tx <= 1;
                    if (tx_bit_idx >= (stop_bits ? 2 : 1)) begin
                        tx_state <= TX_IDLE;
                        tx_busy <= 0;
                        // Consome FIFO
                        tx_rd_ptr <= tx_rd_ptr + 1;
                    end else begin
                        tx_bit_idx <= tx_bit_idx + 1;
                    end
                end
            endcase
        end
    end

// ================ RX ================
reg [2:0]  rx_state;
localparam RX_IDLE_S = 3'd0, RX_HALFBIT = 3'd1, RX_DATA_S = 3'd2,
           RX_PARITY_S = 3'd3, RX_STOP_S = 3'd4;
reg [3:0]  rx_bit_idx;
reg [19:0] rx_bit_cnt;
reg [10:0] rx_shift;
reg        rx_busy;

// Timing in clocks (divisor from DLL/DLM, 16x oversampling):
wire [19:0] rx_half = {divisor, 3'b000};
wire [19:0] rx_full = {divisor, 4'b0000};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_state   <= RX_IDLE_S;
        rx_bit_idx <= 0;
        rx_bit_cnt <= 0;
        rx_busy    <= 0;
        rx_wr_ptr  <= 0;
    end else begin
        case (rx_state)
            RX_IDLE_S: begin
                if (!rx) begin
                    rx_bit_cnt <= rx_half - 1;
                    rx_state   <= RX_HALFBIT;
                    rx_busy    <= 1;
                end
            end
            RX_HALFBIT: begin
                if (rx_bit_cnt == 0) begin
                    if (rx == 0) begin
                        rx_bit_idx <= 0;
                        rx_bit_cnt <= rx_full - 1;
                        rx_state   <= RX_DATA_S;
                    end else begin
                        rx_state <= RX_IDLE_S;
                        rx_busy  <= 0;
                    end
                end else begin
                    rx_bit_cnt <= rx_bit_cnt - 1;
                end
            end
            RX_DATA_S: begin
                if (rx_bit_cnt == 0) begin
                    rx_shift[rx_bit_idx] <= rx;
                    if (rx_bit_idx == tx_data_bits - 1) begin
                        rx_bit_cnt <= rx_full - 1;
                        rx_state   <= parity_en ? RX_PARITY_S : RX_STOP_S;
                    end else begin
                        rx_bit_idx <= rx_bit_idx + 1;
                        rx_bit_cnt <= rx_full - 1;
                    end
                end else begin
                    rx_bit_cnt <= rx_bit_cnt - 1;
                end
            end
            RX_PARITY_S: begin
                if (rx_bit_cnt == 0) begin
                    rx_bit_cnt <= rx_full - 1;
                    rx_state   <= RX_STOP_S;
                end else begin
                    rx_bit_cnt <= rx_bit_cnt - 1;
                end
            end
            RX_STOP_S: begin
                if (rx_bit_cnt == 0) begin
                    if (!rx_fifo_full) begin
                        rx_fifo[rx_wr_ptr] <= rx_shift[7:0];
                        rx_wr_ptr <= rx_wr_ptr + 1;
                    end
                    rx_state <= RX_IDLE_S;
                    rx_busy  <= 0;
                end else begin
                    rx_bit_cnt <= rx_bit_cnt - 1;
                end
            end
        endcase
    end
end

    // ================ Line Status Register ================
    wire [7:0] lsr = {
        1'b0,                       // bit 7: error in FIFO
        tx_fifo_empty && !tx_busy,  // bit 6: TEMT (transmitter empty)
        tx_fifo_empty,              // bit 5: THRE (THR empty)
        1'b0,                       // bit 4: break
        1'b0,                       // bit 3: framing error
        1'b0,                       // bit 2: parity error
        1'b0,                       // bit 1: overrun
        !rx_fifo_empty              // bit 0: data ready
    };

    // ================ Interrupt logic ================
    wire rx_data_avail = !rx_fifo_empty && ier[0];
    wire tx_thr_empty  = tx_fifo_empty && ier[1];
    wire rx_line_status = ier[2];   // simplificado
    wire msr_status    = ier[3];    // simplificado

    wire [3:0] int_pending = {msr_status, rx_line_status, tx_thr_empty, rx_data_avail};
    wire [2:0] int_id = rx_data_avail ? 3'b010 :   // receiver data available
                        tx_thr_empty  ? 3'b001 :   // transmitter holding empty
                        rx_line_status? 3'b011 :   // receiver line status
                        msr_status    ? 3'b000 : 3'b001;

    // ================ MMIO ================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dll <= 8'd1; dlm <= 8'd0;
            ier <= 8'd0; fcr <= 8'd0; lcr <= 8'd3; mcr <= 8'd0; scr <= 8'd0;
            msr <= 8'hB0;   // DCD, DSR, CTS ativos
            rdata <= 0;
            ready <= 0;
            tx_wr_ptr <= 0;
            rx_rd_ptr <= 0;
        end else begin
            ready <= 0;
            if (req) begin
                if (we) begin
                    case (off)
                        8'h00: if (dlab) dll <= wdata[7:0];
                               else if (!tx_fifo_full) begin
                                   tx_fifo[tx_wr_ptr] <= wdata[7:0];
                                   tx_wr_ptr <= tx_wr_ptr + 1;
                               end
                        8'h01: if (dlab) dlm <= wdata[7:0];
                               else ier <= wdata[7:0];
                        8'h02: fcr <= wdata[7:0];
                        8'h03: lcr <= wdata[7:0];
                        8'h04: mcr <= wdata[7:0];
                        8'h07: scr <= wdata[7:0];
                        default: ;
                    endcase
                end else begin
                    case (off)
                        8'h00: if (dlab) rdata <= {56'b0, dll};
                               else rdata <= {56'b0, rx_fifo[rx_rd_ptr]};
                        8'h01: rdata <= {56'b0, dlab ? dlm : ier};
                        8'h02: rdata <= {56'b0, fcr[0], fcr[0], 2'b00, int_id, irq};
                        8'h03: rdata <= {56'b0, lcr};
                        8'h04: rdata <= {56'b0, mcr};
                        8'h05: rdata <= {56'b0, lsr};
                        8'h06: rdata <= {56'b0, msr};
                        8'h07: rdata <= {56'b0, scr};
                        default: rdata <= 0;
                    endcase
                    // Consome RX FIFO quando lê RBR
                    if (off == 8'h00 && !dlab && !rx_fifo_empty)
                        rx_rd_ptr <= rx_rd_ptr + 1;
                end
                ready <= 1;
            end
        end
    end

    // Atualiza contadores de FIFO
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_count <= 0;
            rx_count <= 0;
        end else begin
            // TX count
            if (req && we && off == 8'h00 && !dlab && !tx_fifo_full && !(tx_rd_ptr_dummy))
                tx_count <= tx_count + 1;
            if (tx_state == TX_STOP && sample_tick && tx_bit_idx >= (stop_bits ? 2 : 1))
                tx_count <= tx_count - 1;
            // RX count
            if (rx_state == RX_STOP_S && rx_bit_cnt == 0 && !rx_fifo_full)
                rx_count <= rx_count + 1;
            if (req && !we && off == 8'h00 && !dlab && !rx_fifo_empty)
                rx_count <= rx_count - 1;
        end
    end
    wire tx_rd_ptr_dummy = 0;

    // IRQ
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq <= 0;
        else irq <= (int_pending != 0);
    end
endmodule
