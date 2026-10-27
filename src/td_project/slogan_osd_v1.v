`timescale 1ns/1ps

// ============================================================
// slogan_osd_v1
// 第二阶段：四张图片对应四句固定中文标语。
// 24x24 点阵、底部居中、黑色背景条、白色文字。
// 不修改 HS/VS/DE，只修改 RGB。
// 转场期间由 enable=0 自动关闭。
// ============================================================
module slogan_osd_v1 #(
    parameter integer TEXT_Y    = 424,
    parameter integer CHAR_W    = 24,
    parameter integer CHAR_H    = 24,
    parameter integer PAD_X     = 8,
    parameter integer PAD_Y     = 5,
    parameter [23:0]  BG_RGB    = 24'h000000,
    parameter [23:0]  FONT_RGB  = 24'hFFFFFF
)(
    input               clk,
    input               rst,
    input               enable,
    input      [1:0]    image_index,
    input               vs,
    input               de,
    input      [23:0]  rgb_in,
    output reg [23:0]  rgb_out
);

wire [9:0] pixel_x;
wire [8:0] pixel_y;
reg  [9:0] slogan_x_start;
reg  [9:0] slogan_width;
reg  [3:0] char_index;
reg  [5:0] char_code;
wire  [9:0] rel_x;
reg  [4:0] glyph_col;
wire  [4:0] glyph_row;
wire [23:0] glyph;
wire in_text_area;
wire in_bg_area;
wire glyph_on;

video_coord_gen_640x480 u_video_coord_gen (
    .clk      (clk),
    .rst      (rst),
    .vs       (vs),
    .de       (de),
    .pixel_x  (pixel_x),
    .pixel_y  (pixel_y)
);

// 四句标语长度：9、10、12、9 个 24x24 字符格。
// 预先计算宽度与居中 X，避免像素路径中的乘法/除法。
always @* begin
    case (image_index)
        2'd0: begin slogan_width = 10'd216; slogan_x_start = 10'd212; end
        2'd1: begin slogan_width = 10'd240; slogan_x_start = 10'd200; end
        2'd2: begin slogan_width = 10'd288; slogan_x_start = 10'd176; end
        2'd3: begin slogan_width = 10'd216; slogan_x_start = 10'd212; end
        default: begin slogan_width = 10'd216; slogan_x_start = 10'd212; end
    endcase
end

assign in_text_area = enable && de &&
                      (pixel_x >= slogan_x_start) &&
                      (pixel_x < (slogan_x_start + slogan_width)) &&
                      (pixel_y >= TEXT_Y) &&
                      (pixel_y < (TEXT_Y + CHAR_H));

assign in_bg_area = enable && de &&
                    (pixel_x >= (slogan_x_start - PAD_X)) &&
                    (pixel_x < (slogan_x_start + slogan_width + PAD_X)) &&
                    (pixel_y >= (TEXT_Y - PAD_Y)) &&
                    (pixel_y < (TEXT_Y + CHAR_H + PAD_Y));

assign rel_x = pixel_x - slogan_x_start;

// 字符槽按 24 像素分段，不使用 /24。
always @* begin
    char_index = 4'd15;
    if (in_text_area) begin
        if (rel_x < 10'd24) char_index = 4'd0;
        else if (rel_x < 10'd48) char_index = 4'd1;
        else if (rel_x < 10'd72) char_index = 4'd2;
        else if (rel_x < 10'd96) char_index = 4'd3;
        else if (rel_x < 10'd120) char_index = 4'd4;
        else if (rel_x < 10'd144) char_index = 4'd5;
        else if (rel_x < 10'd168) char_index = 4'd6;
        else if (rel_x < 10'd192) char_index = 4'd7;
        else if (rel_x < 10'd216) char_index = 4'd8;
        else if (rel_x < 10'd240) char_index = 4'd9;
        else if (rel_x < 10'd264) char_index = 4'd10;
        else if (rel_x < 10'd288) char_index = 4'd11;
    end
end

// 由字符编号求 0~23 的字内列坐标，避免乘法。
always @* begin
    case (char_index)
        4'd0: glyph_col = rel_x - 10'd0;
        4'd1: glyph_col = rel_x - 10'd24;
        4'd2: glyph_col = rel_x - 10'd48;
        4'd3: glyph_col = rel_x - 10'd72;
        4'd4: glyph_col = rel_x - 10'd96;
        4'd5: glyph_col = rel_x - 10'd120;
        4'd6: glyph_col = rel_x - 10'd144;
        4'd7: glyph_col = rel_x - 10'd168;
        4'd8: glyph_col = rel_x - 10'd192;
        4'd9: glyph_col = rel_x - 10'd216;
        4'd10: glyph_col = rel_x - 10'd240;
        4'd11: glyph_col = rel_x - 10'd264;
        default: glyph_col = 5'd0;
    endcase
end

assign glyph_row = pixel_y - TEXT_Y;

// 当前图片对应的固定标语字符。
always @* begin
    char_code = 6'd63;
    if (in_text_area) begin
        case (image_index)
            2'd0: begin // 新品上市，全场特惠
                case (char_index)
                    4'd0: char_code = 6'd0;
                    4'd1: char_code = 6'd1;
                    4'd2: char_code = 6'd2;
                    4'd3: char_code = 6'd3;
                    4'd4: char_code = 6'd26;
                    4'd5: char_code = 6'd4;
                    4'd6: char_code = 6'd5;
                    4'd7: char_code = 6'd6;
                    4'd8: char_code = 6'd7;
                    default: char_code = 6'd63;
                endcase
            end
            2'd1: begin // 清凉一夏，第二杯半价
                case (char_index)
                    4'd0: char_code = 6'd8;
                    4'd1: char_code = 6'd9;
                    4'd2: char_code = 6'd10;
                    4'd3: char_code = 6'd11;
                    4'd4: char_code = 6'd26;
                    4'd5: char_code = 6'd12;
                    4'd6: char_code = 6'd13;
                    4'd7: char_code = 6'd14;
                    4'd8: char_code = 6'd15;
                    4'd9: char_code = 6'd16;
                    default: char_code = 6'd63;
                endcase
            end
            2'd2: begin // 感恩回馈，满100减20
                case (char_index)
                    4'd0: char_code = 6'd17;
                    4'd1: char_code = 6'd18;
                    4'd2: char_code = 6'd19;
                    4'd3: char_code = 6'd20;
                    4'd4: char_code = 6'd26;
                    4'd5: char_code = 6'd21;
                    4'd6: char_code = 6'd28;
                    4'd7: char_code = 6'd27;
                    4'd8: char_code = 6'd27;
                    4'd9: char_code = 6'd22;
                    4'd10: char_code = 6'd29;
                    4'd11: char_code = 6'd27;
                    default: char_code = 6'd63;
                endcase
            end
            2'd3: begin // 生鲜特惠，全场8折
                case (char_index)
                    4'd0: char_code = 6'd23;
                    4'd1: char_code = 6'd24;
                    4'd2: char_code = 6'd6;
                    4'd3: char_code = 6'd7;
                    4'd4: char_code = 6'd26;
                    4'd5: char_code = 6'd4;
                    4'd6: char_code = 6'd5;
                    4'd7: char_code = 6'd35;
                    4'd8: char_code = 6'd25;
                    default: char_code = 6'd63;
                endcase
            end
            default: char_code = 6'd63;
        endcase
    end
end

slogan_font_rom_24x24 u_slogan_font_rom (
    .char_code (char_code),
    .row       (glyph_row),
    .glyph     (glyph)
);

assign glyph_on = in_text_area && glyph[23-glyph_col];

always @* begin
    if (!de)
        rgb_out = 24'd0;
    else if (in_bg_area)
        rgb_out = BG_RGB;
    else
        rgb_out = rgb_in;

    if (glyph_on)
        rgb_out = FONT_RGB;
end

endmodule