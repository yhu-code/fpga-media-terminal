`timescale 1ns/1ps

// ============================================================
// hint_font_rom_24x24 —— 「S1 轮播提示」专用点阵字库
// 24x24，bit23 为最左像素；由 test_bmp/gen_hint_font.py 自动生成
// 字体：SimHei 22px，二值化门限 110
// ------------------------------------------------------------
// char_code 映射（共 6 个字符）：
//   0 -> 开
//   1 -> 始
//   2 -> 轮
//   3 -> 播
//   4 -> 解
//   5 -> 除
//   组合：0,1,2,3 = 开始轮播 ； 4,5,2,3 = 解除轮播
// ============================================================
module hint_font_rom_24x24(
    input      [2:0]  char_code,
    input      [4:0]  row,
    output reg [23:0] glyph
);

always @* begin
    glyph = 24'h000000;
    case (char_code)
        3'd0: begin // 开
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h0FFFF8;
                5'd 6: glyph = 24'h0FFFF8;
                5'd 7: glyph = 24'h004100;
                5'd 8: glyph = 24'h00C180;
                5'd 9: glyph = 24'h004180;
                5'd10: glyph = 24'h004180;
                5'd11: glyph = 24'h004180;
                5'd12: glyph = 24'h00C180;
                5'd13: glyph = 24'h3FFFFC;
                5'd14: glyph = 24'h3FFFFC;
                5'd15: glyph = 24'h00C100;
                5'd16: glyph = 24'h00C180;
                5'd17: glyph = 24'h00C180;
                5'd18: glyph = 24'h018180;
                5'd19: glyph = 24'h018180;
                5'd20: glyph = 24'h030180;
                5'd21: glyph = 24'h0F0180;
                5'd22: glyph = 24'h1E0180;
                5'd23: glyph = 24'h0C0180;
                default: glyph = 24'h000000;
            endcase
        end
        3'd1: begin // 始
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h060200;
                5'd 5: glyph = 24'h060300;
                5'd 6: glyph = 24'h040600;
                5'd 7: glyph = 24'h040600;
                5'd 8: glyph = 24'h0C0C60;
                5'd 9: glyph = 24'h3FC830;
                5'd10: glyph = 24'h0CD838;
                5'd11: glyph = 24'h0CFFFC;
                5'd12: glyph = 24'h08BF0C;
                5'd13: glyph = 24'h198000;
                5'd14: glyph = 24'h198000;
                5'd15: glyph = 24'h199FF8;
                5'd16: glyph = 24'h191FF8;
                5'd17: glyph = 24'h0F1818;
                5'd18: glyph = 24'h071818;
                5'd19: glyph = 24'h079818;
                5'd20: glyph = 24'h06D818;
                5'd21: glyph = 24'h0C5FF8;
                5'd22: glyph = 24'h181838;
                5'd23: glyph = 24'h301818;
                default: glyph = 24'h000000;
            endcase
        end
        3'd2: begin // 轮
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h020300;
                5'd 5: glyph = 24'h030300;
                5'd 6: glyph = 24'h060380;
                5'd 7: glyph = 24'h3FE780;
                5'd 8: glyph = 24'h3FE6C0;
                5'd 9: glyph = 24'h0C0C70;
                5'd10: glyph = 24'h0D1838;
                5'd11: glyph = 24'h19B01C;
                5'd12: glyph = 24'h19BC08;
                5'd13: glyph = 24'h3B8C00;
                5'd14: glyph = 24'h3FEC70;
                5'd15: glyph = 24'h018CE0;
                5'd16: glyph = 24'h018F80;
                5'd17: glyph = 24'h018E00;
                5'd18: glyph = 24'h1FEC00;
                5'd19: glyph = 24'h3F8C00;
                5'd20: glyph = 24'h018C18;
                5'd21: glyph = 24'h018C18;
                5'd22: glyph = 24'h018FF8;
                5'd23: glyph = 24'h0187F0;
                default: glyph = 24'h000000;
            endcase
        end
        3'd3: begin // 播
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h060000;
                5'd 5: glyph = 24'h067FF0;
                5'd 6: glyph = 24'h067FE0;
                5'd 7: glyph = 24'h063330;
                5'd 8: glyph = 24'h063330;
                5'd 9: glyph = 24'h3F1360;
                5'd10: glyph = 24'h06FFFC;
                5'd11: glyph = 24'h064FC0;
                5'd12: glyph = 24'h061B60;
                5'd13: glyph = 24'h073B70;
                5'd14: glyph = 24'h0F733C;
                5'd15: glyph = 24'h3EFFFC;
                5'd16: glyph = 24'h36FFF0;
                5'd17: glyph = 24'h062330;
                5'd18: glyph = 24'h063FF0;
                5'd19: glyph = 24'h063FF0;
                5'd20: glyph = 24'h062330;
                5'd21: glyph = 24'h063FF0;
                5'd22: glyph = 24'h1C3FF0;
                5'd23: glyph = 24'h1C3030;
                default: glyph = 24'h000000;
            endcase
        end
        3'd4: begin // 解
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h060000;
                5'd 5: glyph = 24'h060FF8;
                5'd 6: glyph = 24'h07E398;
                5'd 7: glyph = 24'h0FC108;
                5'd 8: glyph = 24'h18C318;
                5'd 9: glyph = 24'h3FF318;
                5'd10: glyph = 24'h3FF678;
                5'd11: glyph = 24'h0DB630;
                5'd12: glyph = 24'h0DB040;
                5'd13: glyph = 24'h0FF240;
                5'd14: glyph = 24'h0DB3E0;
                5'd15: glyph = 24'h0DB7FC;
                5'd16: glyph = 24'h0DB440;
                5'd17: glyph = 24'h0FF040;
                5'd18: glyph = 24'h09B7FC;
                5'd19: glyph = 24'h09BFFC;
                5'd20: glyph = 24'h19B040;
                5'd21: glyph = 24'h19B040;
                5'd22: glyph = 24'h307040;
                5'd23: glyph = 24'h100040;
                default: glyph = 24'h000000;
            endcase
        end
        3'd5: begin // 除
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000300;
                5'd 5: glyph = 24'h1F8300;
                5'd 6: glyph = 24'h1F8780;
                5'd 7: glyph = 24'h198D80;
                5'd 8: glyph = 24'h190CC0;
                5'd 9: glyph = 24'h1B1870;
                5'd10: glyph = 24'h1B303C;
                5'd11: glyph = 24'h1A7FFC;
                5'd12: glyph = 24'h1B4300;
                5'd13: glyph = 24'h1B0300;
                5'd14: glyph = 24'h198300;
                5'd15: glyph = 24'h19BFF8;
                5'd16: glyph = 24'h198300;
                5'd17: glyph = 24'h1B8300;
                5'd18: glyph = 24'h1B1B60;
                5'd19: glyph = 24'h1A3B30;
                5'd20: glyph = 24'h183318;
                5'd21: glyph = 24'h18631C;
                5'd22: glyph = 24'h184F00;
                5'd23: glyph = 24'h180600;
                default: glyph = 24'h000000;
            endcase
        end
        default: glyph = 24'h000000;
    endcase
end

endmodule
