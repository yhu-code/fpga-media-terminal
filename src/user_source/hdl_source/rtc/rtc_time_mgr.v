`timescale 1ns/1ps

// ============================================================
// rtc_time_mgr —— HYM8563 RTC 与 OSD 计时器的桥梁
//
// 职责：
//   1. 上电等 I2C 总线稳定后，每 10 秒从 HYM8563 读一次时间；
//   2. 读到合法 BCD 时间就装载进 system_timer_25m_v2（toggle CDC）；
//   3. 收到串口时间命令（uart_rtc_sync）时，把时间写进芯片（断电由
//      纽扣电池保持），随后读回装载；芯片不可用时直接装载串口值兜底；
//   4. 读回值非法（芯片不在/电池空/数据损坏）时保持运行时间显示。
//
// 全部逻辑在 100MHz sd_card_clk 域；对 system_timer 的装载沿用
// "翻转 + 准静态数值" 的跨时钟域方式。
// ============================================================

module rtc_time_mgr #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer READ_PERIOD_SEC = 10,
    parameter integer BOOT_DELAY_SEC  = 2
)(
    input  wire        clk,
    input  wire        rst,

    // 来自 uart_rtc_sync（同域）
    input  wire        uart_set_tgl,         // 每次串口命令翻转
    input  wire [3:0]  u_hour_tens, u_hour_ones,
    input  wire [3:0]  u_minute_tens, u_minute_ones,
    input  wire [3:0]  u_second_tens, u_second_ones,

    // 到 system_timer_25m_v2（25MHz 视频域，tgl 两级同步）
    output reg         load_tgl,
    output reg  [3:0]  ld_hour_tens,
    output reg  [3:0]  ld_hour_ones,
    output reg  [3:0]  ld_minute_tens,
    output reg  [3:0]  ld_minute_ones,
    output reg  [3:0]  ld_second_tens,
    output reg  [3:0]  ld_second_ones,
    output reg         synced,               // 调试：装载过至少一次

    // RTC8563_Driver 接口（同域）
    output reg         rtc_set_time,         // 单拍脉冲：写时间进芯片
    output reg  [23:0] rtc_time_to_set,      // {hour,minute,second} BCD
    output reg         rtc_read,             // 单拍脉冲：读时间
    input  wire [23:0] rtc_time_read,        // {hour,minute,second} BCD
    input  wire        rtc_cmd_done,         // 驱动完成脉冲

    output reg         rtc_alive             // 调试：RTC 芯片响应正常
);

    // ---------------- 串口命令边沿检测（同域） ----------------
    reg uart_tgl_d;
    always @(posedge clk or posedge rst) begin
        if (rst) uart_tgl_d <= 1'b0;
        else     uart_tgl_d <= uart_set_tgl;
    end
    wire uart_set_evt = (uart_tgl_d != uart_set_tgl);

    // ---------------- 读回值合法性 ----------------
    wire [3:0] r_hh_t = rtc_time_read[21:20];
    wire [3:0] r_hh_o = rtc_time_read[19:16];
    wire [3:0] r_mm_t = rtc_time_read[14:12];
    wire [3:0] r_mm_o = rtc_time_read[11:8];
    wire [3:0] r_ss_t = rtc_time_read[6:4];
    wire [3:0] r_ss_o = rtc_time_read[3:0];

    wire time_sane = (r_mm_t <= 4'd5) && (r_ss_t <= 4'd5) &&
                     ((r_hh_t < 4'd2) || ((r_hh_t == 4'd2) && (r_hh_o <= 4'd3)));

    // 全 0 读数视为"芯片从未校时且时钟未走"（HYM8563 出厂/掉电状态）：
    // 不装载，避免把 OSD 时间戳每 10 秒打回 00:00:00。
    // 校时后芯片开始走时，读数非 0 即正常装载。
    wire time_zero = (rtc_time_read == 24'd0);

    // ---------------- 主状态机 ----------------
    localparam S_BOOT  = 3'd0;   // 上电延时
    localparam S_IDLE  = 3'd1;   // 周期计时
    localparam S_READ  = 3'd2;   // 发起读
    localparam S_WAITR = 3'd3;   // 等读完成
    localparam S_SET   = 3'd4;   // 发起写
    localparam S_WAITW = 3'd5;   // 等写完成

    reg [2:0]  state;
    reg [31:0] wait_cnt;
    reg        bad_reads;        // 连续坏读计数（bit）

    localparam integer BOOT_CYC  = CLK_FREQ_HZ * BOOT_DELAY_SEC;
    localparam integer PERIOD_CYC = CLK_FREQ_HZ * READ_PERIOD_SEC;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= S_BOOT;
            wait_cnt       <= 32'd0;
            bad_reads      <= 1'b0;
            rtc_alive      <= 1'b0;
            synced         <= 1'b0;
            load_tgl       <= 1'b0;
            rtc_set_time   <= 1'b0;
            rtc_read       <= 1'b0;
            rtc_time_to_set<= 24'd0;
            ld_hour_tens   <= 4'd0; ld_hour_ones   <= 4'd0;
            ld_minute_tens <= 4'd0; ld_minute_ones <= 4'd0;
            ld_second_tens <= 4'd0; ld_second_ones <= 4'd0;
        end else begin
            rtc_set_time <= 1'b0;
            rtc_read     <= 1'b0;

            case (state)
                // ---- 上电延时，让 I2C 总线/芯片就绪 ----
                S_BOOT: begin
                    if (uart_set_evt) begin
                        state <= S_SET;               // 上电立刻要校时也响应
                    end else if (wait_cnt >= BOOT_CYC) begin
                        wait_cnt <= 32'd0;
                        state    <= S_READ;
                    end else
                        wait_cnt <= wait_cnt + 32'd1;
                end

                // ---- 周期读 / 等待串口命令 ----
                S_IDLE: begin
                    if (uart_set_evt)
                        state <= S_SET;
                    else if (wait_cnt >= PERIOD_CYC) begin
                        wait_cnt <= 32'd0;
                        state    <= S_READ;
                    end else
                        wait_cnt <= wait_cnt + 32'd1;
                end

                S_READ: begin
                    rtc_read <= 1'b1;
                    state    <= S_WAITR;
                end

                S_WAITR: begin
                    if (rtc_cmd_done) begin
                        if (time_sane && !time_zero) begin
                            // 芯片活着且在走时：装载进计时器
                            bad_reads      <= 1'b0;
                            rtc_alive      <= 1'b1;
                            ld_hour_tens   <= r_hh_t;
                            ld_hour_ones   <= r_hh_o;
                            ld_minute_tens <= r_mm_t;
                            ld_minute_ones <= r_mm_o;
                            ld_second_tens <= r_ss_t;
                            ld_second_ones <= r_ss_o;
                            load_tgl       <= ~load_tgl;
                            synced         <= 1'b1;
                            state          <= S_IDLE;
                        end else if (!rtc_alive) begin
                            // 芯片不在/没电/未校时读全0：不再周期读，等串口命令兜底
                            bad_reads <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            // 偶发坏读：下次再试
                            state <= S_IDLE;
                        end
                    end
                end

                // ---- 把串口时间写进芯片 ----
                S_SET: begin
                    rtc_time_to_set <= {u_hour_tens, u_hour_ones,
                                        u_minute_tens, u_minute_ones,
                                        u_second_tens, u_second_ones};
                    rtc_set_time <= 1'b1;
                    state        <= S_WAITW;
                end

                S_WAITW: begin
                    if (rtc_cmd_done) begin
                        // 写完立即读回：芯片活着就由读回装载，
                        // 芯片不在则直接用串口值兜底装载
                        if (!rtc_alive) begin
                            ld_hour_tens   <= u_hour_tens;
                            ld_hour_ones   <= u_hour_ones;
                            ld_minute_tens <= u_minute_tens;
                            ld_minute_ones <= u_minute_ones;
                            ld_second_tens <= u_second_tens;
                            ld_second_ones <= u_second_ones;
                            load_tgl       <= ~load_tgl;
                            synced         <= 1'b1;
                            state          <= S_IDLE;
                        end else begin
                            state <= S_READ;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
