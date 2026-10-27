// ============================================================
// sd_card_bmp_v3_autokeyfix
// 修正自动轮播按键偶发无响应：
// v6：以 v3 的“已验证自动播放逻辑”为基线，只修正 key1 手动请求丢失问题。
// 1) key2 自动播放逻辑恢复为 v3，不在状态机外层直接翻转 auto_play_en；
// 2) key1 请求可以在 SD 初始化完成后被锁存，不再要求 scan_done；
// 3) 不在扫描开始/首图加载开始时清除 next_req_pending；真正启动手动换图时才消费；
// 4) 保留 15ms 按键消抖和 5s 图片加载超时。
// ============================================================

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer LOAD_TIMEOUT_SEC   = 2,
    parameter integer AUTO_PLAY_SEC      = 18,   // 旧参数（保留兼容，v40 起不用）
    // v44：轮播 = 【每张停留 18 秒】，等价于"每隔 18 秒自动按一下 S0"。
    //   （v41/v42 误做成"整圈 18 秒"即每张 3 秒，已更正。）
    //   读盘时间不计入停留：装载/转场期间 auto_cnt 暂停而不是清零，
    //   所以每张从"画面稳定"起正好停 18 秒。
    //   第 4 张停满 18 秒后按同一规则交棒给视频（handoff_auto）。
    parameter integer AUTO_PHOTO_MS      = 18000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    // 扩展3：图片缩放适配引擎
    //   0 = 拉伸填满 Stretch
    //   1 = 等比完整 Contain（保持比例，黑边居中）
    //   2 = 等比裁剪 Cover（保持比例，裁剪居中）
    //   3 = 原始尺寸 1:1 居中
    parameter [1:0]   SCALE_MODE        = 2'd1
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    output reg                  display_valid,
    output      [3:0]           state_code,

    input                       write_finish_toggle,
    output [1:0]                write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    // 新图整帧写入完成后通知 video_clk 域；video 切换完成后再反向确认
    output reg                  frame_ready_toggle,
    output reg [1:0]            ready_buf_idx,
    output reg [1:0]            ready_img_idx,
    input                       commit_toggle,

    output                      write_req,
    input                       write_req_ack,
    input  [8:0]                wr_fifo_used,   // 写帧 FIFO 水位（反压用，write_clk 域准静态）
    output                      write_en,
    output [31:0]               write_data,

    // v36：当前轮播状态（0=关闭 1=开启），顶层用它决定 S1 提示显示"开始/解除"
    output reg                  auto_play_en,

    // 调试观测总线（不影响功能）
    output [31:0]               dbg_a,
    output [31:0]               dbg_b,
    output [31:0]               dbg_c,

    // ---------------- SD 扇区读总线（由顶层 sd_card_top 统一提供）----------------
    // v30：原来 sd_card_top 在本模块内部实例化，视频模式无法共用同一条 SPI。
    //      现在外提到顶层，照片/视频按模式仲裁请求，数据/valid/end 广播。
    input                       sd_init_done,
    output                      sd_sec_read,
    output [31:0]               sd_sec_read_addr,
    output [4:0]                sd_sec_read_cnt,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    // v41：SD 控制器真正空闲（无命令、无突发在读）。
    //   视频被 S0 打断时控制器还在收尾那一笔 CMD18，期间数据/end 仍然有效；
    //   照片链路必须等它彻底停下来才能发起装载，否则会读错位、5 秒超时。
    input                       sd_bus_idle,

    // ---------------- 模式冻结 ----------------
    // 1 = 视频模式（或视频头检测中）：本模块必须彻底静默，
    //     不清屏、不扫描、不发 write_req、不占用 sd_sec_read。
    input                       video_mode_hold,

    // ---------------- v40：照片组 / 视频组 交棒 ----------------
    // has_video : 卡上检测到 RAW 视频（顶层的 video_mode）
    // video_req : 单拍脉冲 —— 照片组已播完，请求切到视频
    // back_first: 单拍脉冲 —— 视频结束/被 S0 打断，重载第 1 张照片
    input                       has_video,
    output reg                  video_req,
    input                       back_first,
    // v46：本次 back_first 的来源
    //   1 = 视频段用户按 S0 主动退出 -> 解除轮播
    //   0 = 轮播模式下视频播完自动回照片 -> 保持轮播，继续从第 1 张轮
    input                       video_key_exit,
    // v49：音频加载器正占用 SD 总线（CMD18 事务进行中）。
    //   这段时间内不许发起新的 BMP 装载 —— 否则 mux 会在事务中途切地址，
    //   照片和音频双方的数据都会作废（现场就是"屏幕反复刷新 + 没声音"）。
    input                       sd_locked,
    // v47：照片链路完全空闲（没在清屏/扫描/装载/等转场）
    //   音频加载器只在这个窗口里借 SD 总线 + SDRAM 写口，
    //   保证不会和照片帧的写入抢同一个时序窗口。
    output                      photo_idle,

    // ================= v79：回照片时的"写哪块 buffer" =================
    // 视频段结束后，显示通路的 read_buf_idx 由 image_transition_ctrl 接管并
    // **保持**在视频最后一块 buffer 上（画面定格，不黑屏）。
    // 第 1 张照片必须写进【另一块】，否则会把屏幕上正在显示的帧逐行覆盖掉。
    // 本输入是 transition 侧 read_buf_idx 两级同步过来的值（回照片后是静态的）。
    input      [1:0]            disp_buf_live
);


wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
// 扩展3：缩放引擎相关
wire [15:0]      img_w;
wire [15:0]      img_h;
wire             frame_start;
wire             frame_end;
wire             scaler_d_valid;
wire [23:0]      scaler_d_data;
wire             scaler_frame_done;
wire             scaler_rst;

wire [3:0]       scaler_state;
wire [10:0]      scaler_fcnt;
wire [15:0]      scaler_next_fr;
wire [15:0]      scaler_rs;
wire [15:0]      scaler_yd;
wire             scaler_starve;
wire             scaler_s_end_lat;
wire [15:0]      scaler_dh;      // v22：目标区域高度（几何自检用）
wire [15:0]      scaler_dy0;     // v22：目标区域上边距

// v16：恢复 640x480 直通旁路（v5-v11 反复验证的可靠路径）。v13/v14 统一走
// 缩放引擎后暴露了其竖向 Bresenham 的深层 bug（实测只消费 1 行源数据就发完
// 307200 词，其余 479 行复用第 1 行行缓冲 = 水平条纹照片）。
// 旁路仅服务 640x480；其他分辨率仍走缩放引擎（其行推进 bug 待专项修复）。
// v28：bypass_active 打一拍再分发。
//   原因：img_w/img_h 直接参与组合判断，布线后
//   bmp_read_m0/img_h_reg -> ... -> u_bmp_scaler/ramread0.e 走 10.129ns
//   （其中走线 7.795ns 占 77%，LUT 密度到 65.7% 后布局被拉开），
//   是 sd_card_clk 域唯一的真实违例（-0.402ns）。
//   img_w/img_h 在识别完 BMP 头之后就整帧恒定，只在下一次换图时变化，
//   延后 10ns 对数据流没有任何影响；打拍后这条 9 级链被切成两段。
reg  bypass_active_r;
always @(posedge clk or posedge rst) begin
    if (rst) bypass_active_r <= 1'b0;
    else     bypass_active_r <= (img_w == 16'd640) && (img_h == 16'd480);
