`timescale 1ns/1ps

// ============================================================
// timestamp_osd_v2
// 第一阶段 OSD：系统运行时间 HH:MM:SS
//
// 与旧版本相比：
// 1) 不在像素路径执行 hour/10、hour%10 等运算；
// 2) 直接使用 timer 提供的 BCD 数字；
// 3) 修正字模左右位序，bit7 为最左侧像素；
// 4) 默认黑色文字，适合白色图片背景；
// 5) 不修改 HS/VS/DE，只修改 RGB。
// ============================================================
module timestamp_osd_v2 #(
    parameter integer TIMESTAMP_X = 556,
    parameter integer TIMESTAMP_Y = 16,
    parameter integer CHAR_W      = 8,
    parameter integer CHAR_H      = 16,
    parameter [23:0]  FONT_RGB    = 24'h000000
)(
    input            clk,
    input            rst,
    input            enable,

    input            vs,
    input            de,
    input      [23:0] rgb_in,

    input      [3:0]  hour_tens,
    input      [3:0]  hour_ones,
    input      [3:0]  minute_tens,
    input      [3:0]  minute_ones,
    input      [3:0]  second_tens,
    input      [3:0]  second_ones,

    output reg [23:0] rgb_out
);

    wire [9:0] pixel_x;
    wire [8:0] pixel_y;

    reg [3:0] char_code;
    wire [3:0] glyph_row;
    wire [2:0] glyph_col;
    wire [7:0] glyph;

    wire       in_timestamp_area;
    wire [7:0] rel_x;
    wire [3:0] char_index;
    wire       glyph_on;

    video_coord_gen_640x480 u_video_coord_gen (
        .clk      (clk),
        .rst      (rst),
        .vs       (vs),
        .de       (de),
        .pixel_x  (pixel_x),
        .pixel_y  (pixel_y)
    );

    assign in_timestamp_area = enable && de &&
                               (pixel_x >= TIMESTAMP_X) &&
                               (pixel_x < (TIMESTAMP_X + 8*CHAR_W)) &&
                               (pixel_y >= TIMESTAMP_Y) &&
                               (pixel_y < (TIMESTAMP_Y + CHAR_H));

    // 右移3位等价于 /8，避免除法器。
    assign rel_x      = pixel_x - TIMESTAMP_X[9:0];
    assign char_index = rel_x[6:3];
    assign glyph_col  = rel_x[2:0];
    assign glyph_row  = pixel_y - TIMESTAMP_Y[8:0];

    // 8个字符：HH:MM:SS，其中10代表冒号。
    always @* begin
        case (char_index)
            4'd0:    char_code = hour_tens;
            4'd1:    char_code = hour_ones;
            4'd2:    char_code = 4'd10;
            4'd3:    char_code = minute_tens;
            4'd4:    char_code = minute_ones;
            4'd5:    char_code = 4'd10;
            4'd6:    char_code = second_tens;
            4'd7:    char_code = second_ones;
            default: char_code = 4'd0;
        endcase
    end

    font_rom_numeric u_font_rom_numeric (
        .char_code (char_code),
        .row       (glyph_row),
        .glyph     (glyph)
    );

    // 字库定义 bit7 为左侧像素，因此这里使用 [7-glyph_col]。
    assign glyph_on = in_timestamp_area && glyph[7-glyph_col];

    always @* begin
        if (glyph_on)
            rgb_out = FONT_RGB;
        else
            rgb_out = rgb_in;
    end

endmodule
