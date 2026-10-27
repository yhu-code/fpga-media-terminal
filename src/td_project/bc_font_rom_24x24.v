`timescale 1ns/1ps

// ============================================================
// bc_font_rom_24x24 —— 「亮度 / 对比度」OSD 专用点阵字库
// 24x24，bit23 为最左像素；由 test_bmp/gen_bc_font.py 自动生成
// 字体：全部 SimHei 22px（数字与汉字同字体同字号），二值化门限 110
// ------------------------------------------------------------
// char_code 映射（共 15 个字符）：
//    0 -> 对
//    1 -> 比
//    2 -> 度
//    3 -> 亮
//    4 -> 0
//    5 -> 1
//    6 -> 2
//    7 -> 3
//    8 -> 4
//    9 -> 5
//   10 -> 6
//   11 -> 7
//   12 -> %
//   13 -> +
//   14 -> -
// ============================================================
module bc_font_rom_24x24(
    input      [3:0]  char_code,
    input      [4:0]  row,
    output reg [23:0] glyph
);

always @* begin
    glyph = 24'h000000;
    case (char_code)
        4'd0: begin // 对
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000020;
                5'd 5: glyph = 24'h000060;
                5'd 6: glyph = 24'h000020;
                5'd 7: glyph = 24'h1FC020;
                5'd 8: glyph = 24'h1FE020;
                5'd 9: glyph = 24'h005FFC;
                5'd10: glyph = 24'h005FFC;
                5'd11: glyph = 24'h18C020;
                5'd12: glyph = 24'h1CC020;
                5'd13: glyph = 24'h0CC820;
                5'd14: glyph = 24'h078C20;
                5'd15: glyph = 24'h038420;
                5'd16: glyph = 24'h038620;
                5'd17: glyph = 24'h03C620;
                5'd18: glyph = 24'h06C020;
                5'd19: glyph = 24'h0E6020;
                5'd20: glyph = 24'h1C3020;
                5'd21: glyph = 24'h380060;
                5'd22: glyph = 24'h3001E0;
                5'd23: glyph = 24'h0001E0;
                default: glyph = 24'h000000;
            endcase
        end
        4'd1: begin // 比
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000C00;
                5'd 5: glyph = 24'h180C00;
                5'd 6: glyph = 24'h180C00;
                5'd 7: glyph = 24'h080C00;
                5'd 8: glyph = 24'h080C18;
                5'd 9: glyph = 24'h080C78;
                5'd10: glyph = 24'h080CE0;
                5'd11: glyph = 24'h0FEFC0;
                5'd12: glyph = 24'h0FEF00;
                5'd13: glyph = 24'h080C00;
                5'd14: glyph = 24'h080C00;
                5'd15: glyph = 24'h080C00;
                5'd16: glyph = 24'h080C00;
                5'd17: glyph = 24'h080C00;
                5'd18: glyph = 24'h086C00;
                5'd19: glyph = 24'h09EC08;
                5'd20: glyph = 24'h1F8C1C;
                5'd21: glyph = 24'h1E0E38;
                5'd22: glyph = 24'h0807F8;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd2: begin // 度
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000800;
                5'd 5: glyph = 24'h000C00;
                5'd 6: glyph = 24'h0FFFF0;
                5'd 7: glyph = 24'h0FFFF8;
                5'd 8: glyph = 24'h0C2080;
                5'd 9: glyph = 24'h0C6080;
                5'd10: glyph = 24'h0D71C0;
                5'd11: glyph = 24'h0FFFF8;
                5'd12: glyph = 24'h0C6080;
                5'd13: glyph = 24'h0C6080;
                5'd14: glyph = 24'h0C7FC0;
                5'd15: glyph = 24'h0C0000;
                5'd16: glyph = 24'h0DFFE0;
                5'd17: glyph = 24'h09FFC0;
                5'd18: glyph = 24'h083080;
                5'd19: glyph = 24'h183980;
                5'd20: glyph = 24'h181F00;
                5'd21: glyph = 24'h100F00;
                5'd22: glyph = 24'h30FFF8;
                5'd23: glyph = 24'h13E078;
                default: glyph = 24'h000000;
            endcase
        end
        4'd3: begin // 亮
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h001800;
                5'd 5: glyph = 24'h001800;
                5'd 6: glyph = 24'h1FFFF8;
                5'd 7: glyph = 24'h000000;
                5'd 8: glyph = 24'h000000;
                5'd 9: glyph = 24'h03FFC0;
                5'd10: glyph = 24'h0300C0;
                5'd11: glyph = 24'h0300C0;
                5'd12: glyph = 24'h03FFC0;
                5'd13: glyph = 24'h000000;
                5'd14: glyph = 24'h1FFFF8;
                5'd15: glyph = 24'h3FFFFC;
                5'd16: glyph = 24'h30000C;
                5'd17: glyph = 24'h10FE08;
                5'd18: glyph = 24'h00FF00;
                5'd19: glyph = 24'h00C300;
                5'd20: glyph = 24'h00C308;
                5'd21: glyph = 24'h01830C;
                5'd22: glyph = 24'h0F03F8;
                5'd23: glyph = 24'h0E01F8;
                default: glyph = 24'h000000;
            endcase
        end
        4'd4: begin // 0
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h007C00;
                5'd 8: glyph = 24'h006600;
                5'd 9: glyph = 24'h00C300;
                5'd10: glyph = 24'h00C300;
                5'd11: glyph = 24'h018300;
                5'd12: glyph = 24'h018100;
                5'd13: glyph = 24'h018100;
                5'd14: glyph = 24'h018100;
                5'd15: glyph = 24'h018100;
                5'd16: glyph = 24'h018300;
                5'd17: glyph = 24'h008300;
                5'd18: glyph = 24'h00C300;
                5'd19: glyph = 24'h00E600;
                5'd20: glyph = 24'h007E00;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd5: begin // 1
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h001800;
                5'd 8: glyph = 24'h003800;
                5'd 9: glyph = 24'h007800;
                5'd10: glyph = 24'h00D800;
                5'd11: glyph = 24'h001800;
                5'd12: glyph = 24'h001800;
                5'd13: glyph = 24'h001800;
                5'd14: glyph = 24'h001800;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h001800;
                5'd17: glyph = 24'h001800;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h001800;
                5'd20: glyph = 24'h001800;
                5'd21: glyph = 24'h000800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd6: begin // 2
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h007E00;
                5'd 8: glyph = 24'h00E700;
                5'd 9: glyph = 24'h01C300;
                5'd10: glyph = 24'h008300;
                5'd11: glyph = 24'h000300;
                5'd12: glyph = 24'h000300;
                5'd13: glyph = 24'h000600;
                5'd14: glyph = 24'h000C00;
                5'd15: glyph = 24'h000C00;
                5'd16: glyph = 24'h001800;
                5'd17: glyph = 24'h003000;
                5'd18: glyph = 24'h006000;
                5'd19: glyph = 24'h00E000;
                5'd20: glyph = 24'h00FF00;
                5'd21: glyph = 24'h00FF00;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd7: begin // 3
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h007E00;
                5'd 8: glyph = 24'h00E700;
                5'd 9: glyph = 24'h00C300;
                5'd10: glyph = 24'h008300;
                5'd11: glyph = 24'h000300;
                5'd12: glyph = 24'h000600;
                5'd13: glyph = 24'h001C00;
                5'd14: glyph = 24'h001E00;
                5'd15: glyph = 24'h000300;
                5'd16: glyph = 24'h000300;
                5'd17: glyph = 24'h000300;
                5'd18: glyph = 24'h018300;
                5'd19: glyph = 24'h00C700;
                5'd20: glyph = 24'h007E00;
                5'd21: glyph = 24'h003800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd8: begin // 4
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h000600;
                5'd 8: glyph = 24'h000E00;
                5'd 9: glyph = 24'h000E00;
                5'd10: glyph = 24'h001E00;
                5'd11: glyph = 24'h003600;
                5'd12: glyph = 24'h003600;
                5'd13: glyph = 24'h006600;
                5'd14: glyph = 24'h00C600;
                5'd15: glyph = 24'h008600;
                5'd16: glyph = 24'h018600;
                5'd17: glyph = 24'h01FF80;
                5'd18: glyph = 24'h000600;
                5'd19: glyph = 24'h000600;
                5'd20: glyph = 24'h000600;
                5'd21: glyph = 24'h000200;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd9: begin // 5
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h007F00;
                5'd 8: glyph = 24'h007E00;
                5'd 9: glyph = 24'h00C000;
                5'd10: glyph = 24'h00C000;
                5'd11: glyph = 24'h00C000;
                5'd12: glyph = 24'h00FE00;
                5'd13: glyph = 24'h01C600;
                5'd14: glyph = 24'h008300;
                5'd15: glyph = 24'h000300;
                5'd16: glyph = 24'h000300;
                5'd17: glyph = 24'h000300;
                5'd18: glyph = 24'h018300;
                5'd19: glyph = 24'h01C700;
                5'd20: glyph = 24'h00FE00;
                5'd21: glyph = 24'h003800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd10: begin // 6
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h000C00;
                5'd 8: glyph = 24'h001800;
                5'd 9: glyph = 24'h001800;
                5'd10: glyph = 24'h003000;
                5'd11: glyph = 24'h006000;
                5'd12: glyph = 24'h007E00;
                5'd13: glyph = 24'h00FF00;
                5'd14: glyph = 24'h00C380;
                5'd15: glyph = 24'h018180;
                5'd16: glyph = 24'h018180;
                5'd17: glyph = 24'h018180;
                5'd18: glyph = 24'h00C180;
                5'd19: glyph = 24'h00C300;
                5'd20: glyph = 24'h007F00;
                5'd21: glyph = 24'h003C00;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd11: begin // 7
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h01FF80;
                5'd 8: glyph = 24'h00FF80;
                5'd 9: glyph = 24'h000300;
                5'd10: glyph = 24'h000200;
                5'd11: glyph = 24'h000600;
                5'd12: glyph = 24'h000400;
                5'd13: glyph = 24'h000C00;
                5'd14: glyph = 24'h000C00;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h001800;
                5'd17: glyph = 24'h001000;
                5'd18: glyph = 24'h003000;
                5'd19: glyph = 24'h003000;
                5'd20: glyph = 24'h003000;
                5'd21: glyph = 24'h002000;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd12: begin // %
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h00E200;
                5'd 8: glyph = 24'h01A200;
                5'd 9: glyph = 24'h012600;
                5'd10: glyph = 24'h012400;
                5'd11: glyph = 24'h012400;
                5'd12: glyph = 24'h01A800;
                5'd13: glyph = 24'h00E800;
                5'd14: glyph = 24'h001700;
                5'd15: glyph = 24'h001780;
                5'd16: glyph = 24'h002D80;
                5'd17: glyph = 24'h002D80;
                5'd18: glyph = 24'h006D80;
                5'd19: glyph = 24'h004D80;
                5'd20: glyph = 24'h00C700;
                5'd21: glyph = 24'h000200;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd13: begin // +
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h000000;
                5'd 8: glyph = 24'h000000;
                5'd 9: glyph = 24'h001800;
                5'd10: glyph = 24'h001800;
                5'd11: glyph = 24'h001800;
                5'd12: glyph = 24'h001800;
                5'd13: glyph = 24'h01FF80;
                5'd14: glyph = 24'h01FF80;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h001800;
                5'd17: glyph = 24'h001800;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h000000;
                5'd20: glyph = 24'h000000;
                5'd21: glyph = 24'h000000;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        4'd14: begin // -
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h000000;
                5'd 8: glyph = 24'h000000;
                5'd 9: glyph = 24'h000000;
                5'd10: glyph = 24'h000000;
                5'd11: glyph = 24'h000000;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h01FF80;
                5'd14: glyph = 24'h01FF80;
                5'd15: glyph = 24'h000000;
                5'd16: glyph = 24'h000000;
                5'd17: glyph = 24'h000000;
                5'd18: glyph = 24'h000000;
                5'd19: glyph = 24'h000000;
                5'd20: glyph = 24'h000000;
                5'd21: glyph = 24'h000000;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        default: glyph = 24'h000000;
    endcase
end

endmodule
