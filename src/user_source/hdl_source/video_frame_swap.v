`timescale 1ns/1ps
// ============================================================
// video_frame_swap —— 视频模式下的双缓冲切帧器（video_clk 域）
// ------------------------------------------------------------
// 与 image_transition_ctrl 的区别：
//   image_transition_ctrl 是给"照片轮播"用的：淡出 8 帧 -> 黑场 -> 切 buffer -> 淡入 8 帧。
//   8 帧黑场 ≈ 8 x 16.7ms = 133ms，比 12fps 的整帧预算 83ms 还长，
//   视频要是走它就只能放到 5fps，所以视频模式必须直切。
//
// 切帧安全性：
//   SDRAM 读出的一帧是在 frame_fifo_read 里按 read_req（vs 边界）启动、
//   整帧 307200 词读完后给出 read_finish 的。read_finish 之后到下一次 read_req
//   之间不会再有 SDRAM 读地址产生，因此在这段窗口里改 read_addr_index 绝对不会撕裂。
//   本模块就是"收到新帧就绪 -> 等 read_finish -> 立刻切 + 回 commit"。
//
// 首帧：
//   还没有任何有效画面，read_finish 可能不会来（或来的是上一轮垃圾数据），
//   所以首帧收到就绪事件后直接切，不等 read_finish。
// ============================================================
module video_frame_swap (
    input  wire        video_clk,
    input  wire        rst,

    input  wire        vs,
    input  wire        de,

    // v79：每轮视频开始（mode_video_v 上升沿）清一次"已有有效画面"，
    //   否则第二轮进视频时 valid 还是上一轮留下的 1，transition 会
    //   立刻切到 read_buf_idx（还是上一轮的旧 buffer）上，闪一帧旧画面。
    input  wire        restart,

    // 来自 sd_card_clk 域：新帧已完整写入备用 buffer
    input  wire        frame_ready_toggle_async,
    input  wire [1:0]  ready_buf_idx_async,

    // 来自 ext_mem_clk 域：当前帧 SDRAM 读取已完成
    input  wire        read_finish_toggle_async,

    input  wire [23:0] rgb_in,

    output reg  [1:0]  read_buf_idx,
    output reg  [23:0] rgb_out,
    output reg         commit_toggle,
    output reg         valid,          // 已有可显示的帧（一旦置 1 不再清）
    output wire        swap_busy,      // 有待切换的帧（调试/OSD 用）

    output reg  [7:0]  dbg_frames
);

// ------------------------------------------------------------
// 跨域同步：toggle 用 3 级，数据总线用 2 级
// ------------------------------------------------------------
reg        fr_meta, fr_sync, fr_sync_d;
reg        rf_meta, rf_sync, rf_sync_d;
reg [1:0]  rb_meta, rb_sync;

wire fr_pulse = fr_sync ^ fr_sync_d;
wire rf_pulse = rf_sync ^ rf_sync_d;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        fr_meta   <= 1'b0;
        fr_sync   <= 1'b0;
        fr_sync_d <= 1'b0;
        rf_meta   <= 1'b0;
        rf_sync   <= 1'b0;
        rf_sync_d <= 1'b0;
        rb_meta   <= 2'd0;
        rb_sync   <= 2'd0;
    end else begin
        fr_meta   <= frame_ready_toggle_async;
        fr_sync   <= fr_meta;
        fr_sync_d <= fr_sync;

        rf_meta   <= read_finish_toggle_async;
        rf_sync   <= rf_meta;
        rf_sync_d <= rf_sync;

        rb_meta   <= ready_buf_idx_async;
        rb_sync   <= rb_meta;
    end
end

// ------------------------------------------------------------
// 切换状态
// ------------------------------------------------------------
reg       pending;
reg [1:0] target_buf;
reg       read_done;

assign swap_busy = pending;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        pending       <= 1'b0;
        target_buf    <= 2'd0;
        read_done     <= 1'b0;
        read_buf_idx  <= 2'd0;
        commit_toggle <= 1'b0;
        valid         <= 1'b0;
        dbg_frames    <= 8'd0;
    end else begin
        // v79：新一轮视频开始 —— 清掉"已有有效画面"，让首帧就绪时直接切，
        //   首帧到来之前 transition 会继续显示照片（video_valid=0）。
        if (restart) begin
            pending    <= 1'b0;
            read_done  <= 1'b0;
            valid      <= 1'b0;
            dbg_frames <= 8'd0;
        end else begin
            // 新帧就绪：登记目标 buffer，之后只认"登记之后"的 read_finish
            if (fr_pulse) begin
                pending    <= 1'b1;
                target_buf <= rb_sync;
                read_done  <= 1'b0;
            end

            if (rf_pulse)
                read_done <= 1'b1;

            // 首帧直接切；之后必须等当前帧 SDRAM 读完
            if (pending && (read_done || !valid)) begin
                read_buf_idx  <= target_buf;
                commit_toggle <= ~commit_toggle;
                valid         <= 1'b1;
                pending       <= 1'b0;
                read_done     <= 1'b0;
                dbg_frames    <= dbg_frames + 8'd1;
            end
        end
    end
end

// ------------------------------------------------------------
// 输出：de 外强制黑，保证消隐期是纯黑（与原链路一致）
// ------------------------------------------------------------
always @* begin
    rgb_out = de ? rgb_in : 24'd0;
end

endmodule
