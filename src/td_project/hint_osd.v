`timescale 1ns/1ps

// ============================================================
// hint_osd —— S1 轮播状态浮字提示
//
// 位置：左上角参数面板（B/C 两行，x=16..68）的**右边**，x=72 起，4 个字 x 24px
// 颜色：纯白 24'hFFFFFF
// 内容：mode=0 -> 开始轮播（字模 0,1,2,3）
//       mode=1 -> 解除轮播（字模 4,5,2,3）
// 显示时长由顶层计时器给 enable（当前 1 秒），本模块只管"开/关"。
// ============================================================
module hint_osd #(
    parameter integer X0       = 72,        // 面板 x=16..68，这里从 72 开始
    parameter integer Y0       = 10,        // 面板高 44，24px 字垂直居中 -> 10..34
    parameter integer CHAR_W   = 24,
    parameter integer CHAR_H   = 24,
    parameter [23:0]  TEXT_RGB = 24'hFFFFFF
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,       // 1 = 显示（顶层已限时）
    input  wire       vs,
    input  wire       de,
    input  wire [23:0] rgb_in,
    input  wire       mode,         // 0 = 开始轮播, 1 = 解除轮播
    output wire [23:0] rgb_out
);

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

    wire in_area = enable && de &&
                   (pixel_x >= X0) && (pixel_x < (X0 + 4 * CHAR_W)) &&
                   (pixel_y >= Y0) && (pixel_y < (Y0 + CHAR_H));

    localparam [9:0] X0_U = X0[9:0];
    localparam [8:0] Y0_U = Y0[8:0];

    wire [9:0] rel_x = pixel_x - X0_U;
    wire [8:0] rel_y = pixel_y - Y0_U;

    // 字符槽：0..3，每格 24px（用比较链，避免除法器）
    reg [1:0] slot;
    always @* begin
        if      (rel_x < 10'd24) slot = 2'd0;
        else if (rel_x < 10'd48) slot = 2'd1;
        else if (rel_x < 10'd72) slot = 2'd2;
        else                     slot = 2'd3;
    end

    // 槽内列号：rel_x - slot*24 = rel_x - ((slot<<4)+(slot<<3))
    wire [9:0] slot_off = ({8'd0, slot} << 4) + ({8'd0, slot} << 3);
    wire [5:0] col      = rel_x - slot_off;      // 0..23

    // 字模编号：轮/播 两个位置固定，第一个和第二个按 mode 选
    reg [2:0] code;
    always @* begin
        case (slot)
            2'd0:    code = mode ? 3'd4 : 3'd0;   // 开 / 解
            2'd1:    code = mode ? 3'd5 : 3'd1;   // 始 / 除
            2'd2:    code = 3'd2;                 // 轮
            default: code = 3'd3;                 // 播
        endcase
    end

    wire [23:0] glyph;
    hint_font_rom_24x24 u_hint_font_rom_24x24 (
        .char_code (code),
        .row       (rel_y[4:0]),
        .glyph     (glyph)
    );

    // bit23 = 最左像素。col 越界时先钳到 0，避免动态位选下溢
    wire [4:0] col_c  = (col < 6'd24) ? col[4:0] : 5'd0;
    wire       pix_on = (col < 6'd24) && glyph[5'd23 - col_c];

    assign rgb_out = (in_area && pix_on) ? TEXT_RGB : rgb_in;

endmodule
