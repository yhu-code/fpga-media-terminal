
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关

    // 扩展4：拨码开关实时调节
    //   sw[3:0] = 亮度档位（有符号 -8..+7，0x0 = 原始）
    //   sw[7:4] = 对比度档位（有符号 -8..+7，0x0 = 原始）
    input       [7:0]           sw,



    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC 已从引脚释放：L16/M16 与 HYM8563 RTC 共享同一物理总线，
    // EDID 读取结果（edid_valid/edid_data）从未被使用，为避免双驱动冲突，
    // 发送器核的 DDC 端口改接悬空内部线，RTC 独占 L16/M16。

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // 调试串口（P2，115200 8N1，每 200ms 一行状态）
    output                      dbg_uart_tx,

    // 串口时间同步输入（E4，PC 发 "T"+HHMMSS 设置现实时间）
    input                       uart_rxd,

    // HYM8563 RTC 芯片 I2C 总线（L16/M16）
    output                      i2c_sclk,
    inout                       i2c_sdat
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;


wire        video_read_req;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_req_ack;
wire [8:0]  sd_wrfifo_used;     // 写帧 FIFO 水位（供缩放引擎反压）
wire        frame_write_finish;

// ===================== v30：照片 / RAW 视频 双模式仲裁 =====================
// 两条链路的写端口、SD 扇区读总线都是"独占"的，用 video_mode 静态二选一：
//   video_mode=0 -> sd_card_bmp（照片轮播，原有功能）
//   video_mode=1 -> raw_player（RAW 视频流）
// 检测阶段（detect_done=0）SD 总线交给 raw_player 读扇区 0 的头部，
// 同时 sd_card_bmp 被 video_mode_hold 冻结（不清屏、不扫描）。
wire        video_mode;
wire        detect_done;

wire        bmp_wr_en;
wire [31:0] bmp_wr_data;
wire        bmp_wr_req;
wire [1:0]  bmp_wr_buf;

wire        raw_wr_en;
wire [31:0] raw_wr_data;
wire        raw_wr_req;
wire [1:0]  raw_wr_buf;

// v40【关键】写通路按"现在谁在播"（mode_video）仲裁，不能按"卡上有没有视频"（video_mode）。
//   否则插上带视频的卡后，照片帧会被接到 raw_player 的写口上 —— 照片一帧都写不进 SDRAM。
wire        sd_card_write_en   = mode_video ? raw_wr_en   : bmp_wr_en;
wire [31:0] sd_card_write_data = mode_video ? raw_wr_data : bmp_wr_data;
wire        sd_card_write_req  = mode_video ? raw_wr_req  : bmp_wr_req;

// 共享 SD 扇区读总线
wire        bmp_sd_rd;
wire [31:0] bmp_sd_ra;
wire [4:0]  bmp_sd_rc;
wire        raw_sd_rd;
wire [31:0] raw_sd_ra;
wire [4:0]  raw_sd_rc;
wire [7:0]  sd_rd_data;
wire        sd_rd_dv;
wire        sd_rd_end;
wire        sd_bus_idle;        // v41：SD 控制器真正空闲
wire        sd_init_done;

// v40：video_mode = "这张卡上有 RAW 视频"（静态，上电检测一次）
//      mode_video = "现在正在播视频"（动态，照片播完才切过去）
//   两个分开之后，同一张 FAT32 卡可以既放 4 张 BMP、又放一段 RAW 视频。
reg         mode_video;             // 1 = 显示/播放视频，0 = 显示照片
wire        photo_owner   = detect_done && !mode_video;
wire        has_video     = detect_done && video_mode;
wire        raw_owns_sd   = !detect_done ? 1'b1 : mode_video;
wire        sd_sec_read        = raw_owns_sd ? raw_sd_rd : bmp_sd_rd;
wire [31:0] sd_sec_read_addr   = raw_owns_sd ? raw_sd_ra : bmp_sd_ra;
wire [4:0]  sd_sec_read_cnt    = raw_owns_sd ? raw_sd_rc : bmp_sd_rc;
reg         frame_write_toggle_mem;

// video 帧读取完成：ext_mem_clk -> video_clk 用 toggle 方式跨域
wire        video_read_finish;
reg         read_finish_toggle_mem;

wire [1:0]  write_buf_idx = mode_video ? raw_wr_buf : bmp_wr_buf;
wire [1:0]  disp_buf_idx;

// SD -> video：新图已完整写入备用 buffer
wire        frame_ready_toggle;
wire [1:0]  ready_buf_idx;
wire [1:0]  ready_img_idx;
wire [1:0]  current_image_idx;

// video -> SD：video 已完成 buffer 切换
wire        commit_toggle;

// video 侧真正使用的读取 buffer
wire [1:0]  transition_read_buf_idx;
wire [23:0] transition_rgb;
wire        transition_busy;

// ===================== 第一阶段：运行时间 OSD（稳定版） =====================
wire [7:0]  system_hour;
wire [7:0]  system_minute;
wire [7:0]  system_second;
wire [3:0]  system_hour_tens;
wire [3:0]  system_hour_ones;
wire [3:0]  system_minute_tens;
wire [3:0]  system_minute_ones;
wire [3:0]  system_second_tens;
wire [3:0]  system_second_ones;
wire [23:0] timestamp_rgb;
wire [23:0] param_rgb;
wire [23:0] slogan_rgb;

// ===================== 串口现实时间同步 =====================
wire        rtc_set_tgl;
wire [3:0]  rtc_hour_tens;
wire [3:0]  rtc_hour_ones;
wire [3:0]  rtc_minute_tens;
wire [3:0]  rtc_minute_ones;
wire [3:0]  rtc_second_tens;
wire [3:0]  rtc_second_ones;
wire        rtc_synced;

uart_rtc_sync #(
    .CLK_FREQ_HZ (100_000_000),
    .BAUD        (115200)
) u_uart_rtc_sync (
    .clk             (sd_card_clk),
    .rst             (rst_all),
    .rxd             (uart_rxd),
    .set_tgl         (rtc_set_tgl),
    .rtc_hour_tens   (rtc_hour_tens),
    .rtc_hour_ones   (rtc_hour_ones),
    .rtc_minute_tens (rtc_minute_tens),
    .rtc_minute_ones (rtc_minute_ones),
    .rtc_second_tens (rtc_second_tens),
    .rtc_second_ones (rtc_second_ones),
    .synced          (rtc_synced)
);

// ===================== HYM8563 RTC 芯片驱动 =====================
// 串口命令写入芯片（断电保持），每 10s 从芯片读回装载计时器
wire        rtc_set_time;
wire [23:0] rtc_time_to_set;
wire        rtc_read;
wire [23:0] rtc_time_read;
wire        rtc_cmd_done;
wire        rtc_alive;
wire        pcf8563_scl_w, pcf8563_i, pcf8563_o, pcf8563_oe;

assign i2c_sclk = pcf8563_scl_w;
assign pcf8563_i = i2c_sdat;                       // SDA 输入
assign i2c_sdat  = pcf8563_oe ? pcf8563_o : 1'bz;  // SDA 三态输出

wire        time_load_tgl;
wire [3:0]  ld_hour_tens;
wire [3:0]  ld_hour_ones;
wire [3:0]  ld_minute_tens;
wire [3:0]  ld_minute_ones;
wire [3:0]  ld_second_tens;
wire [3:0]  ld_second_ones;

rtc_time_mgr #(
    .CLK_FREQ_HZ      (100_000_000),
    .READ_PERIOD_SEC  (10),
    .BOOT_DELAY_SEC   (2)
) u_rtc_time_mgr (
    .clk             (sd_card_clk),
    .rst             (rst_all),
    .uart_set_tgl    (rtc_set_tgl),
    .u_hour_tens     (rtc_hour_tens),
    .u_hour_ones     (rtc_hour_ones),
    .u_minute_tens   (rtc_minute_tens),
    .u_minute_ones   (rtc_minute_ones),
    .u_second_tens   (rtc_second_tens),
    .u_second_ones   (rtc_second_ones),
    .load_tgl        (time_load_tgl),
    .ld_hour_tens    (ld_hour_tens),
    .ld_hour_ones    (ld_hour_ones),
    .ld_minute_tens  (ld_minute_tens),
    .ld_minute_ones  (ld_minute_ones),
    .ld_second_tens  (ld_second_tens),
    .ld_second_ones  (ld_second_ones),
    .synced          (),
    .rtc_set_time    (rtc_set_time),
    .rtc_time_to_set (rtc_time_to_set),
    .rtc_read        (rtc_read),
    .rtc_time_read   (rtc_time_read),
    .rtc_cmd_done    (rtc_cmd_done),
    .rtc_alive       (rtc_alive)
);

