`timescale 1ns/1ps

// ============================================================
// font_rom_numeric
// 8x16 数字/冒号点阵字库
// char_code：
//   0~9 -> '0'~'9'
//   10  -> ':'
// row   : 0~15
// 输出 glyph[7:0]，bit7 对应最左侧像素
// ============================================================
module font_rom_numeric(
    input      [3:0] char_code,
    input      [3:0] row,
    output reg [7:0] glyph
);

    always @* begin
        glyph = 8'b00000000;

        case (char_code)
            // 0
            4'd0: begin
                case (row)
                    4'd0 : glyph = 8'b00111100;
                    4'd1 : glyph = 8'b01100110;
                    4'd2 : glyph = 8'b11000011;
                    4'd3 : glyph = 8'b11000011;
                    4'd4 : glyph = 8'b11000011;
                    4'd5 : glyph = 8'b11011011;
                    4'd6 : glyph = 8'b11011011;
                    4'd7 : glyph = 8'b11000011;
                    4'd8 : glyph = 8'b11000011;
                    4'd9 : glyph = 8'b11000011;
                    4'd10: glyph = 8'b11000011;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b01100110;
                    4'd14: glyph = 8'b00111100;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 1
            4'd1: begin
                case (row)
                    4'd0 : glyph = 8'b00011000;
                    4'd1 : glyph = 8'b00111000;
                    4'd2 : glyph = 8'b01111000;
                    4'd3 : glyph = 8'b11011000;
                    4'd4 : glyph = 8'b00011000;
                    4'd5 : glyph = 8'b00011000;
                    4'd6 : glyph = 8'b00011000;
                    4'd7 : glyph = 8'b00011000;
                    4'd8 : glyph = 8'b00011000;
                    4'd9 : glyph = 8'b00011000;
                    4'd10: glyph = 8'b00011000;
                    4'd11: glyph = 8'b00011000;
                    4'd12: glyph = 8'b00011000;
                    4'd13: glyph = 8'b01111110;
                    4'd14: glyph = 8'b01111110;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 2
            4'd2: begin
                case (row)
                    4'd0 : glyph = 8'b00111100;
                    4'd1 : glyph = 8'b01100110;
                    4'd2 : glyph = 8'b11000011;
                    4'd3 : glyph = 8'b00000011;
                    4'd4 : glyph = 8'b00000110;
                    4'd5 : glyph = 8'b00001100;
                    4'd6 : glyph = 8'b00011000;
                    4'd7 : glyph = 8'b00110000;
                    4'd8 : glyph = 8'b01100000;
                    4'd9 : glyph = 8'b11000000;
                    4'd10: glyph = 8'b11000000;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b11111111;
                    4'd14: glyph = 8'b11111111;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 3
            4'd3: begin
                case (row)
                    4'd0 : glyph = 8'b00111100;
                    4'd1 : glyph = 8'b01100110;
                    4'd2 : glyph = 8'b11000011;
                    4'd3 : glyph = 8'b00000011;
                    4'd4 : glyph = 8'b00000011;
                    4'd5 : glyph = 8'b00011110;
                    4'd6 : glyph = 8'b00011110;
                    4'd7 : glyph = 8'b00000011;
                    4'd8 : glyph = 8'b00000011;
                    4'd9 : glyph = 8'b00000011;
                    4'd10: glyph = 8'b00000011;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b01100110;
                    4'd14: glyph = 8'b00111100;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 4
            4'd4: begin
                case (row)
                    4'd0 : glyph = 8'b00000110;
                    4'd1 : glyph = 8'b00001110;
                    4'd2 : glyph = 8'b00011110;
                    4'd3 : glyph = 8'b00110110;
                    4'd4 : glyph = 8'b01100110;
                    4'd5 : glyph = 8'b11000110;
                    4'd6 : glyph = 8'b11000110;
                    4'd7 : glyph = 8'b11111111;
                    4'd8 : glyph = 8'b11111111;
                    4'd9 : glyph = 8'b00000110;
                    4'd10: glyph = 8'b00000110;
                    4'd11: glyph = 8'b00000110;
                    4'd12: glyph = 8'b00000110;
                    4'd13: glyph = 8'b00000110;
                    4'd14: glyph = 8'b00000110;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 5
            4'd5: begin
                case (row)
                    4'd0 : glyph = 8'b11111111;
                    4'd1 : glyph = 8'b11111111;
                    4'd2 : glyph = 8'b11000000;
                    4'd3 : glyph = 8'b11000000;
                    4'd4 : glyph = 8'b11000000;
                    4'd5 : glyph = 8'b11111100;
                    4'd6 : glyph = 8'b11111110;
                    4'd7 : glyph = 8'b00000011;
                    4'd8 : glyph = 8'b00000011;
                    4'd9 : glyph = 8'b00000011;
                    4'd10: glyph = 8'b00000011;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b01100110;
                    4'd14: glyph = 8'b00111100;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 6
            4'd6: begin
                case (row)
                    4'd0 : glyph = 8'b00111100;
                    4'd1 : glyph = 8'b01100110;
                    4'd2 : glyph = 8'b11000011;
                    4'd3 : glyph = 8'b11000000;
                    4'd4 : glyph = 8'b11000000;
                    4'd5 : glyph = 8'b11111100;
                    4'd6 : glyph = 8'b11111110;
                    4'd7 : glyph = 8'b11000011;
                    4'd8 : glyph = 8'b11000011;
                    4'd9 : glyph = 8'b11000011;
                    4'd10: glyph = 8'b11000011;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b01100110;
                    4'd14: glyph = 8'b00111100;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 7
            4'd7: begin
                case (row)
                    4'd0 : glyph = 8'b11111111;
                    4'd1 : glyph = 8'b11111111;
                    4'd2 : glyph = 8'b00000011;
                    4'd3 : glyph = 8'b00000110;
                    4'd4 : glyph = 8'b00001100;
                    4'd5 : glyph = 8'b00011000;
                    4'd6 : glyph = 8'b00110000;
                    4'd7 : glyph = 8'b01100000;
                    4'd8 : glyph = 8'b11000000;
                    4'd9 : glyph = 8'b11000000;
                    4'd10: glyph = 8'b11000000;
                    4'd11: glyph = 8'b11000000;
                    4'd12: glyph = 8'b11000000;
                    4'd13: glyph = 8'b11000000;
                    4'd14: glyph = 8'b11000000;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 8
            4'd8: begin
                case (row)
                    4'd0 : glyph = 8'b00111100;
                    4'd1 : glyph = 8'b01100110;
                    4'd2 : glyph = 8'b11000011;
                    4'd3 : glyph = 8'b11000011;
                    4'd4 : glyph = 8'b11000011;
                    4'd5 : glyph = 8'b01100110;
                    4'd6 : glyph = 8'b01100110;
                    4'd7 : glyph = 8'b00111100;
                    4'd8 : glyph = 8'b01100110;
                    4'd9 : glyph = 8'b11000011;
                    4'd10: glyph = 8'b11000011;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b01100110;
                    4'd14: glyph = 8'b00111100;
                    default: glyph = 8'b00000000;
                endcase
            end

            // 9
            4'd9: begin
                case (row)
                    4'd0 : glyph = 8'b00111100;
                    4'd1 : glyph = 8'b01100110;
                    4'd2 : glyph = 8'b11000011;
                    4'd3 : glyph = 8'b11000011;
                    4'd4 : glyph = 8'b11000011;
                    4'd5 : glyph = 8'b01100111;
                    4'd6 : glyph = 8'b00111111;
                    4'd7 : glyph = 8'b00000011;
                    4'd8 : glyph = 8'b00000011;
                    4'd9 : glyph = 8'b00000011;
                    4'd10: glyph = 8'b00000011;
                    4'd11: glyph = 8'b11000011;
                    4'd12: glyph = 8'b11000011;
                    4'd13: glyph = 8'b01100110;
                    4'd14: glyph = 8'b00111100;
                    default: glyph = 8'b00000000;
                endcase
            end

            // colon
            4'd10: begin
                case (row)
                    4'd4 : glyph = 8'b00011000;
                    4'd5 : glyph = 8'b00011000;
                    4'd6 : glyph = 8'b00011000;
                    4'd9 : glyph = 8'b00011000;
                    4'd10: glyph = 8'b00011000;
                    4'd11: glyph = 8'b00011000;
                    default: glyph = 8'b00000000;
                endcase
            end

            default: begin
                glyph = 8'b00000000;
            end
        endcase
    end

endmodule
