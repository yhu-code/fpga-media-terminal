`timescale 1ns/1ps

// ============================================================
// bmp_scaler —— 图片缩放适配引擎（v24 全面重写）
//
// 作用：把 TF 卡里任意分辨率的 BMP 缩放适配到 640x480 屏幕。
// 位置：插在 bmp_read 的像素输出与 SDRAM 写帧 FIFO 之间（写路径）。
//       SDRAM 帧缓存里永远只有标准 640x480，显示链路一行都不用改。
//
// 算法：最近邻（nearest neighbour）
//   横向：源行流入时用一个 Bresenham 累加器把 sw 个源像素重采样成
//         dw 个目标像素，写入行缓冲。
//   纵向：每输出一行，用 Bresenham 累加器判断"上移一行"是否需要
//         换源行；需要就取新行，不需要就复用行缓冲（竖向放大）。
//
// ------------------------------------------------------------
// v24 为什么整篇重写（这是 v12~v23 图像一直乱码的真正原因）
// ------------------------------------------------------------
// v23 之前，输入 FIFO 写成 `wire dout = fifo[rptr]`（组合/异步读），
// 行缓冲写成 `d_data <= lbuf[jr]`（同样是组合读大数组）。1024 深的
// 异步读 RAM 被综合成 **1024:1 的巨型多路选择器**：
//   面积报告：u_bmp_scaler 占 7804 LUT / 7498 FF（整个工程 LUT 用掉 80%）
//   时序报告：u_bmp_scaler/ramread0_syn_*.e[0]  slack = -0.635ns
// 100MHz（10ns）时钟下，10 级 LUT 选择器 + 布线根本来不及，**读地址
// 还没稳定数据就被采样** ⇒ 读出的像素是随机位置的像素。
// 于是：几何、行数、垂直映射全对（这些只靠计数器），但像素值整体乱掉
// （实测：照片与原图整幅 NCC ≈ -0.11，而逐行垂直映射误差 ≤4 行）。
//
// v24 的做法：两个数组全部改成 **地址寄存器化 + 输出寄存器** 的同步读，
// 每读一个数据用 2 拍（发地址 / 取数据）。本模块的吞吐需求只有
// SD 卡的 ~1M 像素/秒，2 拍一个像素（=50M 像素/秒）绰绰有余，
// 因此完全不需要为速度牺牲时序。改动后 u_bmp_scaler 面积降到 ~1/10，
// 全线只剩浅组合逻辑，100MHz 下不再有违例。
//
// 模式 mode[1:0]（在 sd_card_bmp 里用参数 SCALE_MODE 固定/修改）：
//   0 = 拉伸填满 Stretch（忽略宽高比）
//   1 = 等比完整 Contain（保持比例，黑边居中）  <-- 默认
//   2 = 等比裁剪 Cover（保持比例，裁剪居中）
//   3 = 原始尺寸 1:1 居中
//
// BMP 自下而上存储；frame_fifo_write 的 WRITE_V_FLIP=1 会把先写入的
// 数据放到画面底部，因此本模块按"自下而上"顺序输出 480 行。
// ============================================================

module bmp_scaler #(
    parameter DST_W     = 640,
    parameter DST_H     = 480,
    parameter [15:0] MAX_W = 16'd4096,
    parameter [15:0] MAX_H = 16'd4096,
    parameter FIFO_AW   = 9          // 输入 FIFO 深度 512
)(
    input  wire             clk,
    input  wire             rst,

    input  wire [15:0]      src_w,
    input  wire [15:0]      src_h,
    input  wire [1:0]       mode,
    input  wire             start,          // 新图开始（src_w/src_h 已有效）
    input  wire             s_end,          // 源像素流结束脉冲

    input  wire             s_valid,        // 源像素流（自下而上、逐行左->右）
    input  wire [23:0]      s_data,

    input  wire             out_rdy,        // 下游写帧 FIFO 可写（0 时暂停发射）

    output reg              d_valid,        // 目标像素流（送写帧 FIFO）
    output reg  [23:0]      d_data,
    output reg              busy,
    output reg              frame_done,     // 一帧 640x480 已完整输出

    // 调试观测（不影响功能）
    output wire [3:0]       dbg_state,
    output wire [10:0]      dbg_fcnt,
    output wire [15:0]      dbg_next_fr,
    output wire [15:0]      dbg_rs,
    output wire [15:0]      dbg_yd,
    output wire             dbg_starve,
    output wire             dbg_s_end_lat,
    output wire [15:0]      dbg_dh,
    output wire [15:0]      dbg_dy0
);

// ------------------------------------------------------------
// 输入 FIFO（同步读，读延迟 1 拍：先给地址，下一拍出数据）
// ------------------------------------------------------------
localparam FIFO_SIZE = 1 << FIFO_AW;

reg  [23:0]        fifo [0:FIFO_SIZE-1];
reg  [FIFO_AW-1:0] wptr;
reg  [FIFO_AW-1:0] rptr;
reg  [FIFO_AW:0]   fcnt;
reg  [23:0]        fifo_dout;      // 同步读输出寄存器

reg                fifo_flush;

// 两根读请求线提前声明（赋值在后面，见 assign fifo_rd / lbuf_rd）。
// 读请求必须是【当拍组合】的：如果打成寄存器，dout 会晚两拍才有效，
// 取到的就是上一个像素（v24 首版就是这样错位的，逐拍模型立刻暴露：
// 307200 个像素里有 214691 个和正确结果不同）。
wire fifo_rd;
wire lbuf_rd;

wire fifo_full  = (fcnt >= FIFO_SIZE - 2);
wire fifo_empty = (fcnt == 0);

always @(posedge clk) begin
    if (rst) begin
        wptr      <= {FIFO_AW{1'b0}};
        rptr      <= {FIFO_AW{1'b0}};
        fcnt      <= {(FIFO_AW+1){1'b0}};
        fifo_dout <= 24'd0;
    end else if (fifo_flush) begin
        wptr      <= {FIFO_AW{1'b0}};
        rptr      <= {FIFO_AW{1'b0}};
        fcnt      <= {(FIFO_AW+1){1'b0}};
        fifo_dout <= 24'd0;
    end else begin
        if (s_valid && !fifo_full) begin
            fifo[wptr] <= s_data;
            wptr       <= wptr + 1'b1;
        end
        if (fifo_rd && !fifo_empty)
            rptr <= rptr + 1'b1;
        // v26：无条件同步读（去掉 .e 读使能）。
        // 时序报告里最差路径正是
        //   state/lead/rem 译码 -> 高扇出(66)读使能网 -> DRAM .e[0]，-0.349ns
        // rptr 只在 fifo_rd 时前进，所以每拍读 fifo[rptr] 得到的数据和
        // "只在 fifo_rd 时读"完全一样，功能零变化，却把这条控制网彻底删掉。
        fifo_dout <= fifo[rptr];        // 地址是寄存器，读数据也进寄存器
        fcnt <= fcnt
              + ((s_valid && !fifo_full) ? {{FIFO_AW{1'b0}}, 1'b1} : {(FIFO_AW+1){1'b0}})
              - ((fifo_rd && !fifo_empty) ? {{FIFO_AW{1'b0}}, 1'b1} : {(FIFO_AW+1){1'b0}});
    end
end

// ------------------------------------------------------------
// 行缓冲（同步读，读延迟 1 拍）
// ------------------------------------------------------------
reg [23:0]  lbuf [0:DST_W-1];
reg [23:0]  lbuf_rdata;

always @(posedge clk) begin
    // 注意：这个输出寄存器【不能加复位】。TD 的 BRAM 推断模板里读寄存器必须
    // 是"无复位 + if(ce)"，加异步复位就退化成本地分布式 RAM（实测 640x24 的
    // 行缓冲变成 1024x24 DRAM，u_bmp_scaler 从 2853 LUT 涨到 6248 LUT，
    // 100MHz 域直接 -0.649ns 违例）。
    if (lbuf_rd)
        lbuf_rdata <= lbuf[jr];
end

// ------------------------------------------------------------
// 32 位循环减法除法器（每帧只做 1 次，约 34 拍）
// ------------------------------------------------------------
reg        div_start;
reg        div_busy;
reg        div_done;                    // 单拍完成脉冲（只由本 always 块驱动）
reg [31:0] div_a;
reg [31:0] div_b;
reg [31:0] div_q;
reg [31:0] div_r;
reg [5:0]  div_cnt;

always @(posedge clk) begin
    if (rst) begin
        div_busy  <= 1'b0;
        div_done  <= 1'b0;
        div_q     <= 32'd0;
        div_r     <= 32'd0;
        div_cnt   <= 6'd0;
    end else begin
        div_done <= 1'b0;
        if (div_start) begin
            div_r    <= 32'd0;
            div_q    <= div_a;
            div_cnt  <= 6'd0;
            div_busy <= 1'b1;
        end else if (div_busy) begin
            if (div_cnt == 6'd32) begin
                div_busy <= 1'b0;
                div_done <= 1'b1;           // 商在本拍有效，脉冲一拍
            end else begin
                if ({div_r[30:0], div_q[31]} >= div_b) begin
                    div_r <= {div_r[30:0], div_q[31]} - div_b;
                    div_q <= {div_q[30:0], 1'b0} + 32'd1;
                end else begin
                    div_r <= {div_r[30:0], div_q[31]};
                    div_q <= {div_q[30:0], 1'b0};
                end
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end
end

// ------------------------------------------------------------
// 几何参数
// ------------------------------------------------------------
reg [15:0] W, H;
reg [1:0]  mode_r;

reg [15:0] sx0, sy0, sw, sh;   // 源窗口
reg [15:0] dx0, dy0, dw, dh;   // 目标区域

reg [15:0] yd;                 // 当前输出行对应的"屏幕行号"（479 -> 0）
reg [15:0] t;                  // 源窗口内的"自上而下"行号
reg        t_inited;
reg [15:0] vacc;               // 竖向 Bresenham 累加器
reg        vacc_added;
reg [15:0] next_fr;            // 流中下一个可用源行（文件行号，自下而上 0..H-1）
reg [15:0] rs;                 // 当前目标行需要的源行
reg        row_active;

reg [15:0] sc;                 // 行内源列计数（0..W-1）
reg [9:0]  j;                  // 行缓冲写入下标
reg [15:0] hacc;               // 横向 Bresenham 累加器
reg [23:0] pix;                // 当前源像素
reg        pix_vld;

reg [9:0]  x;                  // 输出行内列计数
reg [9:0]  jr;                 // 行缓冲读出下标
reg [9:0]  lead;               // 左侧黑边剩余
reg [9:0]  rem;                // 有效像素剩余
reg        cur_pix;            // 当前要输出的像素是否有效

reg        s_end_latched;
reg        starve;

reg [3:0]  state;
reg [2:0]  geo_step;

// 读请求必须是【当拍组合】的：如果打成寄存器，dout 会晚两拍才有效，
// 取到的就是上一个像素（v24 首版就是这样错位的，逐拍模型立刻暴露：
// 307200 个像素里有 214691 个与正确结果不同）。
// FIFO 读：S_LOAD_REQ / S_SKIP_REQ 当拍组合发地址，下一拍 dout 有效
assign fifo_rd = ((state == S_LOAD_REQ) || (state == S_SKIP_REQ))
              && (sc != W) && !fifo_empty;
// 行缓冲读：S_EMIT_REQ 当拍组合发地址，S_EMIT_OUT 用数据
assign lbuf_rd = (state == S_EMIT_REQ) && out_rdy
              && (lead == 10'd0) && (rem != 10'd0);

localparam S_IDLE     = 4'd0;
localparam S_GEO      = 4'd1;
localparam S_ROW      = 4'd2;
localparam S_PREP     = 4'd3;
localparam S_SKIP_REQ = 4'd4;
localparam S_SKIP_GET = 4'd5;
localparam S_LOAD_REQ = 4'd6;
localparam S_LOAD_GET = 4'd7;
localparam S_LOAD_PUSH= 4'd8;
localparam S_EMIT_REQ = 4'd9;
localparam S_EMIT_OUT = 4'd10;
localparam S_NEXT     = 4'd11;

wire [31:0] w32 = {16'd0, W};
wire [31:0] h32 = {16'd0, H};
// v26：480/640 = 3/4，所以"源图比屏幕更宽"的判据可以把乘法整个约掉：
//   W*DST_H >= H*DST_W   <=>   W*480 >= H*640   <=>   W*3 >= H*4
// 原来用两个 32 位乘法器再比大小，综合出 MULT18+两级加法器，
// 实测这条组合链 10.431ns（sd_card_clk 只有 10ns）→ -0.711ns 违例。
// 换成 3/4 的移位加法后 W*3 ≤ 12288、H*4 ≤ 16384，16 位就够，只剩一级小加法。
wire [15:0] w3 = (W << 1) + W;
wire [15:0] h4 = (H << 2);
wire        wide = (w3 >= h4);      // 源图比屏幕更"宽"

assign dbg_state     = state;
assign dbg_fcnt      = fcnt;        // 10 位零扩展成 11 位（不能写 fcnt[10:0]，越界会报 HDL-8007）
assign dbg_next_fr   = next_fr;
assign dbg_rs        = rs;
assign dbg_yd        = yd;
assign dbg_starve    = starve;
assign dbg_s_end_lat = s_end_latched;
assign dbg_dh        = dh;
assign dbg_dy0       = dy0;

// 第一行有效行还没到时，源行按 sh-1（图像底部）计算
wire [15:0] t_eff = t_inited ? t : (sh - 16'd1);

always @(posedge clk) begin
    if (rst) begin
        state         <= S_IDLE;
        busy          <= 1'b0;
        frame_done    <= 1'b0;
        d_valid       <= 1'b0;
        d_data        <= 24'd0;
        fifo_flush    <= 1'b0;
        div_start     <= 1'b0;
        s_end_latched <= 1'b0;
        starve        <= 1'b0;
        pix_vld       <= 1'b0;
        cur_pix       <= 1'b0;
        W <= 16'd16; H <= 16'd16; mode_r <= 2'd1;
        sx0 <= 0; sy0 <= 0; sw <= 0; sh <= 0;
        dx0 <= 0; dy0 <= 0; dw <= DST_W[15:0]; dh <= DST_H[15:0];
        yd <= 0; t <= 0; t_inited <= 0; vacc <= 0; vacc_added <= 0;
        next_fr <= 0; rs <= 0; row_active <= 0;
        sc <= 0; j <= 0; hacc <= 0; pix <= 0;
        x <= 0; jr <= 0; lead <= 0; rem <= 0;
        geo_step <= 3'd0;
    end else begin
        d_valid    <= 1'b0;
        frame_done <= 1'b0;
        fifo_flush <= 1'b0;
        div_start  <= 1'b0;

        if (s_end)
            s_end_latched <= 1'b1;

        if (state == S_IDLE)
            s_end_latched <= 1'b0;

        case (state)

            // ================================================
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    W <= (src_w < 16'd16) ? 16'd16 :
                         ((src_w > MAX_W) ? MAX_W : src_w);
                    H <= (src_h < 16'd16) ? 16'd16 :
                         ((src_h > MAX_H) ? MAX_H : src_h);
                    mode_r        <= mode;
                    geo_step      <= 3'd0;
                    starve        <= 1'b0;
                    s_end_latched <= 1'b0;
                    fifo_flush    <= 1'b1;      // 丢弃上次残留
                    pix_vld       <= 1'b0;
                    busy          <= 1'b1;
                    state         <= S_GEO;
                end
            end

            // ================================================
            // 几何计算（每帧一次）
            // ================================================
            S_GEO: begin
                case (geo_step)
                    // ---- step0：默认拉伸填满，按模式启动除法 ----
                    3'd0: begin
                        sx0 <= 16'd0; sy0 <= 16'd0; sw <= W;  sh <= H;
                        dx0 <= 16'd0; dy0 <= 16'd0; dw <= DST_W; dh <= DST_H;

                        if (mode_r == 2'd1) begin
                            if (wide) begin
                                dw    <= DST_W;
                                div_a <= h32 * DST_W;
                                div_b <= w32;             // dh = H*640/W
                            end else begin
                                dh    <= DST_H;
                                div_a <= w32 * DST_H;
                                div_b <= h32;             // dw = W*480/H
                            end
                            div_start <= 1'b1;
                            geo_step  <= 3'd1;
                        end else if (mode_r == 2'd2) begin
                            if (wide) begin
                                sh    <= H;
                                sy0   <= 16'd0;
                                div_a <= h32 * DST_W;
                                div_b <= DST_H;           // sw = H*640/480
                            end else begin
                                sw    <= W;
                                sx0   <= 16'd0;
                                div_a <= w32 * DST_H;
                                div_b <= DST_W;           // sh = W*480/640
                            end
                            div_start <= 1'b1;
                            geo_step  <= 3'd2;
                        end else if (mode_r == 2'd3) begin
                            geo_step <= 3'd3;
                        end else begin
                            geo_step <= 3'd4;
                        end
                    end

                    // ---- step1：Contain 的除法结果 ----
                    3'd1: begin
                        if (div_done) begin
                            if (wide) begin
                                dh  <= (div_q > DST_H) ? DST_H[15:0] : div_q[15:0];
                                dy0 <= (div_q > DST_H) ? 16'd0
                                                       : ((DST_H - div_q[15:0]) >> 1);
                            end else begin
                                dw  <= (div_q > DST_W) ? DST_W[15:0] : div_q[15:0];
                                dx0 <= (div_q > DST_W) ? 16'd0
                                                       : ((DST_W - div_q[15:0]) >> 1);
                            end
                            geo_step <= 3'd4;
                        end
                    end

                    // ---- step2：Cover 的除法结果 ----
                    3'd2: begin
                        if (div_done) begin
                            if (wide) begin
                                sw  <= (div_q > {16'd0, W}) ? W       : div_q[15:0];
                                sx0 <= (div_q > {16'd0, W}) ? 16'd0   : ((W - div_q[15:0]) >> 1);
                            end else begin
                                sh  <= (div_q > {16'd0, H}) ? H       : div_q[15:0];
                                sy0 <= (div_q > {16'd0, H}) ? 16'd0   : ((H - div_q[15:0]) >> 1);
                            end
                            geo_step <= 3'd4;
                        end
                    end

                    // ---- step3：1:1 居中 ----
                    3'd3: begin
                        if (W < DST_W) begin
                            sw  <= W;  sx0 <= 16'd0;  dw <= W;
                            dx0 <= (DST_W - W) >> 1;
                        end else begin
                            sw  <= DST_W;  sx0 <= (W - DST_W) >> 1;  dw <= DST_W;
                            dx0 <= 16'd0;
                        end
                        if (H < DST_H) begin
                            sh  <= H;  sy0 <= 16'd0;  dh <= H;
                            dy0 <= (DST_H - H) >> 1;
                        end else begin
                            sh  <= DST_H;  sy0 <= (H - DST_H) >> 1;  dh <= DST_H;
                            dy0 <= 16'd0;
                        end
                        geo_step <= 3'd4;
                    end

                    // ---- step4：安全钳位 + 复位行循环 ----
                    default: begin
                        if (dw == 16'd0) dw <= DST_W[15:0];
                        if (dh == 16'd0) dh <= DST_H[15:0];
                        if (sw == 16'd0) sw <= 16'd1;
                        if (sh == 16'd0) sh <= 16'd1;
                        if ((sx0 + sw) > W) sw <= W - sx0;
                        if ((sy0 + sh) > H) sh <= H - sy0;
                        if ((dx0 + dw) > DST_W) dw <= DST_W - dx0;
                        if ((dy0 + dh) > DST_H) dh <= DST_H - dy0;

                        yd         <= DST_H - 1;
                        t          <= 16'd0;
                        t_inited   <= 1'b0;
                        vacc       <= 16'd0;
                        vacc_added <= 1'b0;
                        next_fr    <= 16'd0;
                        row_active <= 1'b0;
                        x          <= 10'd0;
                        jr         <= 10'd0;
                        pix_vld    <= 1'b0;
                        state      <= S_ROW;
                    end
                endcase
            end

            // ================================================
            // 新的一行：判断是否在图像区域内，计算需要的源行
            // ================================================
            S_ROW: begin
                x  <= 10'd0;
                jr <= 10'd0;
                if (!starve && (yd >= dy0) && (yd < dy0 + dh)) begin
                    row_active <= 1'b1;
                    rs         <= H - 16'd1 - sy0 - t_eff;
                    if (!t_inited) begin
                        t        <= sh - 16'd1;
                        vacc     <= 16'd0;
                        t_inited <= 1'b1;
                    end
                end else begin
                    row_active <= 1'b0;
                end
                state <= S_PREP;
            end

            // ================================================
            // 决定：发黑行 / 跳过源行 / 载入新源行 / 复用行缓冲
            // ================================================
            S_PREP: begin
                if (!row_active) begin
                    lead <= DST_W[9:0];
                    rem  <= 10'd0;
                    state <= S_EMIT_REQ;
                end else begin
                    lead <= dx0[9:0];
                    rem  <= dw[9:0];
                    if (rs > next_fr) begin
                        sc    <= 16'd0;
                        state <= S_SKIP_REQ;
                    end else if (rs == next_fr) begin
                        sc      <= 16'd0;
                        j       <= 10'd0;
                        hacc    <= 16'd0;
                        pix_vld <= 1'b0;
                        state   <= S_LOAD_REQ;
                    end else begin
                        state <= S_EMIT_REQ;      // 竖向放大：复用行缓冲
                    end
                end
            end

            // ================================================
            // 丢弃不需要的源行（每行 W 个像素，2 拍一个）
            // ================================================
            S_SKIP_REQ: begin
                if (sc == W) begin
                    sc      <= 16'd0;
                    next_fr <= next_fr + 1'b1;
                    state   <= S_PREP;
                end else if (!fifo_empty) begin
                    state   <= S_SKIP_GET;
                end else if (s_end_latched) begin
                    starve <= 1'b1;
                    state  <= S_ROW;
                end
            end

            S_SKIP_GET: begin
                sc    <= sc + 1'b1;
                state <= S_SKIP_REQ;
            end

            // ================================================
            // 载入一行源像素，同时横向重采样 -> 行缓冲
            // ================================================
            S_LOAD_REQ: begin
                if (sc == W) begin
                    next_fr <= next_fr + 1'b1;
                    state   <= S_EMIT_REQ;
                end else if (!fifo_empty) begin
                    state   <= S_LOAD_GET;        // 本拍已组合发出读地址
                end else if (s_end_latched) begin
                    starve <= 1'b1;
                    state  <= S_ROW;
                end
            end

            S_LOAD_GET: begin
                pix <= fifo_dout;
                if ((sc >= sx0) && (sc < sx0 + sw))
                    hacc <= hacc + dw;
                sc      <= sc + 1'b1;
                pix_vld <= 1'b1;
                state   <= S_LOAD_PUSH;
            end

            S_LOAD_PUSH: begin
                if (pix_vld && (hacc >= sw) && (j < dw[9:0])) begin
                    lbuf[j] <= pix;
                    j       <= j + 1'b1;
                    hacc    <= hacc - sw;
                    // 留在本状态：竖向/横向放大时同一个源像素要写多次
                end else begin
                    pix_vld <= 1'b0;
                    state   <= S_LOAD_REQ;
                end
            end

            // ================================================
            // 发射一行目标像素（2 拍一个：发地址 / 出数据）
            // ================================================
            S_EMIT_REQ: begin
                if (out_rdy) begin
                    cur_pix <= (lead == 10'd0) && (rem != 10'd0);
                    if ((lead == 10'd0) && (rem != 10'd0))
                        jr <= jr + 1'b1;
                    if (lead != 10'd0)
                        lead <= lead - 1'b1;
                    else if (rem != 10'd0)
                        rem <= rem - 1'b1;
                    state <= S_EMIT_OUT;
                end
            end

            S_EMIT_OUT: begin
                if (out_rdy) begin
                    d_valid <= 1'b1;
                    d_data  <= cur_pix ? lbuf_rdata : 24'd0;
                    if (x == DST_W[9:0] - 10'd1) begin
                        x     <= 10'd0;
                        state <= S_NEXT;
                    end else begin
                        x     <= x + 1'b1;
                        state <= S_EMIT_REQ;
                    end
                end
            end

            // ================================================
            // 行结束：竖向 Bresenham 推进源行号
            // ================================================
            S_NEXT: begin
                if (!row_active) begin
                    if (yd == 16'd0) begin
                        busy       <= 1'b0;
                        frame_done <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        yd    <= yd - 1'b1;
                        state <= S_ROW;
                    end
                end else if (!vacc_added) begin
                    vacc       <= vacc + sh;
                    vacc_added <= 1'b1;
                end else if (vacc >= dh) begin
                    vacc <= vacc - dh;
                    if (t != 16'd0)
                        t <= t - 1'b1;
                end else begin
                    vacc_added <= 1'b0;
                    if (yd == 16'd0) begin
                        busy       <= 1'b0;
                        frame_done <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        yd    <= yd - 1'b1;
                        state <= S_ROW;
                    end
                end
            end

            default: begin
                fifo_flush <= 1'b1;
                state      <= S_IDLE;
            end
        endcase
    end
end

endmodule