RTC8563_Driver u_rtc8563_driver (
    .Clk           (sd_card_clk),
    .Rst_n         (~rst_all),
    .Set_Time      (rtc_set_time),
    .Time_to_Set   (rtc_time_to_set),
    .Set_Date      (1'b0),
    .Date_to_Set   (32'd0),
    .Read          (rtc_read),
    .Time_Read     (rtc_time_read),
    .Date_Read     (),
    .Cmd_Done      (rtc_cmd_done),
    .pcf8563_scl   (pcf8563_scl_w),
    .pcf8563_i     (pcf8563_i),
    .pcf8563_o     (pcf8563_o),
    .pcf8563_oe    (pcf8563_oe)
);

// 调试：SD/缩放引擎状态总线
wire [31:0] dbg_sd_a;
wire [31:0] dbg_sd_b;
wire [31:0] dbg_sd_c;

// ===================== 扩展4：亮度/对比度实时调节 =====================
reg  [7:0]  sw_sync0;
reg  [7:0]  sw_sync1;
reg  [7:0]  sw_stable;
reg  [31:0] param_show_cnt;
reg         sw_init_done;       // v37：上电只对齐一次档位，不弹提示
reg  [3:0]  sw_settle;          // v41：等两级同步链真正跟上再取基准值
wire        sw_changed;

wire [3:0]  bright_lvl   = sw_stable[3:0];
wire [3:0]  contrast_lvl = sw_stable[7:4];
wire        param_show;
wire [23:0] bc_rgb;

// display_valid 原本来自 sd_card_clk，进入 video_clk 前做两级同步
reg         display_valid_meta;
reg         display_valid_video;

// read_req_ack 来自 mem_clk，回到 video_clk 前做两级同步
wire        video_read_req_ack_raw;
reg         video_read_req_ack_meta;
reg         video_read_req_ack_sync;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;
// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;

// ===================== v47：音频 PCM 通路 =====================
// 照片帧写入与视频读的口都改由 mux 选择，音频走"只占空隙"的低优先级支路。
wire        fw_rd_en, fw_wr_en;
wire [23:0] fw_rd_addr, fw_wr_addr;
wire [31:0] fw_wr_din;
wire [3:0]  fw_wr_dm;

wire        photo_idle_sig;
wire [8:0]  mel_dbg_note;
// v79：回照片时"屏幕当前在读哪块 buffer"（video_clk 域 -> sd 域两级同步）。
//   视频结束后 transition 会把 read_buf_idx 定在视频最后一块 buffer 上，
//   照片链路据此把第 1 张写进另一块，装载全程不撕裂、也不需要黑屏。
wire [1:0]  disp_buf_live_sd;
// v79：显示通路当前是否在放"视频内容"（含视频结束后的定格帧）
wire        video_shown;
// v79：模式切换辅助
reg         mode_video_v_d;
wire        video_restart;
// v53：整条 PCM（SD->SDRAM->FIFO->I2S）播放链已移除，改用 melody_player 合成旋律。
//   那条链实测占 3,350 LUT / 3,000 寄存器，把 mslices 顶过 4,900 上限。

wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

// 扩展5：音频可视化
wire [23:0] viz_rgb;
// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;
wire        ddc_scl_nc;   // 发送器核 DDC 输出，悬空不接引脚
wire        ddc_sda_nc;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

// ===================== v71：上电/重新配置后的自愈复位 =====================
// 症状：JTAG 下发完 bit 后偶尔黑屏，必须整机断电重启。
// 成因：重新配置时 SD 卡可能正处在一次多扇区突发中间（CMD18），
//       卡内部状态机停在"还在送数据"；而我们的 SPI 主机只在发命令时产生时钟，
//       卡收不到足够时钟就无法退出该状态 -> 初始化 CMD0 一直失败 -> 永远黑屏。
// 对策：① 复位释放后再等 20ms（原来 20ms 就已经有了，这里保留）；
//       ② 若 1.2 秒内 sd_init_done 还没起来，就【主动再复位一次】（最多 3 次），
//          每次复位都会让控制器重新走 CMD0/CMD8/ACMD41 —— 多给几轮机会，
//          绝大多数"卡住了"的现场会在第 2 轮自愈，不用拔电。
//       ③ 每轮强制复位保持 20ms，期间 CS 为高，卡能收到足够多的空闲时钟。
wire        force_rst;
reg  [20:0] fhold_cnt;       // 强制复位保持定时
reg  [1:0]  boot_retry;      // 自愈重试次数（外部复位才清零）
reg  [27:0] boot_wd;         // 1.2s @50MHz = 60_000_000

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_cnt     <= 20'd0;
        rst_all_reg <= 1'b1;
        fhold_cnt   <= 21'd0;
        boot_retry  <= 2'd0;
        boot_wd     <= 28'd0;
    end else if (force_rst) begin
        // 触发一次完整的强制复位（20ms）
        rst_cnt     <= 20'd0;
        rst_all_reg <= 1'b1;
        fhold_cnt   <= 21'd1_000_000;
        boot_retry  <= boot_retry + 2'd1;
        boot_wd     <= 28'd0;
    end else if (fhold_cnt != 21'd0) begin
        // 强制复位保持窗口
        fhold_cnt   <= fhold_cnt - 21'd1;
        rst_all_reg <= 1'b1;
        rst_cnt     <= 20'd0;
        boot_wd     <= 28'd0;
    end else if (rst_all_reg) begin
        // 上电复位阶段：等两个 PLL 都锁定，再稳 20ms 才释放
        if (sys_pll_lock && video_pll_lock) begin
            if (rst_cnt < 20'd1_000_000) begin
                rst_cnt     <= rst_cnt + 1'b1;
                rst_all_reg <= 1'b1;
            end else begin
                rst_all_reg <= 1'b0;
            end
        end else begin
            rst_cnt <= 20'd0;
        end
        boot_wd <= 28'd0;
    end else begin
        // 已释放：盯着 sd_init_done，超时就自愈
        if (!sd_init_done) begin
            if (boot_wd != 28'd60_000_000)
                boot_wd <= boot_wd + 28'd1;
        end else begin
            boot_wd <= 28'd0;
        end
    end
end

assign force_rst = (!rst_all_reg) && (fhold_cnt == 21'd0) &&
                   (!sd_init_done) && (boot_retry != 2'd3) &&
                   (boot_wd >= 28'd60_000_000);

assign rst_all = rst_all_reg;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);
// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);
// ext_mem_clk 域事件统一转成 toggle：
// 1) SDRAM 写满一帧 -> sd_card_clk 域的 write_finish_toggle
// 2) 视频完整读完一帧 -> video_clk 域的 read_finish_toggle
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all) begin
        frame_write_toggle_mem <= 1'b0;
        read_finish_toggle_mem <= 1'b0;
    end else begin
        if (frame_write_finish)
            frame_write_toggle_mem <= ~frame_write_toggle_mem;

        if (video_read_finish)
            read_finish_toggle_mem <= ~read_finish_toggle_mem;
    end
end

// sd_card_clk -> video_clk
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        display_valid_meta <= 1'b0;
        display_valid_video <= 1'b0;
    end else begin
        display_valid_meta <= display_valid;
        display_valid_video <= display_valid_meta;
    end
end

// mem_clk -> video_clk 的 read_req_ack CDC
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        video_read_req_ack_meta <= 1'b0;
        video_read_req_ack_sync <= 1'b0;
    end else begin
        video_read_req_ack_meta <= video_read_req_ack_raw;
        video_read_req_ack_sync <= video_read_req_ack_meta;
    end
end

// ===================== 扩展4：拨码开关同步 + 参数 OSD 显示计时 =====================
// 拨码开关是慢变信号，两级同步后与 stable 比较，变化时让 OSD 显示 2 秒。
assign sw_changed = (sw_stable != sw_sync1);

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        sw_sync0        <= 8'd0;
        sw_sync1        <= 8'd0;
        sw_stable       <= 8'd0;
        sw_init_done    <= 1'b0;
        sw_settle       <= 4'd0;
        param_show_cnt  <= 32'd0;
    end else begin
        sw_sync0 <= sw;
        sw_sync1 <= sw_sync0;

        if (!sw_init_done) begin
            // v41 修 bug：v37 在复位释放后的【第一拍】就把 sw_sync1 当基准，
            //   但那时两级同步链还是复位值 0（sw_sync0/sw_sync1 各要一拍才跟上）。
            //   于是 sw_stable 记成 0，下一拍 sw_changed 立刻发现"变化"，
            //   拨码停在非 0 档时每次开机照样白闪 2 秒 —— v37 的修复等于没生效。
            //   现在先让同步链跑满 16 拍（640ns，远大于两级同步），再取基准。
            if (sw_settle != 4'd15) begin
                sw_settle <= sw_settle + 4'd1;
            end else begin
                sw_stable    <= sw_sync1;
                sw_init_done <= 1'b1;
            end
        end else if (sw_changed) begin
            sw_stable      <= sw_sync1;
            param_show_cnt <= 32'd50_000_000;    // v37：2 秒 @ 25MHz
        end else if (param_show_cnt != 32'd0) begin
            param_show_cnt <= param_show_cnt - 1'b1;
        end
    end
end

// v37：只在"拨码刚变化"后显示 2 秒，之后即使亮度/对比度仍非默认值也隐藏。
//   （旧版还有 (bright_lvl != 0) || (contrast_lvl != 0) 这个常驻条件，
//    导致调节完文字一直挂在屏幕上。）
assign param_show = (param_show_cnt != 32'd0);

// ===================== v35：按键消抖（全工程唯一一份） =====================
// 照片链路和 RAW 链路共用同一对按键，消抖只做一次，再分发给两个播放器：
//   实现见文件末尾 key_press_debounce（v39 起是"20ms 积分 + 稳定松开才重新武装"），
//   一次物理按压在数学上只能产生 1 个脉冲，与抖动长短无关。
// 放在顶层还有一个好处：sd_card_bmp 和 raw_player 对"这一次按键"的理解
// 永远一致，不会出现一个模块收到、另一个没收到。
wire key1_press;
wire key2_press;

key_press_debounce #(
    .CLK_FREQ_HZ (100_000_000),
    .DEBOUNCE_MS (20),
    .LOCKOUT_MS  (50)
) u_key1_deb (
    .clk        (sd_card_clk),
    .rst        (rst_all),
    .button_in  (key1),
    .press_pulse(key1_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (100_000_000),
    .DEBOUNCE_MS (20),
    .LOCKOUT_MS  (50)
) u_key2_deb (
    .clk        (sd_card_clk),
    .rst        (rst_all),
    .button_in  (key2),
    .press_pulse(key2_press)
);

wire sd_auto_play;          // v36：照片模式（FAT 卡）的轮播状态，供 S1 提示用

// ===================== v40：照片 / 视频 内容切换 =====================
//   照片组播完（第 4 张再按 S0，或轮播周期走完）-> sd_video_req
//   视频段按 S0 -> 立刻回照片组第 1 张
//   两个条件都在 sd_card_clk 域，切换只改一根 mode_video，不存在竞态。
wire sd_video_req;
reg  sd_back_first;         // 回到照片时给 sd_card_bmp 的单拍"重载第 1 张"
reg  mv_prev;
// v46：轮播模式下视频播完 -> 自动回第 1 张，继续轮播
wire vid_done_sd;

// ===================== v58【修复①】轮播第二圈视频秒退 =====================
//   现象：轮播模式下，第一遍视频播完 -> 自动回第 1 张正常；但 **18s×4 之后第二次
//         进视频时，视频只闪一帧就立刻又回到照片**（整圈再也看不到视频）。
//   根因：raw_player 的 vid_done 是电平，play 落下时【不清】它（只在自己
//         ST_IDLE 且 play=1 时清）。于是第二次 mode_video 拉高的那一拍，
//         vid_done 还是上一遍留下的 1，组合出来的 auto_back_from_video 立刻
//         为 1 -> mode_video 当拍又落回 0。raw_player 连 ST_FRAME_WAIT 都没进。
//   修复：给"自动回照片"加一个进入视频后必须稳定一小段时间的条件（1us，
//         远大于 raw_player 清 vid_done 所需的 2 拍）。
reg  [11:0] mv_hold_cnt;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all)
        mv_hold_cnt <= 12'd0;
    else if (!mode_video)
        mv_hold_cnt <= 12'd0;
    else if (mv_hold_cnt != 12'hFFF)
        mv_hold_cnt <= mv_hold_cnt + 12'd1;
end
wire mv_stable = (mv_hold_cnt >= 12'd100);   // 1us @100MHz

wire auto_back_from_video = mode_video && vid_done_sd && sd_auto_play && mv_stable;

// v58【修复②】：原来这里有一个 vid_manual_exit，想在"视频段按 S0 退出"时顺手
//   把轮播关掉。两个问题：
//     ① 它在 mode_video 落下沿之后一拍才采样 key1_press，而按键脉冲只有 1 拍宽，
//        采到时早已归 0 —— 这条逻辑从来没生效过；
//     ② 就算修好也不该这样：照片段按 S0 是"手动切一张，轮播状态不变"，
//        视频段按 S0 却去关轮播，两处行为不一致，用户会觉得"轮播自己没了"。
//   现在统一成：**S0 只负责切内容，任何时候都不改 S1 的轮播开关**。
//   所以 video_key_exit 恒接 0（bmp 里那条 auto_play_en<=0 会被综合掉）。
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        mode_video    <= 1'b0;
        sd_back_first <= 1'b0;
        mv_prev       <= 1'b0;
    end else begin
        sd_back_first <= 1'b0;
        mv_prev       <= mode_video;

        if (!mode_video) begin
            // 照片组交棒（只有卡上真有视频才切）
            if (sd_video_req && has_video)
                mode_video <= 1'b1;
        end else if (key1_press || auto_back_from_video) begin
            // 视频段 S0：不管播到第几帧，立刻回照片组
            // v46：视频播完且轮播开着 -> 也回照片组（继续轮播）
            mode_video <= 1'b0;
        end

        // 落下沿产生一拍"重载第 1 张"
        if (mv_prev && !mode_video)
            sd_back_first <= 1'b1;
    end
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    // v44：看门狗是"源流无推进"计时，正常读盘（哪怕 1920x1080 要 3s）一直在喂狗，
    //   不会误触。给 2 秒是为了让偶发读失败能快速重试（最多 4 次 ≈ 8 秒）。
    .LOAD_TIMEOUT_SEC  (2),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    // 扩展3：0=拉伸填满 1=等比完整(黑边居中) 2=等比裁剪 3=1:1居中
    .SCALE_MODE        (2'd1)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (key1_press),
    .key_auto          (key2_press),
    .state_code        (state_code),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (bmp_wr_buf),
    .disp_buf_idx      (disp_buf_idx),

    .frame_ready_toggle(frame_ready_toggle),
    .ready_buf_idx     (ready_buf_idx),
    .ready_img_idx     (ready_img_idx),
    .commit_toggle     (commit_toggle),

    .write_req         (bmp_wr_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (bmp_wr_en),
    .write_data        (bmp_wr_data),
    .auto_play_en      (sd_auto_play),
    .wr_fifo_used      (sd_wrfifo_used),
    .dbg_a             (dbg_sd_a),
    .dbg_b             (dbg_sd_b),
    .dbg_c             (dbg_sd_c),

    // v30：SD 总线外提到顶层，按模式与 raw_player 共用
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (bmp_sd_rd),
    .sd_sec_read_addr       (bmp_sd_ra),
    .sd_sec_read_cnt        (bmp_sd_rc),
    .sd_sec_read_data       (sd_rd_data),
    .sd_sec_read_data_valid (sd_rd_dv),
    .sd_sec_read_end        (sd_rd_end),
    .sd_bus_idle            (sd_bus_idle),
    .video_mode_hold        (!photo_owner),
    .has_video              (has_video),
    .video_req              (sd_video_req),
    .back_first             (sd_back_first),
    // v46：1 = 视频段是用户按 S0 主动退出（要解除轮播）；
    //       0 = 轮播模式视频播完自动回照片（要保持轮播继续）
    // v58：S0 不改变轮播开关（与照片段行为一致），恒接 0
    .video_key_exit         (1'b0),
    .sd_locked              (1'b0),
    .photo_idle             (photo_idle_sig),
    // v79：告诉照片链路"屏幕当前在读哪块 buffer"，第 1 张要写进另一块
    .disp_buf_live          (disp_buf_live_sd)
);

// ===================== v30：共享 SD 控制器（照片/视频共用一条 SPI）=====================
sd_card_top sd_card_top_m0(
    .clk                    (sd_card_clk),
    .rst                    (rst_all),
    .SD_nCS                 (sd_ncs),
    .SD_DCLK                (sd_dclk),
    .SD_MOSI                (sd_mosi),
    .SD_MISO                (sd_miso),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_cnt        (sd_sec_read_cnt),
    .sd_sec_read_data       (sd_rd_data),
    .sd_sec_read_data_valid (sd_rd_dv),
    .sd_sec_read_end        (sd_rd_end),
    .sd_bus_idle            (sd_bus_idle),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

// ===================== v30：RAW 视频流播放器 =====================
// 上电先读扇区 0 的自定义头：
//   magic "RAWV" + 320x240 + RGB565 + 帧数 -> 进入视频模式（video_mode=1）
//   否则 detect_done=1 且 video_mode=0，整条链路让位给照片轮播（原功能不变）
wire        raw_frame_ready_toggle;
wire [1:0]  raw_ready_buf_idx;
wire        raw_commit_toggle;
wire        phase_video_raw;        // v34：0=片头照片段 1=视频段（sd_card_clk 域）
wire [1:0]  raw_photo_img_idx;      // v34：当前照片序号
wire        raw_auto_play;          // v35：RAW 模式的轮播开关（S1 切换）
wire [31:0] raw_dbg_a;
wire [31:0] raw_dbg_b;
wire [31:0] raw_dbg_c;

// ===================== v42：commit 回程彻底拆线 =====================
// 原来把 transition 和 swap 的 commit 合并成一根 cm_merged 送 raw_player。
// 实测这是"视频卡第一帧 / 顶掉照片"的根因：
//   视频段 swap 每帧翻一次 commit，但合并逻辑的 else-if 链在高频/不定态下
//   会把照片侧的 commit 优先处理，raw_commit_toggle 的翻转被大量吞掉，
//   同时 cm_merged 出现乱翻 → raw_player 收到大量【假 commit】→ 提前认为
//   "本帧已上屏" → disp_buf 记录错 → 下一帧写进正在显示的 buffer。
//
// 现在两条 commit 各自专线：
//   · transition 的 commit_toggle  -> sd_card_bmp（原本就是专线，不动）
//   · swap 的 raw_commit_toggle    -> 两级同步到 sd 域 -> raw_player
// 跨域只用 toggle（每帧最多翻一次，83ms 间隔，远慢于 20ns 同步窗口）。
reg cm_raw_meta, cm_raw_s;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        cm_raw_meta <= 1'b0;
        cm_raw_s    <= 1'b0;
    end else begin
        cm_raw_meta <= raw_commit_toggle;
        cm_raw_s    <= cm_raw_meta;
    end
end

raw_player #(
    .CLK_FREQ_HZ        (100_000_000),
    .FPS                (12),
    .SRC_W              (320),
    .SRC_H              (240),
    .HSCALE             (2),
    .VSCALE             (2),
    .SECT_PER_BURST     (30),
    .DATA_START_SECTOR  (32'd1),
    .STALL_MS           (300),
    .COMMIT_TIMEOUT_SEC (3)
) u_raw_player (
    .clk                    (sd_card_clk),
    .rst                    (rst_all),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (raw_sd_rd),
    .sd_sec_read_addr       (raw_sd_ra),
    .sd_sec_read_cnt        (raw_sd_rc),
    .sd_sec_read_data       (sd_rd_data),
    .sd_sec_read_data_valid (sd_rd_dv),
    .sd_sec_read_end        (sd_rd_end),
    .write_req              (raw_wr_req),
    .write_req_ack          (sd_card_write_req_ack),
    .wr_fifo_used           (sd_wrfifo_used),
    .write_en               (raw_wr_en),
    .write_data             (raw_wr_data),
    .write_buf_idx          (raw_wr_buf),
    .write_finish_toggle    (frame_write_toggle_mem),
    .commit_toggle          (cm_raw_s),           // v42：只吃 swap 的 commit（专线）
    .frame_ready_toggle     (raw_frame_ready_toggle),
    .ready_buf_idx          (raw_ready_buf_idx),
    .video_mode             (video_mode),
    .detect_done            (detect_done),
    // v40：视频只受顶层 mode_video 控制；按键全部由照片链路/top 处理
    .play                   (mode_video && has_video),
    // v41：首帧写照片链路当前没显示的那块 buffer（照片张数为奇数时才不会撕裂）
    .first_buf              (~disp_buf_idx[0]),
    .key_next               (1'b0),
    .key_auto               (1'b0),
    .auto_play              (raw_auto_play),
    .phase_video            (phase_video_raw),
    .photo_img_idx          (raw_photo_img_idx),
    .vid_done_o             (vid_done_sd),
    .dbg_a                  (raw_dbg_a),
    .dbg_b                  (raw_dbg_b),
    .dbg_c                  (raw_dbg_c)
);

// ===================== v31：video_mode 跨到 video_clk 域的两级同步 =====================
// video_mode 在 sd_card_clk 域产生（读卡器解析完头部后一次性翻转，之后恒不变）。
// 显示通路（base_rgb / rd_buf_sel / disp_en / osd_en / swap 输入选择）都在 video_clk 域，
// 直接组合使用会形成一条"sd_card_clk 发起 + 75ns 宽的组合长路"，
// STA 在 40ns 的 video_clk 周期下报 -13.4ns。
// 做成两级同步后：既消除亚稳态，又让 STA 只看到"同步寄存器 -> 本地组合"这一段。
// 代价是显示模式切换晚 2 个 video_clk（80ns），对一次性切换完全无影响。
reg video_mode_meta;
reg video_mode_v;
reg mode_video_meta;
reg mode_video_v;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        video_mode_meta <= 1'b0;
        video_mode_v    <= 1'b0;
        mode_video_meta <= 1'b0;
        mode_video_v    <= 1'b0;
    end else begin
        video_mode_meta <= video_mode;
        video_mode_v    <= video_mode_meta;
        // v40：mode_video（动态"现在放视频"）同样两级同步后再进显示通路
        mode_video_meta <= mode_video;
        mode_video_v    <= mode_video_meta;
    end
end

// ===================== v34：照片段 / 视频段的显示通路仲裁 =====================
// 照片段走 image_transition_ctrl（8 帧黑场淡入淡出，和照片模式一致），
// 视频段走 video_frame_swap（直切）。两相之间按 phase_video 切换。
//
// 必须处理干净的三件事：
//  1) 相位信号是在 sd_card_clk 域产生的，**必须两级同步**再到 video_clk 用
//     （v32 的教训：video_mode 直接组合进显示通路，STA 报 -13.4ns）。
//  2) 两个消费模块都靠"toggle 输入 + 内部同步"工作。相位切换时若把输入从一个
//     源直接换到另一个源，电平跳变本身就会被当成一次 toggle（假事件）。
//     做法：给 transition 的输入在视频段"冻结"在切相瞬间的值，保证换源不跳变；
//     swap 在照片段给恒 0，彻底静默（否则它会把照片帧当视频帧一路 commit）。
//  3) commit 回程：照片段由 transition 产生、视频段由 swap 产生，
//     两条 toggle 在 video_clk 域合并成一条再送回 raw_player。
reg [1:0] raw_fr_s;                // raw_frame_ready_toggle 两级同步
reg [1:0] raw_rb_s;                // raw_ready_buf_idx 两级同步（准静态总线）
reg [1:0] raw_pi_meta, raw_pi_s;   // 照片序号同步
reg       phase_meta, phase_video_v;   // 相位两级同步（0=照片段 1=视频段）
// （v40 起不再需要 tr_fr_hold / tr_rb_hold：两个切帧器的输入源固定，不换源）

// 判据（先声明再使用）
wire raw_video_mode_ok = mode_video_v;                          // 当前在放视频（v40）
wire show_video_phase  = raw_video_mode_ok && phase_video_v;     // 当前处于视频段

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        raw_fr_s     <= 2'b00;
        raw_rb_s     <= 2'b00;
        raw_pi_meta  <= 2'b00;
        raw_pi_s     <= 2'b00;
        phase_meta   <= 1'b0;
        phase_video_v<= 1'b0;
    end else begin
        raw_fr_s     <= {raw_fr_s[0], raw_frame_ready_toggle};
        raw_rb_s     <= {raw_rb_s[0], raw_ready_buf_idx};
        raw_pi_meta  <= raw_photo_img_idx;
        raw_pi_s     <= raw_pi_meta;
        phase_meta   <= phase_video_raw;
        phase_video_v<= phase_meta;
    end
end

// v40：两个"切帧器"各接一个【固定】的帧就绪源，不再随相位换源。
//   换源会在切换那一拍造成电平跳变，被下游当成一次假 toggle（闪一帧旧 buffer）。
//   现在：
//     · transition 永远只看 sd_card_bmp 的 frame_ready_toggle
//       —— 视频段 sd_card_bmp 被冻结，根本不产生 toggle，天然静默；
//     · swap 永远只看 raw_player 的 raw_fr_s[1]
//       —— 照片段 raw_player 处于 ST_IDLE，也不会产生 toggle。
//   两边都不需要"冻结/恒 0"的补丁，切换瞬间电平完全连续。
wire        fr_to_trans = frame_ready_toggle;
wire [1:0]  rb_to_trans = ready_buf_idx;
wire [1:0]  ri_to_trans = ready_img_idx;

wire        fr_to_swap  = raw_fr_s[1];
wire [1:0]  rb_to_swap  = raw_rb_s;



// ===================== v30：视频专用无转场切帧 =====================
// 照片的 8 帧黑场淡入淡出（~133ms）比 12fps 的整帧预算（83ms）还长，
// 视频必须直切：收到新帧 -> 等当前帧 SDRAM 读完 -> 立刻改 read_addr_index -> 回 commit
wire        swap_valid;
wire [1:0]  swap_buf;
wire [23:0] swap_rgb;
wire        swap_busy;
wire [7:0]  swap_dbg_frames;

video_frame_swap u_video_frame_swap (
    .video_clk                  (video_clk),
    .rst                        (rst_all),
    .vs                         (vs),
    .de                         (de),
    // v79：每轮视频开始清一次"已有有效画面"，避免闪上一轮留下的旧 buffer
    .restart                    (video_restart),
    .frame_ready_toggle_async   (fr_to_swap),
    .ready_buf_idx_async        (rb_to_swap),
    .read_finish_toggle_async   (read_finish_toggle_mem),
    .rgb_in                     (vout_data_raw),
    .read_buf_idx               (swap_buf),
    .rgb_out                    (swap_rgb),
    .commit_toggle              (raw_commit_toggle),
    .valid                      (swap_valid),
    .swap_busy                  (swap_busy),
    .dbg_frames                 (swap_dbg_frames)
);

// v79：mode_video_v 上升沿 = 新一轮视频开始
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) mode_video_v_d <= 1'b0;
    else         mode_video_v_d <= mode_video_v;
end
assign video_restart = mode_video_v & ~mode_video_v_d;

// 调试串口：把 SD/缩放引擎内部状态明文发出来
// v79：D/E/F 三个"频谱调试字"已经断开（恒 0）。
//   它们要走 toggle 握手从 video_clk 搬到 sd 域（3 个 32 位寄存器 x 3 级
//   + audio_viz 内部的 64 位压包逻辑），实测吃掉 ~200 LUT。
//   现在 mslice 只剩不到 50 个余量，先把这块诊断让出来 ——
//   A/B/C 三个字（照片/视频状态机 + S0 诊断 + 显示通路镜像）全部保留，
//   `tools/uart_s0_mon.py` 读的 dbg_c 不受影响。

uart_debug_tx #(
    .CLK_FREQ_HZ (100_000_000),
    .BAUD        (115200)
) u_uart_debug_tx (
    .clk   (sd_card_clk),
    .rst   (rst_all),
    // 调试口按"当前内容"选择 A 字：视频段看 raw 状态机（state/frame_idx），
    // 照片段看照片链路（img_found_count / display_valid）。
    // B/C 恒为 v41d 诊断字：
    //   B = {cnt_fr[7:0], cnt_cm[7:0], cnt_wfin[7:0], cnt_bf[7:0]}
    //       raw 就绪 toggle 数 / commit 回数 / SDRAM 写完成数 / 回首图请求数
    //   C = {16'h0000, diag_s[15:0]}  显示通路镜像（位定义见 diag_v 处注释）
    .dbg_a (mode_video ? raw_dbg_a : dbg_sd_a),
    // v50：B 字临时改成音频进度，用来判断"到底卡在搬数据还是卡在放音"
    //   [8:0]  {当前音高索引, 旋律指针}
    //   [15:0]  issued     refill 已发出的读请求数
    .dbg_b ({23'd0, mel_dbg_note}),
    .dbg_c ({16'd0, diag_s}),
    .dbg_d (32'd0),
    .dbg_e (32'd0),
    .dbg_f (32'd0),
    .tx    (dbg_uart_tx)
);


// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack_sync),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// ===================== v79：统一显示仲裁 + 自上而下揭幕 =====================
// v78 及以前这里是两路 mux：视频走 swap_rgb/swap_buf，照片走 transition。
// 视频结束回照片时靠 photo_blank 把屏压黑，等第 1 张重载完（0.4~2.8s）再放行
// —— 那一段就是用户报的"黑屏"。
//
// v79 把"视频段的读 buffer 选择"也交给 image_transition_ctrl：
//   · 视频段：它直接跟随 swap_buf（read_buf_idx = video_buf）
//   · 视频结束：**保持**最后一块 buffer，屏幕继续显示视频最后一帧（定格）
//   · 第 1 张照片写进另一块，写完在帧边界切过去 + 自上而下揭幕
// 输出通路从头到尾没有被关闭，所以没有黑屏、也没有闪烁。
// 数据源始终是 vout_data_raw（SDRAM 同一次读出），所以两条路切换时
// 像素内容完全一致，不存在"切过去闪一帧"的问题。
image_transition_ctrl #(
    .FADE_FRAMES (8)
) u_image_transition_ctrl (
    .video_clk                  (video_clk),
    .rst                        (rst_all),
    // v79：视频相仲裁。用 mode_video_v（交棒那一刻就生效）而不是
    //   show_video_phase（要等 raw_player 识别完头部），否则视频开头那几十
    //   毫秒里照片侧还可能切一次 read_buf_idx，造成 buffer 号错位。
    .video_phase                (mode_video_v),
    .video_valid                (swap_valid),
    .video_start                (video_restart),
    .video_buf                  (swap_buf),
    .vs                         (vs),
    .de                         (de),
    .read_finish_toggle_async   (read_finish_toggle_mem),
    .frame_ready_toggle_async   (fr_to_trans),
    .ready_buf_idx_async        (rb_to_trans),
    .ready_img_idx_async        (ri_to_trans),
    .rgb_in                     (vout_data_raw),
    .read_buf_idx               (transition_read_buf_idx),
    .rgb_out                    (transition_rgb),
    .commit_toggle              (commit_toggle),
    .current_image_idx          (current_image_idx),
    .transition_busy            (transition_busy),
    .video_shown                (video_shown)
);

// ===================== v79：显示路径（只有一条）=====================
// transition 已经把"视频段跟随 swap_buf / 照片段自己维护 / 视频结束保持"
// 全部收进来了，这里不再需要 mux。
wire [23:0] base_rgb   = transition_rgb;
wire [1:0]  rd_buf_sel = transition_read_buf_idx;
// v79：disp_en 不再被 photo_blank 掐断 —— 只要模式/画面有效就一直开着。
wire        disp_en    = raw_video_mode_ok | display_valid_video;
// 视频段没有转场，OSD 无需避让；照片段转场（含揭幕）期间关闭 OSD
wire        osd_en     = disp_en && (video_shown || !transition_busy);

// v79：把"屏幕当前在读哪块 buffer"送回 sd 域。
//   transition 在视频结束后会把它**冻结**在视频最后一块 buffer 上，
//   直到第 1 张照片写好、帧边界切过去才变，所以这里两级同步足够，
//   不存在"边沿正好落在采样窗口"的问题（慢变量，回照片时静止数百毫秒）。
reg [1:0] disp_bl_meta, disp_bl_sync;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        disp_bl_meta <= 2'd0;
        disp_bl_sync <= 2'd0;
    end else begin
        disp_bl_meta <= transition_read_buf_idx;
        disp_bl_sync <= disp_bl_meta;
    end
end
assign disp_buf_live_sd = disp_bl_sync;

// ===================== v41d：显示通路诊断镜像 =====================
// 把 video_clk 域显示仲裁的关键状态打包成 16 位，两级同步到 sd 域给串口。
// 位定义（C 字低 16 位）:
//   [15]   vid_show            1=显示通路当前走视频 swap 侧
//   [14]   swap_valid          swap 已完成过首帧切换
//   [13]   show_video_phase    视频相（mode_video_v && phase_video_v）
//   [12]   mode_video_v
//   [11]   phase_video_v
//   [10:9] swap_buf            swap 当前读 buffer
//   [8:7]  transition_read_buf_idx  照片转场当前读 buffer
//   [6:5]  rd_buf_sel          实际送到 SDRAM 读口的 buffer
//   [4:3]  disp_buf_idx        照片链路认为的显示 buffer（sd 域慢变，直采）
//   [2]    wr_vflip_now        当前写行序（1=翻转/BMP 0=直写/RAW）
//   [1]    frame_write_finish  最近一次写完成电平（诊断采样）
//   [0]    0
reg [15:0] diag_v;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        diag_v <= 16'd0;
    end else begin
        diag_v <= {video_shown, swap_valid, show_video_phase, mode_video_v,
                   phase_video_v, swap_buf, transition_read_buf_idx,
                   rd_buf_sel, disp_buf_idx,
                   mode_video ? 1'b0 : 1'b1, frame_write_finish, 1'b0};
    end
end

reg [15:0] diag_meta, diag_s;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        diag_meta <= 16'd0;
        diag_s    <= 16'd0;
    end else begin
        diag_meta <= diag_v;
        diag_s    <= diag_meta;
    end
end

// v41d：四个 8 位事件计数器（sd 域），够看出"哪条链断了"
//   [31:24] cnt_fr    raw_player 发出的 frame_ready_toggle 翻转次数（写完一帧 +1）
//   [23:16] cnt_cm    cm_merged 翻转次数（swap/transition 回的 commit 总数）
//   [15:8]  cnt_wfin  SDRAM 写控制器 write_finish 次数（照片+视频共用）
//   [7:0]   cnt_bf    sd_back_first 脉冲次数（S0 从视频回照片）
reg [7:0] cnt_fr, cnt_cm, cnt_wfin, cnt_bf;
reg       fr_lat, cm_lat, wfin_lat;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        cnt_fr   <= 8'd0;  cnt_cm   <= 8'd0;
        cnt_wfin <= 8'd0;  cnt_bf   <= 8'd0;
        fr_lat   <= 1'b0;  cm_lat   <= 1'b0;  wfin_lat <= 1'b0;
    end else begin
        if (raw_frame_ready_toggle != fr_lat) begin
            fr_lat <= raw_frame_ready_toggle;
            cnt_fr <= cnt_fr + 8'd1;
        end
        if (cm_raw_s != cm_lat) begin
            cm_lat <= cm_raw_s;
            cnt_cm <= cnt_cm + 8'd1;
        end
        if (frame_write_finish != wfin_lat) begin
            wfin_lat <= frame_write_finish;
            cnt_wfin <= cnt_wfin + 8'd1;
        end
        if (sd_back_first)
            cnt_bf <= cnt_bf + 8'd1;
    end
end

// 首图提交前黑屏；后续切图由 transition_ctrl 控制 RGB 淡入淡出
frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (fw_rd_en),
    .App_rd_addr       (fw_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack_raw),
    .read_finish       (video_read_finish),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (rd_buf_sel),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (fw_wr_en),
    .App_wr_addr       (fw_wr_addr),
    .App_wr_din        (fw_wr_din),
    .App_wr_dm         (fw_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    // 照片 BMP 是 bottom-up -> 翻转；RAW 视频是 top-down -> 不翻转
    // v40【关键】行序跟着"现在谁在写"：BMP 是 bottom-up 必须翻转，RAW 是 top-down 不翻转。
    //   用 mode_video 而不是 video_mode —— 否则带视频的卡上，照片会上下颠倒。
    .wr_vflip          (mode_video ? 1'b0 : 1'b1),
    .wr_fifo_used      (sd_wrfifo_used)
);

// v47：SDRAM 读写口仲裁（音频只占视频读的空隙 + 照片完全不写的时候）
assign App_rd_en   = fw_rd_en;
assign App_rd_addr = fw_rd_addr;
assign App_wr_en   = fw_wr_en;
assign App_wr_addr = fw_wr_addr;
assign App_wr_din  = fw_wr_din;
assign App_wr_dm   = fw_wr_dm;

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);
// ===================== v53：单音合成旋律（替代 PCM 播放链）=====================
// 与按键/模式完全无关：上电就一直循环演奏，不受任何按键影响。
// 旋律取自 10月23日.wav 的主旋律音高序列，用方波单音演奏。
piano_player u_piano_player (
    .clk        (audio_mclk),
    .rst        (rst_all),
    .play       (1'b1),
    .i2s_bclk   (audio_i2s_bclk),
    .i2s_lrclk  (audio_i2s_lrck),
    .i2s_data   (audio_i2s_dout),
    .dbg_note   (mel_dbg_note)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_all),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);
// ===================== 第一阶段：系统运行时间 OSD（稳定版） =====================
// video_clk = 25.000 MHz，精确 25,000,000 个时钟 = 1 秒。
// Timer 直接维护BCD数字，避免在每个像素周期执行除法/取模。
system_timer_25m_v2 #(
    .CLK_FREQ_HZ (25_000_000)
) u_system_timer_25m_v2 (
    .clk         (video_clk),
    .rst         (rst_all),
    .rtc_set_tgl (time_load_tgl),
    .rtc_hour_tens   (ld_hour_tens),
    .rtc_hour_ones   (ld_hour_ones),
    .rtc_minute_tens (ld_minute_tens),
    .rtc_minute_ones (ld_minute_ones),
    .rtc_second_tens (ld_second_tens),
    .rtc_second_ones (ld_second_ones),
    .hour        (system_hour),
    .minute      (system_minute),
    .second      (system_second),
    .hour_tens   (system_hour_tens),
    .hour_ones   (system_hour_ones),
    .minute_tens (system_minute_tens),
    .minute_ones (system_minute_ones),
    .second_tens (system_second_tens),
    .second_ones (system_second_ones)
);

// ===================== 扩展4：亮度 / 对比度实时调节 =====================
// 位置：转场输出之后、OSD 之前。只作用于图像本身，
//       时间戳 / 参数面板 / 字幕不受影响，保证 OSD 始终清晰可读。
video_bc_adjust u_video_bc_adjust (
    .clk          (video_clk),
    .rst          (rst_all),
    .enable       (disp_en),
    .bright_lvl   (bright_lvl),
    .contrast_lvl (contrast_lvl),
    .rgb_in       (base_rgb),
    .rgb_out      (bc_rgb)
);

// 右上角黑色时间戳。转场期间关闭OSD。
timestamp_osd_v2 #(
    .TIMESTAMP_X (556),
    .TIMESTAMP_Y (16),
    .CHAR_W      (8),
    .CHAR_H      (16),
    .FONT_RGB    (24'hFFFFFF)
) u_timestamp_osd_v2 (
    .clk          (video_clk),
    .rst          (rst_all),
    .enable       (osd_en),
    .vs           (vs),
    .de           (de),
    .rgb_in       (bc_rgb),
    .hour_tens    (system_hour_tens),
    .hour_ones    (system_hour_ones),
    .minute_tens  (system_minute_tens),
    .minute_ones  (system_minute_ones),
    .second_tens  (system_second_tens),
    .second_ones  (system_second_ones),
    .rgb_out      (timestamp_rgb)
);

// ===================== 扩展4：亮度/对比度参数 OSD =====================
// 左上角半透明面板：B / C 两行（v29 去掉了原来的第三行「S 缩放模式」）。
// v37：换成图标 + 中文标签 + 大号数字的版式（照参考图），无底框、无压暗。
//   第一行「◐ 对比度 + 0 %」，第二行「☀ 亮度 + 70 %」，纯白叠加。
bc_osd #(
    .BOX_X   (20),         // v39：整块面积约为旧版的 52%
    .BOX_Y   (4),
    .BOX_W   (216),
    .BOX_H   (64),
    .ICON_X  (28),
    .ICON_SZ (28),
    .TEXT_X  (64),
    .ROW0_Y  (8),          // 对比度行
    .ROW1_Y  (40),         // 亮度行
    .DIM_K   (8'd51)       // 背景 = 原图 x20%（压暗 80%）
) u_bc_osd (
    .clk          (video_clk),
    .rst          (rst_all),
    .enable       (osd_en && param_show),
    .vs           (vs),
    .de           (de),
    .rgb_in       (timestamp_rgb),
    .bright_lvl   (bright_lvl),
    .contrast_lvl (contrast_lvl),
    .rgb_out      (param_rgb)
);

// ===================== v36：S1 轮播状态浮字提示 =====================
// 按 S1 后，在左上角 B/C 面板（x=16..68）右侧显示 1 秒白字：
//   开启轮播 -> 「开始轮播」；解除轮播 -> 「解除轮播」
// 位置 x=72、y=10（24px 字在 44px 面板里垂直居中），与参数面板同一行高度。
//
// 【v36b 修 bug：原来"开始/解除"总是显示同一个字】
//   旧做法是在 video_clk 域用 auto_sync 判断"按下前"的状态，但
//   auto_play 的翻转发生在 sd_card_clk 域、且 auto_sync 的同步链（2 拍 @25MHz
//   = 80ns）比 key2 的 toggle 跨域链（3~4 拍）更快，等 video 域拿到脉冲时
//   auto_sync 早已变成"按下后"的新值 —— 于是两次按都读到同一个状态。
//   现在把整个提示状态机搬到 sd_card_clk 域：按键、auto 状态、计时全在同一域，
//   按下那一拍采到的 auto 必然是旧值（翻转用的是非阻塞赋值，下一拍才生效）。
//   hint_on / hint_mode 是慢变量，再用两级同步送到 video_clk 域去画字。
// v40：照片统一走 sd_card_bmp，轮播状态也只认它的（原来 RAW 卡上取 raw_auto_play，
//   而 v40 起 raw_player 不再接按键，会让提示字永远显示"开始轮播"）
wire auto_now_sd = sd_auto_play;

reg        hint_on_sd;
reg        hint_mode_sd;
reg [26:0] hint_cnt_sd;

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        hint_on_sd   <= 1'b0;
        hint_mode_sd <= 1'b0;
        hint_cnt_sd  <= 27'd0;
    end else if (key2_press) begin
        // v41：视频段按 S1 什么都不做（sd_card_bmp 被 video_mode_hold 冻结，
        //   轮播状态根本不会翻转）。原来这里照样弹"开始轮播"，
        //   用户按下去看到字以为生效了、画面却不动 —— 属于自相矛盾的提示。
        hint_on_sd   <= !mode_video;
        // 按下这一拍 auto_now_sd 还是【旧值】：0=未轮播 -> 本次"开始轮播"
        //                                       1=轮播中 -> 本次"解除轮播"
        hint_mode_sd <= !mode_video && auto_now_sd;
        hint_cnt_sd  <= mode_video ? 27'd0 : 27'd100_000_000;   // 1s @100MHz
    end else if (hint_cnt_sd != 27'd0) begin
        hint_cnt_sd  <= hint_cnt_sd - 27'd1;
    end else begin
        hint_on_sd   <= 1'b0;
    end
end

// 慢变量跨到 video_clk 域（两级同步）
reg [1:0] hint_on_sync;
reg [1:0] hint_mode_sync;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        hint_on_sync   <= 2'b00;
        hint_mode_sync <= 2'b00;
    end else begin
        hint_on_sync   <= {hint_on_sync[0],   hint_on_sd};
        hint_mode_sync <= {hint_mode_sync[0], hint_mode_sd};
    end
end
wire hint_on_v   = hint_on_sync[1];
wire hint_mode_v = hint_mode_sync[1];

wire [23:0] hint_rgb;
hint_osd #(
    .X0       (252),       // v39：方框右边界 236，提示从 252 起
    .Y0       (12),
    .CHAR_W   (24),
    .CHAR_H   (24),
    .TEXT_RGB (24'hFFFFFF)
) u_hint_osd (
    .clk     (video_clk),
    .rst     (rst_all),
    .enable  (osd_en && hint_on_v),
    .vs      (vs),
    .de      (de),
    .rgb_in  (param_rgb),
    .mode    (hint_mode_v),
    .rgb_out (hint_rgb)
);

slogan_osd_v3_alpha #(
    .TEXT_Y      (397),      // v29：字幕整体上移 27px，给下方频谱条腾出空间
    .CHAR_W      (24),
    .CHAR_H      (24),
    .BANNER_Y    (392),
    .BANNER_H    (34),
    .BANNER_W    (640),
    .SCROLL_STEP (1),
    .START_X     (640),
    .BG_RGB      (24'h000000),
    .BG_ALPHA    (8),
    .FONT_RGB    (24'hFFFFFF)
) u_slogan_osd_v3_alpha (
    .clk         (video_clk),
    .rst         (rst_all),
    // v44：视频段不显示照片字幕。
    //   image_index 在视频段冻结在最后一张照片上，原来 enable 只跟 osd_en 走，
    //   结果整段视频底部一直挂着第 4 张图的字幕（"神舟五号…点火升空"）。
    // v79：用 video_shown 而不是 show_video_phase。
    //   视频播完后 transition 会继续显示它的最后一帧（定格约 0.4s），
    //   这段时间也不该冒字幕出来 —— 否则字幕会在揭幕前先闪一下。
    .enable      (osd_en && !video_shown),
    .image_index (current_image_idx),
    .vs          (vs),
    .de          (de),
    .rgb_in      (hint_rgb),
    .rgb_out     (slogan_rgb)
);

// ===================== 扩展6：音频频谱可视化（32 段彩虹竖条） =====================
// 数据源：I2S_receiver 解串出的 PCM（audio_left_data），与 video_clk 同域。
// 分析：32 段定点 Goertzel（单频点 DFT），1024 点一块 -> 刷新 46.9Hz。
// 叠加：字幕条（已上移到 y=392..425）正下方居中，512x46，64 根竖条（8px 间距、
//       5px 柱宽）以中线上下对称生长，颜色按"段号（频率）"取彩虹色。
audio_viz #(
    .PANEL_X  (64),        // (640-512)/2 居中
    .PANEL_Y  (430),
    .PANEL_W  (512),       // v31：64 根柱 x 8px（原 32 段 x 16px）
    .PANEL_H  (46),
    .BAR_W    (5),         // v31：柱宽 5px，间隙 3px（原 6px / 10px）
    .CEN_Y    (23),        // 中线在面板内第 23 行 -> 屏幕 y=453
    .MAXH     (22)         // 上下各 22px
) u_audio_viz (
    .clk         (video_clk),
    .rst         (rst_all),
    .enable      (disp_en),
    .vs          (vs),
    .de          (de),
    .rgb_in      (slogan_rgb),
    .rgb_out     (viz_rgb),
    .audio_valid (audio_valid),
    .audio_left  (audio_left_data),
    // v79：频谱调试字不再送串口（见 uart_debug_tx 处的说明），悬空即可
    .dbg_cnt     (),
    .dbg_blk     (),
    .dbg_seen    (),
    .dbg_bands   (),
    .dbg_tgl     ()
);

assign vout_data = disp_en ? viz_rgb : 24'd0;
// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

  .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    // DDC 不再接引脚（L16/M16 让给 RTC），悬空内部线，EDID 结果本就未使用
    .O_ddc_scl          (ddc_scl_nc),
    .IO_ddc_sda         (ddc_sda_nc),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

// ==================== v47 子模块合并自 pcm_player.v ====================
// ============================================================
// pcm_player —— 48kHz 立体声 I2S 主机（纯输出端）
// ------------------------------------------------------------
// v47.1：时钟改用 audio_mclk = 12.288MHz（PLL clk2），
//   BCLK = mclk/4 = 3.072MHz（整数分频，无抖动）
//   LRCK = BCLK/64 = 48kHz
//   数据从外部 FIFO 取（smp_dout / smp_empty / smp_re）
//
// 与按键/模式完全无关：play=1 就一直播，播完由上游循环供数。
// FIFO 空时自动输出静音（加载未完成时不会出噪声）。
//
// I2S 时序（标准 Philips）：LRCLK 变化后延迟 1 个 BCLK 出 MSB，
//   16bit 左对齐，之后补 0 到下一个 LRCLK 边界。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v71）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 470 / 低音 376 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v71）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 470 / 低音 376 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v73）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 470 / 低音 376 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v73）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 470 / 低音 376 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v73）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 470 / 低音 376 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v78）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 237 / 低音 126 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v78）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 237 / 低音 126 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v78）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 113 / 中声部 237 / 低音 126 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v78）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 112 / 中声部 192 / 低音 160 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
// ============================================================
// piano_player —— 三声部钢琴合成器（v78）
// ------------------------------------------------------------
// 音符来自曲谱转录（v69.1）：旋律 128 / 中声部 464 / 低音 320 个事件。
// 三张表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒 -> 循环时三轨永不错位。
// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。
// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。
// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。
// 面积：单个共用乘法器（3 声部时分复用）。
// ============================================================
module piano_player (
    input  wire clk,              // audio_mclk 12.288MHz
    input  wire rst,
    input  wire play,
    output reg  i2s_bclk,
    output reg  i2s_lrclk,
    output reg  i2s_data,
    output wire [8:0] dbg_note
);

localparam [9:0] MEL_N = 10'd128;
localparam [9:0] MID_N = 10'd464;
localparam [9:0] BAS_N = 10'd320;

// melody：{midi-43[5:0], 单位数[9:0]}
reg [15:0] mel_tab [0:127];
initial begin
    mel_tab[  0] = 16'hA978;  // MIDI 78, 376 单位
    mel_tab[  1] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[  2] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[  3] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[  4] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[  5] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[  6] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[  7] = 16'h7978;  // MIDI 66, 376 单位
    mel_tab[  8] = 16'h7D78;  // MIDI 67, 376 单位
    mel_tab[  9] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 10] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 11] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 12] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 13] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 14] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[ 15] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[ 16] = 16'hA978;  // MIDI 78, 376 单位
    mel_tab[ 17] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[ 18] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 19] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[ 20] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 21] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 22] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 23] = 16'h7978;  // MIDI 66, 376 单位
    mel_tab[ 24] = 16'h7D78;  // MIDI 67, 376 单位
    mel_tab[ 25] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 26] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 27] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 28] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 29] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 30] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[ 31] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[ 32] = 16'hA978;  // MIDI 78, 376 单位
    mel_tab[ 33] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[ 34] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 35] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[ 36] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 37] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 38] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 39] = 16'h7978;  // MIDI 66, 376 单位
    mel_tab[ 40] = 16'h7D78;  // MIDI 67, 376 单位
    mel_tab[ 41] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[ 42] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 43] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 44] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[ 45] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[ 46] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[ 47] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[ 48] = 16'hA85E;  // MIDI 78, 94 单位
    mel_tab[ 49] = 16'hAC5E;  // MIDI 79, 94 单位
    mel_tab[ 50] = 16'hA85E;  // MIDI 78, 94 单位
    mel_tab[ 51] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 52] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 53] = 16'hA85E;  // MIDI 78, 94 单位
    mel_tab[ 54] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 55] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 56] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 57] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 58] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 59] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 60] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[ 61] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 62] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[ 63] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 64] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 65] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[ 66] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 67] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 68] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 69] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 70] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 71] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 72] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 73] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 74] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 75] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 76] = 16'h785E;  // MIDI 66, 94 单位
    mel_tab[ 77] = 16'h7C5E;  // MIDI 67, 94 单位
    mel_tab[ 78] = 16'h785E;  // MIDI 66, 94 单位
    mel_tab[ 79] = 16'h705E;  // MIDI 64, 94 单位
    mel_tab[ 80] = 16'h7C5E;  // MIDI 67, 94 单位
    mel_tab[ 81] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 82] = 16'h7C5E;  // MIDI 67, 94 单位
    mel_tab[ 83] = 16'h7C5E;  // MIDI 67, 94 单位
    mel_tab[ 84] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 85] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 86] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 87] = 16'h845E;  // MIDI 69, 94 单位
    mel_tab[ 88] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 89] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[ 90] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 91] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[ 92] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 93] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 94] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 95] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 96] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 97] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[ 98] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[ 99] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[100] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[101] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[102] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[103] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[104] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[105] = 16'hA85E;  // MIDI 78, 94 单位
    mel_tab[106] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[107] = 16'hA05E;  // MIDI 76, 94 单位
    mel_tab[108] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[109] = 16'h985E;  // MIDI 74, 94 单位
    mel_tab[110] = 16'h945E;  // MIDI 73, 94 单位
    mel_tab[111] = 16'h8C5E;  // MIDI 71, 94 单位
    mel_tab[112] = 16'hA978;  // MIDI 78, 376 单位
    mel_tab[113] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[114] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[115] = 16'h9578;  // MIDI 73, 376 单位
    mel_tab[116] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[117] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[118] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[119] = 16'h7978;  // MIDI 66, 376 单位
    mel_tab[120] = 16'h7D78;  // MIDI 67, 376 单位
    mel_tab[121] = 16'h8578;  // MIDI 69, 376 单位
    mel_tab[122] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[123] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[124] = 16'h9978;  // MIDI 74, 376 单位
    mel_tab[125] = 16'h8D78;  // MIDI 71, 376 单位
    mel_tab[126] = 16'hA178;  // MIDI 76, 376 单位
    mel_tab[127] = 16'h9578;  // MIDI 73, 376 单位
