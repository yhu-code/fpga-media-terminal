`timescale 1ns/1ps

// ============================================================
// bc_osd —— 亮度 / 对比度提示（v40）
//
// 版式（640x480 坐标系）：
//
//   ┌──────────────────────────────┐   ← 方框：1px 边框 + 内部"原图压暗 80%"
//   │  ◐  对比度 + 0 %             │
//   │  ☀  亮度  + 70 %             │
//   └──────────────────────────────┘
//
//   · 方框：x 20..235、y 4..67（216x64 = 13824 px²，约为旧版 228x116 的 52%）
//   · 图标 28x28，文字 24x24
//   · 文字/图标纯白；框内其余像素 = 输入 RGB x 20%（压暗 80%）
//   · 两行数字都从 TEXT_X+72 起，符号/十位/个位/% 四列严格对齐
//   · 显示时长与触发时机由顶层 enable 决定（拨码变化后 2 秒），本模块不计时
//
// 数值口径：增量（0 = 原始画面），每档 10%，范围 ±70%
// ============================================================
module bc_osd #(
    parameter integer BOX_X    = 20,
    parameter integer BOX_Y    = 4,
    parameter integer BOX_W    = 216,
    parameter integer BOX_H    = 64,
    parameter integer ICON_X   = 28,
    parameter integer ICON_SZ  = 28,
    parameter integer TEXT_X   = 64,
    parameter integer NUM_DX   = 72,        // 数字区相对 TEXT_X 的偏移（两行共用）
    parameter integer ROW0_Y   = 8,         // 「对比度」行
    parameter integer ROW1_Y   = 40,        // 「亮度」行
    parameter [23:0]  TEXT_RGB = 24'hFFFFFF,
    parameter [23:0]  BORDER_RGB = 24'hB0B0B0,
    parameter [7:0]   DIM_K    = 8'd51       // 51/256 ≈ 20% -> 压暗 80%
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,

    input  wire [3:0]  bright_lvl,
    input  wire [3:0]  contrast_lvl,

    output wire [23:0] rgb_out
);

    localparam integer HALF        = ICON_SZ / 2;      // 14
    localparam integer ROW0_ICON_Y = ROW0_Y - 2;
    localparam integer ROW1_ICON_Y = ROW1_Y - 2;
    localparam integer LAB_W1      = 2 * 24;           // 亮度

    wire [9:0] pixel_x;
    wire [8:0] pixel_y;

    video_coord_gen_640x480 u_video_coord_gen (
        .clk      (clk),
        .rst      (rst),
        .vs       (vs),
        .de       (de),
        .pixel_x  (pixel_x),
        .pixel_y  (pixel_y)
    );

    // ------------------------------------------------ 方框
    wire [9:0] BOX_X_U  = BOX_X;
    wire [8:0] BOX_Y_U  = BOX_Y;
    wire [9:0] BOX_XR   = BOX_X + BOX_W - 1;
    wire [8:0] BOX_YB   = BOX_Y + BOX_H - 1;

    wire in_box = enable && de &&
                  (pixel_x >= BOX_X_U) && (pixel_x <= BOX_XR) &&
                  (pixel_y >= BOX_Y_U) && (pixel_y <= BOX_YB);

    // 1px 边框（上下左右各 1 行/列）
    wire on_border = (pixel_x == BOX_X_U) || (pixel_x == BOX_XR) ||
                     (pixel_y == BOX_Y_U) || (pixel_y == BOX_YB);

    // ------------------------------------------------ 行判定
    wire in_row0 = (pixel_y >= ROW0_Y) && (pixel_y < (ROW0_Y + 24));
    wire in_row1 = (pixel_y >= ROW1_Y) && (pixel_y < (ROW1_Y + 24));

    wire [9:0] ROW0_Y_U = ROW0_Y;
    wire [9:0] ROW1_Y_U = ROW1_Y;
    wire [9:0] trow = in_row0 ? (pixel_y - ROW0_Y_U) : (pixel_y - ROW1_Y_U);

    // ------------------------------------------------ 图标几何
    wire in_icon0 = (pixel_y >= ROW0_ICON_Y) && (pixel_y < (ROW0_ICON_Y + ICON_SZ));
    wire in_icon1 = (pixel_y >= ROW1_ICON_Y) && (pixel_y < (ROW1_ICON_Y + ICON_SZ));
    wire in_icon_row = in_icon0 | in_icon1;

    wire [9:0] ICON_X_U = ICON_X;
    wire       in_icon_col = (pixel_x >= ICON_X_U) && (pixel_x < (ICON_X_U + ICON_SZ));

    wire [9:0] ICON0_Y_U = ROW0_ICON_Y;
    wire [9:0] ICON1_Y_U = ROW1_ICON_Y;

    wire [9:0] ix = pixel_x - ICON_X_U;
    wire [9:0] iy = in_icon0 ? (pixel_y - ICON0_Y_U) : (pixel_y - ICON1_Y_U);

    wire [4:0] dx = (ix > HALF) ? (ix - HALF) : (HALF - ix);
    wire [4:0] dy = (iy > HALF) ? (iy - HALF) : (HALF - iy);

    wire [9:0]  dx2 = dx * dx;
    wire [9:0]  dy2 = dy * dy;
    wire [10:0] r2  = dx2 + dy2;

    // 对比度：圆环 + 左半实心（左白右黑）
    wire c_ring = (r2 >= 11'd121) && (r2 <= 11'd169);        // 半径 11..13
    wire c_half = (ix < HALF) && (r2 <= 11'd121);
    wire contrast_on = c_ring || c_half;

    // 亮度：中心圆环 + 8 条射线
    wire s_ring = (r2 >= 11'd25) && (r2 <= 11'd49);          // 半径 5..7
    wire s_h    = (dy <= 5'd1) && (dx >= 5'd9)  && (dx <= 5'd13);
    wire s_v    = (dx <= 5'd1) && (dy >= 5'd9)  && (dy <= 5'd13);
    wire [4:0] d_ad = (dx > dy) ? (dx - dy) : (dy - dx);
    wire s_d    = (dx >= 5'd2) && (dy >= 5'd2) && (d_ad <= 5'd1) &&
                  (dx >= 5'd6) && (dx <= 5'd9);
    wire sun_on = s_ring || s_h || s_v || s_d;

    wire icon_on = in_box && in_icon_col && in_icon_row &&
                   (in_icon0 ? contrast_on : sun_on);

    // ------------------------------------------------ 文字区
    wire row_a = in_row0;
    wire [9:0] TEXT_X_U = TEXT_X;
    wire [9:0] NUM_X_U  = TEXT_X + NUM_DX;      // 两行共用，保证数字列对齐

    wire [9:0] lab_w = row_a ? (3 * 24) : LAB_W1;

    wire in_text = in_box && (in_row0 || in_row1) &&
                   (pixel_x >= TEXT_X_U) && (pixel_x < (NUM_X_U + 10'd96));

    wire [9:0] rel  = pixel_x - TEXT_X_U;
    wire [9:0] nrel = pixel_x - NUM_X_U;

    wire [9:0] lab_idx = (rel >= 10'd48) ? 10'd2 : (rel >= 10'd24) ? 10'd1 : 10'd0;
    wire [9:0] lab_col = rel - (lab_idx * 10'd24);

    wire [9:0] num_idx = (nrel >= 10'd72) ? 10'd3 :
                         (nrel >= 10'd48) ? 10'd2 :
                         (nrel >= 10'd24) ? 10'd1 : 10'd0;
    wire [9:0] num_col = nrel - (num_idx * 10'd24);

    wire       in_label = (rel < lab_w);
    wire [9:0] col      = in_label ? lab_col : num_col;

    // ------------------------------------------------ 字符选择
    wire [3:0] lvl = row_a ? contrast_lvl : bright_lvl;
    // v41：档位编码是 {方向, m[2:0]}，m=0 时无论方向位是什么幅度都是 0。
    //   旧写法只看方向位，SW=1000（-0 档）会显示成「-0%」，看着像故障。
    wire       neg = lvl[3] && (lvl[2:0] != 3'd0);
    wire [2:0] mag = lvl[2:0];

    reg [3:0] code;
    reg       slot_ok;

    always @* begin
        code    = 4'd0;
        slot_ok = 1'b0;
        if (in_label) begin
            slot_ok = 1'b1;
            if (row_a)
                code = (lab_idx == 10'd0) ? 4'd0 :      // 对
                       (lab_idx == 10'd1) ? 4'd1 :      // 比
                                            4'd2;       // 度
            else
                code = (lab_idx == 10'd0) ? 4'd3 :      // 亮
                                            4'd2;       // 度
        end else if (nrel < 10'd24) begin
            slot_ok = 1'b1;
            code    = neg ? 4'd14 : 4'd13;              // - / +
        end else if (nrel < 10'd48) begin
            // 十位槽：0 档时这里改放个位的 '0'
            slot_ok = 1'b1;
            code    = (mag != 3'd0) ? ({1'b0, mag} + 4'd4) : 4'd4;
        end else if (nrel < 10'd72) begin
            // 个位槽：0 档时这里改放 '%'
            slot_ok = 1'b1;
            code    = (mag != 3'd0) ? 4'd4 : 4'd12;
        end else begin
            // 末槽：0 档时留空
            slot_ok = (mag != 3'd0);
            code    = 4'd12;                            // %
        end
    end

    wire [23:0] glyph;
    bc_font_rom_24x24 u_bc_font_rom_24x24 (
        .char_code (code),
        .row       (trow[4:0]),
        .glyph     (glyph)
    );

    wire [4:0] col5   = (col < 10'd24) ? col[4:0] : 5'd0;
    wire       pix_on = (col < 10'd24) && glyph[5'd23 - col5];

    wire text_on = in_text && slot_ok && pix_on;

    // ------------------------------------------------ 背景：原图压暗 80%
    wire [7:0] r_in  = rgb_in[23:16];
    wire [7:0] g_in  = rgb_in[15:8];
    wire [7:0] b_in  = rgb_in[7:0];
    wire [7:0] r_dim = (r_in * DIM_K) >> 8;
    wire [7:0] g_dim = (g_in * DIM_K) >> 8;
    wire [7:0] b_dim = (b_in * DIM_K) >> 8;

    assign rgb_out = (text_on || icon_on) ? TEXT_RGB
                   : (in_box && on_border) ? BORDER_RGB
                   : in_box                ? {r_dim, g_dim, b_dim}
                                           : rgb_in;

endmodule
