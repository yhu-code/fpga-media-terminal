`timescale 1ns/1ps

// ============================================================
// image_transition_ctrl  —— v79（统一显示仲裁 + 自上而下揭幕）
//
// 【v78 的遗留问题】
//   视频结束回照片时，sd_card_bmp 用 photo_blank 把整屏压黑，等第 1 张重载
//   完成（640x480 约 0.4s，1920x1080 约 2.8s）再放行 —— 现场就是"黑一下"。
//   黑屏时长等于一张图的装载时间，第 1 张是大图时尤其明显。
//
// 【v79 的做法】
//   本模块把"视频段的读 buffer 选择"也接管过来，视频结束后 read_buf_idx
//   **保持**视频最后一块 buffer，于是屏幕继续显示视频最后一帧（定格），
//   照片在后台写进**另一块** buffer；写完才在帧边界切过去，并自上而下揭幕。
//   输出通路从头到尾没有被关闭过，所以不存在黑屏。
//
// 【为什么画面不会颠倒】
//   数据源始终只有一路：SDRAM 读出的 rgb_in。
//     · 照片写：wr_vflip=1，把 BMP 的 bottom-up 行序翻转成"行 0 = 图像顶部"
//     · 视频写：wr_vflip=0，RAW 本身就是"行 0 = 图像顶部"
//   两者在 SDRAM 里行序一致，读出来直接送显示器都正立。
//   （v45/v58 注释里"RAW 被照片通路解释就颠倒"的判断是错的，真正的病根是
//     buffer 号错位/半帧未写完，已在 v79 用"读写不同块 + 帧边界切换"根治。）
//
// 【转场观感】
//   视频最后一帧（全亮，定格） -> 帧边界 -> 顶部 1 条新照片全亮
//   + 下方新照片 1/8 亮度 -> 12 帧扫到底 -> 全屏正常。
//   未揭开区域是"新照片的 1/8 亮度"而不是纯黑，所以没有黑屏感。
// ============================================================
module image_transition_ctrl #(
    parameter integer FADE_FRAMES = 8,       // 兼容旧参数（v78 起不再使用）
    parameter integer WIPE_FRAMES = 12,      // 揭幕用多少帧扫完全屏
    parameter integer V_ACTIVE    = 480      // 有效行数（本工程 640x480）
)(
    input               video_clk,
    input               rst,

    // ---------------- 视频段仲裁（都在 video_clk 域）----------------
    // video_phase : 1 = 逻辑上正在放视频（顶层 mode_video_v）
    // video_valid : 1 = 视频切帧器已经真正切过一帧，buffer 内容可信
    //                （每轮视频开始时由顶层清 0，避免闪上一轮的旧帧）
    // video_buf   : 视频切帧器当前读的 buffer
    // video_start : 本轮视频的第一拍（mode_video_v 上升沿）——
    //               这一拍 swap_valid 还没被清掉，必须先把它挡掉，
    //               否则会立刻切到上一轮留下的 buffer 上闪一帧旧画面。
    input               video_phase,
    input               video_valid,
    input               video_start,
    input      [1:0]    video_buf,

    // 与视频输出时序同域，来自 video_timing_data
    input               vs,
    input               de,

    // 仅用于观察读帧是否已经完成；源头在 ext_mem_clk 域
    input               read_finish_toggle_async,

    // 新图准备完成事件；源头在 sd_card_clk 域
    input               frame_ready_toggle_async,
    input      [1:0]    ready_buf_idx_async,
    input      [1:0]    ready_img_idx_async,

    // 原始 RGB 数据，已经与 vs/de 对齐
    input      [23:0]   rgb_in,

    // 真正送给 frame_read_write 的读 buffer 选择
    output reg [1:0]    read_buf_idx,

    // 经过揭幕处理后的 RGB
    output reg [23:0]   rgb_out,

    // video -> sd_card_bmp：允许 SD 侧正式提交新显示 buffer
    output reg          commit_toggle,

    // 当前真正显示的图片编号，video_clk 域
    output reg [1:0]    current_image_idx,

    // 调试/状态输出，可不连接
    output              transition_busy,

    // v79：1 = 当前屏幕显示的是视频内容（含"视频结束后定格的最后一帧"）
    //   顶层用它决定字幕/OSD 是否让位。
    output              video_shown
);

// ------------------------------------------------------------
// 状态机：IDLE -> FADE（旧画面渐暗）-> SWAP（帧边界换 buffer）-> WIPE（自上而下揭开）
//
//   v79 补的 FADE：如果直接从"旧画面全亮"跳到"新图 1/8 亮度"，
//   整屏会在一帧内暗下去 —— 那一下就是"闪"。加 4 帧（≈67ms）渐变
//   （8/8 -> 5/8 -> 3/8 -> 2/8 -> 1/8）后，再揭开新图，亮度是连续的：
//     旧画面慢慢暗 -> 顶部新图全亮、其余 1/8 -> 12 帧扫到底。
//   视频结束回照片也走同一条路：定格的最后一帧先渐暗，再被新照片盖住。
//
// 注意 FADE 期间读的仍然是【旧 buffer】（read_buf_idx 没变），所以
// 画面内容是连续的旧图，只是亮度在降 —— 这是"淡出"而不是"黑屏"。
// ------------------------------------------------------------
localparam [1:0] ST_IDLE = 2'd0;
localparam [1:0] ST_FADE = 2'd1;
localparam [1:0] ST_SWAP = 2'd2;
localparam [1:0] ST_WIPE = 2'd3;

reg [1:0]  state;
reg [11:0] wipe_y;          // 已经揭开的行数
reg [10:0] row;             // 当前帧内行号
reg        vs_d;
reg        de_d;
reg        request_pending;
reg [1:0]  target_buf_idx;
reg [1:0]  target_img_idx;
reg        read_finished_since_request;
reg [7:0]  swap_timeout;    // 等 read_finish 的帧数兜底
reg [2:0]  fade_step;       // 0..4，第 4 步就是 1/8
reg        hold_dim;        // FADE 结束后压住 1/8，直到 SWAP 真正换了 buffer
// v79：只有"从视频回来"这一次转场才淡出。
//   照片之间的转场保持 v78 的观感（旧图全亮 -> 新图 1/8 底 + 自上而下揭开），
//   用户对这种"上下过渡"没有意见；而视频回来时屏幕上是【全亮的视频定格帧】，
//   直接跳到 1/8 底的暗画面主观上就是"闪了一下"，所以那一次要淡出。
reg        from_video;

// v79：视频段仲裁
reg        vid_d;           // vid_display 打一拍（用来抓"刚退出视频"那一拍）
reg        hold_vid;        // 视频已结束、但屏幕上还是它的最后一帧

// 每帧往下扫多少行（480/12 = 40）
localparam integer STEP = (V_ACTIVE + WIPE_FRAMES - 1) / WIPE_FRAMES;
// 柔化带宽度 = 一个 STEP（交界处不至于是一条硬线）
localparam integer EDGE = STEP;

wire frame_start = vs_d & ~vs;                 // vs 下降沿 = 一帧开始
wire line_start  = de & ~de_d;                 // 一条有效行开始

// v79：当前是否在显示视频（首帧没切过之前 video_valid=0，继续显示照片）
//   video_start 那一拍 video_valid 还是上一轮留下的 1，必须一起挡掉。
wire vid_display = video_phase & video_valid & ~video_start;

// v79：进入视频要卡在帧边界。
//   video_valid 是 swap 收到 frame_ready 后立刻翻的（可能落在某帧扫描到一半
//   的时候），如果这时就把 read_buf_idx 从照片块切到视频块，那一帧会
//   上半张照片 + 下半张视频（撕裂一帧）。所以"进视频"延迟到下一个 vs 下降沿；
//   "退视频"不用延迟 —— 退出时 read_buf_idx 本来就保持不变，没有跳变。
reg vid_lat;
always @(posedge video_clk or posedge rst) begin
    if (rst)              vid_lat <= 1'b0;
    else if (!vid_display) vid_lat <= 1'b0;
    else if (frame_start)  vid_lat <= 1'b1;
end

wire vid_eff = vid_lat;

assign video_shown = vid_eff | hold_vid;

// ------------------------------------------------------------
// 行计数：每帧清零，每出现一条 de 行 +1
// ------------------------------------------------------------
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        row  <= 11'd0;
        de_d <= 1'b0;
        vs_d <= 1'b0;
    end else begin
        de_d <= de;
        vs_d <= vs;
        if (frame_start)
            row <= 11'd0;
        else if (line_start && row != 11'd2047)
            row <= row + 11'd1;
    end
end

// ------------------------------------------------------------
// 跨时钟域同步
// ------------------------------------------------------------
reg fr_tgl_meta, fr_tgl_sync, fr_tgl_sync_d;
wire frame_ready_pulse = fr_tgl_sync ^ fr_tgl_sync_d;

reg [1:0] ready_buf_meta, ready_buf_sync;
reg [1:0] ready_img_meta, ready_img_sync;

reg rf_tgl_meta, rf_tgl_sync, rf_tgl_sync_d;
wire read_finish_pulse = rf_tgl_sync ^ rf_tgl_sync_d;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        fr_tgl_meta  <= 1'b0;  fr_tgl_sync  <= 1'b0;  fr_tgl_sync_d <= 1'b0;
        rf_tgl_meta  <= 1'b0;  rf_tgl_sync  <= 1'b0;  rf_tgl_sync_d <= 1'b0;
        ready_buf_meta <= 2'd0; ready_buf_sync <= 2'd0;
        ready_img_meta <= 2'd0; ready_img_sync <= 2'd0;
    end else begin
        fr_tgl_meta   <= frame_ready_toggle_async;
        fr_tgl_sync   <= fr_tgl_meta;
        fr_tgl_sync_d <= fr_tgl_sync;

        rf_tgl_meta   <= read_finish_toggle_async;
        rf_tgl_sync   <= rf_tgl_meta;
        rf_tgl_sync_d <= rf_tgl_sync;

        ready_buf_meta <= ready_buf_idx_async;
        ready_buf_sync <= ready_buf_meta;
        ready_img_meta <= ready_img_idx_async;
        ready_img_sync <= ready_img_meta;
    end
end

assign transition_busy = (state != ST_IDLE) | request_pending;

// ------------------------------------------------------------
// 主状态机
// ------------------------------------------------------------
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        state                       <= ST_IDLE;
        wipe_y                      <= 12'd0;
        request_pending             <= 1'b0;
        target_buf_idx              <= 2'd0;
        target_img_idx              <= 2'd0;
        read_buf_idx                <= 2'd0;
        current_image_idx           <= 2'd0;
        commit_toggle               <= 1'b0;
        read_finished_since_request <= 1'b0;
        swap_timeout                <= 8'd0;
        vid_d                       <= 1'b0;
        hold_vid                    <= 1'b0;
        fade_step                   <= 3'd0;
        hold_dim                    <= 1'b0;
        from_video                  <= 1'b0;
    end else begin
        vid_d <= vid_eff;

        if (vid_eff) begin
            // ------------------------------------------------
            // 视频段：读 buffer 完全跟着视频切帧器走
            //   照片侧状态机保持 IDLE、清掉待切换请求（sd_card_bmp 在视频段
            //   被冻结，本来也不会产生 frame_ready）。
            // ------------------------------------------------
            read_buf_idx                <= video_buf;
            state                       <= ST_IDLE;
            wipe_y                      <= 12'd0;
            request_pending             <= 1'b0;
            read_finished_since_request <= 1'b0;
            swap_timeout                <= 8'd0;
            hold_vid                    <= 1'b1;
            fade_step                   <= 3'd0;
            hold_dim                    <= 1'b0;
            from_video                  <= 1'b0;
        end else if (vid_d) begin
            // ------------------------------------------------
            // 刚退出视频：**保持** read_buf_idx（= 最后一块视频 buffer），
            // 屏幕继续显示视频最后一帧。v78 在这里把它清 0，导致画面被
            // 强行切到另一块 buffer，再靠 photo_blank 压黑来遮丑。
            // ------------------------------------------------
            state                       <= ST_IDLE;
            wipe_y                      <= 12'd0;
            request_pending             <= 1'b0;
            read_finished_since_request <= 1'b0;
            swap_timeout                <= 8'd0;
            fade_step                   <= 3'd0;
            hold_dim                    <= 1'b0;
            from_video                  <= 1'b1;   // 这一次转场要淡出
        end else begin
            // ---- 新图写好：记下目标，不在帧中途动作 ----
            if (frame_ready_pulse) begin
                request_pending             <= 1'b1;
                target_buf_idx              <= ready_buf_sync;
                target_img_idx              <= ready_img_sync;
                read_finished_since_request <= 1'b0;
                swap_timeout                <= 8'd0;
            end

            if (read_finish_pulse)
                read_finished_since_request <= 1'b1;

            case (state)

                // ------------------------------------------------
                // 空闲：等新图，等到了就在下一帧边界开始淡出旧画面
                // ------------------------------------------------
                ST_IDLE: begin
                    wipe_y <= 12'd0;
                    if (request_pending && frame_start) begin
                        if (from_video) begin
                            fade_step <= 3'd0;      // 第一帧仍是 8/8
                            state     <= ST_FADE;
                        end else begin
                            state     <= ST_SWAP;   // 照片之间：保持 v78 的观感
                        end
                    end
                end

                // ------------------------------------------------
                // 淡出：4 帧把旧画面压到 1/8（8 -> 5 -> 3 -> 2 -> 1）
                //   读的还是旧 buffer，内容连续，只是越来越暗。
                // ------------------------------------------------
                ST_FADE: begin
                    if (frame_start) begin
                        if (fade_step >= 3'd4) begin
                            hold_dim <= 1'b1;   // 压住 1/8，等 SWAP 换 buffer
                            state    <= ST_SWAP;
                        end else begin
                            fade_step <= fade_step + 3'd1;
                        end
                    end
                end

                // ------------------------------------------------
                // 等旧帧读完 -> 在帧边界换 buffer
                // ------------------------------------------------
                ST_SWAP: begin
                    if (frame_start) begin
                        if (read_finished_since_request || (swap_timeout >= 8'd40)) begin
                            // 换读 buffer。下一帧开始读的就是新图。
                            read_buf_idx      <= target_buf_idx;
                            current_image_idx <= target_img_idx;
                            commit_toggle     <= ~commit_toggle;
                            request_pending   <= 1'b0;
                            swap_timeout      <= 8'd0;
                            // 第一帧就露出顶部一条，视觉上是"从上面压下来"
                            wipe_y            <= STEP[11:0];
                            hold_vid          <= 1'b0;   // 视频定格到此结束
                            hold_dim          <= 1'b0;
                            from_video        <= 1'b0;
                            state             <= ST_WIPE;
                        end else if (swap_timeout != 8'd255) begin
                            swap_timeout <= swap_timeout + 8'd1;
                        end
                    end
                end

                // ------------------------------------------------
                // 揭幕：每帧 wipe_y += STEP，扫到底就回 IDLE
                // ------------------------------------------------
                ST_WIPE: begin
                    if (frame_start) begin
                        if (wipe_y >= (V_ACTIVE + EDGE)) begin
                            wipe_y <= 12'd0;
                            state  <= ST_IDLE;
                        end else begin
                            wipe_y <= wipe_y + STEP[11:0];
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
end

// ------------------------------------------------------------
// 逐行亮度：delta = 已揭开高度 - 当前行
//   delta <= 0        -> 1/8（未揭开区：不是纯黑，避免"黑屏感"）
//   0 < delta < EDGE  -> 2/8 .. 8/8 的柔化带
//   delta >= EDGE     -> 8/8 全亮
// 全程只用比较 + 移位，不占乘法器/DSP。
// ------------------------------------------------------------
reg signed [12:0] delta;
always @* begin
    delta = $signed({1'b0, wipe_y}) - $signed({2'b0, row});
end

reg [3:0] wipe_scale;
always @* begin
    if (delta >= EDGE)
        wipe_scale = 4'd8;
    else if (delta >= EDGE / 3)
        wipe_scale = 4'd5;
    else if (delta >= 1)
        wipe_scale = 4'd2;
    else
        wipe_scale = 4'd1;      // 还没揭到的地方：1/8 微亮
end

// v79：淡出档位（8 -> 5 -> 3 -> 2 -> 1），4 帧走完
reg [3:0] fade_scale;
always @* begin
    case (fade_step)
        3'd0:    fade_scale = 4'd8;
        3'd1:    fade_scale = 4'd5;
        3'd2:    fade_scale = 4'd3;
        3'd3:    fade_scale = 4'd2;
        default: fade_scale = 4'd1;
    endcase
end

wire [3:0] scale_now = (state == ST_WIPE) ? wipe_scale
                     : (hold_dim ? 4'd1 : 4'd8);
// ST_FADE 期间用 fade_scale
wire [3:0] scale_final = (state == ST_FADE) ? fade_scale : scale_now;

// ------------------------------------------------------------
// 亮度缩放：0~8 倍（沿用移位表，无乘法器）
// ------------------------------------------------------------
function [7:0] scale_channel;
    input [7:0] din;
    input [3:0] scale;
    begin
        case (scale)
            4'd0: scale_channel = 8'd0;
            4'd1: scale_channel = din >> 3;                                  // 1/8
            4'd2: scale_channel = din >> 2;                                  // 2/8
            4'd3: scale_channel = (din >> 2) + (din >> 3);                   // 3/8
            4'd4: scale_channel = din >> 1;                                  // 4/8
            4'd5: scale_channel = (din >> 1) + (din >> 3);                   // 5/8
            4'd6: scale_channel = (din >> 1) + (din >> 2);                   // 6/8
            4'd7: scale_channel = din - (din >> 3);                          // 7/8
            default: scale_channel = din;                                    // 8/8
        endcase
    end
endfunction

always @* begin
    if (!de) begin
        rgb_out = 24'd0;
    end else begin
        rgb_out = {
            scale_channel(rgb_in[23:16], scale_final),
            scale_channel(rgb_in[15:8],  scale_final),
            scale_channel(rgb_in[7:0],   scale_final)
        };
    end
end

endmodule