end

// middle：{midi-43[5:0], 单位数[9:0]}
reg [15:0] mid_tab [0:463];
initial begin
    mid_tab[  0] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[  1] = 16'h785E;  // MIDI 66, 94 单位
    mid_tab[  2] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[  3] = 16'h985E;  // MIDI 74, 94 单位
    mid_tab[  4] = 16'h545E;  // MIDI 57, 94 单位
    mid_tab[  5] = 16'h645E;  // MIDI 61, 94 单位
    mid_tab[  6] = 16'h705E;  // MIDI 64, 94 单位
    mid_tab[  7] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[  8] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[  9] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 10] = 16'h785E;  // MIDI 66, 94 单位
    mid_tab[ 11] = 16'h8C5E;  // MIDI 71, 94 单位
    mid_tab[ 12] = 16'h485E;  // MIDI 54, 94 单位
    mid_tab[ 13] = 16'h545E;  // MIDI 57, 94 单位
    mid_tab[ 14] = 16'h345E;  // MIDI 49, 94 单位
    mid_tab[ 15] = 16'h785E;  // MIDI 66, 94 单位
    mid_tab[ 16] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 17] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 18] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 19] = 16'h7C5E;  // MIDI 67, 94 单位
    mid_tab[ 20] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 21] = 16'h785E;  // MIDI 66, 94 单位
    mid_tab[ 22] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[ 23] = 16'h985E;  // MIDI 74, 94 单位
    mid_tab[ 24] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 25] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 26] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 27] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 28] = 16'h545E;  // MIDI 57, 94 单位
    mid_tab[ 29] = 16'h645E;  // MIDI 61, 94 单位
    mid_tab[ 30] = 16'h705E;  // MIDI 64, 94 单位
    mid_tab[ 31] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[ 32] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 33] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 34] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 35] = 16'h7C5E;  // MIDI 67, 94 单位
    mid_tab[ 36] = 16'h545E;  // MIDI 57, 94 单位
    mid_tab[ 37] = 16'h645E;  // MIDI 61, 94 单位
    mid_tab[ 38] = 16'h705E;  // MIDI 64, 94 单位
    mid_tab[ 39] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[ 40] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 41] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 42] = 16'h785E;  // MIDI 66, 94 单位
    mid_tab[ 43] = 16'h8C5E;  // MIDI 71, 94 单位
    mid_tab[ 44] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 45] = 16'h785E;  // MIDI 66, 94 单位
    mid_tab[ 46] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[ 47] = 16'h985E;  // MIDI 74, 94 单位
    mid_tab[ 48] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 49] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 50] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 51] = 16'h7C5E;  // MIDI 67, 94 单位
    mid_tab[ 52] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 53] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 54] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 55] = 16'h7C5E;  // MIDI 67, 94 单位
    mid_tab[ 56] = 16'h4C5E;  // MIDI 55, 94 单位
    mid_tab[ 57] = 16'h5C5E;  // MIDI 59, 94 单位
    mid_tab[ 58] = 16'h685E;  // MIDI 62, 94 单位
    mid_tab[ 59] = 16'h7C5E;  // MIDI 67, 94 单位
    mid_tab[ 60] = 16'h545E;  // MIDI 57, 94 单位
    mid_tab[ 61] = 16'h645E;  // MIDI 61, 94 单位
    mid_tab[ 62] = 16'h705E;  // MIDI 64, 94 单位
    mid_tab[ 63] = 16'h845E;  // MIDI 69, 94 单位
    mid_tab[ 64] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[ 65] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[ 66] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[ 67] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[ 68] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[ 69] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[ 70] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[ 71] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[ 72] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[ 73] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[ 74] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[ 75] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[ 76] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[ 77] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[ 78] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[ 79] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[ 80] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[ 81] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[ 82] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[ 83] = 16'h8C2F;  // MIDI 71, 47 单位
    mid_tab[ 84] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[ 85] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[ 86] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[ 87] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[ 88] = 16'h482F;  // MIDI 54, 47 单位
    mid_tab[ 89] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[ 90] = 16'h342F;  // MIDI 49, 47 单位
    mid_tab[ 91] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[ 92] = 16'h342F;  // MIDI 49, 47 单位
    mid_tab[ 93] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[ 94] = 16'h482F;  // MIDI 54, 47 单位
    mid_tab[ 95] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[ 96] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[ 97] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[ 98] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[ 99] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[100] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[101] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[102] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[103] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[104] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[105] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[106] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[107] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[108] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[109] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[110] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[111] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[112] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[113] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[114] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[115] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[116] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[117] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[118] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[119] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[120] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[121] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[122] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[123] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[124] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[125] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[126] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[127] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[128] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[129] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[130] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[131] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[132] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[133] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[134] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[135] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[136] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[137] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[138] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[139] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[140] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[141] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[142] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[143] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[144] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[145] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[146] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[147] = 16'h8C2F;  // MIDI 71, 47 单位
    mid_tab[148] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[149] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[150] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[151] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[152] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[153] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[154] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[155] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[156] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[157] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[158] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[159] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[160] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[161] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[162] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[163] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[164] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[165] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[166] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[167] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[168] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[169] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[170] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[171] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[172] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[173] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[174] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[175] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[176] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[177] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[178] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[179] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[180] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[181] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[182] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[183] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[184] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[185] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[186] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[187] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[188] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[189] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[190] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[191] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[192] = 16'h6978;  // MIDI 62, 376 单位
    mid_tab[193] = 16'h5578;  // MIDI 57, 376 单位
    mid_tab[194] = 16'h6978;  // MIDI 62, 376 单位
    mid_tab[195] = 16'h5578;  // MIDI 57, 376 单位
    mid_tab[196] = 16'h7D78;  // MIDI 67, 376 单位
    mid_tab[197] = 16'h6978;  // MIDI 62, 376 单位
    mid_tab[198] = 16'h6978;  // MIDI 62, 376 单位
    mid_tab[199] = 16'h6578;  // MIDI 61, 376 单位
    mid_tab[200] = 16'h5D78;  // MIDI 59, 376 单位
    mid_tab[201] = 16'h5578;  // MIDI 57, 376 单位
    mid_tab[202] = 16'h5D78;  // MIDI 59, 376 单位
    mid_tab[203] = 16'h4978;  // MIDI 54, 376 单位
    mid_tab[204] = 16'h4D78;  // MIDI 55, 376 单位
    mid_tab[205] = 16'h4D78;  // MIDI 55, 376 单位
    mid_tab[206] = 16'h5D78;  // MIDI 59, 376 单位
    mid_tab[207] = 16'h6578;  // MIDI 61, 376 单位
    mid_tab[208] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[209] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[210] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[211] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[212] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[213] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[214] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[215] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[216] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[217] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[218] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[219] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[220] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[221] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[222] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[223] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[224] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[225] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[226] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[227] = 16'h8C2F;  // MIDI 71, 47 单位
    mid_tab[228] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[229] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[230] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[231] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[232] = 16'h482F;  // MIDI 54, 47 单位
    mid_tab[233] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[234] = 16'h342F;  // MIDI 49, 47 单位
    mid_tab[235] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[236] = 16'h342F;  // MIDI 49, 47 单位
    mid_tab[237] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[238] = 16'h482F;  // MIDI 54, 47 单位
    mid_tab[239] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[240] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[241] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[242] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[243] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[244] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[245] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[246] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[247] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[248] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[249] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[250] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[251] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[252] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[253] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[254] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[255] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[256] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[257] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[258] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[259] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[260] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[261] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[262] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[263] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[264] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[265] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[266] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[267] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[268] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[269] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[270] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[271] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[272] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[273] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[274] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[275] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[276] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[277] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[278] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[279] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[280] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[281] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[282] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[283] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[284] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[285] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[286] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[287] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[288] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[289] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[290] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[291] = 16'h8C2F;  // MIDI 71, 47 单位
    mid_tab[292] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[293] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[294] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[295] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[296] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[297] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[298] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[299] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[300] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[301] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[302] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[303] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[304] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[305] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[306] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[307] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[308] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[309] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[310] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[311] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[312] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[313] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[314] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[315] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[316] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[317] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[318] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[319] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[320] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[321] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[322] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[323] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[324] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[325] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[326] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[327] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[328] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[329] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[330] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[331] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[332] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[333] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[334] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[335] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[336] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[337] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[338] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[339] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[340] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[341] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[342] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[343] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[344] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[345] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[346] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[347] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[348] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[349] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[350] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[351] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[352] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[353] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[354] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[355] = 16'h8C2F;  // MIDI 71, 47 单位
    mid_tab[356] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[357] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[358] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[359] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[360] = 16'h482F;  // MIDI 54, 47 单位
    mid_tab[361] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[362] = 16'h342F;  // MIDI 49, 47 单位
    mid_tab[363] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[364] = 16'h342F;  // MIDI 49, 47 单位
    mid_tab[365] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[366] = 16'h482F;  // MIDI 54, 47 单位
    mid_tab[367] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[368] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[369] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[370] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[371] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[372] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[373] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[374] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[375] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[376] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[377] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[378] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[379] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[380] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[381] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[382] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[383] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[384] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[385] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[386] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[387] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[388] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[389] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[390] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[391] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[392] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[393] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[394] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[395] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[396] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[397] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[398] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[399] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[400] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[401] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[402] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[403] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[404] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[405] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[406] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[407] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[408] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[409] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[410] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[411] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[412] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[413] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[414] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[415] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[416] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[417] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[418] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[419] = 16'h8C2F;  // MIDI 71, 47 单位
    mid_tab[420] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[421] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[422] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[423] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[424] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[425] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[426] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[427] = 16'h982F;  // MIDI 74, 47 单位
    mid_tab[428] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[429] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[430] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[431] = 16'h782F;  // MIDI 66, 47 单位
    mid_tab[432] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[433] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[434] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[435] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[436] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[437] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[438] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[439] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[440] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[441] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[442] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[443] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[444] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[445] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[446] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[447] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[448] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[449] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[450] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[451] = 16'h7C2F;  // MIDI 67, 47 单位
    mid_tab[452] = 16'h682F;  // MIDI 62, 47 单位
    mid_tab[453] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[454] = 16'h4C2F;  // MIDI 55, 47 单位
    mid_tab[455] = 16'h5C2F;  // MIDI 59, 47 单位
    mid_tab[456] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[457] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[458] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[459] = 16'h842F;  // MIDI 69, 47 单位
    mid_tab[460] = 16'h702F;  // MIDI 64, 47 单位
    mid_tab[461] = 16'h642F;  // MIDI 61, 47 单位
    mid_tab[462] = 16'h542F;  // MIDI 57, 47 单位
    mid_tab[463] = 16'h642F;  // MIDI 61, 47 单位
