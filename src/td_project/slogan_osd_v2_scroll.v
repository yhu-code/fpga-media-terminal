`timescale 1ns/1ps

// ============================================================
// slogan_osd_v2_scroll
// 第三阶段：当前图片对应的中文标语平滑横向滚动。
//
// 功能：
// 1) 保留第二阶段的四图四标语映射；
// 2) 每个视频帧移动 SCROLL_STEP 个像素，默认 1 pixel/frame；
// 3) 标语从屏幕右侧进入，向左平滑滚动，完全离屏后重新循环；
// 4) 底部使用固定黑色背景条，文字为白色，保证在白色图片上可见；
// 5) 图片切换后自动把新标语的起始位置重置到屏幕右侧；
// 6) 不修改 HS/VS/DE，只修改 RGB；
// 7) 转场期间由 enable=0 自动关闭字幕层。
//
// 四句标语：
//   0 -> 新品上市，全场特惠
//   1 -> 清凉一夏，第二杯半价
//   2 -> 感恩回馈，满100减20
//   3 -> 生鲜特惠，全场8折
//
// 注意：
//   当前采用整条黑色不透明背景带，暂不做 Alpha 混合。
//   第四阶段再把背景改成真正的半透明 Alpha Blend。
// ============================================================
module slogan_osd_v2_scroll #(
    parameter integer TEXT_Y       = 424,
    parameter integer CHAR_W       = 24,
    parameter integer CHAR_H       = 24,
    parameter integer BANNER_Y     = 419,
    parameter integer BANNER_H     = 34,
    parameter integer BANNER_W     = 640,
    parameter integer SCROLL_STEP  = 1,
    parameter integer START_X      = 640,
    parameter [23:0]  BG_RGB       = 24'h000000,
    parameter [23:0]  FONT_RGB     = 24'hFFFFFF
)(
    input               clk,
    input               rst,
    input               enable,
    input      [1:0]    image_index,
    input               vs,
    input               de,
    input      [23:0]   rgb_in,
    output reg [23:0]   rgb_out
);

wire [9:0] pixel_x;
wire [8:0] pixel_y;

// 四句标语的字符数：9、10、12、9。
reg [4:0] text_chars;
reg [9:0] text_width;

// scroll_x 使用有符号数：
// 640      -> 完全在屏幕右侧
// 0       -> 文本左边缘与屏幕左边重合
// -width  -> 文本完全离开屏幕左侧
reg signed [10:0] scroll_x;
reg [1:0] image_index_d;
reg       vs_d;

wire frame_start;
assign frame_start = vs_d & ~vs;

reg signed [11:0] rel_x_s;
reg [3:0]         char_index;
reg [4:0]         glyph_col;
wire [4:0]         glyph_row;
reg [5:0]         char_code;
wire [23:0]       glyph;

reg  in_banner_area;
reg in_text_area;
wire glyph_on;

video_coord_gen_640x480 u_video_coord_gen (
    .clk      (clk),
    .rst      (rst),
    .vs       (vs),
    .de       (de),
    .pixel_x  (pixel_x),
    .pixel_y  (pixel_y)
);

// ------------------------------------------------------------
// 当前图片对应文本长度
// ------------------------------------------------------------
always @* begin
    case (image_index)
        2'd0: begin
            text_chars = 5'd9;
            text_width = 10'd216;
        end
        2'd1: begin
            text_chars = 5'd10;
            text_width = 10'd240;
        end
        2'd2: begin
            text_chars = 5'd12;
            text_width = 10'd288;
        end
        2'd3: begin
            text_chars = 5'd9;
            text_width = 10'd216;
        end
        default: begin
            text_chars = 5'd9;
            text_width = 10'd216;
        end
    endcase
end

// ------------------------------------------------------------
// 滚动位置控制
// 只在帧边界更新一次，避免一个画面内字符跳位置。
// 图片编号变化时，重新从右侧进入。
// ------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scroll_x    <= START_X;
        image_index_d <= 2'd0;
        vs_d        <= 1'b0;
    end else begin
        vs_d <= vs;
        image_index_d <= image_index;

        // 图片已经真正切换到新图时，当前图片编号在 video_clk 域更新；
        // 新字幕从右边重新进入。
        if (image_index != image_index_d) begin
            scroll_x <= START_X;
        end else if (frame_start && enable) begin
            if (scroll_x <= -$signed({1'b0, text_width})) begin
                scroll_x <= START_X;
            end else begin
                scroll_x <= scroll_x - SCROLL_STEP;
            end
        end
    end
end

// ------------------------------------------------------------
// 字幕/背景区域
// 背景带固定在底部，文字本身做横向滚动。
// ------------------------------------------------------------
always @* begin
    in_banner_area = 1'b0;
    if (enable && de &&
        (pixel_y >= BANNER_Y) &&
        (pixel_y < (BANNER_Y + BANNER_H)) &&
        (pixel_x < BANNER_W)) begin
        in_banner_area = 1'b1;
    end
end

// 像素 X 相对于滚动文本左边缘的位置。
// 采用有符号运算，支持文本位于屏幕外的负 X 坐标。
always @* begin
    rel_x_s = $signed({2'b00, pixel_x}) - scroll_x;
end

always @* begin
    in_text_area = 1'b0;

    if (enable && de &&
        (pixel_y >= TEXT_Y) &&
        (pixel_y < (TEXT_Y + CHAR_H)) &&
        (rel_x_s >= 0) &&
        (rel_x_s < $signed({2'b00, text_width}))) begin
        in_text_area = 1'b1;
    end
end

// ------------------------------------------------------------
// 字符槽定位，不使用 /24。
// ------------------------------------------------------------
always @* begin
    char_index = 4'd15;
    if (in_text_area) begin
        if (rel_x_s < 12'd24)       char_index = 4'd0;
        else if (rel_x_s < 12'd48)  char_index = 4'd1;
        else if (rel_x_s < 12'd72)  char_index = 4'd2;
        else if (rel_x_s < 12'd96)  char_index = 4'd3;
        else if (rel_x_s < 12'd120) char_index = 4'd4;
        else if (rel_x_s < 12'd144) char_index = 4'd5;
        else if (rel_x_s < 12'd168) char_index = 4'd6;
        else if (rel_x_s < 12'd192) char_index = 4'd7;
        else if (rel_x_s < 12'd216) char_index = 4'd8;
        else if (rel_x_s < 12'd240) char_index = 4'd9;
        else if (rel_x_s < 12'd264) char_index = 4'd10;
        else if (rel_x_s < 12'd288) char_index = 4'd11;
    end
end

always @* begin
    case (char_index)
        4'd0:  glyph_col = rel_x_s - 12'd0;
        4'd1:  glyph_col = rel_x_s - 12'd24;
        4'd2:  glyph_col = rel_x_s - 12'd48;
        4'd3:  glyph_col = rel_x_s - 12'd72;
        4'd4:  glyph_col = rel_x_s - 12'd96;
        4'd5:  glyph_col = rel_x_s - 12'd120;
        4'd6:  glyph_col = rel_x_s - 12'd144;
        4'd7:  glyph_col = rel_x_s - 12'd168;
        4'd8:  glyph_col = rel_x_s - 12'd192;
        4'd9:  glyph_col = rel_x_s - 12'd216;
        4'd10: glyph_col = rel_x_s - 12'd240;
        4'd11: glyph_col = rel_x_s - 12'd264;
        default: glyph_col = 5'd0;
    endcase
end

assign glyph_row = pixel_y - TEXT_Y;

// ------------------------------------------------------------
// 当前图片对应的文字编码
// char_code 直接对应 slogan_font_rom_24x24.v。
// ------------------------------------------------------------
always @* begin
    char_code = 6'd63;

    if (in_text_area) begin
        case (image_index)
            2'd0: begin // 新品上市，全场特惠
                case (char_index)
                    4'd0: char_code = 6'd0;   // 新
                    4'd1: char_code = 6'd1;   // 品
                    4'd2: char_code = 6'd2;   // 上
                    4'd3: char_code = 6'd3;   // 市
                    4'd4: char_code = 6'd26;  // ，
                    4'd5: char_code = 6'd4;   // 全
                    4'd6: char_code = 6'd5;   // 场
                    4'd7: char_code = 6'd6;   // 特
                    4'd8: char_code = 6'd7;   // 惠
                    default: char_code = 6'd63;
                endcase
            end

            2'd1: begin // 清凉一夏，第二杯半价
                case (char_index)
                    4'd0: char_code = 6'd8;   // 清
                    4'd1: char_code = 6'd9;   // 凉
                    4'd2: char_code = 6'd10;  // 一
                    4'd3: char_code = 6'd11;  // 夏
                    4'd4: char_code = 6'd26;  // ，
                    4'd5: char_code = 6'd12;  // 第
                    4'd6: char_code = 6'd13;  // 二
                    4'd7: char_code = 6'd14;  // 杯
                    4'd8: char_code = 6'd15;  // 半
                    4'd9: char_code = 6'd16;  // 价
                    default: char_code = 6'd63;
                endcase
            end

            2'd2: begin // 感恩回馈，满100减20
                case (char_index)
                    4'd0:  char_code = 6'd17;  // 感
                    4'd1:  char_code = 6'd18;  // 恩
                    4'd2:  char_code = 6'd19;  // 回
                    4'd3:  char_code = 6'd20;  // 馈
                    4'd4:  char_code = 6'd26;  // ，
                    4'd5:  char_code = 6'd21;  // 满
                    4'd6:  char_code = 6'd28;  // 1
                    4'd7:  char_code = 6'd27;  // 0
                    4'd8:  char_code = 6'd27;  // 0
                    4'd9:  char_code = 6'd22;  // 减
                    4'd10: char_code = 6'd29;  // 2
                    4'd11: char_code = 6'd27;  // 0
                    default: char_code = 6'd63;
                endcase
            end

            2'd3: begin // 生鲜特惠，全场8折
                case (char_index)
                    4'd0: char_code = 6'd23;  // 生
                    4'd1: char_code = 6'd24;  // 鲜
                    4'd2: char_code = 6'd6;   // 特
                    4'd3: char_code = 6'd7;   // 惠
                    4'd4: char_code = 6'd26;  // ，
                    4'd5: char_code = 6'd4;   // 全
                    4'd6: char_code = 6'd5;   // 场
                    4'd7: char_code = 6'd35;  // 8
                    4'd8: char_code = 6'd25;  // 折
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

// ------------------------------------------------------------
// RGB输出：
// 先画固定背景带，再画移动的白色文字。
// ------------------------------------------------------------
always @* begin
    if (!de)
        rgb_out = 24'd0;
    else if (in_banner_area)
        rgb_out = BG_RGB;
    else
        rgb_out = rgb_in;

    if (glyph_on)
        rgb_out = FONT_RGB;
end

endmodule