end
wire             bypass_active = bypass_active_r;
// v21：突发粒度回到 1 扇区（旁路）/ 2 扇区（缩放），并且【必须】由 wr_ok 反压。
// 一个扇区 = 512 字节 = 170 像素，这是"不可打断的在途数据量"。
// wr_ok 门限 128 时：旁路 128+170=298 < 512，缩放 128+342=470 < 512 → 写 FIFO 永不溢出。
// v18 的"旁路 burst_ok=1'b1 无门控"会让 8 扇区(1365 像素)同时在途，写通道一停
// 就静默丢词 —— 丢一个词后面所有像素左移，表现为整幅撕裂 / 纵向虚线列。
wire             burst_ok = wr_ok && (bypass_active || (scaler_fcnt < 11'd96));
wire [4:0]       burst_cnt = bypass_active ? 5'd1 : 5'd2;

reg              ever_aborted;          // 调试：是否发生过超时中止
always @(posedge clk or posedge rst) begin
    if (rst)
        ever_aborted <= 1'b0;
    else if (load_abort)
        ever_aborted <= 1'b1;
end

// ===================== 上电清屏：两个帧缓存写全黑 =====================
// 缩放图片只写目标区域，信箱黑边区域是 SDRAM 上电垃圾（显示为噪声）。
// 开机后先走正常写帧通路把 buffer0/buffer1 各写一帧全黑，噪声彻底消失。
reg        clear_done;      // 清屏完成
reg        clear_active;    // 清屏占用写端口
reg        clear_phase;     // 0=buffer0, 1=buffer1
reg        clear_req_r;     // 写请求（保持到 ack）
reg [18:0] clear_cnt;       // 已写像素数（640*480=307200）
reg [1:0]  clear_buf;    // 清屏目标 buffer
reg [2:0]  clear_st;
reg [31:0] clear_wdg;    // 清屏看门狗计数
wire       write_finish_pulse;  // 帧写完成脉冲（声明提前供清屏状态机使用）
wire       wr_ok;               // 写帧 FIFO 有空位（<128/512），反压用

// v21：写 FIFO 静默丢词（溢出）粘滞标志，正常必须恒 0。
// 打进串口 dbg_a 的 drop 位，一次抓包即可确认"门限/反压是否真的成立"。
reg drop_any;
always @(posedge clk or posedge rst) begin
    if (rst)
        drop_any <= 1'b0;
    else if (write_en && (wr_fifo_used >= 9'd504))
        drop_any <= 1'b1;
end

localparam C_IDLE = 3'd0, C_REQ = 3'd1, C_WAIT_ACK = 3'd2,
           C_GAP = 3'd3, C_FILL = 3'd4, C_WAIT_DONE = 3'd5;
localparam [18:0] CLEAR_TOTAL = 19'd307200;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        clear_done   <= 1'b0;
        clear_active <= 1'b0;
        clear_phase  <= 1'b0;
        clear_req_r  <= 1'b0;
        clear_cnt    <= 19'd0;
        clear_st     <= C_IDLE;
        clear_wdg    <= 32'd0;
    end else begin
        case (clear_st)
            C_IDLE: begin
                // v30：视频模式下绝不能清屏（会抢写通路、把视频帧覆盖成黑）
                if (sd_init_done && !clear_done && !video_mode_hold) begin
                    clear_active <= 1'b1;
                    clear_phase  <= 1'b0;
                    clear_buf   <= 2'd0;
                    clear_cnt    <= 19'd0;
                    clear_req_r  <= 1'b1;
                    clear_st     <= C_REQ;
                end
            end
            C_REQ: begin
                clear_st <= C_WAIT_ACK;      // write_req 保持高直到 ack
            end
            C_WAIT_ACK: begin
                if (write_req_ack) begin
                    clear_req_r <= 1'b0;
                    clear_cnt   <= 19'd0;
                    clear_st    <= C_GAP;
                end
            end
            // 关键间隙：等 write_req 在 mem_clk 域同步落下去、fifo_aclr 释放后
            // 才开始灌数据，否则最先写入的词会被 FIFO 复位吃掉，
            // 导致实际写入数 < 307200、write_finish 永远不来、看门狗中途弃清
            C_GAP: begin
                if (clear_cnt >= 19'd31) begin
                    clear_cnt <= 19'd0;
                    clear_st  <= C_FILL;
                end else begin
                    clear_cnt <= clear_cnt + 19'd1;
                end
            end
            C_FILL: begin
                // wr_ok=0 时原地等待（不计数），保证恰好 307200 词全部入 FIFO
                if (wr_ok) begin
                    if (clear_cnt == CLEAR_TOTAL - 19'd1) begin
                        clear_cnt <= 19'd0;
                        clear_st  <= C_WAIT_DONE;
                    end else begin
                        clear_cnt <= clear_cnt + 19'd1;
                    end
                end
            end
            C_WAIT_DONE: begin
                // 等帧写完成脉冲（wrfin_tgl_sync 边沿，本阶段无其他装载源）
                if (write_finish_pulse) begin
                    if (!clear_phase) begin
                        clear_phase   <= 1'b1;
                        clear_buf   <= 2'd1;
                        clear_cnt     <= 19'd0;
                        clear_req_r   <= 1'b1;
                        clear_st      <= C_REQ;
                    end else begin
                        clear_active <= 1'b0;
                        clear_done   <= 1'b1;
                        clear_st     <= C_IDLE;
                    end
                end
                // v20：3s 超时强制的职责移交给下方公共看门狗（覆盖所有状态）
            end
            default: clear_st <= C_IDLE;
        endcase

        // v20 清屏看门狗：只在真正里程碑（ack / 完成脉冲）时喂狗。
        // 旧版在 C_FILL && wr_ok 时喂狗——但 wr_ok=1 只说明 FIFO 未满，
        // 排水死锁时数据正被丢弃、清屏毫无进展，假进展喂狗导致永不超时。
        // 超时（5s 无里程碑）从【任何状态】强制结束清屏，绝不停摆在半路。
        if (clear_active && !clear_done) begin
            if ((clear_st == C_WAIT_ACK  && write_req_ack) ||
                (clear_st == C_WAIT_DONE && write_finish_pulse))
                clear_wdg <= 32'd0;
            else if (clear_wdg != 32'hFFFF_FFFF)
                clear_wdg <= clear_wdg + 32'd1;
        end else begin
            clear_wdg <= 32'd0;
        end

        // v20：超时从【任何状态】强制结束清屏（旧版只在 C_WAIT_DONE 生效，
        // C_FILL 死锁时看门狗空转 60s 都不救）。同时清干净 clear_req_r，
        // 防止 write_req 残留高电平把写 FSM 卡死在 S_ACK。
        if (clear_watchdog && clear_active && !clear_done) begin
            clear_done   <= 1'b1;
            clear_active <= 1'b0;
            clear_req_r  <= 1'b0;
            clear_st     <= C_IDLE;
        end
    end
end

wire clear_watchdog = (clear_wdg >= 32'd500_000_000);   // 5s @100MHz

wire             bmp_ready;
wire             scan_done;
wire             scan_ok;      // 扫描有效：完成 或 LUT 已满（防 scan_done 卡 0 弄死切换）
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;
wire             br_write_req;      // bmp_read 的写帧请求（清屏时让位给清屏状态机）
reg              scan_kicked;

// v16：写数据按图源选择——640x480 走直通（bmp_read 原始像素流），
// 其他分辨率走缩放引擎。两条路径都由 burst_ok 节流，绝不溢出。
wire [23:0]      wr_pix = bypass_active ? bmp_data : scaler_d_data;

// 缩放引擎已完成帧计数（调试用）
reg [17:0]       dbg_done_cnt;
always @(posedge clk or posedge rst) begin
    if (rst)
        dbg_done_cnt <= 18'd0;
    else if (scaler_frame_done)
        dbg_done_cnt <= dbg_done_cnt + 18'd1;
end

// v24：A 字段重打包，严格 32 位（原来 33 位，最高位被静默截断，解出来全是错的）
//   bit31    load_busy            bit21    bypass_active
//   bit30:27 bmp_read 状态码      bit20:17 缩放引擎状态
//   bit26:24 找到的图片数         bit16    缩放忙
//   bit23    显示有效             bit15    缩放 starve
//   bit22    SD 初始化完成        bit14    源帧完成
//   bit13    曾超时中止           bit12    写FIFO丢词(粘滞)
//   bit11:10 加载序号             bit9:0   空闲/加载附加信息
// 末 10 位：
//   load_busy=1 -> {wr_ok, 写FIFO水位[8:0]}
//   空闲        -> {clear_done, clear_active, scan_kicked, bmp_ready,
//                   scan_done, auto_play_en, 有待处理换图请求,
//                   key_auto_seen, key_next_seen, 1'b0}
//   （v26 起把 auto_cnt[30] 换成按键粘滞标志：抓包就能判断按键有没有进 FPGA）
wire [9:0] dbg_a_tail = load_busy ? {wr_ok, wr_fifo_used[8:0]}
                                  : {clear_done, clear_active, scan_kicked,
                                     bmp_ready, scan_done, auto_play_en,
                                     next_req, key_auto_seen,
                                     key_next_seen, 1'b0};
// v22：调试总线打一拍。原来 wr_fifo_used / 状态量直接扇出到 uart_debug_tx 的
// 32 位移位器，会把"FIFO 水位 -> 串口移位器 -> ..." 串进同一条关键路径
// （时序报告里 shifter_b1[*] 出现在 jr.ce 的违例路径上）。调试量晚一拍无影响。
reg [31:0] dbg_a_r, dbg_b_r, dbg_c_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dbg_a_r <= 32'd0;
        dbg_b_r <= 32'd0;
        dbg_c_r <= 32'd0;
    end else begin
        dbg_a_r <= {load_busy, state_code_i, img_found_count, display_valid,
                    sd_init_done, bypass_active, scaler_state, scaler_busy,
                    scaler_starve, source_done_seen, ever_aborted, drop_any,
                    load_idx, dbg_a_tail};
        dbg_b_r <= {img_w, img_h};
        // v73：装载中照旧给缩放几何；空闲时给【S0 诊断字】，串口抓包即可定位
        //   一次按键卡在哪一步。
        //   {disp_idx, disp_buf_idx, next_disp, frame_ready_pending, bus_ok,
        //    sd_bus_idle, next_req, cnt_key[7:0], cnt_load[7:0], cnt_hand[5:0]}
        if (load_busy)
            dbg_c_r <= {scaler_dh[9:0], scaler_dy0[9:0], scaler_yd[8:0],
                        scaler_s_end_lat, scaler_starve, scaler_busy};
        else
            dbg_c_r <= {disp_idx, disp_buf_idx, next_disp,
                        frame_ready_pending, bus_ok, sd_bus_idle, next_req,
                        cnt_key, cnt_load, cnt_hand};
    end
end
assign dbg_a = dbg_a_r;
assign dbg_b = dbg_b_r;
assign dbg_c = dbg_c_r;
// C 字段布局（v22，见下方 dbg_c_r）：
//   {dh[9:0], dy0[9:0], yd[8:0], s_end锁存, starve, 缩放忙}
// 一次抓包就能判断"几何算对没有"——720p Contain 应为 dh=360、dy0=60。

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              first_image_committed;
// auto_play_en 已提升为输出端口（v36），此处不再重复声明
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 装载/换图指针（会超前于屏幕内容）
// v44：disp_idx = 屏幕上【真正显示着】的那张图。
//   img_idx 在"装载超时跳过"时会往前推，所以它不能代表屏幕内容。
//   交棒判据（是否到最后一张）必须用 disp_idx：
//     · 只在 transition 回 commit（确认新图已上屏）时才更新
//     · 装载失败/中止时绝不动它
//   否则第 4 张读失败时 img_idx 已经=3，按 S0 会被误判成"到最后一张"→直接进视频。
reg [1:0]        disp_idx;
// v79：原来的 blank_cnt / photo_blank（回照片压黑屏）已彻底删除。
//   黑屏等于"把 disp_en 关掉"，视频结束到第 1 张上屏之间的 0.4~2.8 秒
//   屏幕上什么都没有 —— 那正是用户报的"切回照片黑屏"。
//   现在改用"写另一块 buffer + 帧边界切换"，画面全程有内容。
reg [1:0]        load_retry;           // v44：同一张图装载失败的重试计数（0/1）
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg              frame_ready_pending; // 新图已写完，等待 video 侧确认切换
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
// v73：S0 请求改成【1 位待办标志】，语义 = "用户还要往前走一张"。
//   老实现是 3 位计数器 + inflight + 超时回收 三套状态互相拉扯，任何一条
//   兜底路径都可能让"按一下"变成 0 次或 2 次动作（S0 失灵 / 跳张）。
//   现在只有两件事：
//     · 按下 S0  -> next_req <= 1（不管此时是否在装载）
//     · 真正开始装载的那一刻 -> next_req <= 0（同拍又按了则保持 1）
//   一次按键最多驱动一次推进；按下时若正忙，就等这一张装完立刻兑现，绝不丢。
reg              next_req;
// v73：诊断计数器（串口抓包用，只增不减，一次抓包就能定位卡在哪一步）
reg  [7:0]       cnt_key;      // 消抖后的 S0 按下次数
reg  [7:0]       cnt_load;     // 真正发起的换图装载次数
reg  [5:0]       cnt_hand;     // 交棒视频次数
reg  [31:0]      load_wd_cnt;   // 装载硬看门狗（6s）
// v35：请求排队超时。某些异常（首图始终没提交 / 一直是 first_start）会让请求
//   永远轮不到消费，按键"石沉大海"。8s 内一次都没被消费就清空，避免假死。
// v44：原来 28 位放不下 8 秒（100MHz x 8s = 8e8 > 2^28），常数被截断成 2.63 秒。
//   18 秒停留期间装载大图要 3 秒以上，按键排队超过 2.63 秒就被清掉 = "S0 按了没反应"。
reg  [31:0]      req_wait_cnt;
// 手动请求已经启动过一次装载（用于"转场卡死/装载超时"后把请求还回去）
reg              manual_inflight;
// v41：从视频回到照片时的"重载第 1 张"请求。
//   back_first 只有一拍，而那一拍未必满足装载条件（例如 SD 控制器还在收尾
//   视频那一笔突发）。旧写法是"当拍不满足就永远丢掉"，屏幕会一直停在视频最后一帧。
//   现在改成挂起标志，等条件满足（或超时/确认没有照片）再执行。
//   计时复用 req_wait_cnt（同一时刻只有一条分支在跑，不必再开一个 28 位计数器）。
reg              reload_pending;
reg              load_busy;
reg [31:0]       load_timeout_cnt;
localparam integer LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * LOAD_TIMEOUT_SEC;

// v26：按键"见过"粘滞标志（只在复位时清）。
// 串口调试里能直接看出按键到底有没有进到 FPGA，省得再猜。
reg              key_next_seen;
reg              key_auto_seen;

// v26：等待 video 侧黑场确认的兜底计时（2s @100MHz）
reg [27:0]       pend_timeout_cnt;
wire             pend_timeout = (pend_timeout_cnt >= 32'd200_000_000);

reg              load_abort;
reg [1:0]        wb_idx_main;      // 主状态机选择的写 buffer（清屏时让位）

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;

// video_clk -> sd_card_clk 提交确认同步
reg [2:0]        commit_tgl_sync;
wire             commit_pulse;

wire auto_tick;
wire [1:0] next_from_current;

// 写进 SDRAM 的永远是缩放后的 640x480 像素流
// 写端口仲裁：清屏阶段由清屏状态机独占，否则走正常装载路径
// 写端口仲裁：清屏阶段由清屏状态机独占，否则走正常装载路径
// 反压不能在 mux 层拒收（单拍脉冲会丢像素），必须让源头自己暂停：
//   缩放引擎经 out_rdy 暂停发射；清屏状态机经 wr_ok 暂停计数
assign write_buf_idx = clear_active ? clear_buf : wb_idx_main;
assign write_req  = clear_req_r | br_write_req;
assign write_en   = clear_active ? (clear_st == C_FILL)
                                 : (bypass_active ? bmp_data_wr_en : scaler_d_valid);
assign write_data = clear_active ? 32'd0 : {wr_pix[23:16], wr_pix[15:8], wr_pix[7:0], 8'b0};
// v44：每张停留 AUTO_PHOTO_MS（18000ms）。100MHz 下 18000ms = 1_800_000_000 拍，
//   32 位以内 ✅。装载/转场期间计时暂停，所以每张从画面稳定起正好停 18 秒。
//   仍在 32 位范围内。4 张 = 18s 一个轮播周期。
localparam [31:0] AUTO_TICK_CYC = (CLK_FREQ_HZ / 1000) * AUTO_PHOTO_MS - 1;
assign auto_tick  = (auto_cnt >= AUTO_TICK_CYC);
assign next_from_current = next_index_limited(img_idx, img_found_count);
// v44：基于"屏幕上真正显示的那张"算下一张 —— 交棒判据只用这个
wire [1:0] next_disp = next_index_limited(disp_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
// v21：进水门限从 384 降到 128。
// 384 太大：写 FIFO 只有 512 深，允许进水到 384 后，还有 1~2 个扇区(170~342 像素)
// 在途，384+342=726 > 512 → 必然溢出丢词（v18/v19 纵向虚线列的真正来源）。
// 128 与排水门限(rdusedw>=BURST_SIZE=128)错开为"进水 <128 / 排水 >=128"，
// 边界上一定有一侧能动作，不存在 [128,128] 死区。
// v22：wr_ok 打一拍再往下游送。
// 7000+ 端的时序报告显示 worst path 是：
//   write_buf/wr_addr 减法器(FIFO IP 内部) -> wr_fifo_used[8] -> 比较/选择 -> jr_reg[*].ce
// 10.9ns/10ns 违例。水位门限 128/512 余量极大，晚一拍完全无害。
reg wr_ok_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_ok_r <= 1'b0;
    else
        wr_ok_r <= (wr_fifo_used < 9'd128);
end
assign wr_ok              = wr_ok_r;


assign scan_ok            = scan_done || (img_found_count == 3'd4);

// 换图启动条件（与下方 if 链一一对应，抽成 wire 便于按键登记判断"本拍是否要消费"）
// v41：加了 sd_bus_idle —— 只有 SD 控制器真的停下来（不在收尾别人的 CMD18 突发）
//   才允许发起下一次装载，否则第一张图会读到错位的数据。
// v44：sd_bus_idle 兜底。
//   v41 为了让"视频被打断后立刻换图"不读到视频残留字节，把 sd_bus_idle 加进了
//   换图条件。但它一旦因为 SD 控制器状态机没回到空闲态而长期为 0，
//   所有换图（S0/S1/轮播）都会被永久阻塞 —— 现场表现就是"S0 偶尔彻底失效"。
//   兜底：有按键在等且 idle 持续 84ms（足够收完一笔 30 扇区突发 ≈7.7ms）没有回来，
//   就不再等它，直接走后续流程。
reg        sd_bus_idle_r;      // v79：sd_bus_idle 打一拍（见下方说明）
reg [22:0] bus_idle_wait;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bus_idle_wait <= 23'd0;
    end else if (sd_bus_idle_r || (!next_req && !reload_pending)) begin
        bus_idle_wait <= 23'd0;
    end else if (bus_idle_wait != 23'd8_400_000) begin
        bus_idle_wait <= bus_idle_wait + 23'd1;
    end
end

// v79【时序】sd_bus_idle 打一拍再用。
//   布线报告里 sd 域最差路径是：
//     sd_card_top/sd_card_sec_read_write/state_reg
//       -> sd_bus_idle -> bus_ok -> bmp_base_ready -> manual_start -> load_idx_reg.d
//   8 级逻辑，place 后走线占 68%（14.2ns / 10ns 周期）。
//   sd_bus_idle 是控制器的"空闲"标志（准静态，变化间隔以微秒计），
//   晚一拍完全不影响功能，但能把这条长链从中间切断。
always @(posedge clk or posedge rst) begin
    if (rst) sd_bus_idle_r <= 1'b1;      // 复位时按"空闲"处理，与原来等价
    else     sd_bus_idle_r <= sd_bus_idle;
end

wire bus_ok = sd_bus_idle_r || (bus_idle_wait >= 23'd8_400_000);

wire bmp_base_ready = scan_ok && bmp_ready && display_valid &&
                      !load_busy && !frame_ready_pending && bus_ok && !sd_locked;

// v79：回照片重载前的"跨域稳定等待"。512 拍 @100MHz ≈ 5µs。
//   reload_pending 落下时清零，到 512 拍后 settle_ok 才为 1。
//   用 10 位计数器（而不是复用 32 位的 req_wait_cnt），省 30 多个 mslice。
reg [9:0] settle_cnt;
wire      settle_ok = settle_cnt[9];
always @(posedge clk or posedge rst) begin
    if (rst)
        settle_cnt <= 10'd0;
    else if (!reload_pending)
        settle_cnt <= 10'd0;
    else if (!settle_ok)
        settle_cnt <= settle_cnt + 10'd1;
end
wire first_start    = scan_ok && !first_image_committed && bmp_ready &&
                      !load_busy && !frame_ready_pending && bus_ok && !sd_locked &&
                      (img_found_count != 3'd0);
wire manual_start   = bmp_base_ready && next_req &&
                      (img_found_count != 3'd0) && !first_start;
assign commit_pulse       = commit_tgl_sync[2] ^ commit_tgl_sync[1];

// ---------------- v40：照片组 -> 视频组 交棒 ----------------
//   at_last_photo：当前显示的就是最后一张（next 会绕回 0）
//   手动：S0 在最后一张按下；轮播：最后一张的停留时间走完
//   两者都要求链路空闲（没有正在装载/正在等转场），保证切换时 SDRAM 状态干净。
wire at_last_photo  = (next_disp == 2'd0) || (img_found_count == 3'd1);
// 手动交棒判据放在【真正要推进的那一刻】判断，而不是按键那一刻：
//   S0 可能是在第 4 张还在装载时按下的（进了 pending_cnt 队列），
//   等队列被消费时 img_idx 已经是 3，此时"下一步会绕回 0"才是准确信息。
//   这样"第 4 张按 S0"无论按得多早/多晚，都一定进视频，不会跳回第 1 张。
// v71【修复·跳视频】判据里的 key_next_press 去掉了。
//   原来 (key_next_press || pending_cnt!=0) 会在"按键那一拍"就直接触发交棒，
//   而同一个按键在同一拍也会被登记成 pending —— 两条路径叠加，现场就是
//   "按一下，画面直接跳进视频"。现在只认 pending_cnt，走完整的
//   登记 -> 消费 流程，一次按键只会产生一次动作。
wire handoff_manual = has_video && at_last_photo && bmp_base_ready && next_req;
wire handoff_auto   = has_video && at_last_photo && auto_play_en && auto_tick &&
                      scan_ok && bmp_ready && display_valid &&
                      !load_busy && !frame_ready_pending && first_image_committed;
// 卡上一张 BMP 都没有、但有 RAW 视频：直接交棒，别让屏幕一直黑着
//   （纯视频卡也能播，兼容旧用法）
wire no_photo_handoff = has_video && scan_ok && (img_found_count == 3'd0) &&
                        !load_busy && !frame_ready_pending;
assign state_code         = state_code_i;
// v47：照片链路空闲窗口（音频加载器用它决定何时借总线/写 SDRAM）
assign photo_idle         = scan_ok && display_valid && !load_busy &&
                            !frame_ready_pending && !clear_active;

// v35：按键消抖统一挪到顶层（同一个 sd_card_clk 域，一份逻辑喂两个播放器）。
//   原来照片链路和 RAW 链路各自例化 2 个消抖器 = 4 份 32 位计数器 + 比较器，
//   LUT 到 75.86% 后这些逻辑挤占了 audio_viz 的 LUT-RAM 所需布线资源，
//   布线报 PHY-8023（audio_viz/ramread0 vs ramread1 抢同一个 local 资源）。
//   现在这里只接收"已消抖的按下脉冲"，判断逻辑保持不变。
wire key_next_press = key_next;
wire key_auto_press = key_auto;

// 按键粘滞标志：按下过一次就置 1，便于串口抓包判断"按键有没有进 FPGA"
always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_next_seen <= 1'b0;
        key_auto_seen <= 1'b0;
    end else begin
        if (key_next_press) key_next_seen <= 1'b1;
        if (key_auto_press) key_auto_seen <= 1'b1;
    end
end

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        disp_idx              <= 2'd0;
        load_retry            <= 2'd0;
        load_idx              <= 2'd0;
        video_req             <= 1'b0;
        pending_buf_idx       <= 2'd0;
        frame_ready_pending   <= 1'b0;
        ready_img_idx         <= 2'd0;
        frame_ready_toggle    <= 1'b0;
        ready_buf_idx         <= 2'd0;
        commit_tgl_sync       <= 3'b000;
        wb_idx_main           <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req              <= 1'b0;
        req_wait_cnt          <= 32'd0;
        manual_inflight       <= 1'b0;
        reload_pending        <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        commit_tgl_sync  <= {commit_tgl_sync[1:0], commit_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            disp_idx              <= 2'd0;
            load_retry            <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            frame_ready_pending   <= 1'b0;
            ready_img_idx         <= 2'd0;
            frame_ready_toggle    <= 1'b0;
            ready_buf_idx         <= 2'd0;
            commit_tgl_sync       <= 3'b000;
            wb_idx_main           <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req              <= 1'b0;
            req_wait_cnt          <= 32'd0;
            manual_inflight       <= 1'b0;
            reload_pending        <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            video_req <= 1'b0;          // v40：单拍脉冲，默认清零

            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住缩放引擎已经把整帧 640x480 送完，但还不能切显示，得等整帧写完
            // v16：源流结束信号按图源选择——640x480 直通用 frame_end，
            // 其他分辨率用缩放引擎 frame_done。两者都要求源真正读完。
            if (load_busy && (bypass_active ? frame_end : scaler_frame_done))
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // video 侧已经在黑场期间切换到新 buffer，收到 commit 后 SD 侧才正式
            // 把该 buffer 认定为当前显示 buffer。这样下一张图永远不会覆盖
            // video 仍可能正在读取的旧 buffer。
            if (frame_ready_pending && commit_pulse) begin
                frame_ready_pending   <= 1'b0;
                disp_buf_idx          <= ready_buf_idx;
                img_idx               <= ready_img_idx;
                disp_idx              <= ready_img_idx;   // v44：屏幕内容才算数
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                auto_cnt              <= 32'd0;
                manual_inflight       <= 1'b0;
            end

            // v26：黑场切换握手的兜底。
            // 正常路径 170ms 内一定收到 commit；如果 2s 还没回来，说明 video 侧
            // 的淡入淡出 / read_finish 握手卡住了。此时 frame_ready_pending 会
            // 永久为 1，而 key1/key2/轮播三个分支都要求它为 0 ——
            // 表现就是"图还在，但换图彻底没反应"。这里本地强行收尾让它自愈。
            if (frame_ready_pending) begin
                if (pend_timeout) begin
                    frame_ready_pending   <= 1'b0;
                    // v79：这里**不能**照抄 ready_buf_idx。
                    //   能走到这条兜底路径，说明 video 侧根本没切过 buffer ——
                    //   屏幕读的还是 disp_buf_live（旧那块）。如果本地把
                    //   disp_buf_idx 记成"新那块"，下一次装载就会写进屏幕
                    //   正在读的 buffer，现场是撕成两半的图。
                    //   现在如实记录"屏幕真正在读的那块"，下一张写另一块，
                    //   状态与画面永远一致。
                    disp_buf_idx          <= disp_buf_live;
                    img_idx               <= ready_img_idx;
                    disp_idx              <= ready_img_idx;   // v44
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    pend_timeout_cnt      <= 28'd0;
                    // v71【修复·跳张】这里原来是"把请求还回去重试"
                    //   （manual_inflight && pending_cnt!=7 -> pending_cnt+1）。
                    //   但这条路径是【兜底】才能到：图其实已经装好，只是 commit 没回来。
                    //   一还回去，用户那一下按键就变成了两次换图 ——
                    //   现场表现正是"第二张切第三张，一下跳到第四张"。
                    //   现在不再补队列：超时只做本地收尾，绝不多走一张。
                    manual_inflight <= 1'b0;
                end else begin
                    pend_timeout_cnt      <= pend_timeout_cnt + 28'd1;
                end
            end else begin
                pend_timeout_cnt <= 28'd0;
            end

            // 只有“源图送完 + 整帧写完”都满足，才认为新图已经准备好。
            // 首图直接提交；后续图片先进入 pending，等待 video 侧完成黑场切换。
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;

                if (!first_image_committed) begin
                    // 首图不做转场，直接显示 buffer0。
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    disp_idx              <= load_idx;   // v44：首图直接上屏
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    frame_ready_pending   <= 1'b0;
                end else begin
                    // 后续图片：保持 disp_buf_idx 不变，等待 video 侧黑场切换。
                    frame_ready_pending <= 1'b1;
                    ready_buf_idx       <= pending_buf_idx;
                    ready_img_idx       <= load_idx;
                    frame_ready_toggle  <= ~frame_ready_toggle;
                end
            end else if (load_busy) begin
                // 进度看门狗：源像素流只要还在推进就喂狗。
                // 旧实现是"总时长"预算，大图（如 1280x720，约 2.76MB）SPI
                // 读盘本身就会超过预算而被误中止，表现为大图永远播不出来。
                if (bmp_data_wr_en) begin
                    load_timeout_cnt <= 32'd0;
                    load_retry       <= 2'd0;      // v44：源流在推，重试计数归零
                end else if (load_timeout_cnt > LOAD_TIMEOUT_CYCLES) begin
                    // 源流停滞超时（坏图/截断/读卡偶发失败）
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                    manual_inflight       <= 1'b0;

                    // v44：原来直接把 img_idx 推到目标图 —— 那等于"没显示出来也算已显示"。
                    //   第 4 张（1920x1080，12151 扇区）偶发读失败时 img_idx 会悄悄变成 3
                    //   并且再也回不去，于是：
                    //     · 屏幕还停在第 2/3 张，按 S0 却被判成"到最后一张"→直接进视频
                    //     · 或者每按一次都去装那张读不出来的图 → 表现为 S0 失效
                    //   现在：重试 3 次（把请求还回队列），每次 2 秒看门狗；
                    //   第 4 次仍失败才放弃，并且此时 img_idx / disp_idx 一起推进
                    //   （承认这张读不出来，避免永远卡在同一张）。
                    if (load_retry != 2'd3) begin
                        load_retry <= load_retry + 2'd1;
                        // v78【修复·S0 需要按两次】这里是"一次按键失效"的真正根因：
                        //   本次装载开始时就把 next_req 消费掉了（清 0），而这里
                        //   原来只加了重试计数、**没有真正重新发起装载** ——
                        //   于是任何一次读卡抖动（第 4 张 1920x1080 有 12151 扇区，
                        //   最容易触发）就等于"用户那一下白按了"，必须再按一次。
                        //   现在把请求放回去重试。因为 disp_idx 没动，重试一定还是
                        //   同一张图，不会跳张；next_req 是 1 位标志，按多次也只算一次。
                        if (manual_inflight)
                            next_req <= 1'b1;
                    end else begin
                        load_retry <= 2'd0;
                        img_idx    <= load_idx;
                        disp_idx   <= load_idx;   // 确认放弃这张，屏幕内容按新的算
                        // v79【修复·首图死锁】如果失败的是【首图】，原来只推进
                        //   img_idx，display_valid / first_image_committed 仍是 0：
                        //     · 屏幕上一直没有画面（disp_en 恒 0 = 全黑）
                        //     · bmp_base_ready 恒为 0 -> S0/S1/轮播全部失效
                        //   现场就是"开机黑屏，按什么都没反应，只能重新上电"。
                        //   现在承认"这张读不出来"，把首图状态置成已完成：
                        //   屏幕还是黑的（buffer 里没内容），但按键链路立刻恢复，
                        //   下一张装成功就正常显示了。
                        if (!first_image_committed) begin
                            display_valid         <= 1'b1;
                            first_image_committed <= 1'b1;
                            disp_buf_idx          <= pending_buf_idx;
                        end
                    end
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // ---------------- v73：装载硬看门狗 ----------------
            //   load_timeout 只盯"源流不推进"。如果数据一直在流、但整帧写完成
            //   脉冲因为写通路异常始终不来，load_busy 会永久为 1：
            //   bmp_base_ready 永远为 0 -> S0/S1/轮播 全部失效（只能断电救）。
            //   这里直接盯"忙了多久"：超过 12 秒（1080p 最大图约 3s，留 4 倍余量）
            //   无条件脱身。disp_idx 不动，所以脱身后重试的还是同一张。
            if (load_busy) begin
                if (load_wd_cnt != 32'd1_200_000_000)
                    load_wd_cnt <= load_wd_cnt + 32'd1;
                else begin
                    load_wd_cnt         <= 32'd0;
                    load_busy           <= 1'b0;
                    frame_ready_pending <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                    load_timeout_cnt    <= 32'd0;
                    load_abort          <= 1'b1;
                    // v78：脱身后同样把请求放回去（否则又是一次"白按"）
                    if (manual_inflight)
                        next_req <= 1'b1;
                    manual_inflight     <= 1'b0;
                    // v79：首图被 12s 看门狗脱身时同样要解锁，
                    //   否则 display_valid 永远 0 -> S0/S1/轮播全部失效。
                    if (!first_image_committed) begin
                        display_valid         <= 1'b1;
                        first_image_committed <= 1'b1;
                        disp_buf_idx          <= pending_buf_idx;
                        img_idx               <= load_idx;
                        disp_idx              <= load_idx;
                    end
                end
            end else begin
                load_wd_cnt <= 32'd0;
            end

            // 上电后先等清屏完成，再自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && clear_done && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                disp_idx              <= 2'd0;
                load_retry            <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                frame_ready_pending   <= 1'b0;
                ready_img_idx         <= 2'd0;
                frame_ready_toggle    <= 1'b0;
                ready_buf_idx         <= 2'd0;
                wb_idx_main           <= 2'd0;
                disp_buf_idx          <= 2'd0;
                // 不清除 pending_cnt：扫描启动期间按下 key1 的请求保留。
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
            end else if (video_mode_hold) begin
                // ---------------- v40：视频播放期间彻底静默 ----------------
                //   不清屏、不扫描、不登记按键、不发 load_start。
                //   一条 in-flight 的装载也要在这里掐掉，否则它会继续往 SDRAM 写，
                //   把视频帧覆盖掉。
                video_req           <= 1'b0;
                next_req            <= 1'b0;
                load_busy           <= 1'b0;
                frame_ready_pending <= 1'b0;
                auto_cnt            <= 32'd0;
                req_wait_cnt        <= 32'd0;
            end else if (back_first) begin
                // ---------------- v40：从视频回到照片 ----------------
                //   视频已经占用了两块 SDRAM buffer，必须重载第 1 张。
                // v41：这里只【登记】请求，真正装载放到下面 reload_pending 分支，
                //   等 SD 控制器收尾完视频那一笔突发（sd_bus_idle）再动手。
                video_req    <= 1'b0;
                next_req     <= 1'b0;
                auto_cnt     <= 32'd0;
                // 回到照片后：手动退出就停住，等用户再按 S1 才恢复轮播；
                // v46：如果是轮播模式下视频播完自动回来的，保持轮播继续跑
                //   （不清零，auto_cnt 从 0 重新计 18 秒）。
                if (video_key_exit)
                    auto_play_en <= 1'b0;
                reload_pending <= 1'b1;
                req_wait_cnt   <= 32'd0;

                // ---- v45：把视频段残留的握手状态清干净 ----
                //   frame_ready_pending 在视频段可能就是 1（视频前最后一张照片的
                //   "等转场确认"没走完）。不清掉的话 reload 分支要求它为 0，
                //   只能等 pend_timeout（2 秒）兜底。
                frame_ready_pending <= 1'b0;
                load_busy           <= 1'b0;
                manual_inflight     <= 1'b0;
                source_done_seen    <= 1'b0;
                write_done_seen     <= 1'b0;

                // ---- v45：屏幕内容直接认定成第 1 张 ----
                //   disp_idx 原来是"视频开始前那张"（通常第 4 张 = 最后一张），
                //   回照片后 at_last_photo 依然为真 —— 再按 S0 立刻又交棒，
                //   现场表现就是"视频重播"或"按 S0 又跳回视频"。
                disp_idx <= 2'd0;

                // ---- v79：disp_buf_idx 不再在这里钉死 ----
                //   v59 把它和 transition 的 read_buf_idx 都清 0，靠"写显示中的
                //   buffer + photo_blank 遮黑"来掩盖撕裂。v79 改成：
                //     · transition 保持 read_buf_idx = 视频最后一块 buffer（显示定格）
                //     · 本模块在真正发起重载那一刻（reload 分支）采 disp_buf_live，
                //       把第 1 张写进**另一块**
                //   读写不同块，装载全程不撕裂，也就不需要黑屏。
            end else if (reload_pending) begin
                // ---------------- v41：挂起的"重载第 1 张" ----------------
                // v79：不再每拍清 next_req。原来这里 `next_req <= 0` 有个副作用：
                //   重载窗口（第 1 张 640x480 约 0.4s；1080p 约 2.8s）里按 S0
                //   完全没反应。现在允许排队 —— 重载完成后立刻消费一次，
                //   next_req 是 1 位饱和，所以最多推进一张，不会连跳。
                auto_cnt    <= 32'd0;
                // v79：S1 条件从"至少 2 张图"放宽到"至少 1 张"。
                //   旧条件在单图卡上会让 auto_play_en 根本不翻转，而顶层的
                //   提示字只看 mode_video —— 于是按下 S1 弹出"开始轮播"，
                //   状态却没变，是自相矛盾的提示。现在状态一定会真的翻转。
                if (key_auto_press && scan_ok && (img_found_count != 3'd0)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end
                // v79：S0 在这个窗口里也排队（见上面的说明）。
                //   窗口最长 2.8s（第 1 张是 1920x1080 时），"按了完全没反应"
                //   比"等这张上屏后立刻切下一张"要难受得多。
                if (key_next_press && first_image_committed) begin
                    next_req <= 1'b1;
                    cnt_key  <= cnt_key + 8'd1;
                end
                // v79：除了空闲条件，还必须等一小段再发起：
                //   disp_buf_live 是 video 域 read_buf_idx 的两级同步值，
                //   而 read_buf_idx 真正冻结还要等 mode_video_v 落下（video 域
                //   比这边晚 2 拍）。这里多等 512 拍（≈5µs），确保采到的是稳定值 ——
                //   否则可能把第 1 张写进屏幕正在读的那块，画面撕裂。
                //   5µs 对 0.4s 的装载时间完全无感。
                //   （用独立的 10 位计数器而不是复用 32 位的 req_wait_cnt：
                //     32 位比较器要吃掉 30 多个 mslice，而 mslice 只剩不到 50 个了。）
                if (bmp_base_ready && (img_found_count != 3'd0) && settle_ok) begin
                    reload_pending   <= 1'b0;
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    // ---- v79【关键】：写进"屏幕当前没读的那一块" ----
                    //   disp_buf_live 是 transition 侧 read_buf_idx 的同步值，
                    //   回照片后它静止在视频最后一块 buffer 上（画面定格中）。
                    //   往另一块写，屏幕就不会看到半张图/撕裂。
                    //   装载完成后由 transition 在帧边界切过去并揭幕。
                    disp_buf_idx     <= disp_buf_live;
                    pending_buf_idx  <= {1'b0, ~disp_buf_live[0]};
                    wb_idx_main      <= {1'b0, ~disp_buf_live[0]};
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    req_wait_cnt     <= 32'd0;
                end else if (!scan_ok || (img_found_count == 3'd0) ||
                             (req_wait_cnt >= 32'd200_000_000)) begin
                    // 卡上根本没有可显示的照片 / 等了 2 秒还没等到总线空闲：
                    // 放弃重载，交回主流程（否则状态机会永远卡在这里）。
                    // v79：不再需要"别留黑屏"的善后 —— 屏幕本来一直在显示
                    //   视频最后一帧（定格），交给 transition 继续定格即可。
                    reload_pending <= 1'b0;
                end else begin
                    req_wait_cnt <= req_wait_cnt + 32'd1;
                end
            end else begin
                // key1：登记手动换图请求（v35：3 位队列，饱和 7 次）。
                //   本拍如果正好要消费一次（manual_start=1），就交给下面的消费分支
                //   统一算净增量 —— 否则同一个 reg 在同拍两次非阻塞赋值，
                //   按键会被后一次覆盖掉（这是"偶尔按了没反应"的来源之一）。
                //
                // v59【修复·延时】不要再"装载中按 S0 就中止"。
                //   这条 v46 加的逻辑其实让手感更慢，算一下就清楚：
                //     · 装载第 3 张要 1.7s、第 4 张要 2.8s
                //     · 在第 3 张装了 1.0s 时按 S0：
                //         中止 -> 队列 +1 -> 下一拍 manual_start 又重新装载【同一张】
                //         （disp_idx 还没变，load_idx 还是它）-> 有效耗时 1.0+1.7=2.7s
                //       而如果只排队，等 0.7s 这张就上屏了，再按一次才是下一张。
                //   也就是每按一次就白扔一整张图的装载时间 —— 现场感受就是
                //   "按了要等好几秒才动"。现在改回纯排队：按键进队列，
                //   当前这张一装完立刻消费，绝不重复装载同一张。
                // v59【修复·开机 S0】两个限制，专治"刚上电时按 S0 乱来"：
                //   ① 首图还没上屏之前【不登记】。开机前 3~5 秒要清屏 + 扫描
                //      （从 LBA 0 扫到第 4 张的 21068，SPI 只有 2.2MB/s），
                //      这段时间 display_valid=0，任何请求都消费不了；登记进去只会
                //      攒着，等首图上屏后一次性全部兑现 —— 用户看到的就是
                //      "刚上电按了几下没反应，过一会儿自己连跳好几张"。
                //   ② 队列饱和到 1。装载中（最长 2.8s）连按是多按几下想让它快点，
                //      不是想跳 7 张。饱和到 1 就永远不会出现"没按却自己切"。
                //      空闲时每次按都会被当拍消费（manual_start=1），不受影响。
                // v73：按下就置位。不再要求 pending==0 / !manual_start：
                //   那些条件正是"S0 按了没反应"的来源（装载中按的一下被丢掉）。
                // v78 曾加过"装载期间不排队"，本意是防"按两次直接跳视频"，
                //   但那属于过度修复：
                //     · 一次按键只会置 1 位 next_req，最多推进一张，本来就不可能
                //       "按一下走两张"（v71 的计数双触发已经修掉了）；
                //     · 反过来，"装载期间按的一下被丢掉"才是用户最直接的
                //       "按了没反应、要按两次"体验 —— 第 4 张要装 2.8 秒，
                //       这段时间里再按一下是极其自然的动作。
                // v79：恢复"按下就排队"，一次按键 = 一次推进，永不丢弃。
                // v79【补·开机边界】但首图还没上屏之前不登记：
                //   开机前 3~5 秒是清屏 + 扫描（SPI 只有 2.2MB/s），这段时间
                //   display_valid=0，任何请求都消费不了；登记进去只会在首图上屏
                //   的下一拍一次性兑现 —— 现场就是"开机时按了一下，画面刚出来
                //   就自己跳到了第 2 张"。
                if (key_next_press && first_image_committed)
                    next_req <= 1'b1;
                if (key_next_press && first_image_committed)
                    cnt_key <= cnt_key + 8'd1;

                // 自动播放开/关
                // v79：条件放宽到"至少 1 张图"。旧条件 >1 时，单图卡上
                //   auto_play_en 根本不翻转，但顶层提示字只看 mode_video，
                //   按 S1 会弹"开始轮播"却没有状态变化 —— 自相矛盾的提示。
                if (key_auto_press && scan_ok && (img_found_count != 3'd0)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // v35：请求排队超时兜底。
                //   v59：8 秒 -> 2 秒。一张图最长装载 2.8s，2 秒还没轮到说明
                //   消费条件根本不成立（卡读不出来），再等下去只会让按键"迟到"。
                if (manual_start || !next_req)
                    req_wait_cnt <= 32'd0;
                else if (req_wait_cnt != 32'd200_000_000)
                    req_wait_cnt <= req_wait_cnt + 32'd1;
                // v71【修复·S0 失灵】这里原来是"2 秒还没轮到就清空请求"。
                //   但消费条件（sd_bus_idle / 转场握手）本来就可能卡到 2 秒以上，
                //   一清就等于用户按的那下凭空消失。
                //   现在不丢请求：只计数（串口可看 req_wait 时长），请求一直有效，
                //   真正消费掉才清；装载失败由 load_retry 那条路径推进 disp_idx，
                //   不会死锁。

                // 自动播放停留计时：装载中 / 等转场时【暂停】而不是清零。
                //   v44：原来 else 分支无条件清零，切图后要重新数满 3s，而且只要
                //   display_valid 有一拍抖动就归零 —— 一圈下来时长飘忽（实测到过 5s
                //   一圈）。现在只有"装载/转场"期间暂停，停留时间稳定按
                //   AUTO_PHOTO_MS 走，加上读盘时间一圈约 18s。
                if (scan_ok && auto_play_en && first_image_committed &&
                    (img_found_count > 3'd1)) begin
                    if (!load_busy && !frame_ready_pending && display_valid) begin
                        if (auto_tick)
                            auto_cnt <= 32'd0;
                        else
                            auto_cnt <= auto_cnt + 32'd1;
                    end
                    // else：保持 auto_cnt 不变（暂停计时）
                end else begin
                    auto_cnt <= 32'd0;
                end

                if (handoff_manual || handoff_auto || no_photo_handoff) begin
                    // ---------------- v40：交棒给视频 ----------------
                    //   不装载新图，只发一拍请求；顶层收到后把 SD 总线/写通路
                    //   整体切给 raw_player。
                    video_req   <= 1'b1;
                    next_req    <= 1'b0;
                    auto_cnt    <= 32'd0;
                    cnt_hand    <= cnt_hand + 5'd1;    // v73 诊断
                end
                // 首图自动加载到 buffer0
                else if (scan_ok && !first_image_committed && bmp_ready && !load_busy && !frame_ready_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    wb_idx_main      <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    // 不清除 pending_cnt：首图加载期间按下 key1 的请求保留。
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (manual_start) begin
                    // v44：装载目标改用 disp_idx（屏幕内容）推算，不再用 img_idx。
                    //   img_idx 在装载失败时会前进且回不去，一旦卡在最后一张，
                    //   后续每按 S0 都会一直去装那张读不出来的图（表现为 S0 失效），
                    //   或者被误判成"已到最后一张"而直接进视频。
                    load_idx         <= next_disp;
                    load_sector      <= sector_lut(next_disp);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    wb_idx_main      <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    // v35：消费一次必须 -1。同拍又来了新按键则净增量 0（保留原值）。
                    //   旧写法 "==2 ? 2 : ..." 在排满时永不递减，是"连按两下后画面
                    //   自己一直跳/或按了没反应"的直接原因。
                    next_req        <= key_next_press;   // 消费掉；同拍再按则保留
                    manual_inflight <= 1'b1;
                    req_wait_cnt    <= 32'd0;
                    auto_cnt        <= 32'd0;
                    cnt_load        <= cnt_load + 8'd1;   // v73 诊断
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_ok && bmp_ready && display_valid && !load_busy && !frame_ready_pending && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    // v44：装载目标改用 disp_idx（屏幕内容）推算，不再用 img_idx。
                    //   img_idx 在装载失败时会前进且回不去，一旦卡在最后一张，
                    //   后续每按 S0 都会一直去装那张读不出来的图（表现为 S0 失效），
                    //   或者被误判成"已到最后一张"而直接进视频。
                    load_idx         <= next_disp;
                    load_sector      <= sector_lut(next_disp);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    wb_idx_main      <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .img_w                  (img_w),
    .img_h                  (img_h),
    .frame_start            (frame_start),
    .frame_end              (frame_end),
    .write_req              (br_write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_cnt        (sd_sec_read_cnt),
    .burst_ok               (burst_ok),
    .burst_cnt              (burst_cnt),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

// ===================== 扩展3：任意分辨率 BMP -> 640x480 缩放适配 =====================
// v21：640x480 走直通时不希望缩放引擎空转（它会拿不到源数据、走 starve 路径空发
// 307200 个黑像素），直接把它的复位挂上 bypass_active。
assign scaler_rst = rst | load_abort | bypass_active;

bmp_scaler #(
    .DST_W   (640),
    .DST_H   (480),
    // v26：2048 -> 4096，覆盖 1920x1080 / 2560x1440 / 3840x2160
    .MAX_W   (4096),
    .MAX_H   (4096),
    .FIFO_AW (9)        // 512 深：能吞下 2 扇区突发（341 像素）+ 门限余量
) u_bmp_scaler (
    .clk           (clk),
    .rst           (scaler_rst),
    .src_w         (img_w),
    .src_h         (img_h),
    .mode          (SCALE_MODE[1:0]),
    .start         (frame_start),
    .s_end         (frame_end),
    .s_valid       (bmp_data_wr_en && !bypass_active),
    .s_data        (bmp_data),
    .out_rdy       (wr_ok),
    .d_valid       (scaler_d_valid),
    .d_data        (scaler_d_data),
    .busy          (scaler_busy),
    .frame_done    (scaler_frame_done),
    .dbg_state     (scaler_state),
    .dbg_fcnt      (scaler_fcnt),
    .dbg_next_fr   (scaler_next_fr),
    .dbg_rs        (scaler_rs),
    .dbg_yd        (scaler_yd),
    .dbg_starve    (scaler_starve),
    .dbg_s_end_lat (scaler_s_end_lat),
    .dbg_dh        (scaler_dh),
    .dbg_dy0       (scaler_dy0)
);

endmodule

// ============================================================
// v35 按键采集：边沿即触发 + 锁定窗
//
// 旧实现（v34 及以前）是"电平必须稳定 15ms 才认一次按下"：
//   - 轻点（触点闭合 <15ms）整段被吞掉 —— 这是"按了没反应，用点力就有了"的主因；
//   - 抖动跨过 15ms 窗口时，cnt 反复清零，按下时间被无限拉长直到松手才判定，
//     期间若又按一次，两次会合成一次。
// 现在改成：两级同步后【只要检测到下降沿就立刻出脉冲】，随后用 50ms 锁定窗
// 吸收机械抖动与回弹。任何按压时长（哪怕 1ms）都必然产生且只产生 1 个脉冲。
// 40~50ms 的锁定窗同时支持每秒 20 次以上的连按，不会把第二下吃掉。
// ============================================================
module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,     // 电平必须稳定这么久才算数
    parameter integer LOCKOUT_MS  = 50      // 兼容旧实例参数（本实现不再用时间锁）
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg        s0, s1;          // 两级同步
reg        stable;          // 去抖后的电平（1=松开, 0=按下）
reg        armed;           // 只有"稳定松开"过才允许下一次触发
reg [31:0] cnt;

// ------------------------------------------------------------
// v39：按键改成"积分式去抖 + 松开才重新武装"
//
// 旧实现是"纯边沿检测 + 50ms 时间锁"，两个致命问题：
//   1) 机械抖动本身就是连续下降沿，时间锁一过，第二个抖动脉冲就会再触发一次
//      —— 现场表现就是"按一下 S1，先显示开始轮播、紧跟着又跳解除轮播"；
//   2) 时间锁只挡 50ms，慢慢按 / 触点脏的时候照样漏。
// 现在：
//   · 电平必须连续稳定 20ms 才被承认（抖动被完全吸收）；
//   · 承认"按下"后置 armed=0，只有再稳定"松开"20ms 才重新武装
//     —— 一次物理按压在数学上只能产生 1 个脉冲，与抖动长短无关。
// ------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        s0          <= 1'b1;
        s1          <= 1'b1;
        stable      <= 1'b1;
        armed       <= 1'b1;
        cnt         <= 32'd0;
        press_pulse <= 1'b0;
    end else begin
        s0          <= button_in;
        s1          <= s0;
        press_pulse <= 1'b0;

        if (s1 == stable) begin
            cnt <= 32'd0;
        end else if (cnt >= DEBOUNCE_CYCLES - 1) begin
            cnt    <= 32'd0;
            stable <= s1;
            if (!s1) begin
                // 稳定按下：只有重新武装过才发一次脉冲
                if (armed) begin
                    press_pulse <= 1'b1;
                    armed       <= 1'b0;
                end
            end else begin
                // 稳定松开：重新武装
                armed <= 1'b1;
            end
        end else begin
            cnt <= cnt + 32'd1;
        end
    end
end

endmodule