end

// bass：{midi-43[5:0], 单位数[9:0]}
reg [15:0] bas_tab [0:319];
initial begin
    bas_tab[  0] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[  1] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[  2] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[  3] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[  4] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[  5] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[  6] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[  7] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[  8] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[  9] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 10] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[ 11] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 12] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[ 13] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[ 14] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 15] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[ 16] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[ 17] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 18] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[ 19] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 20] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[ 21] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 22] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 23] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 24] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[ 25] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 26] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[ 27] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 28] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 29] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 30] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[ 31] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 32] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[ 33] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 34] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 35] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 36] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 37] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 38] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[ 39] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 40] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[ 41] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 42] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[ 43] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 44] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[ 45] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[ 46] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 47] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[ 48] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[ 49] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 50] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[ 51] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 52] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[ 53] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 54] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 55] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 56] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[ 57] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 58] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[ 59] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 60] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 61] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 62] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[ 63] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 64] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[ 65] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 66] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 67] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 68] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 69] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 70] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[ 71] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 72] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[ 73] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 74] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[ 75] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 76] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[ 77] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[ 78] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[ 79] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[ 80] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[ 81] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 82] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[ 83] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 84] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[ 85] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 86] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 87] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 88] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[ 89] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 90] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[ 91] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 92] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 93] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 94] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[ 95] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[ 96] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[ 97] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[ 98] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[ 99] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[100] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[101] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[102] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[103] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[104] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[105] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[106] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[107] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[108] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[109] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[110] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[111] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[112] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[113] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[114] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[115] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[116] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[117] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[118] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[119] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[120] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[121] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[122] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[123] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[124] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[125] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[126] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[127] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[128] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[129] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[130] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[131] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[132] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[133] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[134] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[135] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[136] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[137] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[138] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[139] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[140] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[141] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[142] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[143] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[144] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[145] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[146] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[147] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[148] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[149] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[150] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[151] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[152] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[153] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[154] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[155] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[156] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[157] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[158] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[159] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[160] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[161] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[162] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[163] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[164] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[165] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[166] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[167] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[168] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[169] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[170] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[171] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[172] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[173] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[174] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[175] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[176] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[177] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[178] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[179] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[180] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[181] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[182] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[183] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[184] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[185] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[186] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[187] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[188] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[189] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[190] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[191] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[192] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[193] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[194] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[195] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[196] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[197] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[198] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[199] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[200] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[201] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[202] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[203] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[204] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[205] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[206] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[207] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[208] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[209] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[210] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[211] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[212] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[213] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[214] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[215] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[216] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[217] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[218] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[219] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[220] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[221] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[222] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[223] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[224] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[225] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[226] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[227] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[228] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[229] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[230] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[231] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[232] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[233] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[234] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[235] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[236] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[237] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[238] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[239] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[240] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[241] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[242] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[243] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[244] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[245] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[246] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[247] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[248] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[249] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[250] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[251] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[252] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[253] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[254] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[255] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[256] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[257] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[258] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[259] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[260] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[261] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[262] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[263] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[264] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[265] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[266] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[267] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[268] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[269] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[270] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[271] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[272] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[273] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[274] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[275] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[276] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[277] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[278] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[279] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[280] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[281] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[282] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[283] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[284] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[285] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[286] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[287] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[288] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[289] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[290] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[291] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[292] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[293] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[294] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[295] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[296] = 16'h2C5E;  // MIDI 47, 94 单位
    bas_tab[297] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[298] = 16'h5C5E;  // MIDI 59, 94 单位
    bas_tab[299] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[300] = 16'h185E;  // MIDI 42, 94 单位
    bas_tab[301] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[302] = 16'h485E;  // MIDI 54, 94 单位
    bas_tab[303] = 16'h345E;  // MIDI 49, 94 单位
    bas_tab[304] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[305] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[306] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[307] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[308] = 16'h085E;  // MIDI 38, 94 单位
    bas_tab[309] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[310] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[311] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[312] = 16'h1C5E;  // MIDI 43, 94 单位
    bas_tab[313] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[314] = 16'h4C5E;  // MIDI 55, 94 单位
    bas_tab[315] = 16'h385E;  // MIDI 50, 94 单位
    bas_tab[316] = 16'h245E;  // MIDI 45, 94 单位
    bas_tab[317] = 16'h405E;  // MIDI 52, 94 单位
    bas_tab[318] = 16'h545E;  // MIDI 57, 94 单位
    bas_tab[319] = 16'h405E;  // MIDI 52, 94 单位
