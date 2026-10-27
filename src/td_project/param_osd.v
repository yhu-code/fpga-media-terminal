`timescale 1ns/1ps

// ============================================================
// param_osd —— 亮度/对比度 OSD（扩展要求 4）
//
// v25：把「进度条 + 档位数字」改成「百分比」，占位从 152x64 缩到 52x64。
//      百分比以 100% 为基准（原始画面）：+7 档 = 170%，-7 档 = 30%。
// v29：去掉第三行「S 缩放模式」（该值由 640x480 显示链固定为 1，没有信息量），
//      面板高度 64 -> 44。
//
// 左上角透明叠加（无底框、无压暗、无描边），两行：
//   行0：B 170%      亮度
//   行1：C 100%      对比度
//
// 档位 -> 百分比：
//   bright_lvl[3] = 符号位（0 = +，1 = -），bright_lvl[2:0] = 幅度 0~7（每档 10%）
//   百分比 = (10 ± 幅度) × 10  => 30 ~ 170
//   因为步长固定 10%，个位恒为 0，只需显示「百位（满 100 才画）+ 十位 + '0' + '%'」。
//
// 字模：数字复用 font_rom_numeric（0~9 / ':'），B / C / S / % 在本模块内补 8x16 点阵。
// 不修改 HS/VS/DE，只替换 RGB。
// ============================================================
module param_osd #(
    parameter integer PANEL_X    = 16,
    parameter integer PANEL_Y    = 32,
    parameter integer PANEL_W    = 52,
    parameter integer PANEL_H    = 44,
    parameter integer LABEL_X    = 4,      // 相对面板左上角
    parameter integer VALUE_X    = 16,     // 相对面板左上角（4 个 8px 槽）
    parameter [23:0]  TEXT_RGB   = 24'hFFFFFF
)(
    input            clk,
    input            rst,
    input            enable,

    input            vs,
    input            de,
    input      [23:0] rgb_in,

    input      [3:0]  bright_lvl,
    input      [3:0]  contrast_lvl,

    output reg [23:0] rgb_out
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

    // ---------------- 面板区域 ----------------
    wire in_panel = enable && de &&
                    (pixel_x >= PANEL_X) && (pixel_x < (PANEL_X + PANEL_W)) &&
                    (pixel_y >= PANEL_Y) && (pixel_y < (PANEL_Y + PANEL_H));

    wire [8:0] rel_x = pixel_x - PANEL_X;
    wire [7:0] rel_y = pixel_y - PANEL_Y;

    // ---------------- 三行文字 ----------------
    wire in_row0 = (rel_y >= 8'd4)  && (rel_y < 8'd20);
    wire in_row1 = (rel_y >= 8'd24) && (rel_y < 8'd40);
    wire in_text_row = in_row0 || in_row1;

    wire       row_sel  = in_row1;                       // 0 = B 行，1 = C 行
    wire [7:0] row_base = row_sel ? 8'd24 : 8'd4;
    wire [3:0] glyph_row = rel_y - row_base;

    // 字符槽：字模列号相对各自槽起点计算（不能直接用 rel_x[2:0]，
    // 否则不是 8 的倍数时会把字模左右两半对调撕裂）。
    localparam [8:0] LBL_X9 = LABEL_X;
    localparam [8:0] VAL_X9 = VALUE_X;

    wire in_s0 = (rel_x >= LBL_X9)        && (rel_x < (LBL_X9 + 9'd8));
    wire in_v0 = (rel_x >= VAL_X9)        && (rel_x < (VAL_X9 + 9'd8));
    wire in_v1 = (rel_x >= (VAL_X9 + 9'd8))  && (rel_x < (VAL_X9 + 9'd16));
    wire in_v2 = (rel_x >= (VAL_X9 + 9'd16)) && (rel_x < (VAL_X9 + 9'd24));
    wire in_v3 = (rel_x >= (VAL_X9 + 9'd24)) && (rel_x < (VAL_X9 + 9'd32));

    wire [8:0] gc0 = rel_x - LBL_X9;
    wire [8:0] gc1 = rel_x - VAL_X9;
    wire [8:0] gc2 = rel_x - (VAL_X9 + 9'd8);
    wire [8:0] gc3 = rel_x - (VAL_X9 + 9'd16);
    wire [8:0] gc4 = rel_x - (VAL_X9 + 9'd24);

    wire [2:0] glyph_col = in_s0 ? gc0[2:0] :
                           in_v0 ? gc1[2:0] :
                           in_v1 ? gc2[2:0] :
                           in_v2 ? gc3[2:0] :
                                   gc4[2:0];

    // ---------------- 档位 -> 百分比 ----------------
    // u = 百分比 / 10，范围 3..17（即 30%~170%）
    wire [4:0] b_u = bright_lvl[3]   ? (5'd10 - {2'b0, bright_lvl[2:0]})
                                     : (5'd10 + {2'b0, bright_lvl[2:0]});
    wire [4:0] c_u = contrast_lvl[3] ? (5'd10 - {2'b0, contrast_lvl[2:0]})
                                     : (5'd10 + {2'b0, contrast_lvl[2:0]});

    wire       b_h = (b_u >= 5'd10);                 // 是否有百位（>=100%）
    wire       c_h = (c_u >= 5'd10);
    wire [4:0] b_t5 = b_h ? (b_u - 5'd10) : b_u;     // 十位数字
    wire [4:0] c_t5 = c_h ? (c_u - 5'd10) : c_u;

    wire [3:0] b_t = b_t5[3:0];
    wire [3:0] c_t = c_t5[3:0];

    // ---------------- 字符选择 ----------------
    // 5 位：11=B 12=C 16='%'，4 位放不下 16
    reg  [4:0] char_code;
    reg        slot_valid;

    always @* begin
        char_code  = 4'd0;
        slot_valid = 1'b0;
        if (in_s0) begin
            slot_valid = 1'b1;
            char_code  = row_sel ? 4'd12 : 4'd11;           // C / B
        end else if (in_v0) begin
            // 百位：只有 >=100% 才画，否则留空（"90%"而不是"090%"）
            if (row_sel ? c_h : b_h) begin
                slot_valid = 1'b1;
                char_code  = 4'd1;
            end
        end else if (in_v1) begin
            slot_valid = 1'b1;
            char_code  = row_sel ? c_t : b_t;
        end else if (in_v2) begin
            slot_valid = 1'b1;
            char_code  = 4'd0;                              // 步长 10%，个位恒 0
        end else if (in_v3) begin
            slot_valid = 1'b1;
            char_code  = 5'd16;                             // %
        end
    end

    // ---------------- 字模 ----------------
    wire [7:0] glyph_num;
    reg  [7:0] glyph_ext;

    font_rom_numeric u_font_rom_numeric (
        .char_code (char_code[3:0]),
        .row       (glyph_row),
        .glyph     (glyph_num)
    );

    // 11='B' 12='C' 16='%'
    always @* begin
        case (char_code)
            5'd11: begin   // B
                case (glyph_row)
                    4'd0 : glyph_ext = 8'b11111100;
                    4'd1 : glyph_ext = 8'b11111110;
                    4'd2 : glyph_ext = 8'b11000111;
                    4'd3 : glyph_ext = 8'b11000111;
                    4'd4 : glyph_ext = 8'b11000111;
                    4'd5 : glyph_ext = 8'b11000111;
                    4'd6 : glyph_ext = 8'b11111100;
                    4'd7 : glyph_ext = 8'b11111100;
                    4'd8 : glyph_ext = 8'b11000111;
                    4'd9 : glyph_ext = 8'b11000111;
                    4'd10: glyph_ext = 8'b11000111;
                    4'd11: glyph_ext = 8'b11000111;
                    4'd12: glyph_ext = 8'b11000111;
                    4'd13: glyph_ext = 8'b11111110;
                    4'd14: glyph_ext = 8'b11111100;
                    default: glyph_ext = 8'b00000000;
                endcase
            end
            5'd12: begin   // C
                case (glyph_row)
                    4'd0 : glyph_ext = 8'b00111100;
                    4'd1 : glyph_ext = 8'b01111110;
                    4'd2 : glyph_ext = 8'b11000111;
                    4'd3 : glyph_ext = 8'b11000011;
                    4'd4 : glyph_ext = 8'b11000000;
                    4'd5 : glyph_ext = 8'b11000000;
                    4'd6 : glyph_ext = 8'b11000000;
                    4'd7 : glyph_ext = 8'b11000000;
                    4'd8 : glyph_ext = 8'b11000000;
                    4'd9 : glyph_ext = 8'b11000000;
                    4'd10: glyph_ext = 8'b11000000;
                    4'd11: glyph_ext = 8'b11000011;
                    4'd12: glyph_ext = 8'b11000111;
                    4'd13: glyph_ext = 8'b01111110;
                    4'd14: glyph_ext = 8'b00111100;
                    default: glyph_ext = 8'b00000000;
                endcase
            end
            5'd16: begin   // %
                case (glyph_row)
                    4'd0 : glyph_ext = 8'b11100000;
                    4'd1 : glyph_ext = 8'b10100000;
                    4'd2 : glyph_ext = 8'b11100110;
                    4'd3 : glyph_ext = 8'b00001100;
                    4'd4 : glyph_ext = 8'b00011000;
                    4'd5 : glyph_ext = 8'b00110000;
                    4'd6 : glyph_ext = 8'b01100111;
                    4'd7 : glyph_ext = 8'b11000101;
                    4'd8 : glyph_ext = 8'b00000111;
                    default: glyph_ext = 8'b00000000;
                endcase
            end
            default: glyph_ext = 8'b00000000;
        endcase
    end

    wire [7:0] glyph   = (char_code <= 4'd10) ? glyph_num : glyph_ext;
    wire       text_on = in_panel && in_text_row && slot_valid && glyph[7-glyph_col];

    // ---------------- 输出合成 ----------------
    // 无底框、无进度条：只叠加文字，其余像素原图直通
    always @* begin
        rgb_out = text_on ? TEXT_RGB : rgb_in;
    end

endmodule
