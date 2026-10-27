`timescale 1ns/1ps
// ============================================================
// raw_player —— SD 卡裸扇区 RAW 视频流播放器（默认 320x240 RGB565 @12fps）
// ------------------------------------------------------------
// 【为什么是"裸扇区"】
//   现有照片链路走 FAT/BMP 解析，每帧要重复 CMD17/18 + 头部解析，且 BMP 是底向上、
//   每行 4 字节对齐。视频要求"定长、连续、可预测"，所以直接按扇区线性读：
//     扇区 0        : 512 字节自定义头（magic "RAWV"）
//                     ver=1 纯视频 / ver=2 照片+视频混合（v34）
//     ver=2 且 photo_count>0：
//       photo_data_start 起 photo_count 张定格照片（每张也是一帧 320x240 RGB565）
//       随后 data_start 起连续 frame_count 帧视频
//   播放顺序：照片 1..N（每张定格 photo_hold_ms 毫秒，走黑场淡入淡出）
//             -> 视频（12fps 直切）-> 循环回照片 1
//   一张卡专用于视频时，这就是最简单、最不容易出错的格式。
//
// 【视频怎么放大到 640x480】
//   SDRAM 帧缓存固定 640x480x32bit（读侧 video_delay 取 [31:8] 作 RGB888），
//   所以写入侧必须凑满 307200 个词。这里用最近邻 2x：
//     水平 2x：同一像素连写两遍（不需要缓存，直接重复）
//     垂直 2x：一行写两遍 —— 这需要"行缓冲"，于是用两块 320x16bit 的
//              ping-pong bank（各占 1 个 BRAM9K），收第 n 行时输出第 n-1 行。
//   输入速率 ~1.8MB/s（每行 256us），输出 1280 词/行只需 ~13us，余量 ~20x，
//   所以永远不会因为输出慢而丢 SD 数据。
//
// 【帧率与缓冲】
//   12fps -> 帧时隙 CLK_FREQ_HZ/FPS = 8333333 拍（83.33ms）。
//   双缓冲：写 A 显示 B；本帧写完后通知 video 域，video 在"上一帧 SDRAM 读结束"
//   的那一刻切 read_buf_idx 并回 commit，本模块收到 commit 后才能写另一块。
//   窗口：读一帧约 70ms（300 扇区 @ 2.2MB/s）+ 等 commit 0~16ms < 83.3ms。
//   注意节拍是"从本帧起点算 83.33ms"，不是"commit 之后空等 83.33ms"——
//   后者会把周期拉成 83+70+commit ≈ 155ms，12fps 变成 6fps（v33 修正）。
//
// 【上下方向】
//   RAW 第 0 行 = 屏幕顶行（top-down）。而 frame_fifo_write 原本带 WRITE_V_FLIP=1
//   （为 BMP bottom-up 服务），视频模式下由顶层把 wr_vflip 置 0，行序不再翻转。
//
// 【关键时序约束（踩过的坑，别再改）】
//   1) write_req 拉高 -> 下游 ack -> 下游会异步清空写 FIFO 并持续到 write_req 落下，
//      必须等 ~32 拍再灌数据，否则最前面几十个词被 aclr 吃掉，凑不满 307200。
//      这就是 ST_WR_GAP 存在的原因（与 sd_card_bmp 清屏的 C_GAP 同源）。
//   2) 扇区地址用"预算寄存器"推进，不在触发沿上现算 32 位加法，
//      否则加法器串进 sd_sec_read_addr 的使能路径，100MHz 下直接违例。
//   3) 写 FIFO 水位门限用 128/512（wr_ok），与 frame_fifo_write 的排水粒度一致，
//      两侧错开才不会出现 [128,128] 死区。
//   4) 行缓冲的"满/空"必须用两个回绕计数器（bank_wr_cnt / bank_rd_cnt），
//      不能用单个 full 标志：写满新行与取走旧行可能发生在同一拍，单标志会互相覆盖。
// ============================================================
module raw_player #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer FPS               = 12,
    parameter integer SRC_W             = 320,
    parameter integer SRC_H             = 240,
    parameter integer HSCALE            = 2,
    parameter integer VSCALE            = 2,
    parameter integer SECT_PER_BURST    = 30,       // 单笔 CMD18 连读扇区数（<=31）
    parameter [31:0]  DATA_START_SECTOR = 32'd1,    // 视频数据起始扇区（头里也会写一份）
    parameter integer STALL_MS          = 300,      // 源流停滞判定（毫秒）
    parameter integer COMMIT_TIMEOUT_SEC= 3,        // 等 video 切帧的兜底（秒）
    // v36：照片组 / 视频组是两个【独立内容】。
    //   1 = 轮播（S1 打开）时会从照片组末尾跨到视频组、视频播完再回照片组；
    //   0 = 两组各自循环，跨界【只能】按 S0。
    //   无论哪种取值，"跨界"都不是开机固定时间点发生的 —— 默认 auto_play=0，
    //   上电停在第 1 张，必须按 S0 步进或按 S1 主动开启轮播才会有自动前进。
    parameter integer CROSS_PHASE       = 1,

    // v40：视频数据不再占用整盘扇区 0，而是放在卡的固定 LBA 上。
    //   这样同一张 FAT32 卡可以同时装 4 张 BMP（照片模式）和 1 段 RAW 视频：
    //     LBA 0            : MBR（FAT32 分区表）
    //     LBA 2048 起      : FAT32 分区，只开 200MB，装 4 个 BMP
    //     LBA 524288 (256M): RAW 视频（在分区之外，Windows 看不见，也不会被整理动到）
    //   板子只在 VIDEO_LBA 处找 RAWV 头；找不到就退回照片模式，互不干扰。
    parameter [31:0]  VIDEO_LBA         = 32'd524288
)(
    input  wire                 clk,
    input  wire                 rst,

    // ---------------- 共享 SD 扇区读总线（顶层按模式仲裁）----------------
    input  wire                 sd_init_done,
    output reg                  sd_sec_read,
    output reg  [31:0]          sd_sec_read_addr,
    output reg  [4:0]           sd_sec_read_cnt,
    input  wire [7:0]           sd_sec_read_data,
    input  wire                 sd_sec_read_data_valid,
    input  wire                 sd_sec_read_end,

    // ---------------- 帧写通路（与 sd_card_bmp 共用，顶层按模式仲裁）----
    output reg                  write_req,
    input  wire                 write_req_ack,
    input  wire [8:0]           wr_fifo_used,
    output reg                  write_en,
    output reg  [31:0]          write_data,
    output wire [1:0]           write_buf_idx,

    // ---------------- 与 video_clk 域的握手 ----------------
    input  wire                 write_finish_toggle,   // ext_mem_clk 域，整帧写完
    input  wire                 commit_toggle,         // video_clk 域，已完成切帧
    output reg                  frame_ready_toggle,    // 本模块 -> video：新帧就绪
    output reg  [1:0]           ready_buf_idx,

    // ---------------- v35：按键（与照片模式语义对齐）----------------
    //   key_next(S0)：照片段 = 立刻结束定格、切下一张（最后一张 -> 视频首帧）
    //                 视频段 = 跳过视频，回到片头第一张照片（无照片则视频首帧）
    //   key_auto(S1)：轮播 开/关。关 = 停在当前内容不动，再按恢复。
    // v40：视频播放由顶层 mode_video 控制（照片由 sd_card_bmp 负责）。
    //   play=0 -> 本模块完全静默（不占 SD 总线、不写帧），画面由照片链路接管
    //   play=1 -> 从第 1 帧开始按 12fps 播；播完停在最后一帧
    input  wire                 play,
    // v41：第一帧该写哪块 SDRAM buffer。
    //   由顶层给（= 照片链路当前【没有】在显示的那一块）。
    //   固定写 0 会有隐患：照片张数是奇数时，视频第一帧正好写进正在显示的那块，
    //   一边读一边写，第一帧必然撕裂花屏。
    input  wire                 first_buf,
    input  wire                 key_next,              // 保留端口（v40 起不再使用）
    input  wire                 key_auto,
    output reg                  auto_play,             // 保留端口（v40 起恒 0）

    // ---------------- 状态 ----------------
    output reg                  video_mode,            // 1 = 头部识别成功（RAW 卡）
    output reg                  detect_done,           // 头检测结束（无论成功与否）

    // ---------------- v34：照片段 / 视频段双相 ----------------
    output reg                  phase_video,           // 0 = 正在播片头照片，1 = 正在播视频
    output wire [1:0]           photo_img_idx,         // 当前照片序号（给 OSD 选字幕）

    // v46：视频播完（停在最后一帧）。顶层用它做"轮播模式下自动回第 1 张"。
    output wire                 vid_done_o,

    // ---------------- 调试观察 ----------------
    output reg  [31:0]          dbg_a,
    output reg  [31:0]          dbg_b,
    output reg  [31:0]          dbg_c
);

// ------------------------------------------------------------
// 派生常量
// ------------------------------------------------------------
localparam integer SRC_PIXELS   = SRC_W * SRC_H;
localparam integer OUT_W        = SRC_W * HSCALE;
localparam integer OUT_H        = SRC_H * VSCALE;
localparam integer FRAME_BYTES  = SRC_PIXELS * 2;                       // RGB565
localparam integer FRAME_SECT   = (FRAME_BYTES + 511) / 512;
localparam integer FRAME_WORDS  = OUT_W * OUT_H;                        // 写进 SDRAM 的词数
localparam integer FRAME_CYCLES = CLK_FREQ_HZ / FPS;
localparam integer STALL_CYCLES = (CLK_FREQ_HZ / 1000) * STALL_MS;
localparam integer COMMIT_CYCLES= CLK_FREQ_HZ * COMMIT_TIMEOUT_SEC;

localparam [31:0] FRAME_SECT32  = FRAME_SECT;
localparam [8:0]  LAST_COL      = SRC_W - 1;
localparam [9:0]  LAST_OUT_COL  = OUT_W - 1;

// ------------------------------------------------------------
// 状态机
// ------------------------------------------------------------
localparam [3:0] ST_BOOT        = 4'd0;
localparam [3:0] ST_HDR         = 4'd1;
localparam [3:0] ST_HDR_GAP     = 4'd2;
localparam [3:0] ST_PHOTO       = 4'd3;    // 头不匹配：永久让位给照片链路
localparam [3:0] ST_FRAME_WAIT  = 4'd4;
localparam [3:0] ST_WR_ACK      = 4'd5;
localparam [3:0] ST_WR_GAP      = 4'd6;
localparam [3:0] ST_STREAM      = 4'd7;
localparam [3:0] ST_BURST_GAP   = 4'd8;
localparam [3:0] ST_LAST        = 4'd9;
localparam [3:0] ST_WAIT_COMMIT = 4'd10;
// v35：推进动作与暂停从 ST_WAIT_COMMIT 里拆出来。
//   原来 commit 后直接在 ST_WAIT_COMMIT 里推进并回 ST_FRAME_WAIT，
//   没有任何"停住"的位置，S1 关轮播就无处落脚。
localparam [3:0] ST_ADV         = 4'd11;   // 单拍：按 skip/正常语义推进指针
localparam [3:0] ST_PAUSE       = 4'd12;   // 播完/未启动：画面停在当前内容
localparam [3:0] ST_IDLE        = 4'd13;   // v40：play=0，彻底静默等上级开闸

reg [3:0]  state;

// v40：视频"播完即停"判定（模块级组合逻辑）
//   vid_last_frame : 当前已经是视频最后一帧
//   vid_stop_now   : 播完就停 —— 不论轮播开没开，都停在最后一帧等 S0
//   vid_done       : 已经停在视频结尾（防止 ST_PAUSE 因 auto_play=1 又弹回 ST_ADV 空转）
wire vid_last_frame = phase_video && ((frame_idx + 32'd1) >= total_frames);
wire vid_stop_now   = vid_last_frame;
reg  vid_done;

// ------------------------------------------------------------
// v35：按键采集与"跳过"请求
//   skip_req 是电平请求（不是单拍），保证在 ST_STREAM / ST_WR_* 期间按下的键
//   不会丢，等到下一个可以推进的时刻（commit 后）才被消费。
//   消抖在顶层统一做（见 top_tf_hdmi_audio.v），这里只吃消抖后的脉冲。
// ------------------------------------------------------------
wire key_next_press = key_next;
wire key_auto_press = key_auto;
reg  skip_req;

// ------------------------------------------------------------
// 头部字段（扇区 0）
//   0..3   'R','A','W','V'
//   4      version = 1        5  format(0=RGB565)
//   6      fps                7  reserved
//   8..11  width              12..15 height
//   16..19 frame_count        20..23 frame_bytes
//   24..27 data_start_sector  28..31 flags(bit0=loop)
//   32..35 photo_count        36..39 photo_hold_ms（每张定格毫秒）
//   40..43 photo_data_start（0 视为 1）
// ------------------------------------------------------------
reg [7:0]  h_m0, h_m1, h_m2, h_m3;
reg [7:0]  h_ver, h_fmt, h_fps;
reg [31:0] h_w, h_h, h_frames, h_bytes, h_start, h_flags;
reg [31:0] h_ph_cnt, h_ph_hold, h_ph_start;
// v40【黑屏根因】：原来是 6 位（0..63），而一个扇区有 512 字节的有效数据脉冲，
//   计数器每 64 字节回绕一次 -> 头部字段被后面 7 段全 0 的填充区反复覆盖，
//   最终 h_m0 拿到的是第 448 字节的 0x00，magic 永远判不出 "RAWV"。
//   位宽必须能覆盖 512 字节（10 位），并且只在前 64 字节里收字段。
reg [9:0]  rd_cnt;
// v40：读头超时 5ms（@100MHz = 500_000 拍）；失败最多重试 2 次
localparam integer HDR_TIMEOUT_CYC = CLK_FREQ_HZ / 200;
reg [31:0] hdr_to_cnt;
reg [1:0]  hdr_try;

wire [31:0] hdr_start_use = (h_start == 32'd0) ? DATA_START_SECTOR : h_start;

// v34：ver=1 纯视频（老文件照旧能播），ver=2 照片+视频。
//   ver=2 带照片时才校验照片字段：张数 1..8、定格 >= 200ms（否则照片一闪而过没法看）。
wire [31:0] h_photo_cnt = (h_ver == 8'd2) ? h_ph_cnt : 32'd0;
wire [31:0] h_hold_ms   = (h_ph_hold > 32'd60000) ? 32'd60000 : h_ph_hold;

wire hdr_ok = (h_m0 == "R") && (h_m1 == "A") && (h_m2 == "W") && (h_m3 == "V") &&
              ((h_ver == 8'd1) || (h_ver == 8'd2)) &&
              (h_fmt == 8'd0) &&
              (h_w   == SRC_W) &&
              (h_h   == SRC_H) &&
              (h_bytes == FRAME_BYTES) &&
              (h_frames != 32'd0) &&
              (h_photo_cnt == 32'd0 ||
               ((h_photo_cnt <= 32'd8) && (h_ph_hold >= 32'd200)));

// v37b：hdr_ok 是一棵很深的与树（4 个字节比较 + 5 个 32bit 比较 + 范围判断），
//   原来直接驱动 ST_HDR_GAP 里 cur_sector 等一大批寄存器的 CE，sd 域 100MHz
//   下实测 13.7ns（-3.7ns 违例），而且不同布局种子都收不回来。
//   header 字段在 counter 0..7 就写完了，到 gap_cnt>=63 早已稳定 60 多拍，
//   所以把 hdr_ok 打一拍、判定时用打拍后的值，行为完全不变，但把长路径切成两段。
reg hdr_ok_q;
always @(posedge clk or posedge rst) begin
    if (rst) hdr_ok_q <= 1'b0;
    else     hdr_ok_q <= hdr_ok;
end

// ------------------------------------------------------------
// 跨域同步：write_finish_toggle / commit_toggle
// ------------------------------------------------------------
reg [2:0] wf_sync;
reg [2:0] cm_sync;
wire      wf_pulse = wf_sync[2] ^ wf_sync[1];
wire      cm_pulse = cm_sync[2] ^ cm_sync[1];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wf_sync <= 3'b000;
        cm_sync <= 3'b000;
    end else begin
        wf_sync <= {wf_sync[1:0], write_finish_toggle};
        cm_sync <= {cm_sync[1:0], commit_toggle};
    end
end

// ------------------------------------------------------------
// 写 FIFO 反压（<128/512 才允许进数据，与排水门限对齐）
// ------------------------------------------------------------
reg  wr_ok_r;
wire wr_ok = wr_ok_r;
always @(posedge clk or posedge rst) begin
    if (rst) wr_ok_r <= 1'b0;
    else     wr_ok_r <= (wr_fifo_used < 9'd128);
end

// ------------------------------------------------------------
// 帧调度 / 缓冲指针
// ------------------------------------------------------------
reg [31:0] slot_cnt;
reg [31:0] frame_idx;
reg [31:0] total_frames;
reg [31:0] start_sector;
reg [31:0] cur_sector;      // 当前帧起始扇区
reg [1:0]  disp_buf;        // video 已确认显示的 buffer
reg [1:0]  wr_buf;          // 本帧正在写的 buffer
reg        first_frame;

// ---- v34 照片段 ----
reg [31:0] ph_cnt;          // 片头照片张数（ver=1 恒 0）
reg [31:0] ph_hold_ms;      // 每张定格时长
reg [31:0] ph_start;        // 照片数据起始扇区
reg [31:0] photo_idx;       // 当前正在播的照片序号
reg [31:0] hold_ms_cnt;     // 当前照片已定格毫秒数
reg        hold_arm;        // 1 = 本张立即写（首张 / 视频放完循环回首张）
// 最后一张照片已上屏，正在定格；定格结束的那一拍才切视频相。
//   没有这个标志的话，最后一张只显示"写下一帧的 90ms"就被视频顶掉。
reg        photo_end_pending;

// 1ms 心跳：照片定格计时用，不做乘除法
localparam integer MS_CYC = CLK_FREQ_HZ / 1000;
reg [19:0] ms_cnt;
reg        ms_tick;

// 帧节拍：从"本帧开始读"那一刻起自由计数，到 FRAME_CYCLES 饱和。
//   v33 之前是在 commit 时清零、只在 ST_FRAME_WAIT 里自增，
//   于是每帧实际周期 = 83.3ms(空等) + 读帧(约70ms) + 等 commit(0~16ms) ≈ 155ms，
//   12fps 变成 6fps（慢放一倍）。现在节拍覆盖整帧周期：
//   周期 = max(FRAME_CYCLES, 读帧 + commit)，读得快时就是标准的 83.33ms。
wire slot_due = (slot_cnt >= FRAME_CYCLES - 1);

assign write_buf_idx = wr_buf;
assign photo_img_idx = photo_idx[1:0];
// v46：视频播完指示（顶层轮播模式据此自动回第 1 张）
assign vid_done_o    = vid_done;

// ------------------------------------------------------------
// 1ms 心跳
// ------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_cnt  <= 20'd0;
        ms_tick <= 1'b0;
    end else if (ms_cnt >= MS_CYC - 1) begin
        ms_cnt  <= 20'd0;
        ms_tick <= 1'b1;
    end else begin
        ms_cnt  <= ms_cnt + 20'd1;
        ms_tick <= 1'b0;
    end
end

// ------------------------------------------------------------
// 帧内读指针
// ------------------------------------------------------------
reg [31:0] sect_done;       // 本帧已读扇区数
reg [31:0] burst_base;      // 当前这笔的起始扇区
reg [4:0]  burst_cnt_cur;   // 当前这笔扇区数
reg [31:0] gap_cnt;
reg [31:0] stall_cnt;

wire [31:0] remain_sect    = FRAME_SECT32 - sect_done;
wire [4:0]  spb            = SECT_PER_BURST[4:0];
wire [4:0]  next_burst_cnt = (remain_sect >= {27'd0, spb}) ? spb : remain_sect[4:0];

// v33：每帧第一笔的扇区数。
//   不能沿用 next_burst_cnt —— 进入 ST_WR_GAP 时 sect_done 还是上一帧留下的
//   FRAME_SECT（300），remain_sect = 0，算出来是 0。
//   SD 控制器对 cnt=0 有兜底（按 1 个扇区走 CMD17），所以之前"没炸"，
//   但每帧开头会多一次 CMD17 单扇区读（多 ~0.3ms），而且依赖下游兜底才能工作。
wire [4:0]  first_burst_cnt = (FRAME_SECT > SECT_PER_BURST) ? spb : FRAME_SECT[4:0];
wire [31:0] sect_after     = sect_done + {27'd0, burst_cnt_cur};
wire        last_burst     = (sect_after >= FRAME_SECT32);
wire        stall_hit      = (stall_cnt >= STALL_CYCLES);

// ------------------------------------------------------------
// 行缓冲（ping-pong，各 320x16bit ≈ 1 个 BRAM9K）
//   bank_wr_cnt / bank_rd_cnt 是回绕计数器：第 n 行写 bank n[0]、读 bank n[0]。
//   用差值而不是单个 full 标志，才能在"写满新行"与"取走旧行"同拍时不丢标记。
// ------------------------------------------------------------
(* ram_style = "block" *) reg [15:0] lb0 [0:511];
(* ram_style = "block" *) reg [15:0] lb1 [0:511];

reg        byte_phase;      // 0=等低字节 1=等高字节
reg [7:0]  pix_lo;
reg [8:0]  pix_col;         // 0..SRC_W-1
reg [15:0] rows_in;
reg [1:0]  bank_wr_cnt;
reg [1:0]  bank_rd_cnt;

reg        lb_we;
reg [8:0]  lb_wa;
reg [15:0] lb_wd;

// 帧起点复位的单拍脉冲：行缓冲/输出两套寄存器各自在本 always 内清零，
// 绝不能在主状态机里给它们赋值（否则多驱动）。
reg        frame_rst;

wire lb_row_done = lb_we && (lb_wa == LAST_COL);
wire wr_bank     = bank_wr_cnt[0];

// 读侧
reg        out_busy;
reg        out_take;
reg [9:0]  out_col;
reg        out_pass;
reg [3:0]  pre_cnt;
reg [8:0]  rd_addr;
reg        rd_bank_lat;
reg [15:0] q0, q1;
reg [15:0] rd_q;
reg [31:0] words_out;

wire        lb_pending = (bank_wr_cnt != bank_rd_cnt);

wire [10:0] nc_a = {1'b0, out_col} + 11'd2;
wire [10:0] nc_b = (nc_a >= OUT_W) ? (nc_a - OUT_W) : nc_a;
wire [8:0]  nc_addr = nc_b[9:1];

// ------------------------------------------------------------
// 像素装配 + 行缓冲写口
// ------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        byte_phase   <= 1'b0;
        pix_lo       <= 8'd0;
        pix_col      <= 9'd0;
        rows_in      <= 16'd0;
        bank_wr_cnt  <= 2'd0;
        bank_rd_cnt  <= 2'd0;
        lb_we        <= 1'b0;
        lb_wa        <= 9'd0;
        lb_wd        <= 16'd0;
    end else if (frame_rst) begin
        byte_phase   <= 1'b0;
        pix_col      <= 9'd0;
        rows_in      <= 16'd0;
        bank_wr_cnt  <= 2'd0;
        bank_rd_cnt  <= 2'd0;
        lb_we        <= 1'b0;
    end else begin
        lb_we <= 1'b0;

        // RGB565 两字节拼一个像素（小端：低字节先到）
        if ((state == ST_STREAM) && sd_sec_read_data_valid) begin
            if (!byte_phase) begin
                byte_phase <= 1'b1;
                pix_lo     <= sd_sec_read_data;
            end else begin
                byte_phase <= 1'b0;
                lb_we      <= 1'b1;
                lb_wa      <= pix_col;
                lb_wd      <= {sd_sec_read_data, pix_lo};
                if (pix_col == LAST_COL) begin
                    pix_col <= 9'd0;
                    rows_in <= rows_in + 16'd1;
                end else begin
                    pix_col <= pix_col + 9'd1;
                end
            end
        end

        // 一行写满 -> 交给读侧
        if (lb_row_done)
            bank_wr_cnt <= bank_wr_cnt + 2'd1;

        // 读侧取走一行 -> 释放
        if (out_take)
            bank_rd_cnt <= bank_rd_cnt + 2'd1;
    end
end

always @(posedge clk) begin
    if (lb_we) begin
        if (wr_bank) lb1[lb_wa] <= lb_wd;
        else         lb0[lb_wa] <= lb_wd;
    end
end

// ------------------------------------------------------------
// 行输出：BRAM 同步读（2 拍延迟）+ 水平 2x + 垂直 2x
//   rd_addr 按"2 拍后的那一列"预算，行尾自动回绕到下一遍的第 0 列，
//   因此两遍之间不需要插入空拍。
// ------------------------------------------------------------
always @(posedge clk) begin
    q0   <= lb0[rd_addr];
    q1   <= lb1[rd_addr];
    rd_q <= rd_bank_lat ? q1 : q0;
end

function [23:0] cvt565;
    input [15:0] p;
    reg [4:0] r5;
    reg [5:0] g6;
    reg [4:0] b5;
    begin
        r5 = p[15:11];
        g6 = p[10:5];
        b5 = p[4:0];
        cvt565 = {r5, r5[4:2], g6, g6[5:4], b5, b5[4:2]};
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        out_busy    <= 1'b0;
        out_take    <= 1'b0;
        out_col     <= 10'd0;
        out_pass    <= 1'b0;
        pre_cnt     <= 4'd0;
        rd_addr     <= 9'd0;
        rd_bank_lat <= 1'b0;
        write_en    <= 1'b0;
        write_data  <= 32'd0;
        words_out   <= 32'd0;
    end else if (frame_rst) begin
        out_busy    <= 1'b0;
        out_take    <= 1'b0;
        out_col     <= 10'd0;
        out_pass    <= 1'b0;
        pre_cnt     <= 4'd0;
        rd_addr     <= 9'd0;
        write_en    <= 1'b0;
        words_out   <= 32'd0;
    end else begin
        write_en <= 1'b0;
        out_take <= 1'b0;

        if (!out_busy) begin
            if (lb_pending) begin
                out_busy    <= 1'b1;
                out_take    <= 1'b1;
                rd_bank_lat <= bank_rd_cnt[0];
                out_col     <= 10'd0;
                out_pass    <= 1'b0;
                pre_cnt     <= 4'd4;
                rd_addr     <= 9'd0;
            end
        end else if (pre_cnt != 4'd0) begin
            pre_cnt <= pre_cnt - 4'd1;
            rd_addr <= 9'd0;
        end else if (wr_ok) begin
            // 本拍输出 rd_q 对应的第 out_col 列
            write_en   <= 1'b1;
            write_data <= {cvt565(rd_q), 8'd0};
            words_out  <= words_out + 32'd1;
            rd_addr    <= nc_addr;

            if (out_col == LAST_OUT_COL) begin
                out_col <= 10'd0;
                if ((VSCALE == 1) || out_pass) begin
                    out_pass <= 1'b0;
                    out_busy <= 1'b0;
                end else begin
                    out_pass <= 1'b1;
                end
            end else begin
                out_col <= out_col + 10'd1;
            end
        end
    end
end

// ------------------------------------------------------------
// 主状态机
// ------------------------------------------------------------
reg        write_done_seen;
reg [31:0] commit_wait_cnt;
reg [31:0] last_wait_cnt;
reg [31:0] abort_cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_BOOT;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        sd_sec_read_cnt   <= 5'd1;
        write_req         <= 1'b0;
        frame_ready_toggle<= 1'b0;
        ready_buf_idx     <= 2'd0;
        video_mode        <= 1'b0;
        detect_done       <= 1'b0;
        rd_cnt            <= 10'd0;
        hdr_to_cnt        <= 32'd0;
        hdr_try           <= 2'd0;
        h_m0 <= 8'd0; h_m1 <= 8'd0; h_m2 <= 8'd0; h_m3 <= 8'd0;
        h_ver <= 8'd0; h_fmt <= 8'd0; h_fps <= 8'd0;
        h_w <= 32'd0; h_h <= 32'd0; h_frames <= 32'd0;
        h_bytes <= 32'd0; h_start <= 32'd0; h_flags <= 32'd0;
        slot_cnt          <= 32'd0;
        frame_idx         <= 32'd0;
        total_frames      <= 32'd0;
        start_sector      <= 32'd0;
        cur_sector        <= 32'd0;
        disp_buf          <= 2'd0;
        wr_buf            <= 2'd0;
        first_frame       <= 1'b1;
        phase_video       <= 1'b0;      // 复位默认照片相；识别到纯视频卡后置 1
        ph_cnt            <= 32'd0;
        ph_hold_ms        <= 32'd0;
        ph_start          <= 32'd1;
        photo_idx         <= 32'd0;
        hold_ms_cnt       <= 32'd0;
        hold_arm          <= 1'b0;
        photo_end_pending <= 1'b0;
        sect_done         <= 32'd0;
        burst_base        <= 32'd0;
        burst_cnt_cur     <= 5'd1;
        gap_cnt           <= 32'd0;
        stall_cnt         <= 32'd0;
        write_done_seen   <= 1'b0;
        commit_wait_cnt   <= 32'd0;
        last_wait_cnt     <= 32'd0;
        abort_cnt         <= 32'd0;
        frame_rst         <= 1'b0;
        // v35
        skip_req          <= 1'b0;
        vid_done          <= 1'b0;
        auto_play         <= 1'b0;      // v36：默认静止，等 S0 步进 / S1 开轮播
    end else begin
        frame_rst <= 1'b0;

        // ---------- v35：按键采集 ----------
        //   S1 切换轮播；S0 只置"跳过请求"，由 ST_FRAME_WAIT / ST_ADV 消费。
        //   请求用电平锁存而不是单拍脉冲：帧读、写帧、等 commit 这三个阶段
        //   加起来最长几十毫秒，单拍脉冲会被整段吞掉。
        if (key_auto_press)
            auto_play <= ~auto_play;
        if (key_next_press)
            skip_req  <= 1'b1;

        // ---------- 头部字节收集 ----------
        if ((state == ST_HDR) && sd_sec_read_data_valid) begin
            // 只收前 64 字节（头部字段只到 43），其余填充字节丢掉
            case (rd_cnt)
                6'd0 : h_m0 <= sd_sec_read_data;
                6'd1 : h_m1 <= sd_sec_read_data;
                6'd2 : h_m2 <= sd_sec_read_data;
                6'd3 : h_m3 <= sd_sec_read_data;
                6'd4 : h_ver <= sd_sec_read_data;
                6'd5 : h_fmt <= sd_sec_read_data;
                6'd6 : h_fps <= sd_sec_read_data;

                6'd8 : h_w[7:0]   <= sd_sec_read_data;
                6'd9 : h_w[15:8]  <= sd_sec_read_data;
                6'd10: h_w[23:16] <= sd_sec_read_data;
                6'd11: h_w[31:24] <= sd_sec_read_data;

                6'd12: h_h[7:0]   <= sd_sec_read_data;
                6'd13: h_h[15:8]  <= sd_sec_read_data;
                6'd14: h_h[23:16] <= sd_sec_read_data;
                6'd15: h_h[31:24] <= sd_sec_read_data;

                6'd16: h_frames[7:0]   <= sd_sec_read_data;
                6'd17: h_frames[15:8]  <= sd_sec_read_data;
                6'd18: h_frames[23:16] <= sd_sec_read_data;
                6'd19: h_frames[31:24] <= sd_sec_read_data;

                6'd20: h_bytes[7:0]   <= sd_sec_read_data;
                6'd21: h_bytes[15:8]  <= sd_sec_read_data;
                6'd22: h_bytes[23:16] <= sd_sec_read_data;
                6'd23: h_bytes[31:24] <= sd_sec_read_data;

                6'd24: h_start[7:0]   <= sd_sec_read_data;
                6'd25: h_start[15:8]  <= sd_sec_read_data;
                6'd26: h_start[23:16] <= sd_sec_read_data;
                6'd27: h_start[31:24] <= sd_sec_read_data;

                6'd28: h_flags[7:0]   <= sd_sec_read_data;

                // v34：照片字段
                6'd32: h_ph_cnt[7:0]     <= sd_sec_read_data;
                6'd33: h_ph_cnt[15:8]    <= sd_sec_read_data;
                6'd34: h_ph_cnt[23:16]   <= sd_sec_read_data;
                6'd35: h_ph_cnt[31:24]   <= sd_sec_read_data;

                6'd36: h_ph_hold[7:0]    <= sd_sec_read_data;
                6'd37: h_ph_hold[15:8]   <= sd_sec_read_data;
                6'd38: h_ph_hold[23:16]  <= sd_sec_read_data;
                6'd39: h_ph_hold[31:24]  <= sd_sec_read_data;

                6'd40: h_ph_start[7:0]   <= sd_sec_read_data;
                6'd41: h_ph_start[15:8]  <= sd_sec_read_data;
                6'd42: h_ph_start[23:16] <= sd_sec_read_data;
                6'd43: h_ph_start[31:24] <= sd_sec_read_data;
                default: ;
            endcase
            if (rd_cnt != 10'd1023)
                rd_cnt <= rd_cnt + 10'd1;
        end

        // ---------- 整帧写完脉冲：全程锁存 ----------
        // write_finish 是 ext_mem_clk 域的单拍脉冲，整帧最后一个词入 FIFO 后
        // 约 13us 出现；而 sd_sec_read_end 要等 CRC + CMD12，约 4us 就到了。
        // 两者只差 10us 量级，若只在 ST_LAST 里采样，遇到慢卡/快 CMD12
        // 就会漏掉这一帧的完成事件（然后被 300ms 看门狗判成超时、白扔一帧）。
        // 改成从帧起点开始全程锁存，ST_LAST 只看标志位。
        if (wf_pulse)
            write_done_seen <= 1'b1;

        // ---------- 帧节拍：自由计数，帧起点清零 ----------
        if (frame_rst)
            slot_cnt <= 32'd0;
        else if (slot_cnt < FRAME_CYCLES - 1)
            slot_cnt <= slot_cnt + 32'd1;

        // ---------- 源流停滞看门狗 ----------
        if (state == ST_STREAM) begin
            if (sd_sec_read_data_valid) stall_cnt <= 32'd0;
            else if (!stall_hit)        stall_cnt <= stall_cnt + 32'd1;
        end else begin
            stall_cnt <= 32'd0;
        end

        // ---------- v40：play 闸门 ----------
        //   照片链路接管时（mode_video 落下）本模块必须立刻停手：
        //   不占 SD 总线、不申请写 buffer，并把内部指针留在 IDLE，
        //   下次 play 拉高从第 1 帧重新开始。
        //   v41 备注：这里不需要额外去清行输出流水（out_busy/write_en）。
        //     ① 写口在顶层已按 mode_video 切给照片链路，残余的 write_en 落不了盘；
        //     ② 下次开闸必经 ST_WR_GAP，那里的 frame_rst 会把流水全清。
        //   多加一份优先级分支只会白烧 ~20 个 LUT。
        if (!play && (state != ST_IDLE) && (state != ST_BOOT) &&
            (state != ST_HDR) && (state != ST_HDR_GAP) && (state != ST_PHOTO)) begin
            sd_sec_read <= 1'b0;
            write_req   <= 1'b0;
            // v58：把"跳过请求"也清掉。视频段按 S0 退出时 key1_press 会顺手置
            //   skip_req=1，而这条 !play 分支原来不碰它 —— 下次再进视频时
            //   skip_req 还是 1，会在第一帧就白跳掉一帧（83ms）。
            skip_req    <= 1'b0;
            state       <= ST_IDLE;
        end else begin
        case (state)
            // ------------------------------------------------
            ST_BOOT: begin
                if (sd_init_done) begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= VIDEO_LBA;      // v40：视频头不在扇区 0
                    sd_sec_read_cnt  <= 5'd1;
                    rd_cnt           <= 10'd0;
                    hdr_to_cnt       <= 32'd0;
                    state            <= ST_HDR;
                end
            end

            ST_HDR: begin
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    rd_cnt      <= 10'd0;
                    gap_cnt     <= 32'd0;
                    state       <= ST_HDR_GAP;
                end else if (hdr_to_cnt >= HDR_TIMEOUT_CYC) begin
                    // 读头超时（卡接触不良 / 换卡）：重试一次，再不行就当照片卡
                    sd_sec_read <= 1'b0;
                    if (hdr_try < 2'd2) begin
                        hdr_try   <= hdr_try + 2'd1;
                        hdr_to_cnt<= 32'd0;
                        state     <= ST_BOOT;
                    end else begin
                        video_mode  <= 1'b0;
                        detect_done <= 1'b1;
                        state       <= ST_PHOTO;
                    end
                end else begin
                    hdr_to_cnt <= hdr_to_cnt + 32'd1;
                end
            end

            ST_HDR_GAP: begin
                // 等 header 字段落定 + 总线回到空闲
                if (gap_cnt >= 32'd63) begin
                    gap_cnt <= 32'd0;
                    if (hdr_ok_q) begin
                        video_mode   <= 1'b1;
                        detect_done  <= 1'b1;
                        total_frames <= h_frames;
                        // v40：头里的 data_start / photo_data_start 是"相对视频区"的偏移，
                        //   这里统一加 VIDEO_LBA 变成绝对扇区号，后面的指针推进全用绝对值。
                        start_sector <= VIDEO_LBA + hdr_start_use;
                        frame_idx    <= 32'd0;
                        disp_buf     <= 2'd0;
                        wr_buf       <= 2'd0;
                        first_frame  <= 1'b1;
                        slot_cnt     <= FRAME_CYCLES - 1;   // 首帧立即启动
                        // v34：有照片就先照片段，没有就直接视频段（等价 v33）
                        // v40：照片统一由 FAT/BMP 链路负责，本模块只播视频，
                        //   所以固定 ph_cnt=0 / phase_video=1，忽略头里的照片字段
                        //   （老 ver=2 带照片的文件也能照常播，只是照片段被跳过）。
                        ph_cnt       <= 32'd0;
                        ph_hold_ms   <= 32'd0;
                        ph_start     <= VIDEO_LBA + 32'd1;
                        photo_idx    <= 32'd0;
                        hold_ms_cnt  <= 32'd0;
                        hold_arm     <= 1'b0;
                        photo_end_pending <= 1'b0;
                        phase_video  <= 1'b1;
                        cur_sector   <= VIDEO_LBA + hdr_start_use;
                        state        <= play ? ST_FRAME_WAIT : ST_IDLE;
                    end else if (hdr_try < 2'd2) begin
                        // 头部内容不对（可能是刚上电第一拍读飞）：再读一次
                        hdr_try    <= hdr_try + 2'd1;
                        hdr_to_cnt <= 32'd0;
                        state      <= ST_BOOT;
                    end else begin
                        video_mode   <= 1'b0;
                        detect_done  <= 1'b1;
                        state        <= ST_PHOTO;
                    end
                end else begin
                    gap_cnt <= gap_cnt + 32'd1;
                end
            end

            // 头不匹配：让位给照片链路，本模块永久静默
            ST_PHOTO: begin
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end

            // ------------------------------------------------
            // 等帧时隙，然后向写通路申请一块 buffer
            // ------------------------------------------------
            ST_FRAME_WAIT: begin
                // 照片段定格计时：每过 1ms 加一，够 ph_hold_ms 才允许换下一张。
                //   slot_due 在照片阶段会一直保持高（没有 frame_rst 去清 slot_cnt），
                //   所以计时必须独立于 slot_due，否则永远等不到。
                if (!phase_video && ms_tick && !hold_arm && (hold_ms_cnt < ph_hold_ms))
                    hold_ms_cnt <= hold_ms_cnt + 32'd1;

                // v35：S0 在定格期间按下 —— 直接把定格计时补满，下一次 slot_due
                // （<=83ms）就会推进到下一张。这里消费掉请求，因为它要表达的就是
                // "结束当前定格、前进一张"，不需要在 ST_ADV 再跳一次。
                if (!phase_video && !hold_arm && skip_req) begin
                    hold_ms_cnt <= ph_hold_ms;
                    skip_req    <= 1'b0;
                end

                if (slot_due) begin
                    if (!phase_video && !hold_arm && (hold_ms_cnt < ph_hold_ms)) begin
                        // 还在定格，继续等
                    end else begin
                        // 最后一张照片定格够了：先把相位切到视频、指针指到视频首帧，
                        // 然后同一拍就发起视频首帧的写请求（地址在 ST_WR_GAP 才真正用，
                        // 那时 cur_sector 已经更新为 start_sector）。
                        if (!phase_video && photo_end_pending) begin
                            phase_video       <= 1'b1;
                            photo_end_pending <= 1'b0;
                            vid_done          <= 1'b0;
                            frame_idx         <= 32'd0;
                            cur_sector        <= start_sector;
                            hold_ms_cnt       <= 32'd0;
                        end
                        // 首帧写顶层指定的那块（不在显示中的 buffer），
                        // 之后写"不在显示"的另一块
                        wr_buf    <= first_frame ? {1'b0, first_buf}
                                                 : ((disp_buf == 2'd0) ? 2'd1 : 2'd0);
                        write_req <= 1'b1;
                        gap_cnt   <= 32'd0;
                        state     <= ST_WR_ACK;
                    end
                end
                // 节拍由公共段统一自增（见 slot_due 注释）
            end

            ST_WR_ACK: begin
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    gap_cnt   <= 32'd0;
                    state     <= ST_WR_GAP;
                end
            end

            // 下游 ack 后它会 aclr 写 FIFO，必须留出复位窗口
            ST_WR_GAP: begin
                if (gap_cnt >= 32'd31) begin
                    gap_cnt         <= 32'd0;
                    sect_done       <= 32'd0;
                    burst_base      <= cur_sector;
                    burst_cnt_cur   <= first_burst_cnt;
                    write_done_seen <= 1'b0;
                    commit_wait_cnt <= 32'd0;
                    last_wait_cnt   <= 32'd0;
                    frame_rst       <= 1'b1;      // 单拍：行缓冲/输出侧清零
                    sd_sec_read_addr<= cur_sector;
                    sd_sec_read_cnt <= first_burst_cnt;
                    sd_sec_read     <= 1'b1;
                    state           <= ST_STREAM;
                end else begin
                    gap_cnt <= gap_cnt + 32'd1;
                end
            end

            // ------------------------------------------------
            ST_STREAM: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    sect_done   <= sect_after;
                    if (last_burst) begin
                        state <= ST_LAST;
                    end else begin
                        // 预算下一笔的起始地址（常驻加法器，不进触发沿路径）
                        burst_base <= burst_base + {27'd0, burst_cnt_cur};
                        gap_cnt    <= 32'd0;
                        state      <= ST_BURST_GAP;
                    end
                end else if (stall_hit) begin
                    // 源流停滞：放弃本帧（下次 write_req 会重新 aclr 写 FIFO）
                    sd_sec_read <= 1'b0;
                    slot_cnt    <= 32'd0;
                    abort_cnt   <= abort_cnt + 32'd1;
                    // 安全阀：照片区连续读不出来（坏扇区/卡接触不良）就别死循环，
                    // 直接跳到视频段——至少视频还能播，不会整机卡在黑屏上。
                    if (!phase_video && (abort_cnt >= 32'd7)) begin
                        phase_video       <= 1'b1;
                        photo_end_pending <= 1'b0;
                        hold_ms_cnt       <= 32'd0;
                        frame_idx         <= 32'd0;
                        cur_sector        <= start_sector;
                    end
                    state       <= ST_FRAME_WAIT;
                end
            end

            ST_BURST_GAP: begin
                // 两笔 CMD18 之间留几个拍，等控制器从 S_READ_END 回到等待态
                if (gap_cnt >= 32'd15) begin
                    gap_cnt          <= 32'd0;
                    burst_cnt_cur    <= next_burst_cnt;
                    sd_sec_read_addr <= burst_base;      // burst_base 已指向本笔起点
                    sd_sec_read_cnt  <= next_burst_cnt;
                    sd_sec_read      <= 1'b1;
                    state            <= ST_STREAM;
                end else begin
                    gap_cnt <= gap_cnt + 32'd1;
                end
            end

            // ------------------------------------------------
            // 整帧 307200 词都写进 SDRAM 后，通知 video 域
            // ------------------------------------------------
            ST_LAST: begin
                if (write_done_seen) begin
                    frame_ready_toggle <= ~frame_ready_toggle;
                    ready_buf_idx      <= wr_buf;
                    commit_wait_cnt    <= 32'd0;
                    state              <= ST_WAIT_COMMIT;
                end else if (last_wait_cnt >= STALL_CYCLES) begin
                    // 写不满一帧（丢行/写通道异常），放弃本帧重来
                    slot_cnt     <= 32'd0;
                    abort_cnt    <= abort_cnt + 32'd1;
                    last_wait_cnt<= 32'd0;
                    state        <= ST_FRAME_WAIT;
                end else begin
                    last_wait_cnt <= last_wait_cnt + 32'd1;
                end
            end

            // ------------------------------------------------
            // 一张（照片或视频帧）已经上屏，推进到下一张
            //   照片段：还有下一张就等定格再写；最后一张播完 -> 切视频段
            //   视频段：按 frame_idx 走，循环时若带片头照片则回到照片段
            // ------------------------------------------------
            ST_WAIT_COMMIT: begin
                if (cm_pulse) begin
                    disp_buf        <= wr_buf;
                    first_frame     <= 1'b0;
                    commit_wait_cnt <= 32'd0;
                    hold_ms_cnt     <= 32'd0;
                    // v38：只有【照片段】在轮播关闭时才停在当前画面；
                    //   视频段必须自动按 12fps 连续播，不能一帧一停。
                    state <= (!auto_play && !skip_req && !phase_video)
                             ? ST_PAUSE : ST_ADV;
                end else if (commit_wait_cnt >= COMMIT_CYCLES) begin
                    // video 侧没回 commit（切帧卡住），本地强行收尾，避免整机停摆
                    disp_buf        <= wr_buf;
                    first_frame     <= 1'b0;
                    commit_wait_cnt <= 32'd0;
                    abort_cnt       <= abort_cnt + 32'd1;
                    hold_ms_cnt     <= 32'd0;
                    state <= (!auto_play && !skip_req && !phase_video)
                             ? ST_PAUSE : ST_ADV;
                end else begin
                    commit_wait_cnt <= commit_wait_cnt + 32'd1;
                end
            end

            // ------------------------------------------------
            // v35：单拍推进（原来内联在 ST_WAIT_COMMIT 里）
            //   skip_req=1 -> 手动"下一张 / 跳过视频"
            //   skip_req=0 -> 按时间轴正常前进
            // ------------------------------------------------
            ST_ADV: begin
                hold_ms_cnt <= 32'd0;
                if (skip_req) begin
                    skip_req <= 1'b0;
                    if (!phase_video) begin
                        // ---- 照片段：跳下一张，且立即出图（不等定格）----
                        hold_arm          <= 1'b1;
                        photo_end_pending <= 1'b0;
                        if ((photo_idx + 32'd1) >= ph_cnt) begin
                            // 已是最后一张 -> 进视频段首帧
                            phase_video <= 1'b1;
                            vid_done    <= 1'b0;
                            photo_idx   <= 32'd0;
                            frame_idx   <= 32'd0;
                            cur_sector  <= start_sector;
                        end else begin
                            photo_idx  <= photo_idx + 32'd1;
                            cur_sector <= cur_sector + FRAME_SECT32;
                        end
                    end else begin
                        // ---- 视频段：立刻结束视频，回第一张照片（无照片则回首帧）----
                        hold_arm <= 1'b1;
                        vid_done <= 1'b0;
                        if (ph_cnt != 32'd0) begin
                            phase_video <= 1'b0;
                            photo_idx   <= 32'd0;
                            cur_sector  <= ph_start;
                        end else begin
                            frame_idx   <= 32'd0;
                            cur_sector  <= start_sector;
                        end
                    end
                end else if (!phase_video) begin
                    // ---- 照片组自动推进（轮播）----
                    hold_arm <= 1'b0;    // 后续照片必须等够定格时长
                    if ((photo_idx + 32'd1) >= ph_cnt) begin
                        if (CROSS_PHASE != 0) begin
                            // 轮播跨界：最后一张定格结束后进视频组（见 ST_FRAME_WAIT）
                            photo_end_pending <= 1'b1;
                        end else begin
                            // 照片组独立循环：回到本组第 1 张，绝不碰视频
                            photo_idx  <= 32'd0;
                            cur_sector <= ph_start;
                            hold_arm   <= 1'b0;
                        end
                    end else begin
                        photo_idx  <= photo_idx + 32'd1;
                        cur_sector <= cur_sector + FRAME_SECT32;
                    end
                end else if ((frame_idx + 32'd1) >= total_frames) begin
                    // v40：视频播完 —— 停在最后一帧（不再自动回卷、不再自动回照片），
                    //   等用户按 S0 才回第一张照片。
                    frame_idx <= total_frames - 32'd1;
                    vid_done  <= 1'b1;
                end else begin
                    frame_idx  <= frame_idx + 32'd1;
                    cur_sector <= cur_sector + FRAME_SECT32;
                end
                // 视频刚好播完 -> 直接停在 PAUSE（跳过再读一遍同一帧）
                // 手动 S0 那一拍 skip_req 还是 1，此时走 skip 分支，不能被误判成停
                state <= (vid_stop_now && !skip_req) ? ST_PAUSE : ST_FRAME_WAIT;
            end

            // ------------------------------------------------
            // v35：轮播关闭时的停留点。画面保持不动（video 侧持续读同一块
            //   buffer，天然静止）；按 S0 继续下一张、按 S1 恢复轮播都能走。
            // ------------------------------------------------
            ST_PAUSE: begin
                // 停在某一项上：S0 -> 继续（照片下一张 / 视频回第一张）
                //   轮播开着且【不是】停在视频结尾 -> 继续自动前进
                if (skip_req || (auto_play && !vid_done))
                    state <= ST_ADV;
            end

            // v40：未启动 / 播放结束后的静默态
            ST_IDLE: begin
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
                if (play) begin
                    frame_idx   <= 32'd0;
                    cur_sector  <= start_sector;
                    first_frame <= 1'b1;
                    vid_done    <= 1'b0;
                    abort_cnt   <= 32'd0;
                    hold_ms_cnt <= 32'd0;
                    slot_cnt    <= FRAME_CYCLES - 1;   // 开闸即出首帧
                    state       <= ST_FRAME_WAIT;
                end
            end

            default: state <= ST_BOOT;
        endcase
        end
    end
end

// ------------------------------------------------------------
// 调试总线
//   dbg_a: {video_mode, detect_done, state[3:0], phase_video, rows_in[6:0],
//           frame_idx[7:0], sect_done[4:0], abort_cnt[2:0], wr_buf[1:0]}
//   dbg_b: words_out（本帧已送出的写词数，正常 307200 = 0x0004B000）
//   dbg_c: {cur_sector[15:0], h_w[7:0], h_h[7:0], h_fps}
// ------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dbg_a <= 32'd0;
        dbg_b <= 32'd0;
        dbg_c <= 32'd0;
    end else begin
        dbg_a <= {video_mode, detect_done, state, phase_video, rows_in[6:0],
                  frame_idx[7:0], sect_done[4:0], abort_cnt[2:0], wr_buf};
        // v37d 诊断：临时改为输出头部 4 个 magic 字节，用来确认
        //   板子到底读到了什么（"RAWV"=52 41 57 56；全 FF/全 00 = 没读到数据）
        dbg_b <= {h_m0, h_m1, h_m2, h_m3};
        dbg_c <= {cur_sector[15:0], h_w[7:0], h_h[7:0], h_fps};
    end
end

endmodule