end

// 波形表：0..255 基波主体，256..511 高次谐波
reg [11:0] wave_rom [0:511];
initial begin
    wave_rom[  0]=12'h000; wave_rom[  1]=12'h063; wave_rom[  2]=12'h0C6; wave_rom[  3]=12'h129; wave_rom[  4]=12'h18A; wave_rom[  5]=12'h1EA; wave_rom[  6]=12'h248; wave_rom[  7]=12'h2A4;
    wave_rom[  8]=12'h2FD; wave_rom[  9]=12'h354; wave_rom[ 10]=12'h3A8; wave_rom[ 11]=12'h3F8; wave_rom[ 12]=12'h445; wave_rom[ 13]=12'h48E; wave_rom[ 14]=12'h4D3; wave_rom[ 15]=12'h515;
    wave_rom[ 16]=12'h552; wave_rom[ 17]=12'h58A; wave_rom[ 18]=12'h5BE; wave_rom[ 19]=12'h5EE; wave_rom[ 20]=12'h619; wave_rom[ 21]=12'h63F; wave_rom[ 22]=12'h661; wave_rom[ 23]=12'h67E;
    wave_rom[ 24]=12'h697; wave_rom[ 25]=12'h6AC; wave_rom[ 26]=12'h6BC; wave_rom[ 27]=12'h6C8; wave_rom[ 28]=12'h6D1; wave_rom[ 29]=12'h6D5; wave_rom[ 30]=12'h6D6; wave_rom[ 31]=12'h6D3;
    wave_rom[ 32]=12'h6CE; wave_rom[ 33]=12'h6C5; wave_rom[ 34]=12'h6BA; wave_rom[ 35]=12'h6AC; wave_rom[ 36]=12'h69C; wave_rom[ 37]=12'h68A; wave_rom[ 38]=12'h677; wave_rom[ 39]=12'h662;
    wave_rom[ 40]=12'h64C; wave_rom[ 41]=12'h634; wave_rom[ 42]=12'h61D; wave_rom[ 43]=12'h604; wave_rom[ 44]=12'h5EC; wave_rom[ 45]=12'h5D3; wave_rom[ 46]=12'h5BB; wave_rom[ 47]=12'h5A3;
    wave_rom[ 48]=12'h58B; wave_rom[ 49]=12'h575; wave_rom[ 50]=12'h55E; wave_rom[ 51]=12'h549; wave_rom[ 52]=12'h535; wave_rom[ 53]=12'h522; wave_rom[ 54]=12'h510; wave_rom[ 55]=12'h4FF;
    wave_rom[ 56]=12'h4EF; wave_rom[ 57]=12'h4E0; wave_rom[ 58]=12'h4D3; wave_rom[ 59]=12'h4C6; wave_rom[ 60]=12'h4BB; wave_rom[ 61]=12'h4B1; wave_rom[ 62]=12'h4A8; wave_rom[ 63]=12'h49F;
    wave_rom[ 64]=12'h497; wave_rom[ 65]=12'h490; wave_rom[ 66]=12'h48A; wave_rom[ 67]=12'h484; wave_rom[ 68]=12'h47E; wave_rom[ 69]=12'h478; wave_rom[ 70]=12'h472; wave_rom[ 71]=12'h46C;
    wave_rom[ 72]=12'h466; wave_rom[ 73]=12'h460; wave_rom[ 74]=12'h459; wave_rom[ 75]=12'h451; wave_rom[ 76]=12'h449; wave_rom[ 77]=12'h440; wave_rom[ 78]=12'h436; wave_rom[ 79]=12'h42B;
    wave_rom[ 80]=12'h420; wave_rom[ 81]=12'h413; wave_rom[ 82]=12'h404; wave_rom[ 83]=12'h3F5; wave_rom[ 84]=12'h3E4; wave_rom[ 85]=12'h3D3; wave_rom[ 86]=12'h3C0; wave_rom[ 87]=12'h3AB;
    wave_rom[ 88]=12'h396; wave_rom[ 89]=12'h380; wave_rom[ 90]=12'h368; wave_rom[ 91]=12'h350; wave_rom[ 92]=12'h336; wave_rom[ 93]=12'h31C; wave_rom[ 94]=12'h301; wave_rom[ 95]=12'h2E5;
    wave_rom[ 96]=12'h2C9; wave_rom[ 97]=12'h2AC; wave_rom[ 98]=12'h28F; wave_rom[ 99]=12'h271; wave_rom[100]=12'h254; wave_rom[101]=12'h237; wave_rom[102]=12'h219; wave_rom[103]=12'h1FC;
    wave_rom[104]=12'h1DF; wave_rom[105]=12'h1C3; wave_rom[106]=12'h1A7; wave_rom[107]=12'h18C; wave_rom[108]=12'h171; wave_rom[109]=12'h157; wave_rom[110]=12'h13E; wave_rom[111]=12'h125;
    wave_rom[112]=12'h10E; wave_rom[113]=12'h0F7; wave_rom[114]=12'h0E2; wave_rom[115]=12'h0CD; wave_rom[116]=12'h0B9; wave_rom[117]=12'h0A6; wave_rom[118]=12'h094; wave_rom[119]=12'h083;
    wave_rom[120]=12'h072; wave_rom[121]=12'h062; wave_rom[122]=12'h053; wave_rom[123]=12'h044; wave_rom[124]=12'h036; wave_rom[125]=12'h028; wave_rom[126]=12'h01B; wave_rom[127]=12'h00D;
    wave_rom[128]=12'h000; wave_rom[129]=12'hFF3; wave_rom[130]=12'hFE5; wave_rom[131]=12'hFD8; wave_rom[132]=12'hFCA; wave_rom[133]=12'hFBC; wave_rom[134]=12'hFAD; wave_rom[135]=12'hF9E;
    wave_rom[136]=12'hF8E; wave_rom[137]=12'hF7D; wave_rom[138]=12'hF6C; wave_rom[139]=12'hF5A; wave_rom[140]=12'hF47; wave_rom[141]=12'hF33; wave_rom[142]=12'hF1E; wave_rom[143]=12'hF09;
    wave_rom[144]=12'hEF2; wave_rom[145]=12'hEDB; wave_rom[146]=12'hEC2; wave_rom[147]=12'hEA9; wave_rom[148]=12'hE8F; wave_rom[149]=12'hE74; wave_rom[150]=12'hE59; wave_rom[151]=12'hE3D;
    wave_rom[152]=12'hE21; wave_rom[153]=12'hE04; wave_rom[154]=12'hDE7; wave_rom[155]=12'hDC9; wave_rom[156]=12'hDAC; wave_rom[157]=12'hD8F; wave_rom[158]=12'hD71; wave_rom[159]=12'hD54;
    wave_rom[160]=12'hD37; wave_rom[161]=12'hD1B; wave_rom[162]=12'hCFF; wave_rom[163]=12'hCE4; wave_rom[164]=12'hCCA; wave_rom[165]=12'hCB0; wave_rom[166]=12'hC98; wave_rom[167]=12'hC80;
    wave_rom[168]=12'hC6A; wave_rom[169]=12'hC55; wave_rom[170]=12'hC40; wave_rom[171]=12'hC2D; wave_rom[172]=12'hC1C; wave_rom[173]=12'hC0B; wave_rom[174]=12'hBFC; wave_rom[175]=12'hBED;
    wave_rom[176]=12'hBE0; wave_rom[177]=12'hBD5; wave_rom[178]=12'hBCA; wave_rom[179]=12'hBC0; wave_rom[180]=12'hBB7; wave_rom[181]=12'hBAF; wave_rom[182]=12'hBA7; wave_rom[183]=12'hBA0;
    wave_rom[184]=12'hB9A; wave_rom[185]=12'hB94; wave_rom[186]=12'hB8E; wave_rom[187]=12'hB88; wave_rom[188]=12'hB82; wave_rom[189]=12'hB7C; wave_rom[190]=12'hB76; wave_rom[191]=12'hB70;
    wave_rom[192]=12'hB69; wave_rom[193]=12'hB61; wave_rom[194]=12'hB58; wave_rom[195]=12'hB4F; wave_rom[196]=12'hB45; wave_rom[197]=12'hB3A; wave_rom[198]=12'hB2D; wave_rom[199]=12'hB20;
    wave_rom[200]=12'hB11; wave_rom[201]=12'hB01; wave_rom[202]=12'hAF0; wave_rom[203]=12'hADE; wave_rom[204]=12'hACB; wave_rom[205]=12'hAB7; wave_rom[206]=12'hAA2; wave_rom[207]=12'hA8B;
    wave_rom[208]=12'hA75; wave_rom[209]=12'hA5D; wave_rom[210]=12'hA45; wave_rom[211]=12'hA2D; wave_rom[212]=12'hA14; wave_rom[213]=12'h9FC; wave_rom[214]=12'h9E3; wave_rom[215]=12'h9CC;
    wave_rom[216]=12'h9B4; wave_rom[217]=12'h99E; wave_rom[218]=12'h989; wave_rom[219]=12'h976; wave_rom[220]=12'h964; wave_rom[221]=12'h954; wave_rom[222]=12'h946; wave_rom[223]=12'h93B;
    wave_rom[224]=12'h932; wave_rom[225]=12'h92D; wave_rom[226]=12'h92A; wave_rom[227]=12'h92B; wave_rom[228]=12'h92F; wave_rom[229]=12'h938; wave_rom[230]=12'h944; wave_rom[231]=12'h954;
    wave_rom[232]=12'h969; wave_rom[233]=12'h982; wave_rom[234]=12'h99F; wave_rom[235]=12'h9C1; wave_rom[236]=12'h9E7; wave_rom[237]=12'hA12; wave_rom[238]=12'hA42; wave_rom[239]=12'hA76;
    wave_rom[240]=12'hAAE; wave_rom[241]=12'hAEB; wave_rom[242]=12'hB2D; wave_rom[243]=12'hB72; wave_rom[244]=12'hBBB; wave_rom[245]=12'hC08; wave_rom[246]=12'hC58; wave_rom[247]=12'hCAC;
    wave_rom[248]=12'hD03; wave_rom[249]=12'hD5C; wave_rom[250]=12'hDB8; wave_rom[251]=12'hE16; wave_rom[252]=12'hE76; wave_rom[253]=12'hED7; wave_rom[254]=12'hF3A; wave_rom[255]=12'hF9D;
    wave_rom[256]=12'h000; wave_rom[257]=12'h09B; wave_rom[258]=12'h134; wave_rom[259]=12'h1C6; wave_rom[260]=12'h251; wave_rom[261]=12'h2D0; wave_rom[262]=12'h342; wave_rom[263]=12'h3A6;
    wave_rom[264]=12'h3FB; wave_rom[265]=12'h43F; wave_rom[266]=12'h473; wave_rom[267]=12'h496; wave_rom[268]=12'h4AA; wave_rom[269]=12'h4B0; wave_rom[270]=12'h4A8; wave_rom[271]=12'h495;
    wave_rom[272]=12'h479; wave_rom[273]=12'h454; wave_rom[274]=12'h429; wave_rom[275]=12'h3F9; wave_rom[276]=12'h3C7; wave_rom[277]=12'h393; wave_rom[278]=12'h35F; wave_rom[279]=12'h32B;
    wave_rom[280]=12'h2F9; wave_rom[281]=12'h2C9; wave_rom[282]=12'h29B; wave_rom[283]=12'h26F; wave_rom[284]=12'h245; wave_rom[285]=12'h21E; wave_rom[286]=12'h1F8; wave_rom[287]=12'h1D4;
    wave_rom[288]=12'h1B1; wave_rom[289]=12'h18F; wave_rom[290]=12'h16E; wave_rom[291]=12'h14D; wave_rom[292]=12'h12D; wave_rom[293]=12'h10E; wave_rom[294]=12'h0EF; wave_rom[295]=12'h0D2;
    wave_rom[296]=12'h0B5; wave_rom[297]=12'h09A; wave_rom[298]=12'h07F; wave_rom[299]=12'h067; wave_rom[300]=12'h050; wave_rom[301]=12'h03A; wave_rom[302]=12'h026; wave_rom[303]=12'h014;
    wave_rom[304]=12'h004; wave_rom[305]=12'hFF4; wave_rom[306]=12'hFE6; wave_rom[307]=12'hFD8; wave_rom[308]=12'hFCB; wave_rom[309]=12'hFBF; wave_rom[310]=12'hFB3; wave_rom[311]=12'hFA6;
    wave_rom[312]=12'hF9A; wave_rom[313]=12'hF8D; wave_rom[314]=12'hF80; wave_rom[315]=12'hF72; wave_rom[316]=12'hF65; wave_rom[317]=12'hF57; wave_rom[318]=12'hF4A; wave_rom[319]=12'hF3D;
    wave_rom[320]=12'hF31; wave_rom[321]=12'hF25; wave_rom[322]=12'hF1A; wave_rom[323]=12'hF10; wave_rom[324]=12'hF06; wave_rom[325]=12'hEFE; wave_rom[326]=12'hEF7; wave_rom[327]=12'hEF0;
    wave_rom[328]=12'hEEB; wave_rom[329]=12'hEE6; wave_rom[330]=12'hEE1; wave_rom[331]=12'hEDD; wave_rom[332]=12'hEDA; wave_rom[333]=12'hED7; wave_rom[334]=12'hED3; wave_rom[335]=12'hED0;
    wave_rom[336]=12'hECE; wave_rom[337]=12'hECB; wave_rom[338]=12'hEC9; wave_rom[339]=12'hEC6; wave_rom[340]=12'hEC5; wave_rom[341]=12'hEC4; wave_rom[342]=12'hEC3; wave_rom[343]=12'hEC4;
    wave_rom[344]=12'hEC5; wave_rom[345]=12'hEC7; wave_rom[346]=12'hECA; wave_rom[347]=12'hECD; wave_rom[348]=12'hED2; wave_rom[349]=12'hED7; wave_rom[350]=12'hEDD; wave_rom[351]=12'hEE4;
    wave_rom[352]=12'hEEB; wave_rom[353]=12'hEF2; wave_rom[354]=12'hEF9; wave_rom[355]=12'hF00; wave_rom[356]=12'hF08; wave_rom[357]=12'hF0F; wave_rom[358]=12'hF16; wave_rom[359]=12'hF1D;
    wave_rom[360]=12'hF24; wave_rom[361]=12'hF2B; wave_rom[362]=12'hF31; wave_rom[363]=12'hF39; wave_rom[364]=12'hF40; wave_rom[365]=12'hF48; wave_rom[366]=12'hF50; wave_rom[367]=12'hF58;
    wave_rom[368]=12'hF61; wave_rom[369]=12'hF6B; wave_rom[370]=12'hF74; wave_rom[371]=12'hF7F; wave_rom[372]=12'hF89; wave_rom[373]=12'hF94; wave_rom[374]=12'hF9F; wave_rom[375]=12'hFA9;
    wave_rom[376]=12'hFB4; wave_rom[377]=12'hFBE; wave_rom[378]=12'hFC9; wave_rom[379]=12'hFD2; wave_rom[380]=12'hFDC; wave_rom[381]=12'hFE5; wave_rom[382]=12'hFEE; wave_rom[383]=12'hFF7;
    wave_rom[384]=12'h000; wave_rom[385]=12'h009; wave_rom[386]=12'h012; wave_rom[387]=12'h01B; wave_rom[388]=12'h024; wave_rom[389]=12'h02E; wave_rom[390]=12'h037; wave_rom[391]=12'h042;
    wave_rom[392]=12'h04C; wave_rom[393]=12'h057; wave_rom[394]=12'h061; wave_rom[395]=12'h06C; wave_rom[396]=12'h077; wave_rom[397]=12'h081; wave_rom[398]=12'h08C; wave_rom[399]=12'h095;
    wave_rom[400]=12'h09F; wave_rom[401]=12'h0A8; wave_rom[402]=12'h0B0; wave_rom[403]=12'h0B8; wave_rom[404]=12'h0C0; wave_rom[405]=12'h0C7; wave_rom[406]=12'h0CF; wave_rom[407]=12'h0D5;
    wave_rom[408]=12'h0DC; wave_rom[409]=12'h0E3; wave_rom[410]=12'h0EA; wave_rom[411]=12'h0F1; wave_rom[412]=12'h0F8; wave_rom[413]=12'h100; wave_rom[414]=12'h107; wave_rom[415]=12'h10E;
    wave_rom[416]=12'h115; wave_rom[417]=12'h11C; wave_rom[418]=12'h123; wave_rom[419]=12'h129; wave_rom[420]=12'h12E; wave_rom[421]=12'h133; wave_rom[422]=12'h136; wave_rom[423]=12'h139;
    wave_rom[424]=12'h13B; wave_rom[425]=12'h13C; wave_rom[426]=12'h13D; wave_rom[427]=12'h13C; wave_rom[428]=12'h13B; wave_rom[429]=12'h13A; wave_rom[430]=12'h137; wave_rom[431]=12'h135;
    wave_rom[432]=12'h132; wave_rom[433]=12'h130; wave_rom[434]=12'h12D; wave_rom[435]=12'h129; wave_rom[436]=12'h126; wave_rom[437]=12'h123; wave_rom[438]=12'h11F; wave_rom[439]=12'h11A;
    wave_rom[440]=12'h115; wave_rom[441]=12'h110; wave_rom[442]=12'h109; wave_rom[443]=12'h102; wave_rom[444]=12'h0FA; wave_rom[445]=12'h0F0; wave_rom[446]=12'h0E6; wave_rom[447]=12'h0DB;
    wave_rom[448]=12'h0CF; wave_rom[449]=12'h0C3; wave_rom[450]=12'h0B6; wave_rom[451]=12'h0A9; wave_rom[452]=12'h09B; wave_rom[453]=12'h08E; wave_rom[454]=12'h080; wave_rom[455]=12'h073;
    wave_rom[456]=12'h066; wave_rom[457]=12'h05A; wave_rom[458]=12'h04D; wave_rom[459]=12'h041; wave_rom[460]=12'h035; wave_rom[461]=12'h028; wave_rom[462]=12'h01A; wave_rom[463]=12'h00C;
    wave_rom[464]=12'hFFC; wave_rom[465]=12'hFEC; wave_rom[466]=12'hFDA; wave_rom[467]=12'hFC6; wave_rom[468]=12'hFB0; wave_rom[469]=12'hF99; wave_rom[470]=12'hF81; wave_rom[471]=12'hF66;
    wave_rom[472]=12'hF4B; wave_rom[473]=12'hF2E; wave_rom[474]=12'hF11; wave_rom[475]=12'hEF2; wave_rom[476]=12'hED3; wave_rom[477]=12'hEB3; wave_rom[478]=12'hE92; wave_rom[479]=12'hE71;
    wave_rom[480]=12'hE4F; wave_rom[481]=12'hE2C; wave_rom[482]=12'hE08; wave_rom[483]=12'hDE2; wave_rom[484]=12'hDBB; wave_rom[485]=12'hD91; wave_rom[486]=12'hD65; wave_rom[487]=12'hD37;
    wave_rom[488]=12'hD07; wave_rom[489]=12'hCD5; wave_rom[490]=12'hCA1; wave_rom[491]=12'hC6D; wave_rom[492]=12'hC39; wave_rom[493]=12'hC07; wave_rom[494]=12'hBD7; wave_rom[495]=12'hBAC;
    wave_rom[496]=12'hB87; wave_rom[497]=12'hB6B; wave_rom[498]=12'hB58; wave_rom[499]=12'hB50; wave_rom[500]=12'hB56; wave_rom[501]=12'hB6A; wave_rom[502]=12'hB8D; wave_rom[503]=12'hBC1;
    wave_rom[504]=12'hC05; wave_rom[505]=12'hC5A; wave_rom[506]=12'hCBE; wave_rom[507]=12'hD30; wave_rom[508]=12'hDAF; wave_rom[509]=12'hE3A; wave_rom[510]=12'hECC; wave_rom[511]=12'hF65;
