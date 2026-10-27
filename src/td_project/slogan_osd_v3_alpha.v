`timescale 1ns/1ps

// ============================================================
// slogan_osd_v3_alpha
// 底部字幕条：半透明黑色底带 + 白色 24x24 字模横向滚动。
//
// 本版改动（相对四句促销标语）：
//   1) 文案换成四条历史事件，最长 29 字（696px > 640px），
//      字符槽从 12 个扩展到 29 个，char_index 由 4bit 扩到 5bit；
//   2) 字符槽偏移不再用 case 展开减法，改为 char_index*24 = (n<<4)+(n<<3)；
//   3) 字模库换成新生成的 60 字表（slogan_font_rom_24x24.v）。
//
// 文案与字模均由 test_bmp/gen_slogan_font.py 自动生成，请勿手工改映射表。
// ============================================================
module slogan_osd_v3_alpha #(
    parameter integer TEXT_Y       = 424,
    parameter integer CHAR_W       = 24,
    parameter integer CHAR_H       = 24,
    parameter integer BANNER_Y     = 419,
    parameter integer BANNER_H     = 34,
    parameter integer BANNER_W     = 640,
    parameter integer SCROLL_STEP  = 1,
    parameter integer START_X      = 640,
    parameter [23:0]  BG_RGB       = 24'h000000,
    parameter integer BG_ALPHA     = 8,
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

// 当前图片对应文本的像素宽度（字符数 * 24）
reg [9:0] text_width;

// scroll_x 为有符号数：
//   START_X -> 完全在屏幕右侧
//   0       -> 文本左边缘与屏幕左边重合
//   -width  -> 文本完全离去屏幕左侧
reg signed [10:0] scroll_x;
reg [1:0] image_index_d;
reg       vs_d;

wire frame_start;
assign frame_start = vs_d & ~vs;

reg signed [11:0] rel_x_s;
wire [4:0]        char_index;
wire [4:0]        glyph_col;
wire [4:0]        glyph_row;
reg [5:0]         char_code;
wire [23:0]       glyph;

reg  in_banner_area;
reg  in_text_area;
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
// 每条文案的像素宽度
// ------------------------------------------------------------
always @* begin
    case (image_index)
        2'd0:    text_width = 10'd624;   // 26 字
        2'd1:    text_width = 10'd576;   // 24 字
        2'd2:    text_width = 10'd648;   // 27 字
        2'd3:    text_width = 10'd696;   // 29 字
        default: text_width = 10'd624;
    endcase
end

// ------------------------------------------------------------
// 滚动位置：只在帧边界更新，图片切换时重置到屏幕右侧
// ------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scroll_x     <= START_X;
        image_index_d <= 2'd0;
        vs_d         <= 1'b0;
    end else begin
        vs_d         <= vs;
        image_index_d <= image_index;

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
// 底带区域 / 文字区域
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
// 字符槽定位：char_index = rel_x / 24
//   24 = 8*3，所以先右移 3 位得 q8 = rel_x/8，再算 q8/3。
//   q8/3 用 (q8*86)>>8 近似，已穷举验证 rel_x 0..719 与整除结果全等。
//   相比 29 级比较链：逻辑深度 29 -> 3 级，面积也小得多。
//   （v28 首版用比较链，布线后 scroll_x -> rgb_out 27 级逻辑 39.5ns，
//    只剩 0.221ns 余量，改此算法后余量回到安全区。）
// ------------------------------------------------------------
wire [8:0]  slot_q8  = rel_x_s[11:3];       // 0..86
wire [13:0] slot_mul = slot_q8 * 7'd86;     // 0..7396，13bit
assign char_index = in_text_area ? slot_mul[12:8] : 5'd31;

// 槽内偏移：char_index * 24 = (n<<4) + (n<<3)
wire [9:0] slot_off = ({5'd0, char_index} << 4) + ({5'd0, char_index} << 3);
wire [9:0] gcol_raw = rel_x_s[9:0] - slot_off;

// 钳位到 0..23：char_index 取到越界哨兵(31)时 gcol_raw 会下溢成
// 大数，而 glyph[23-glyph_col] 的位索引不能为负（仿真会出 x，
// 综合行为未定义）。此时 in_text_area=0、glyph_on 恒 0，取哪一位
// 都不影响显示，钳位只是消除这个未定义访问。
assign glyph_col = (gcol_raw > 10'd23) ? 5'd23 : gcol_raw[4:0];

assign glyph_row = pixel_y - TEXT_Y;

// ------------------------------------------------------------
// 文案 -> 字模编码（由 gen_slogan_font.py 生成）
// ------------------------------------------------------------
always @* begin
    char_code = 6'd63;               // 63 超出字库，ROM 输出空白
    if (in_text_area) begin
        case (image_index)
            2'd0: begin // 1970年4月24日，中国首颗“东方红一号”发射成功
                case (char_index)
                    5'd0 : char_code = 6'd0 ;  // 1
                    5'd1 : char_code = 6'd1 ;  // 9
                    5'd2 : char_code = 6'd2 ;  // 7
                    5'd3 : char_code = 6'd3 ;  // 0
                    5'd4 : char_code = 6'd4 ;  // 年
                    5'd5 : char_code = 6'd5 ;  // 4
                    5'd6 : char_code = 6'd6 ;  // 月
                    5'd7 : char_code = 6'd7 ;  // 2
                    5'd8 : char_code = 6'd5 ;  // 4
                    5'd9 : char_code = 6'd8 ;  // 日
                    5'd10: char_code = 6'd9 ;  // ，
                    5'd11: char_code = 6'd10;  // 中
                    5'd12: char_code = 6'd11;  // 国
                    5'd13: char_code = 6'd12;  // 首
                    5'd14: char_code = 6'd13;  // 颗
                    5'd15: char_code = 6'd14;  // “
                    5'd16: char_code = 6'd15;  // 东
                    5'd17: char_code = 6'd16;  // 方
                    5'd18: char_code = 6'd17;  // 红
                    5'd19: char_code = 6'd18;  // 一
                    5'd20: char_code = 6'd19;  // 号
                    5'd21: char_code = 6'd20;  // ”
                    5'd22: char_code = 6'd21;  // 发
                    5'd23: char_code = 6'd22;  // 射
                    5'd24: char_code = 6'd23;  // 成
                    5'd25: char_code = 6'd24;  // 功
                    default: char_code = 6'd63;
                endcase
            end
            2'd1: begin // 2003年10月15日，神舟五号首次载人飞行成功
                case (char_index)
                    5'd0 : char_code = 6'd7 ;  // 2
                    5'd1 : char_code = 6'd3 ;  // 0
                    5'd2 : char_code = 6'd3 ;  // 0
                    5'd3 : char_code = 6'd25;  // 3
                    5'd4 : char_code = 6'd4 ;  // 年
                    5'd5 : char_code = 6'd0 ;  // 1
                    5'd6 : char_code = 6'd3 ;  // 0
                    5'd7 : char_code = 6'd6 ;  // 月
                    5'd8 : char_code = 6'd0 ;  // 1
                    5'd9 : char_code = 6'd26;  // 5
                    5'd10: char_code = 6'd8 ;  // 日
                    5'd11: char_code = 6'd9 ;  // ，
                    5'd12: char_code = 6'd27;  // 神
                    5'd13: char_code = 6'd28;  // 舟
                    5'd14: char_code = 6'd29;  // 五
                    5'd15: char_code = 6'd19;  // 号
                    5'd16: char_code = 6'd12;  // 首
                    5'd17: char_code = 6'd30;  // 次
                    5'd18: char_code = 6'd31;  // 载
                    5'd19: char_code = 6'd32;  // 人
                    5'd20: char_code = 6'd33;  // 飞
                    5'd21: char_code = 6'd34;  // 行
                    5'd22: char_code = 6'd23;  // 成
                    5'd23: char_code = 6'd24;  // 功
                    default: char_code = 6'd63;
                endcase
            end
            2'd2: begin // 2022年11月3日，梦天转位，空间站“T”字构型完成
                case (char_index)
                    5'd0 : char_code = 6'd7 ;  // 2
                    5'd1 : char_code = 6'd3 ;  // 0
                    5'd2 : char_code = 6'd7 ;  // 2
                    5'd3 : char_code = 6'd7 ;  // 2
                    5'd4 : char_code = 6'd4 ;  // 年
                    5'd5 : char_code = 6'd0 ;  // 1
                    5'd6 : char_code = 6'd0 ;  // 1
                    5'd7 : char_code = 6'd6 ;  // 月
                    5'd8 : char_code = 6'd25;  // 3
                    5'd9 : char_code = 6'd8 ;  // 日
                    5'd10: char_code = 6'd9 ;  // ，
                    5'd11: char_code = 6'd35;  // 梦
                    5'd12: char_code = 6'd36;  // 天
                    5'd13: char_code = 6'd37;  // 转
                    5'd14: char_code = 6'd38;  // 位
                    5'd15: char_code = 6'd9 ;  // ，
                    5'd16: char_code = 6'd39;  // 空
                    5'd17: char_code = 6'd40;  // 间
                    5'd18: char_code = 6'd41;  // 站
                    5'd19: char_code = 6'd14;  // “
                    5'd20: char_code = 6'd42;  // T
                    5'd21: char_code = 6'd20;  // ”
                    5'd22: char_code = 6'd43;  // 字
                    5'd23: char_code = 6'd44;  // 构
                    5'd24: char_code = 6'd45;  // 型
                    5'd25: char_code = 6'd46;  // 完
                    5'd26: char_code = 6'd23;  // 成
                    default: char_code = 6'd63;
                endcase
            end
            2'd3: begin // 2026年8月19日，朱雀三号遥二发射，一子级成功陆地回收
                case (char_index)
                    5'd0 : char_code = 6'd7 ;  // 2
                    5'd1 : char_code = 6'd3 ;  // 0
                    5'd2 : char_code = 6'd7 ;  // 2
                    5'd3 : char_code = 6'd47;  // 6
                    5'd4 : char_code = 6'd4 ;  // 年
                    5'd5 : char_code = 6'd48;  // 8
                    5'd6 : char_code = 6'd6 ;  // 月
                    5'd7 : char_code = 6'd0 ;  // 1
                    5'd8 : char_code = 6'd1 ;  // 9
                    5'd9 : char_code = 6'd8 ;  // 日
                    5'd10: char_code = 6'd9 ;  // ，
                    5'd11: char_code = 6'd49;  // 朱
                    5'd12: char_code = 6'd50;  // 雀
                    5'd13: char_code = 6'd51;  // 三
                    5'd14: char_code = 6'd19;  // 号
                    5'd15: char_code = 6'd52;  // 遥
                    5'd16: char_code = 6'd53;  // 二
                    5'd17: char_code = 6'd21;  // 发
                    5'd18: char_code = 6'd22;  // 射
                    5'd19: char_code = 6'd9 ;  // ，
                    5'd20: char_code = 6'd18;  // 一
                    5'd21: char_code = 6'd54;  // 子
                    5'd22: char_code = 6'd55;  // 级
                    5'd23: char_code = 6'd23;  // 成
                    5'd24: char_code = 6'd24;  // 功
                    5'd25: char_code = 6'd56;  // 陆
                    5'd26: char_code = 6'd57;  // 地
                    5'd27: char_code = 6'd58;  // 回
                    5'd28: char_code = 6'd59;  // 收
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
// Alpha 混合：黑色底带与原图混合，白色文字再叠在上面（不透明）
// ------------------------------------------------------------
wire [23:0] banner_rgb;

osd_alpha_blend #(
    .ALPHA (BG_ALPHA)
) u_banner_alpha_blend (
    .bg_rgb  (rgb_in),
    .fg_rgb  (BG_RGB),
    .out_rgb (banner_rgb)
);

always @* begin
    if (!de)
        rgb_out = 24'd0;
    else if (in_banner_area)
        rgb_out = banner_rgb;
    else
        rgb_out = rgb_in;

    if (glyph_on)
        rgb_out = FONT_RGB;
end

endmodule
