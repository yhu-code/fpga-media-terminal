`timescale 1ns/1ps

// ============================================================
// system_timer_25m_v2
// 25.000 MHz 精确系统计时器（24 小时制）
//
// 25,000,000 个 video_clk 周期 = 1 秒
// 输出同时提供 HH:MM:SS 数值和 6 个 BCD 数字，
// 供 OSD 使用，避免在每个视频像素周期执行 /10 和 %10。
//
// 现实时间同步：uart_rtc_sync（100MHz 域）每收到一次 PC 发来的
// "T+HHMMSS" 就翻转 rtc_set_tgl 并给出 6 个 BCD nibble。
// 本模块对 tgl 做两级同步 + 边沿检测后装载；nibble 为准静态信号，
// 边沿到达时早已稳定，采样安全。同步过的时钟按 24 小时制回绕。
// ============================================================
module system_timer_25m_v2 #(
    parameter integer CLK_FREQ_HZ = 25_000_000
)(
    input            clk,
    input            rst,

    // 现实时间同步（来自 uart_rtc_sync，100MHz 域）
    input            rtc_set_tgl,
    input      [3:0] rtc_hour_tens,
    input      [3:0] rtc_hour_ones,
    input      [3:0] rtc_minute_tens,
    input      [3:0] rtc_minute_ones,
    input      [3:0] rtc_second_tens,
    input      [3:0] rtc_second_ones,

    output reg [7:0] hour,
    output reg [7:0] minute,
    output reg [7:0] second,

    output reg [3:0] hour_tens,
    output reg [3:0] hour_ones,
    output reg [3:0] minute_tens,
    output reg [3:0] minute_ones,
    output reg [3:0] second_tens,
    output reg [3:0] second_ones
);

    localparam integer SEC_CNT_MAX = CLK_FREQ_HZ - 1;

    reg [24:0] sec_cnt;

    // ---- set_tgl 跨时钟域同步 + 边沿检测 ----
    reg [2:0] tgl_sync;
    always @(posedge clk or posedge rst) begin
        if (rst)
            tgl_sync <= 3'b000;
        else
            tgl_sync <= {tgl_sync[1:0], rtc_set_tgl};
    end
    wire rtc_load = tgl_sync[2] ^ tgl_sync[1];   // 任何方向的翻转都装载

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sec_cnt    <= 25'd0;

            hour       <= 8'd0;
            minute     <= 8'd0;
            second     <= 8'd0;

            hour_tens  <= 4'd0;
            hour_ones  <= 4'd0;
            minute_tens<= 4'd0;
            minute_ones<= 4'd0;
            second_tens<= 4'd0;
            second_ones<= 4'd0;
        end else if (rtc_load) begin
            // ---- 装载现实时间，本秒从头数 ----
            sec_cnt     <= 25'd0;
            hour_tens   <= rtc_hour_tens;
            hour_ones   <= rtc_hour_ones;
            minute_tens <= rtc_minute_tens;
            minute_ones <= rtc_minute_ones;
            second_tens <= rtc_second_tens;
            second_ones <= rtc_second_ones;
            hour        <= rtc_hour_tens * 8'd10 + rtc_hour_ones;
            minute      <= rtc_minute_tens * 8'd10 + rtc_minute_ones;
            second      <= rtc_second_tens * 8'd10 + rtc_second_ones;
        end else begin
            if (sec_cnt >= SEC_CNT_MAX) begin
                sec_cnt <= 25'd0;

                // 秒个位
                if (second_ones == 4'd9) begin
                    second_ones <= 4'd0;

                    // 秒十位
                    if (second_tens == 4'd5) begin
                        second_tens <= 4'd0;

                        // 分个位
                        if (minute_ones == 4'd9) begin
                            minute_ones <= 4'd0;

                            // 分十位
                            if (minute_tens == 4'd5) begin
                                minute_tens <= 4'd0;

                                // 小时：24 小时制回绕（23:59:59 -> 00:00:00）
                                if ((hour_tens == 4'd2) && (hour_ones == 4'd3)) begin
                                    hour_tens <= 4'd0;
                                    hour_ones <= 4'd0;
                                end else if (hour_ones == 4'd9) begin
                                    hour_ones <= 4'd0;
                                    hour_tens <= hour_tens + 4'd1;
                                end else begin
                                    hour_ones <= hour_ones + 4'd1;
                                end
                            end else begin
                                minute_tens <= minute_tens + 4'd1;
                            end
                        end else begin
                            minute_ones <= minute_ones + 4'd1;
                        end
                    end else begin
                        second_tens <= second_tens + 4'd1;
                    end
                end else begin
                    second_ones <= second_ones + 4'd1;
                end

                // 数值输出同步更新（24 小时制回绕）。
                // 仅用于调试/后续扩展，OSD直接使用上面的BCD输出。
                if (second == 8'd59) begin
                    second <= 8'd0;
                    if (minute == 8'd59) begin
                        minute <= 8'd0;
                        if (hour == 8'd23)
                            hour <= 8'd0;
                        else
                            hour <= hour + 8'd1;
                    end else begin
                        minute <= minute + 8'd1;
                    end
                end else begin
                    second <= second + 8'd1;
                end
            end else begin
                sec_cnt <= sec_cnt + 25'd1;
            end
        end
    end

endmodule