end

// 音高增量表：inc = round(f * 2^32 / 48000)
reg [31:0] inc_rom [0:54];
initial begin
    inc_rom[ 0]=32'h00594D31; inc_rom[ 1]=32'h005E9C96; inc_rom[ 2]=32'h00643CD2; inc_rom[ 3]=32'h006A32B1;
    inc_rom[ 4]=32'h0070834C; inc_rom[ 5]=32'h00773407; inc_rom[ 6]=32'h007E4A9B; inc_rom[ 7]=32'h0085CD15;
    inc_rom[ 8]=32'h008DC1E1; inc_rom[ 9]=32'h00962FC9; inc_rom[10]=32'h009F1E03; inc_rom[11]=32'h00A8942E;
    inc_rom[12]=32'h00B29A62; inc_rom[13]=32'h00BD392D; inc_rom[14]=32'h00C879A3; inc_rom[15]=32'h00D46562;
    inc_rom[16]=32'h00E10697; inc_rom[17]=32'h00EE680F; inc_rom[18]=32'h00FC9536; inc_rom[19]=32'h010B9A2B;
    inc_rom[20]=32'h011B83C2; inc_rom[21]=32'h012C5F93; inc_rom[22]=32'h013E3C06; inc_rom[23]=32'h0151285D;
    inc_rom[24]=32'h016534C3; inc_rom[25]=32'h017A725A; inc_rom[26]=32'h0190F347; inc_rom[27]=32'h01A8CAC3;
    inc_rom[28]=32'h01C20D2F; inc_rom[29]=32'h01DCD01D; inc_rom[30]=32'h01F92A6D; inc_rom[31]=32'h02173456;
    inc_rom[32]=32'h02370783; inc_rom[33]=32'h0258BF26; inc_rom[34]=32'h027C780B; inc_rom[35]=32'h02A250BA;
    inc_rom[36]=32'h02CA6987; inc_rom[37]=32'h02F4E4B4; inc_rom[38]=32'h0321E68D; inc_rom[39]=32'h03519586;
    inc_rom[40]=32'h03841A5D; inc_rom[41]=32'h03B9A03A; inc_rom[42]=32'h03F254D9; inc_rom[43]=32'h042E68AC;
    inc_rom[44]=32'h046E0F07; inc_rom[45]=32'h04B17E4B; inc_rom[46]=32'h04F8F017; inc_rom[47]=32'h0544A173;
    inc_rom[48]=32'h0594D30D; inc_rom[49]=32'h05E9C968; inc_rom[50]=32'h0643CD1B; inc_rom[51]=32'h06A32B0D;
    inc_rom[52]=32'h070834BA; inc_rom[53]=32'h07734075; inc_rom[54]=32'h07E4A9B2;
