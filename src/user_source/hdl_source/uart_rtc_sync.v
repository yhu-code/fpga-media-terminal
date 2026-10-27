`timescale 1ns/1ps

// ============================================================
// uart_rtc_sync —— 串口时间同步（给 OSD 提供现实时间）
//
// 板上没有 RTC 芯片，上电后计时器从 0 数（运行时间）。
// PC 通过 USB 串口发 ASCII 命令即可把现实时间写进来：
//
//     T + HHMMSS + 回车(可选)
//     例：19 时 30 分 45 秒 →  T193045
//
// 解析规则：
//   - 任意时刻遇到 'T' 开始收集，之后 6 个字节必须是 '0'~'9'
//   - 中途出现非数字字符则放弃，重新寻找 'T'
//   - 6 位收齐后校验 HH<=23, MM<=59, SS<=59，合法则装载并翻转 set_tgl
//   - 可以反复发送，随时重新校准
//
// CDC：本模块在 100MHz 时钟域，消费方（system_timer_25m_v2，25MHz 视频域）
// 对 set_tgl 做两级同步后沿检测；6 个 BCD nibble 只在 set_tgl 翻转的同一
// 时刻改变，属于准静态信号，边沿到达时早已稳定，采样安全。
// ============================================================

module uart_rtc_sync #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD        = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,            // E4, CH340 TXD -> FPGA

    output reg        set_tgl,        // 每次成功同步翻转一次
    output reg  [3:0] rtc_hour_tens,
    output reg  [3:0] rtc_hour_ones,
    output reg  [3:0] rtc_minute_tens,
    output reg  [3:0] rtc_minute_ones,
    output reg  [3:0] rtc_second_tens,
    output reg  [3:0] rtc_second_ones,
    output reg        synced          // 调试：至少成功同步过一次
);

    localparam integer BIT_CYC = CLK_FREQ_HZ / BAUD;   // 868 @100MHz

    // ---------------- UART RX ----------------
    reg [1:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[0], rxd};
    wire rx_in = rx_sync[1];

    localparam RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
    reg [1:0]  rx_state;
    reg [15:0] rx_baud_cnt;
    reg [2:0]  rx_bit_idx;
    reg [7:0]  rx_shift;
    reg        rx_byte_vld;
    reg [7:0]  rx_byte;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_state    <= RX_IDLE;
            rx_baud_cnt <= 16'd0;
            rx_bit_idx  <= 3'd0;
            rx_shift    <= 8'd0;
            rx_byte_vld <= 1'b0;
            rx_byte     <= 8'd0;
        end else begin
            rx_byte_vld <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    if (!rx_in) begin                    // 起始位下降沿
                        rx_state    <= RX_START;
                        rx_baud_cnt <= 16'd0;
                    end
                end

                RX_START: begin                          // 数到半位中心采样确认
                    if (rx_baud_cnt == (BIT_CYC >> 1) - 1) begin
                        rx_baud_cnt <= 16'd0;
                        if (!rx_in) begin
                            rx_bit_idx <= 3'd0;
                            rx_state   <= RX_DATA;
                        end else
                            rx_state <= RX_IDLE;         // 毛刺
                    end else
                        rx_baud_cnt <= rx_baud_cnt + 16'd1;
                end

                RX_DATA: begin                           // 每 BIT_CYC 采一位
                    if (rx_baud_cnt == BIT_CYC - 1) begin
                        rx_baud_cnt <= 16'd0;
                        rx_shift    <= {rx_in, rx_shift[7:1]};
                        if (rx_bit_idx == 3'd7) begin
                            rx_bit_idx <= 3'd0;
                            rx_state   <= RX_STOP;
                        end else
                            rx_bit_idx <= rx_bit_idx + 3'd1;
                    end else
                        rx_baud_cnt <= rx_baud_cnt + 16'd1;
                end

                RX_STOP: begin
                    if (rx_baud_cnt == BIT_CYC - 1) begin
                        rx_baud_cnt <= 16'd0;
                        if (rx_in) begin                 // 停止位正确
                            // rx_shift 高位进/低位出，8 位收完即为正确字节值
                            // （bit0 在 [0]，bit7 在 [7]），直接取用，勿再旋转
                            rx_byte     <= rx_shift;
                            rx_byte_vld <= 1'b1;
                        end
                        rx_state <= RX_IDLE;
                    end else
                        rx_baud_cnt <= rx_baud_cnt + 16'd1;
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // ---------------- 命令解析器 ----------------
    // 'T' -> 6 个 ASCII 数字 -> 校验 -> 装载
    localparam P_HUNT = 2'd0, P_TENS = 2'd1, P_ONES = 2'd2, P_REST = 2'd3;
    reg [1:0] p_state;
    reg [2:0] dig_idx;
    reg [3:0] d_hh_t, d_hh_o, d_mm_t, d_mm_o, d_ss_t, d_ss_o;

    wire is_digit = rx_byte_vld && (rx_byte >= 8'd48) && (rx_byte <= 8'd57);
    wire [3:0] dig_val = rx_byte[3:0];
    wire is_T  = rx_byte_vld && (rx_byte == 8'h54);
    wire hh_ok = (d_hh_t < 4'd2) || ((d_hh_t == 4'd2) && (d_hh_o <= 4'd3));
    wire mm_ok = (d_mm_t <= 4'd5) && (d_ss_t <= 4'd5);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            p_state         <= P_HUNT;
            dig_idx         <= 3'd0;
            set_tgl         <= 1'b0;
            synced          <= 1'b0;
            rtc_hour_tens   <= 4'd0;
            rtc_hour_ones   <= 4'd0;
            rtc_minute_tens <= 4'd0;
            rtc_minute_ones <= 4'd0;
            rtc_second_tens <= 4'd0;
            rtc_second_ones <= 4'd0;
            d_hh_t <= 4'd0; d_hh_o <= 4'd0; d_mm_t <= 4'd0;
            d_mm_o <= 4'd0; d_ss_t <= 4'd0; d_ss_o <= 4'd0;
        end else begin
            case (p_state)
                P_HUNT: begin
                    if (is_T) begin
                        p_state <= P_TENS;
                        dig_idx <= 3'd0;
                    end
                end

                // 依次收 6 个数字
                P_TENS, P_ONES, P_REST: begin
                    if (is_T) begin
                        p_state <= P_TENS;                // 重新开始
                        dig_idx <= 3'd0;
                    end else if (is_digit) begin
                        case (dig_idx)
                            3'd0: d_hh_t <= dig_val;
                            3'd1: d_hh_o <= dig_val;
                            3'd2: d_mm_t <= dig_val;
                            3'd3: d_mm_o <= dig_val;
                            3'd4: d_ss_t <= dig_val;
                            3'd5: d_ss_o <= dig_val;
                            default: ;
                        endcase
                        if (dig_idx == 3'd5) begin
                            dig_idx <= 3'd0;
                            if (hh_ok && mm_ok) begin     // 合法：装载
                                rtc_hour_tens   <= d_hh_t;
                                rtc_hour_ones   <= d_hh_o;
                                rtc_minute_tens <= d_mm_t;
                                rtc_minute_ones <= d_mm_o;
                                rtc_second_tens <= d_ss_t;
                                rtc_second_ones <= d_ss_o;
                                set_tgl <= ~set_tgl;
                                synced  <= 1'b1;
                            end
                            p_state <= P_HUNT;            // 非法也回到搜索
                        end else begin
                            dig_idx <= dig_idx + 3'd1;
                            p_state <= (dig_idx == 3'd0) ? P_TENS :
                                       (dig_idx == 3'd1) ? P_ONES : P_REST;
                        end
                    end else if (rx_byte_vld) begin       // 非数字非T：放弃
                        p_state <= P_HUNT;
                        dig_idx <= 3'd0;
                    end
                end

                default: p_state <= P_HUNT;
            endcase
        end
    end

endmodule
