`timescale 1ns/1ps

// ============================================================
// uart_debug_tx —— 板上状态明文输出（调试专用，不影响功能）
//
// 每 200ms 从 TX 脚发一行（115200 8N1）：
//   [NNNN] A=XXXXXXXX B=XXXXXXXX C=XXXXXXXX D=XXXXXXXX E=XXXXXXXX F=XXXXXXXX
//
//   NNNN : 行计数（每行 +1，5 行/秒）
//   A    : {load_busy, state_code[3:0], img_cnt[2:0], display_valid,
//           sd_init_done, scaler_state[2:0], scaler_busy, done_cnt[17:0]}
//   B    : {img_w[15:0], img_h[15:0]}      —— 当前图片分辨率
//   C    : {scaler_fcnt[6:0], scaler_next_fr[15:0], scaler_rs[8:0]}
//   D    : {audio_cnt[15:0], blk_cnt[7:0], aud_seen, 1'b0, peak_disp[5:0]}
//   E    : 频谱柱 0..7   （每段 4bit，= 柱高>>2）
//   F    : 频谱柱 8..15  （每段 4bit）
// ============================================================

module uart_debug_tx #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD        = 115200,
    parameter integer PERIOD_CYC  = CLK_FREQ_HZ / 5    // 200ms
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] dbg_a,
    input  wire [31:0] dbg_b,
    input  wire [31:0] dbg_c,
    input  wire [31:0] dbg_d,
    input  wire [31:0] dbg_e,
    input  wire [31:0] dbg_f,
    output reg         tx
);

    localparam integer NW    = 6;                 // 字数
    localparam integer PW    = 11;                // 每字字节数：" X=" + 8 hex
    localparam integer TOTAL = 6 + NW * PW + 1;   // 73
    localparam [8:0]   LAST  = TOTAL - 1;         // 72

    localparam BIT_CYC = CLK_FREQ_HZ / BAUD;      // 868 @100MHz

    reg [31:0] tick_cnt;
    reg [8:0]  byte_idx;
    reg [3:0]  sub;                               // 字内字节序号 0..10
    reg [2:0]  widx;                              // 第几个字 0..5
    reg [3:0]  bit_idx;
    reg [15:0] bit_cnt;
    reg [9:0]  shifter;
    reg [1:0]  state;

    localparam S_IDLE = 2'd0, S_LOAD = 2'd1, S_SHIFT = 2'd2;

    // 行计数（BCD 4 位）
    reg [15:0] line_bcd;
    always @(posedge clk) begin
        if (rst) begin
            line_bcd <= 16'd0;
        end else if (state == S_IDLE && tick_cnt == PERIOD_CYC - 1) begin
            if (line_bcd[3:0]   != 4'd9) line_bcd[3:0]   <= line_bcd[3:0]   + 4'd1;
            else begin
                line_bcd[3:0] <= 4'd0;
                if (line_bcd[7:4]   != 4'd9) line_bcd[7:4]   <= line_bcd[7:4]   + 4'd1;
                else begin
                    line_bcd[7:4] <= 4'd0;
                    if (line_bcd[11:8]  != 4'd9) line_bcd[11:8]  <= line_bcd[11:8]  + 4'd1;
                    else begin
                        line_bcd[11:8] <= 4'd0;
                        if (line_bcd[15:12] != 4'd9) line_bcd[15:12] <= line_bcd[15:12] + 4'd1;
                        else                         line_bcd[15:12] <= 4'd0;
                    end
                end
            end
        end
    end

    function [7:0] nib_hex;
        input [3:0] v;
        begin
            nib_hex = (v < 4'd10) ? (8'd48 + {4'd0, v})       // '0'+v
                                  : (8'd65 + {4'd0, v} - 8'd10); // 'A'+v-10
        end
    endfunction

    // 当前要发的字
    reg [31:0] word;
    always @* begin
        case (widx)
            3'd0: word = dbg_a;
            3'd1: word = dbg_b;
            3'd2: word = dbg_c;
            3'd3: word = dbg_d;
            3'd4: word = dbg_e;
            default: word = dbg_f;
        endcase
    end

    reg [7:0] msg_byte;
    reg [3:0] nib;
    always @* begin
        msg_byte = 8'd0;
        nib      = 4'd0;
        if (byte_idx == LAST) begin
            msg_byte = 8'd10;                                         // '\n'
        end else if (byte_idx < 9'd6) begin
            case (byte_idx)
                9'd0: msg_byte = 8'd91;                               // '['
                9'd1: msg_byte = "0" + {4'd0, line_bcd[15:12]};
                9'd2: msg_byte = "0" + {4'd0, line_bcd[11:8]};
                9'd3: msg_byte = "0" + {4'd0, line_bcd[7:4]};
                9'd4: msg_byte = "0" + {4'd0, line_bcd[3:0]};
                default: msg_byte = 8'd93;                            // ']'
            endcase
        end else begin
            case (sub)
                4'd0: msg_byte = 8'd32;                               // ' '
                4'd1: msg_byte = 8'd65 + {5'd0, widx};                // 'A' + widx
                4'd2: msg_byte = 8'd61;                               // '='
                4'd3: begin nib = word[31:28]; msg_byte = nib_hex(nib); end
                4'd4: begin nib = word[27:24]; msg_byte = nib_hex(nib); end
                4'd5: begin nib = word[23:20]; msg_byte = nib_hex(nib); end
                4'd6: begin nib = word[19:16]; msg_byte = nib_hex(nib); end
                4'd7: begin nib = word[15:12]; msg_byte = nib_hex(nib); end
                4'd8: begin nib = word[11:8];  msg_byte = nib_hex(nib); end
                4'd9: begin nib = word[7:4];   msg_byte = nib_hex(nib); end
                default: begin nib = word[3:0]; msg_byte = nib_hex(nib); end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            tick_cnt <= 32'd0;
            byte_idx <= 9'd0;
            sub      <= 4'd0;
            widx     <= 3'd0;
            bit_idx  <= 4'd0;
            bit_cnt  <= 16'd0;
            shifter  <= 10'h3FF;
            state    <= S_IDLE;
            tx       <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (tick_cnt == PERIOD_CYC - 1) begin
                        tick_cnt <= 32'd0;
                        byte_idx <= 9'd0;
                        sub      <= 4'd0;
                        widx     <= 3'd0;
                        state    <= S_LOAD;
                    end else begin
                        tick_cnt <= tick_cnt + 32'd1;
                    end
                end

                S_LOAD: begin
                    shifter <= {1'b1, msg_byte, 1'b0};   // 停止位 + 数据 + 起始位
                    bit_idx <= 4'd0;
                    bit_cnt <= 16'd0;
                    state   <= S_SHIFT;
                end

                S_SHIFT: begin
                    tx <= shifter[0];
                    if (bit_cnt == BIT_CYC - 1) begin
                        bit_cnt <= 16'd0;
                        shifter <= {1'b1, shifter[9:1]};
                        if (bit_idx == 4'd9) begin          // 本字节 10 位发完
                            if (byte_idx == LAST)
                                state <= S_IDLE;
                            else begin
                                byte_idx <= byte_idx + 9'd1;
                                if (byte_idx >= 9'd6) begin
                                    // 正文区：每 11 字节推进一个字
                                    if (sub == PW - 1) begin
                                        sub  <= 4'd0;
                                        widx <= widx + 3'd1;
                                    end else begin
                                        sub <= sub + 4'd1;
                                    end
                                end
                                state <= S_LOAD;
                            end
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