end


wire bclk_fall = i2s_bclk;
reg  [5:0] bit_cnt;
reg        lr;
wire slot_end = (bit_cnt == 6'd63);
wire smp_new  = bclk_fall && slot_end && lr;    // 离开右声道 = 出一个新样本

reg [5:0]  st;
reg [9:0]  a;                     // 走表地址
reg [8:0]  a2;                    // 波形表地址（bit8=1 取高次谐波段）
reg signed [11:0] wb, wr;
reg signed [12:0] ws0, ws1, ws2;
reg signed [12:0] ma;
reg signed [16:0] mb;
reg signed [31:0] acc;
reg [15:0] out16;
reg [15:0] sr_hold;

reg [31:0] ph0, ph1, ph2;
reg [31:0] inc0, inc1, inc2;
reg [15:0] env0, env1, env2;
reg [9:0]  ptr0, ptr1, ptr2;
reg [9:0]  left0, left1, left2;
reg [5:0]  ecnt;                  // 32 样本 = 包络节拍
reg [7:0]  cnt5;                  // 240 样本 = 5ms
reg        adv;

reg [15:0] rd0, rd1, rd2;
reg [5:0]  m0, m1, m2;
reg [9:0]  u0, u1, u2;
reg        nx0, nx1, nx2;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        i2s_bclk <= 1'b0; i2s_lrclk <= 1'b0; i2s_data <= 1'b0;
        bit_cnt <= 6'd0; lr <= 1'b0; sr_hold <= 16'd0;
        st <= 6'd0; out16 <= 16'd0; acc <= 32'sd0;
        ph0 <= 32'd0; ph1 <= 32'd0; ph2 <= 32'd0;
        inc0 <= 32'd0; inc1 <= 32'd0; inc2 <= 32'd0;
        ptr0 <= 10'd0; ptr1 <= 10'd0; ptr2 <= 10'd0;
        left0 <= 10'd0; left1 <= 10'd0; left2 <= 10'd0;
        env0 <= 16'd0; env1 <= 16'd0; env2 <= 16'd0;
        ecnt <= 6'd0; cnt5 <= 8'd0; adv <= 1'b1;
        nx0 <= 1'b0; nx1 <= 1'b0; nx2 <= 1'b0;
    end else if (!play) begin
        i2s_bclk <= 1'b0; i2s_lrclk <= 1'b0; i2s_data <= 1'b0;
        bit_cnt <= 6'd0; lr <= 1'b0; st <= 6'd0;
    end else begin
        // ---------------- I2S 串行输出 ----------------
        i2s_bclk <= ~i2s_bclk;
        if (bclk_fall) begin
            if (slot_end) begin
                bit_cnt <= 6'd0;
                lr <= ~lr;
                i2s_lrclk <= ~lr;
                i2s_data <= 1'b0;         // LRCLK 变化后的 1 bit 延迟
                sr_hold <= out16;
            end else begin
                bit_cnt  <= bit_cnt + 6'd1;
                i2s_data <= sr_hold[15];
                sr_hold  <= {sr_hold[14:0], 1'b0};
            end
        end

        // ---------------- 合成状态机 ----------------
        case (st)
        6'd0: if (smp_new) begin
                  ph0 <= ph0 + inc0;
                  ph1 <= ph1 + inc1;
                  ph2 <= ph2 + inc2;
                  st  <= 6'd1;
              end
        6'd1:  begin a  <= {2'b00, ph0[31:24]};               st <= 6'd2; end
        6'd2:  begin a2 <= {1'b1, a[7:0]}; wb <= wave_rom[{1'b0, a[7:0]}]; st <= 6'd3; end
        6'd3:  begin wr <= wave_rom[a2];
                     ws0 <= wb + ((m0 >= 6'd42) ? (wr >>> 4) :
                                  (m0 >= 6'd39) ? (wr >>> 3) :
                                  (m0 >= 6'd36) ? (wr >>> 2) :
                                  (env0[15] ? (wr >>> 1) : (wr >>> 3)));
                     a   <= {2'b00, ph1[31:24]};              st <= 6'd4; end
        6'd4:  begin a2 <= {1'b1, a[7:0]}; wb <= wave_rom[{1'b0, a[7:0]}]; st <= 6'd5; end
        6'd5:  begin wr <= wave_rom[a2];
                     ws1 <= wb + (env1[15] ? (wr >>> 1) : (wr >>> 3));
                     a   <= {2'b00, ph2[31:24]};              st <= 6'd6; end
        6'd6:  begin a2 <= {1'b1, a[7:0]}; wb <= wave_rom[{1'b0, a[7:0]}]; st <= 6'd7; end
        6'd7:  begin wr <= wave_rom[a2];
                     ws2 <= wb + (env2[15] ? (wr >>> 1) : (wr >>> 3));
                     ma <= ws0; mb <= {1'b0, env0};           st <= 6'd8; end
        6'd8:  begin acc <= (ma * mb) >>> 16; ma <= ws1; mb <= {1'b0, env1}; st <= 6'd9;  end
        6'd9:  begin acc <= acc + ((ma * mb) >>> 16); ma <= ws2; mb <= {1'b0, env2}; st <= 6'd10; end
        6'd10: begin acc <= acc + ((ma * mb) >>> 16);                        st <= 6'd11; end
        6'd11: begin                                                         st <= 6'd12; end
        6'd12: begin
            if (acc > 32'sd4095)       out16 <= 16'd32767;
            else if (acc < -32'sd4096) out16 <= 16'h8000;
            else                       out16 <= {acc[12:0], 3'b000};
            st <= adv ? 6'd13 : 6'd0;
        end
        // ---- 5ms 走表：melody ----
        6'd13: begin
            nx0 <= (left0 == 10'd0);
            if (left0 == 10'd0)
                a <= (ptr0 == MEL_N - 10'd1) ? 10'd0 : ptr0 + 10'd1;
            st <= 6'd14;
        end
        6'd14: begin
            if (nx0) begin rd0 <= mel_tab[a]; st <= 6'd15; end
            else     begin left0 <= left0 - 10'd1; st <= 6'd17; end
        end
        6'd15: begin ptr0 <= a; m0 <= rd0[15:10]; u0 <= rd0[9:0]; st <= 6'd16; end
        6'd16: begin inc0 <= inc_rom[m0];
                     left0 <= (u0 == 10'd0) ? 10'd0 : u0 - 10'd1;
                     env0 <= 16'd49807; nx0 <= 1'b0;   // 0.80 x 0.95
                     ph0  <= 32'd0;            // v78：起音相位清零 = 软起音
                     st   <= 6'd17; end
        // ---- middle ----
        6'd17: begin
            nx1 <= (left1 == 10'd0);
            if (left1 == 10'd0)
                a <= (ptr1 == MID_N - 10'd1) ? 10'd0 : ptr1 + 10'd1;
            st <= 6'd18;
        end
        6'd18: begin
            if (nx1) begin rd1 <= mid_tab[a]; st <= 6'd19; end
            else     begin left1 <= left1 - 10'd1; st <= 6'd21; end
        end
        6'd19: begin ptr1 <= a; m1 <= rd1[15:10]; u1 <= rd1[9:0]; st <= 6'd20; end
        6'd20: begin inc1 <= inc_rom[m1];
                     left1 <= (u1 == 10'd0) ? 10'd0 : u1 - 10'd1;
                     // 中声部：0.26 x (1.00/0.90/0.96/0.92) —— 上行琶音的层次
                     env1 <= (ptr1[1:0] == 2'd0) ? 16'd17039 :
                             (ptr1[1:0] == 2'd1) ? 16'd15335 :
                             (ptr1[1:0] == 2'd2) ? 16'd16357 : 16'd15676;
                     nx1 <= 1'b0;
                     ph1  <= 32'd0;
                     st   <= 6'd21; end
        // ---- bass ----
        6'd21: begin
            nx2 <= (left2 == 10'd0);
            if (left2 == 10'd0)
                a <= (ptr2 == BAS_N - 10'd1) ? 10'd0 : ptr2 + 10'd1;
            st <= 6'd22;
        end
        6'd22: begin
            if (nx2) begin rd2 <= bas_tab[a]; st <= 6'd23; end
            else     begin left2 <= left2 - 10'd1; adv <= 1'b0; st <= 6'd0; end
        end
        6'd23: begin ptr2 <= a; m2 <= rd2[15:10]; u2 <= rd2[9:0]; st <= 6'd24; end
        6'd24: begin inc2 <= inc_rom[m2];
                     left2 <= (u2 == 10'd0) ? 10'd0 : u2 - 10'd1;
                     // 低音：0.30 x (1.10/0.90) —— 每小节第 1 拍重音
                     env2 <= (ptr2[0] == 1'b0) ? 16'd21627 : 16'd17695;
                     nx2 <= 1'b0;
                     ph2  <= 32'd0;
                     adv <= 1'b0; st <= 6'd0; end
        default: st <= 6'd0;
        endcase

        // ---------------- 包络 / 5ms 计时 ----------------
        if (smp_new) begin
            cnt5 <= (cnt5 == 8'd239) ? 8'd0 : cnt5 + 8'd1;
            if (cnt5 == 8'd239) adv <= 1'b1;
        end
        if (st == 6'd0 && smp_new) begin
            if (ecnt == 6'd31) begin
                ecnt <= 6'd0;
                env0 <= (left0 <= 10'd8) ? (env0 - (env0 >> 4)) : (env0 - (env0 >> 11));
                env1 <= (left1 <= 10'd8) ? (env1 - (env1 >> 4)) : (env1 - (env1 >> 10));
                env2 <= (left2 <= 10'd8) ? (env2 - (env2 >> 4)) : (env2 - (env2 >> 9));
            end else begin
                ecnt <= ecnt + 6'd1;
            end
        end
    end
end

endmodule











// ==================== v47 子模块合并自 pcm_loader.v ====================
// ============================================================
// pcm_loader —— 上电把 SD 卡上的 PCM 音频搬进 SDRAM
// ------------------------------------------------------------
// v47 新增。
//   SD 源：LBA AUDIO_LBA 起，共 TOTAL_WORDS*4 字节（立体声 16bit 帧）
//   目的：SDRAM 词地址 AUDIO_BASE 起
//
// 资源与总线策略（关键，避免影响视频）：
//   · 只在"照片链路空闲"时借 SD 总线（照片段 18 秒足够搬完 18.7MB）
//   · 用 31 扇区/笔的 CMD18（与 raw_player 同一套 SD 接口）
//   · 每收 4 字节拼一个 32bit 词，写 SDRAM
//   · done 置 1 后永不重启（除非复位）
//
// 播放不依赖本模块完成：pcm_player 只播"已经搬好的部分"，
// 搬完之前播到末尾会自动回绕（听感上是短循环），搬完后自然连续。
// ============================================================
module pcm_loader #(
    parameter [31:0]  AUDIO_LBA   = 32'd640000,
    parameter [4:0]   SECT_BURST  = 5'd31
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        sd_init_done,
    input  wire        bus_free,          // 照片/视频都不在用 SD 总线
    input  wire        enable,            // 允许搬运（照片段 & 无装载任务）

    // ---- SD 读（接到顶层 SD 读 mux）----
    output reg         sd_rd,
    output reg  [31:0] sd_ra,
    output reg  [4:0]  sd_rc,
    input  wire        sd_dv,
    input  wire [7:0]  sd_data,
    input  wire        sd_end,

    // ---- SDRAM 写（接到顶层写 mux）----
    output reg         wr_en,
    output reg  [23:0] wr_addr,
    output reg  [31:0] wr_data,

    output reg         done,
    output wire [23:0] progress,         // 已搬词数
    output wire        bus_busy
);

// ------------------------------------------------------------
// v52：缓冲改成 2 的幂对齐，把地址算术全部消掉
//   基址 = 2^20 = 1_048_576 词，长度 = 2^20 词 = 4MB = 21.85 秒（48k 立体声）
//     · wr_addr = {1'b1, wr_ptr[19:0]}   —— 纯拼接，没有加法器
//     · wr_ptr 20 位自然回绕              —— 没有回绕比较器
//     · "没搬完" = cur_word[20]==0        —— 1 个位判断，没有比较器
//   原来有 24bit 加法器 ×1、24bit 比较器 ×2，现在全没了。
//   代价：音频从 29.9 秒缩到 21.85 秒（用户选择不删既有功能，先缩音频）。
// ------------------------------------------------------------
localparam [23:0] SECT_WORDS = (24'd512 * SECT_BURST) / 4;   // 31*512/4 = 3968

localparam [2:0] L_IDLE = 3'd0,
                 L_REQ  = 3'd1,
                 L_COLL = 3'd2,
                 L_GAP  = 3'd3;

reg [2:0]   st;
reg [31:0]  cur_lba;
reg [20:0]  cur_word;      // 0 .. 2^20，bit20 置 1 表示 4MB 搬满
reg [19:0]  wr_ptr;        // 缓冲内偏移，20 位自然回绕
reg [1:0]   byte_cnt;
reg [31:0]  pack;
reg [11:0]  coll_words;
reg [13:0]  gap_cnt;
reg [15:0]  req_to_cnt;

assign progress = {3'd0, cur_word};
assign bus_busy = (st != L_IDLE) || sd_rd;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        st         <= L_IDLE;
        sd_rd      <= 1'b0;
        sd_ra      <= AUDIO_LBA;
        sd_rc      <= SECT_BURST;
        cur_lba    <= AUDIO_LBA;
        cur_word   <= 21'd0;
        wr_ptr     <= 20'd0;
        wr_en      <= 1'b0;
        wr_addr    <= 24'd0;
        wr_data    <= 32'd0;
        byte_cnt   <= 2'd0;
        pack       <= 32'd0;
        coll_words <= 12'd0;
        gap_cnt    <= 14'd0;
        req_to_cnt <= 16'd0;
        done       <= 1'b0;
    end else begin
        wr_en <= 1'b0;

        case (st)
            L_IDLE: begin
                if (cur_word[20]) begin
                    done <= 1'b1;                   // 4MB 搬完
                end else if (!done && enable && bus_free && sd_init_done) begin
                    sd_rd  <= 1'b1;
                    sd_ra  <= cur_lba;
                    sd_rc  <= SECT_BURST;
                    st     <= L_REQ;
                end
            end

            L_REQ: begin
                // sd_rd 必须保持到整批 sd_end，中途撤销会让控制器中止传输
                if (sd_dv) begin
                    byte_cnt    <= 2'd1;
                    pack[31:24] <= sd_data;
                    coll_words  <= 12'd0;
                    req_to_cnt  <= 16'd0;
                    st          <= L_COLL;
                end else if (req_to_cnt >= 16'd50000) begin   // 500us 无响应 -> 放弃
                    req_to_cnt <= 16'd0;
                    sd_rd      <= 1'b0;
                    st         <= L_GAP;
                end else begin
                    req_to_cnt <= req_to_cnt + 16'd1;
                end
            end

            L_COLL: begin
                if (sd_dv) begin
                    case (byte_cnt)
                        2'd0: pack[31:24] <= sd_data;
                        2'd1: pack[23:16] <= sd_data;
                        2'd2: pack[15:8]  <= sd_data;
                        2'd3: begin
                            // 4 字节拼一个词：{b0,b1,b2,b3}
                            wr_en   <= ~cur_word[20];
                            wr_addr <= {3'b000, 1'b1, wr_ptr};
                            wr_data <= {pack[31:8], sd_data};
                            if (!cur_word[20]) begin
                                wr_ptr   <= wr_ptr + 20'd1;
                                cur_word <= cur_word + 21'd1;
                                coll_words <= coll_words + 12'd1;
                            end
                        end
                    endcase
                    byte_cnt <= byte_cnt + 2'd1;
                end
                if (sd_end || coll_words >= SECT_WORDS[11:0]) begin
                    sd_rd   <= 1'b0;
                    cur_lba <= cur_lba + SECT_BURST;
                    gap_cnt <= 14'd0;
                    st      <= L_GAP;
                end
            end

            L_GAP: begin
                // 两笔 CMD18 之间留 ~100us，等控制器回等待态并把总线让给照片链路
                if (gap_cnt >= 14'd10000) begin
                    gap_cnt <= 14'd0;
                    st      <= L_IDLE;
                end else begin
                    gap_cnt <= gap_cnt + 14'd1;
                end
            end
        endcase
    end
end

endmodule


// ==================== v47 子模块合并自 pcm_refill.v ====================
// ============================================================
// pcm_refill —— 从 SDRAM 取音频帧填进跨时钟 FIFO
// ------------------------------------------------------------
// v47 新增，工作在 ext_mem_clk 域（125MHz，与 SDRAM 同域）。
//
// 仲裁策略：
//   视频每帧连续读 307200 词（约 3ms），之后空闲约 80ms。
//   本模块只在 fw_busy=0（视频没在读）时向 SDRAM 发读请求，
//   一次连续读 BURST 个词（32 词 = 320ns），对视频完全无感。
//
// 读位置约束：
//   只在【已经被 pcm_loader 搬好的范围】内读（pos < loaded），
//   加载未完成时读到边界就停，FIFO 自然被读空 -> 播放器静音，
//   不会把 SDRAM 里的垃圾当声音放出来。
//   播到尽头自动回到 AUDIO_BASE（整首循环）。
// ============================================================
module pcm_refill #(
    parameter integer BURST      = 256,
    parameter integer LOW_WATER  = 64
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        play,
    input  wire [23:0] loaded,            // = pcm_loader 的 cur_word
    input  wire        vid_safe,
    output wire        rd_en,
    output wire [23:0] rd_addr,
    input  wire        rd_gnt,
    input  wire [9:0]  fifo_cnt,
    input  wire        fifo_full,
    output wire [15:0] issued
);

assign issued = 16'd0;

localparam [1:0] R_IDLE = 2'd0, R_BURST = 2'd1;

reg [1:0]  st;
reg [19:0] rd_pos;
reg [9:0]  burst_cnt;

// v52：与 loader 同一套 2^20 对齐
//   · rd_addr = {1'b1, rd_pos} 纯拼接，没有加法器
//   · rd_pos 20 位自然回绕（整段循环），没有回绕比较器
//   · 只有一处比较："读到哪儿了 vs 已搬多少"
wire [20:0] limit    = loaded[20:0];
wire        has_data = ({1'b0, rd_pos} < limit);
wire        low      = (fifo_cnt < LOW_WATER[9:0]) && !fifo_full;

assign rd_en   = (st == R_BURST) && has_data && low;
assign rd_addr = {3'b000, 1'b1, rd_pos};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        st        <= R_IDLE;
        rd_pos    <= 20'd0;
        burst_cnt <= 10'd0;
    end else if (!play) begin
        st     <= R_IDLE;
        rd_pos <= 20'd0;
    end else begin
        case (st)
            R_IDLE: begin
                if (vid_safe && has_data && low) begin
                    burst_cnt <= 10'd0;
                    st        <= R_BURST;
                end
            end
            R_BURST: begin
                if (rd_gnt && rd_en) begin
                    rd_pos    <= rd_pos + 20'd1;
                    burst_cnt <= burst_cnt + 10'd1;
                end
                // burst 内部不查 vid_safe：一旦进来就连续读满，避免被自己的读清零
                if (burst_cnt >= BURST[9:0] || !low) begin
                    st <= R_IDLE;
                end
            end
        endcase
    end
end

endmodule

module dc_fifo_32 #(
    parameter integer AW = 7          // 深度 = 2^AW = 128
)(
    input  wire        rst,

    input  wire        clkw,
    input  wire        we,
    input  wire [31:0] di,
    output wire        full,
    output wire [AW:0] wcnt,

    input  wire        clkr,
    input  wire        re,
    output wire [31:0] dout,
    output wire        empty,
    output wire [AW:0] rcnt
);

reg [31:0] mem [0:(1<<AW)-1];

// ---- 写侧指针 ----
reg  [AW:0] wp_bin, wp_gray;
wire [AW:0] wp_bin_nxt  = wp_bin + {{AW{1'b0}}, 1'b1};
wire [AW:0] wp_gray_nxt = (wp_bin_nxt >> 1) ^ wp_bin_nxt;

// ---- 读侧指针 ----
reg  [AW:0] rp_bin, rp_gray;
wire [AW:0] rp_bin_nxt  = rp_bin + {{AW{1'b0}}, 1'b1};
wire [AW:0] rp_gray_nxt = (rp_bin_nxt >> 1) ^ rp_bin_nxt;

// ---- 跨域同步 ----
reg [AW:0] rp_gray_w1, rp_gray_w2;   // 读指针 -> 写域
reg [AW:0] wp_gray_r1, wp_gray_r2;   // 写指针 -> 读域

wire [AW:0] wp_gray_w2_comb = wp_gray;   // 写域本地

// 写域看到"读指针"
always @(posedge clkw or posedge rst) begin
    if (rst) begin
        rp_gray_w1 <= {(AW+1){1'b0}};
        rp_gray_w2 <= {(AW+1){1'b0}};
    end else begin
        rp_gray_w1 <= rp_gray;
        rp_gray_w2 <= rp_gray_w1;
    end
end

// 读域看到"写指针"
always @(posedge clkr or posedge rst) begin
    if (rst) begin
        wp_gray_r1 <= {(AW+1){1'b0}};
        wp_gray_r2 <= {(AW+1){1'b0}};
    end else begin
        wp_gray_r1 <= wp_gray;
        wp_gray_r2 <= wp_gray_r1;
    end
end

// 格雷码转二进制（用于计数/比较）
function [AW:0] gray2bin;
    input [AW:0] g;
    integer i;
    begin
        gray2bin[AW] = g[AW];
        for (i = AW-1; i >= 0; i = i - 1)
            gray2bin[i] = gray2bin[i+1] ^ g[i];
    end
endfunction

wire [AW:0] wp_bin_w = wp_bin;                        // 写域
wire [AW:0] rp_bin_w = gray2bin(rp_gray_w2);          // 写域看到的读指针（二进制）
wire [AW:0] rp_bin_r = rp_bin;                        // 读域
wire [AW:0] wp_bin_r = gray2bin(wp_gray_r2);          // 读域看到的写指针（二进制）

assign wcnt  = wp_bin_w - rp_bin_w;
assign rcnt  = wp_bin_r - rp_bin_r;
assign full  = (wcnt >= (1 << AW) - 2);               // 留 2 个空位（保守）
assign empty = (rcnt == {(AW+1){1'b0}});

// ---- 写 ----
always @(posedge clkw) begin
    if (we && !full)
        mem[wp_bin[AW-1:0]] <= di;
end

always @(posedge clkw or posedge rst) begin
    if (rst) begin
        wp_bin  <= {(AW+1){1'b0}};
        wp_gray <= {(AW+1){1'b0}};
    end else if (we && !full) begin
        wp_bin  <= wp_bin_nxt;
        wp_gray <= wp_gray_nxt;
    end
end

// ---- 读 ----
assign dout = mem[rp_bin[AW-1:0]];

always @(posedge clkr or posedge rst) begin
    if (rst) begin
        rp_bin  <= {(AW+1){1'b0}};
        rp_gray <= {(AW+1){1'b0}};
    end else if (re && !empty) begin
        rp_bin  <= rp_bin_nxt;
        rp_gray <= rp_gray_nxt;
    end
end

endmodule

