`timescale 1ns/1ps

// ============================================================
// slogan_font_rom_24x24
// 「历史事件四句标语」点阵字库，24x24，bit23 为最左像素。
// 由 test_bmp/gen_slogan_font.py 自动生成，勿手工修改。
// 字体：SimHei 22px，二值化门限 110
// ------------------------------------------------------------
// char_code 映射（共 60 个字符）：
//    0 -> 1
//    1 -> 9
//    2 -> 7
//    3 -> 0
//    4 -> 年
//    5 -> 4
//    6 -> 月
//    7 -> 2
//    8 -> 日
//    9 -> ，
//   10 -> 中
//   11 -> 国
//   12 -> 首
//   13 -> 颗
//   14 -> “
//   15 -> 东
//   16 -> 方
//   17 -> 红
//   18 -> 一
//   19 -> 号
//   20 -> ”
//   21 -> 发
//   22 -> 射
//   23 -> 成
//   24 -> 功
//   25 -> 3
//   26 -> 5
//   27 -> 神
//   28 -> 舟
//   29 -> 五
//   30 -> 次
//   31 -> 载
//   32 -> 人
//   33 -> 飞
//   34 -> 行
//   35 -> 梦
//   36 -> 天
//   37 -> 转
//   38 -> 位
//   39 -> 空
//   40 -> 间
//   41 -> 站
//   42 -> T
//   43 -> 字
//   44 -> 构
//   45 -> 型
//   46 -> 完
//   47 -> 6
//   48 -> 8
//   49 -> 朱
//   50 -> 雀
//   51 -> 三
//   52 -> 遥
//   53 -> 二
//   54 -> 子
//   55 -> 级
//   56 -> 陆
//   57 -> 地
//   58 -> 回
//   59 -> 收
// ============================================================
module slogan_font_rom_24x24(
    input      [5:0]  char_code,
    input      [4:0]  row,
    output reg [23:0] glyph
);

always @* begin
    glyph = 24'h000000;
    case (char_code)
        6'd0: begin // 1
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000800;
                5'd 6: glyph = 24'h001800;
                5'd 7: glyph = 24'h003800;
                5'd 8: glyph = 24'h007800;
                5'd 9: glyph = 24'h00D800;
                5'd10: glyph = 24'h009800;
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
        6'd1: begin // 9
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h003800;
                5'd 6: glyph = 24'h00FE00;
                5'd 7: glyph = 24'h01C700;
                5'd 8: glyph = 24'h018300;
                5'd 9: glyph = 24'h018380;
                5'd10: glyph = 24'h038380;
                5'd11: glyph = 24'h038300;
                5'd12: glyph = 24'h018300;
                5'd13: glyph = 24'h01C700;
                5'd14: glyph = 24'h00FE00;
                5'd15: glyph = 24'h003E00;
                5'd16: glyph = 24'h000C00;
                5'd17: glyph = 24'h001C00;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h003000;
                5'd20: glyph = 24'h003000;
                5'd21: glyph = 24'h006000;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd2: begin // 7
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h01FF80;
                5'd 7: glyph = 24'h000180;
                5'd 8: glyph = 24'h000300;
                5'd 9: glyph = 24'h000300;
                5'd10: glyph = 24'h000600;
                5'd11: glyph = 24'h000600;
                5'd12: glyph = 24'h000C00;
                5'd13: glyph = 24'h000C00;
                5'd14: glyph = 24'h001800;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h001800;
                5'd17: glyph = 24'h003000;
                5'd18: glyph = 24'h003000;
                5'd19: glyph = 24'h003000;
                5'd20: glyph = 24'h007000;
                5'd21: glyph = 24'h002000;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd3: begin // 0
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h003C00;
                5'd 6: glyph = 24'h007E00;
                5'd 7: glyph = 24'h00E700;
                5'd 8: glyph = 24'h00C300;
                5'd 9: glyph = 24'h018300;
                5'd10: glyph = 24'h018180;
                5'd11: glyph = 24'h018180;
                5'd12: glyph = 24'h018180;
                5'd13: glyph = 24'h018180;
                5'd14: glyph = 24'h018180;
                5'd15: glyph = 24'h018180;
                5'd16: glyph = 24'h018180;
                5'd17: glyph = 24'h018300;
                5'd18: glyph = 24'h00C300;
                5'd19: glyph = 24'h00E700;
                5'd20: glyph = 24'h007E00;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd4: begin // 年
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h018000;
                5'd 5: glyph = 24'h018000;
                5'd 6: glyph = 24'h038000;
                5'd 7: glyph = 24'h03FFF8;
                5'd 8: glyph = 24'h07FFF0;
                5'd 9: glyph = 24'h0E0C00;
                5'd10: glyph = 24'h1C0C00;
                5'd11: glyph = 24'h180C00;
                5'd12: glyph = 24'h1BFFF0;
                5'd13: glyph = 24'h030C00;
                5'd14: glyph = 24'h030C00;
                5'd15: glyph = 24'h030C00;
                5'd16: glyph = 24'h030C00;
                5'd17: glyph = 24'h3FFFFC;
                5'd18: glyph = 24'h3FFFFC;
                5'd19: glyph = 24'h000C00;
                5'd20: glyph = 24'h000C00;
                5'd21: glyph = 24'h000C00;
                5'd22: glyph = 24'h000C00;
                5'd23: glyph = 24'h000C00;
                default: glyph = 24'h000000;
            endcase
        end
        6'd5: begin // 4
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000200;
                5'd 6: glyph = 24'h000600;
                5'd 7: glyph = 24'h000E00;
                5'd 8: glyph = 24'h000E00;
                5'd 9: glyph = 24'h001E00;
                5'd10: glyph = 24'h003200;
                5'd11: glyph = 24'h003600;
                5'd12: glyph = 24'h006600;
                5'd13: glyph = 24'h00C600;
                5'd14: glyph = 24'h01C600;
                5'd15: glyph = 24'h018600;
                5'd16: glyph = 24'h03FF80;
                5'd17: glyph = 24'h03FFC0;
                5'd18: glyph = 24'h000600;
                5'd19: glyph = 24'h000600;
                5'd20: glyph = 24'h000600;
                5'd21: glyph = 24'h000200;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd6: begin // 月
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h03FFE0;
                5'd 6: glyph = 24'h03FFE0;
                5'd 7: glyph = 24'h020060;
                5'd 8: glyph = 24'h030060;
                5'd 9: glyph = 24'h020060;
                5'd10: glyph = 24'h03FFE0;
                5'd11: glyph = 24'h03FFE0;
                5'd12: glyph = 24'h020060;
                5'd13: glyph = 24'h030060;
                5'd14: glyph = 24'h030060;
                5'd15: glyph = 24'h03FFE0;
                5'd16: glyph = 24'h03FFE0;
                5'd17: glyph = 24'h060060;
                5'd18: glyph = 24'h060060;
                5'd19: glyph = 24'h060060;
                5'd20: glyph = 24'h0C0060;
                5'd21: glyph = 24'h0C0060;
                5'd22: glyph = 24'h1803E0;
                5'd23: glyph = 24'h1801C0;
                default: glyph = 24'h000000;
            endcase
        end
        6'd7: begin // 2
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h003C00;
                5'd 6: glyph = 24'h00FE00;
                5'd 7: glyph = 24'h00C700;
                5'd 8: glyph = 24'h018300;
                5'd 9: glyph = 24'h018300;
                5'd10: glyph = 24'h000300;
                5'd11: glyph = 24'h000300;
                5'd12: glyph = 24'h000700;
                5'd13: glyph = 24'h000600;
                5'd14: glyph = 24'h000C00;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h003800;
                5'd17: glyph = 24'h007000;
                5'd18: glyph = 24'h00E000;
                5'd19: glyph = 24'h00C000;
                5'd20: glyph = 24'h01FF80;
                5'd21: glyph = 24'h00FD00;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd8: begin // 日
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h07FFF0;
                5'd 6: glyph = 24'h070070;
                5'd 7: glyph = 24'h060060;
                5'd 8: glyph = 24'h060060;
                5'd 9: glyph = 24'h060060;
                5'd10: glyph = 24'h060060;
                5'd11: glyph = 24'h060060;
                5'd12: glyph = 24'h07FFE0;
                5'd13: glyph = 24'h07FFE0;
                5'd14: glyph = 24'h060060;
                5'd15: glyph = 24'h060060;
                5'd16: glyph = 24'h060060;
                5'd17: glyph = 24'h060060;
                5'd18: glyph = 24'h060060;
                5'd19: glyph = 24'h060060;
                5'd20: glyph = 24'h07FFE0;
                5'd21: glyph = 24'h070060;
                5'd22: glyph = 24'h060070;
                5'd23: glyph = 24'h060020;
                default: glyph = 24'h000000;
            endcase
        end
        6'd9: begin // ，
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
                5'd13: glyph = 24'h000000;
                5'd14: glyph = 24'h000000;
                5'd15: glyph = 24'h000000;
                5'd16: glyph = 24'h000000;
                5'd17: glyph = 24'h000000;
                5'd18: glyph = 24'h000000;
                5'd19: glyph = 24'h0E0000;
                5'd20: glyph = 24'h0E0000;
                5'd21: glyph = 24'h0E0000;
                5'd22: glyph = 24'h060000;
                5'd23: glyph = 24'h060000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd10: begin // 中
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h001800;
                5'd 5: glyph = 24'h001800;
                5'd 6: glyph = 24'h001800;
                5'd 7: glyph = 24'h001800;
                5'd 8: glyph = 24'h001800;
                5'd 9: glyph = 24'h0FFFF0;
                5'd10: glyph = 24'h0C1830;
                5'd11: glyph = 24'h0C1830;
                5'd12: glyph = 24'h0C1830;
                5'd13: glyph = 24'h0C1830;
                5'd14: glyph = 24'h0C1830;
                5'd15: glyph = 24'h0FFFF0;
                5'd16: glyph = 24'h0FFFF0;
                5'd17: glyph = 24'h081810;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h001800;
                5'd20: glyph = 24'h001800;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h001800;
                5'd23: glyph = 24'h001800;
                default: glyph = 24'h000000;
            endcase
        end
        6'd11: begin // 国
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h1FFFF8;
                5'd 6: glyph = 24'h180018;
                5'd 7: glyph = 24'h180018;
                5'd 8: glyph = 24'h19FF98;
                5'd 9: glyph = 24'h19FF98;
                5'd10: glyph = 24'h181818;
                5'd11: glyph = 24'h181818;
                5'd12: glyph = 24'h181818;
                5'd13: glyph = 24'h19FF98;
                5'd14: glyph = 24'h181818;
                5'd15: glyph = 24'h181B18;
                5'd16: glyph = 24'h181B18;
                5'd17: glyph = 24'h181818;
                5'd18: glyph = 24'h1BFFD8;
                5'd19: glyph = 24'h180018;
                5'd20: glyph = 24'h180018;
                5'd21: glyph = 24'h180018;
                5'd22: glyph = 24'h1FFFF8;
                5'd23: glyph = 24'h180018;
                default: glyph = 24'h000000;
            endcase
        end
        6'd12: begin // 首
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h010180;
                5'd 5: glyph = 24'h018180;
                5'd 6: glyph = 24'h00C300;
                5'd 7: glyph = 24'h008300;
                5'd 8: glyph = 24'h3FFFFC;
                5'd 9: glyph = 24'h103808;
                5'd10: glyph = 24'h003000;
                5'd11: glyph = 24'h007000;
                5'd12: glyph = 24'h03FFC0;
                5'd13: glyph = 24'h0200C0;
                5'd14: glyph = 24'h0200C0;
                5'd15: glyph = 24'h03FFC0;
                5'd16: glyph = 24'h0342C0;
                5'd17: glyph = 24'h020040;
                5'd18: glyph = 24'h03FFC0;
                5'd19: glyph = 24'h03FFC0;
                5'd20: glyph = 24'h020040;
                5'd21: glyph = 24'h03FFC0;
                5'd22: glyph = 24'h03FFC0;
                5'd23: glyph = 24'h020040;
                default: glyph = 24'h000000;
            endcase
        end
        6'd13: begin // 颗
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h1FFFFC;
                5'd 7: glyph = 24'h1930C0;
                5'd 8: glyph = 24'h1B3080;
                5'd 9: glyph = 24'h1FF180;
                5'd10: glyph = 24'h1B37F8;
                5'd11: glyph = 24'h193618;
                5'd12: glyph = 24'h1FF498;
                5'd13: glyph = 24'h1FE4D8;
                5'd14: glyph = 24'h010498;
                5'd15: glyph = 24'h3FF498;
                5'd16: glyph = 24'h3FF498;
                5'd17: glyph = 24'h034498;
                5'd18: glyph = 24'h07E598;
                5'd19: glyph = 24'h0F3180;
                5'd20: glyph = 24'h390360;
                5'd21: glyph = 24'h330738;
                5'd22: glyph = 24'h030E1C;
                5'd23: glyph = 24'h030C08;
                default: glyph = 24'h000000;
            endcase
        end
        6'd14: begin // “
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000318;
                5'd 6: glyph = 24'h000630;
                5'd 7: glyph = 24'h000630;
                5'd 8: glyph = 24'h000738;
                5'd 9: glyph = 24'h000738;
                5'd10: glyph = 24'h000738;
                5'd11: glyph = 24'h000000;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h000000;
                5'd14: glyph = 24'h000000;
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
        6'd15: begin // 东
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h003000;
                5'd 5: glyph = 24'h003000;
                5'd 6: glyph = 24'h006000;
                5'd 7: glyph = 24'h006000;
                5'd 8: glyph = 24'h1FFFF0;
                5'd 9: glyph = 24'h01C000;
                5'd10: glyph = 24'h018000;
                5'd11: glyph = 24'h038C00;
                5'd12: glyph = 24'h030C00;
                5'd13: glyph = 24'h060C00;
                5'd14: glyph = 24'h0FFFF0;
                5'd15: glyph = 24'h07FFF0;
                5'd16: glyph = 24'h000C00;
                5'd17: glyph = 24'h010C00;
                5'd18: glyph = 24'h038CC0;
                5'd19: glyph = 24'h070C60;
                5'd20: glyph = 24'h0E0C30;
                5'd21: glyph = 24'h1C0C18;
                5'd22: glyph = 24'h187C18;
                5'd23: glyph = 24'h003800;
                default: glyph = 24'h000000;
            endcase
        end
        6'd16: begin // 方
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h003000;
                5'd 5: glyph = 24'h003000;
                5'd 6: glyph = 24'h001800;
                5'd 7: glyph = 24'h001000;
                5'd 8: glyph = 24'h1FFFF8;
                5'd 9: glyph = 24'h3FFFFC;
                5'd10: glyph = 24'h00C000;
                5'd11: glyph = 24'h00C000;
                5'd12: glyph = 24'h00C000;
                5'd13: glyph = 24'h00FFE0;
                5'd14: glyph = 24'h00FFE0;
                5'd15: glyph = 24'h008060;
                5'd16: glyph = 24'h018060;
                5'd17: glyph = 24'h018060;
                5'd18: glyph = 24'h018060;
                5'd19: glyph = 24'h030060;
                5'd20: glyph = 24'h070060;
                5'd21: glyph = 24'h0E00C0;
                5'd22: glyph = 24'h1C07C0;
                5'd23: glyph = 24'h180780;
                default: glyph = 24'h000000;
            endcase
        end
        6'd17: begin // 红
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h030000;
                5'd 6: glyph = 24'h060000;
                5'd 7: glyph = 24'h061FF8;
                5'd 8: glyph = 24'h0C0180;
                5'd 9: glyph = 24'h0C6180;
                5'd10: glyph = 24'h18C180;
                5'd11: glyph = 24'h3F8180;
                5'd12: glyph = 24'h3F8180;
                5'd13: glyph = 24'h030180;
                5'd14: glyph = 24'h060180;
                5'd15: glyph = 24'h040180;
                5'd16: glyph = 24'h0FE180;
                5'd17: glyph = 24'h1FC180;
                5'd18: glyph = 24'h100180;
                5'd19: glyph = 24'h000180;
                5'd20: glyph = 24'h03E180;
                5'd21: glyph = 24'h1FBFFC;
                5'd22: glyph = 24'h183FFC;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd18: begin // 一
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
                5'd13: glyph = 24'h3FFFFC;
                5'd14: glyph = 24'h3FFFFC;
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
        6'd19: begin // 号
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h03FFC0;
                5'd 6: glyph = 24'h03FFC0;
                5'd 7: glyph = 24'h030040;
                5'd 8: glyph = 24'h030040;
                5'd 9: glyph = 24'h0300C0;
                5'd10: glyph = 24'h03FFC0;
                5'd11: glyph = 24'h000000;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h3FFFFC;
                5'd14: glyph = 24'h01C000;
                5'd15: glyph = 24'h018000;
                5'd16: glyph = 24'h018000;
                5'd17: glyph = 24'h01FFE0;
                5'd18: glyph = 24'h01FFE0;
                5'd19: glyph = 24'h000040;
                5'd20: glyph = 24'h0000C0;
                5'd21: glyph = 24'h0000C0;
                5'd22: glyph = 24'h001FC0;
                5'd23: glyph = 24'h000F80;
                default: glyph = 24'h000000;
            endcase
        end
        6'd20: begin // ”
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h18C000;
                5'd 5: glyph = 24'h1CE000;
                5'd 6: glyph = 24'h1CE000;
                5'd 7: glyph = 24'h0C6000;
                5'd 8: glyph = 24'h0C6000;
                5'd 9: glyph = 24'h18C000;
                5'd10: glyph = 24'h108000;
                5'd11: glyph = 24'h000000;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h000000;
                5'd14: glyph = 24'h000000;
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
        6'd21: begin // 发
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h021980;
                5'd 6: glyph = 24'h0610C0;
                5'd 7: glyph = 24'h0630E0;
                5'd 8: glyph = 24'h043040;
                5'd 9: glyph = 24'h0C3000;
                5'd10: glyph = 24'h0FFFF8;
                5'd11: glyph = 24'h006000;
                5'd12: glyph = 24'h006000;
                5'd13: glyph = 24'h00E000;
                5'd14: glyph = 24'h00FFE0;
                5'd15: glyph = 24'h01E0C0;
                5'd16: glyph = 24'h03E0C0;
                5'd17: glyph = 24'h033180;
                5'd18: glyph = 24'h061B00;
                5'd19: glyph = 24'h1C0F00;
                5'd20: glyph = 24'h380E00;
                5'd21: glyph = 24'h103F80;
                5'd22: glyph = 24'h03E1F8;
                5'd23: glyph = 24'h078078;
                default: glyph = 24'h000000;
            endcase
        end
        6'd22: begin // 射
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h030020;
                5'd 5: glyph = 24'h030020;
                5'd 6: glyph = 24'h0FF020;
                5'd 7: glyph = 24'h0FF020;
                5'd 8: glyph = 24'h083020;
                5'd 9: glyph = 24'h0C3030;
                5'd10: glyph = 24'h0FFFFC;
                5'd11: glyph = 24'h083030;
                5'd12: glyph = 24'h083020;
                5'd13: glyph = 24'h0FF620;
                5'd14: glyph = 24'h0C3620;
                5'd15: glyph = 24'h083320;
                5'd16: glyph = 24'h3FF320;
                5'd17: glyph = 24'h3FF020;
                5'd18: glyph = 24'h01B020;
                5'd19: glyph = 24'h03B020;
                5'd20: glyph = 24'h073020;
                5'd21: glyph = 24'h0E3020;
                5'd22: glyph = 24'h38F1E0;
                5'd23: glyph = 24'h10E0C0;
                default: glyph = 24'h000000;
            endcase
        end
        6'd23: begin // 成
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000640;
                5'd 5: glyph = 24'h000660;
                5'd 6: glyph = 24'h000630;
                5'd 7: glyph = 24'h000610;
                5'd 8: glyph = 24'h0FFFF8;
                5'd 9: glyph = 24'h0FFFF8;
                5'd10: glyph = 24'h0C0600;
                5'd11: glyph = 24'h0C0620;
                5'd12: glyph = 24'h0C0630;
                5'd13: glyph = 24'h0FE630;
                5'd14: glyph = 24'h0C6260;
                5'd15: glyph = 24'h0C6360;
                5'd16: glyph = 24'h0C63C0;
                5'd17: glyph = 24'h0C63C0;
                5'd18: glyph = 24'h0C6180;
                5'd19: glyph = 24'h186388;
                5'd20: glyph = 24'h19E6CC;
                5'd21: glyph = 24'h199CEC;
                5'd22: glyph = 24'h30387C;
                5'd23: glyph = 24'h303038;
                default: glyph = 24'h000000;
            endcase
        end
        6'd24: begin // 功
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000200;
                5'd 5: glyph = 24'h000300;
                5'd 6: glyph = 24'h000300;
                5'd 7: glyph = 24'h3FC300;
                5'd 8: glyph = 24'h1FC300;
                5'd 9: glyph = 24'h021FF8;
                5'd10: glyph = 24'h031FF8;
                5'd11: glyph = 24'h030318;
                5'd12: glyph = 24'h030318;
                5'd13: glyph = 24'h030218;
                5'd14: glyph = 24'h030218;
                5'd15: glyph = 24'h030618;
                5'd16: glyph = 24'h020618;
                5'd17: glyph = 24'h036618;
                5'd18: glyph = 24'h0FEC18;
                5'd19: glyph = 24'h3E0C18;
                5'd20: glyph = 24'h101818;
                5'd21: glyph = 24'h003030;
                5'd22: glyph = 24'h0070F0;
                5'd23: glyph = 24'h0060C0;
                default: glyph = 24'h000000;
            endcase
        end
        6'd25: begin // 3
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h003C00;
                5'd 6: glyph = 24'h007E00;
                5'd 7: glyph = 24'h00C700;
                5'd 8: glyph = 24'h018300;
                5'd 9: glyph = 24'h008300;
                5'd10: glyph = 24'h000300;
                5'd11: glyph = 24'h000700;
                5'd12: glyph = 24'h001E00;
                5'd13: glyph = 24'h001E00;
                5'd14: glyph = 24'h000700;
                5'd15: glyph = 24'h000300;
                5'd16: glyph = 24'h000180;
                5'd17: glyph = 24'h018180;
                5'd18: glyph = 24'h018300;
                5'd19: glyph = 24'h00C700;
                5'd20: glyph = 24'h007E00;
                5'd21: glyph = 24'h003800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd26: begin // 5
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h00FF00;
                5'd 7: glyph = 24'h00C000;
                5'd 8: glyph = 24'h00C000;
                5'd 9: glyph = 24'h00C000;
                5'd10: glyph = 24'h008000;
                5'd11: glyph = 24'h01FE00;
                5'd12: glyph = 24'h01EF00;
                5'd13: glyph = 24'h018300;
                5'd14: glyph = 24'h000380;
                5'd15: glyph = 24'h000180;
                5'd16: glyph = 24'h000180;
                5'd17: glyph = 24'h010380;
                5'd18: glyph = 24'h018300;
                5'd19: glyph = 24'h01C700;
                5'd20: glyph = 24'h00FE00;
                5'd21: glyph = 24'h003800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd27: begin // 神
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h060180;
                5'd 5: glyph = 24'h060180;
                5'd 6: glyph = 24'h030180;
                5'd 7: glyph = 24'h001FF8;
                5'd 8: glyph = 24'h1FBFF8;
                5'd 9: glyph = 24'h3F9188;
                5'd10: glyph = 24'h019188;
                5'd11: glyph = 24'h031188;
                5'd12: glyph = 24'h031FF8;
                5'd13: glyph = 24'h061FF8;
                5'd14: glyph = 24'h0F9188;
                5'd15: glyph = 24'h1F9188;
                5'd16: glyph = 24'h369198;
                5'd17: glyph = 24'h061FF8;
                5'd18: glyph = 24'h061198;
                5'd19: glyph = 24'h063188;
                5'd20: glyph = 24'h060180;
                5'd21: glyph = 24'h060180;
                5'd22: glyph = 24'h060180;
                5'd23: glyph = 24'h060180;
                default: glyph = 24'h000000;
            endcase
        end
        6'd28: begin // 舟
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h003000;
                5'd 5: glyph = 24'h003000;
                5'd 6: glyph = 24'h003000;
                5'd 7: glyph = 24'h03FFC0;
                5'd 8: glyph = 24'h03FFC0;
                5'd 9: glyph = 24'h0300C0;
                5'd10: glyph = 24'h0330C0;
                5'd11: glyph = 24'h0318C0;
                5'd12: glyph = 24'h0318C0;
                5'd13: glyph = 24'h0300C0;
                5'd14: glyph = 24'h3FFFFC;
                5'd15: glyph = 24'h3FFFFC;
                5'd16: glyph = 24'h0300C0;
                5'd17: glyph = 24'h0330C0;
                5'd18: glyph = 24'h0338C0;
                5'd19: glyph = 24'h0618C0;
                5'd20: glyph = 24'h0608C0;
                5'd21: glyph = 24'h0C00C0;
                5'd22: glyph = 24'h1C03C0;
                5'd23: glyph = 24'h180380;
                default: glyph = 24'h000000;
            endcase
        end
        6'd29: begin // 五
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h0FFFF0;
                5'd 7: glyph = 24'h0FFFF0;
                5'd 8: glyph = 24'h003000;
                5'd 9: glyph = 24'h003000;
                5'd10: glyph = 24'h003000;
                5'd11: glyph = 24'h002000;
                5'd12: glyph = 24'h07FFC0;
                5'd13: glyph = 24'h07FFC0;
                5'd14: glyph = 24'h0060C0;
                5'd15: glyph = 24'h0060C0;
                5'd16: glyph = 24'h0060C0;
                5'd17: glyph = 24'h0060C0;
                5'd18: glyph = 24'h0060C0;
                5'd19: glyph = 24'h0040C0;
                5'd20: glyph = 24'h00C0C0;
                5'd21: glyph = 24'h3FFFFC;
                5'd22: glyph = 24'h1FFFF8;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd30: begin // 次
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000800;
                5'd 5: glyph = 24'h001800;
                5'd 6: glyph = 24'h181800;
                5'd 7: glyph = 24'h1C1000;
                5'd 8: glyph = 24'h0C3FF8;
                5'd 9: glyph = 24'h063FF0;
                5'd10: glyph = 24'h066030;
                5'd11: glyph = 24'h006630;
                5'd12: glyph = 24'h00C630;
                5'd13: glyph = 24'h000600;
                5'd14: glyph = 24'h020600;
                5'd15: glyph = 24'h030600;
                5'd16: glyph = 24'h060700;
                5'd17: glyph = 24'h060F00;
                5'd18: glyph = 24'h0C0D80;
                5'd19: glyph = 24'h1819C0;
                5'd20: glyph = 24'h3830E0;
                5'd21: glyph = 24'h30E070;
                5'd22: glyph = 24'h01C03C;
                5'd23: glyph = 24'h018008;
                default: glyph = 24'h000000;
            endcase
        end
        6'd31: begin // 载
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h018600;
                5'd 5: glyph = 24'h018660;
                5'd 6: glyph = 24'h1FF230;
                5'd 7: glyph = 24'h1FF210;
                5'd 8: glyph = 24'h018200;
                5'd 9: glyph = 24'h3FFFFC;
                5'd10: glyph = 24'h030700;
                5'd11: glyph = 24'h030200;
                5'd12: glyph = 24'h1FF330;
                5'd13: glyph = 24'h3FFB30;
                5'd14: glyph = 24'h0C0320;
                5'd15: glyph = 24'h098360;
                5'd16: glyph = 24'h1FF160;
                5'd17: glyph = 24'h1FF1C0;
                5'd18: glyph = 24'h0181C0;
                5'd19: glyph = 24'h01F1C0;
                5'd20: glyph = 24'h3FF3CC;
                5'd21: glyph = 24'h3D866C;
                5'd22: glyph = 24'h019C38;
                5'd23: glyph = 24'h019838;
                default: glyph = 24'h000000;
            endcase
        end
        6'd32: begin // 人
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h001800;
                5'd 5: glyph = 24'h001800;
                5'd 6: glyph = 24'h001800;
                5'd 7: glyph = 24'h001800;
                5'd 8: glyph = 24'h001800;
                5'd 9: glyph = 24'h001800;
                5'd10: glyph = 24'h001800;
                5'd11: glyph = 24'h003800;
                5'd12: glyph = 24'h003800;
                5'd13: glyph = 24'h003C00;
                5'd14: glyph = 24'h003400;
                5'd15: glyph = 24'h006600;
                5'd16: glyph = 24'h006700;
                5'd17: glyph = 24'h00C300;
                5'd18: glyph = 24'h01C180;
                5'd19: glyph = 24'h0381C0;
                5'd20: glyph = 24'h0700E0;
                5'd21: glyph = 24'h0E0078;
                5'd22: glyph = 24'h1C003C;
                5'd23: glyph = 24'h180008;
                default: glyph = 24'h000000;
            endcase
        end
        6'd33: begin // 飞
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h100000;
                5'd 6: glyph = 24'h1FFE00;
                5'd 7: glyph = 24'h000620;
                5'd 8: glyph = 24'h000670;
                5'd 9: glyph = 24'h0006E0;
                5'd10: glyph = 24'h0006C0;
                5'd11: glyph = 24'h000780;
                5'd12: glyph = 24'h000700;
                5'd13: glyph = 24'h0007C0;
                5'd14: glyph = 24'h0006E0;
                5'd15: glyph = 24'h000670;
                5'd16: glyph = 24'h000630;
                5'd17: glyph = 24'h000600;
                5'd18: glyph = 24'h000300;
                5'd19: glyph = 24'h000308;
                5'd20: glyph = 24'h00018C;
                5'd21: glyph = 24'h0001F8;
                5'd22: glyph = 24'h0000F8;
                5'd23: glyph = 24'h000030;
                default: glyph = 24'h000000;
            endcase
        end
        6'd34: begin // 行
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h030000;
                5'd 5: glyph = 24'h071FF8;
                5'd 6: glyph = 24'h061FF8;
                5'd 7: glyph = 24'h0C0000;
                5'd 8: glyph = 24'h180000;
                5'd 9: glyph = 24'h310000;
                5'd10: glyph = 24'h138000;
                5'd11: glyph = 24'h033FFC;
                5'd12: glyph = 24'h063FFC;
                5'd13: glyph = 24'h0E00C0;
                5'd14: glyph = 24'h1E00C0;
                5'd15: glyph = 24'h3E00C0;
                5'd16: glyph = 24'h3600C0;
                5'd17: glyph = 24'h0600C0;
                5'd18: glyph = 24'h0600C0;
                5'd19: glyph = 24'h0600C0;
                5'd20: glyph = 24'h0600C0;
                5'd21: glyph = 24'h0600C0;
                5'd22: glyph = 24'h0603C0;
                5'd23: glyph = 24'h0603C0;
                default: glyph = 24'h000000;
            endcase
        end
        6'd35: begin // 梦
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h010080;
                5'd 5: glyph = 24'h010180;
                5'd 6: glyph = 24'h030180;
                5'd 7: glyph = 24'h1FEFF8;
                5'd 8: glyph = 24'h0701C0;
                5'd 9: glyph = 24'h07C3E0;
                5'd10: glyph = 24'h0FE7B0;
                5'd11: glyph = 24'h192C98;
                5'd12: glyph = 24'h3B1D8C;
                5'd13: glyph = 24'h136980;
                5'd14: glyph = 24'h006000;
                5'd15: glyph = 24'h00FFE0;
                5'd16: glyph = 24'h01FFE0;
                5'd17: glyph = 24'h0300C0;
                5'd18: glyph = 24'h0E71C0;
                5'd19: glyph = 24'h043B80;
                5'd20: glyph = 24'h000F00;
                5'd21: glyph = 24'h003C00;
                5'd22: glyph = 24'h0FF800;
                5'd23: glyph = 24'h0FC000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd36: begin // 天
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h0FFFF0;
                5'd 6: glyph = 24'h0FFFE0;
                5'd 7: glyph = 24'h001800;
                5'd 8: glyph = 24'h001800;
                5'd 9: glyph = 24'h001800;
                5'd10: glyph = 24'h001800;
                5'd11: glyph = 24'h1FFFF8;
                5'd12: glyph = 24'h1FFFF8;
                5'd13: glyph = 24'h001800;
                5'd14: glyph = 24'h003C00;
                5'd15: glyph = 24'h003C00;
                5'd16: glyph = 24'h006600;
                5'd17: glyph = 24'h006700;
                5'd18: glyph = 24'h00C300;
                5'd19: glyph = 24'h01C1C0;
                5'd20: glyph = 24'h0380E0;
                5'd21: glyph = 24'h0F007C;
                5'd22: glyph = 24'h3C003C;
                5'd23: glyph = 24'h100000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd37: begin // 转
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h020100;
                5'd 5: glyph = 24'h060300;
                5'd 6: glyph = 24'h060300;
                5'd 7: glyph = 24'h3FDFF8;
                5'd 8: glyph = 24'h3FDFF8;
                5'd 9: glyph = 24'h0C0300;
                5'd10: glyph = 24'h090200;
                5'd11: glyph = 24'h1B1FF8;
                5'd12: glyph = 24'h133FFC;
                5'd13: glyph = 24'h3FC600;
                5'd14: glyph = 24'h3FC400;
                5'd15: glyph = 24'h030FF8;
                5'd16: glyph = 24'h0307F8;
                5'd17: glyph = 24'h03C070;
                5'd18: glyph = 24'h3FC0E0;
                5'd19: glyph = 24'h3F0CC0;
                5'd20: glyph = 24'h030F80;
                5'd21: glyph = 24'h030380;
                5'd22: glyph = 24'h0300E0;
                5'd23: glyph = 24'h030060;
                default: glyph = 24'h000000;
            endcase
        end
        6'd38: begin // 位
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h020600;
                5'd 5: glyph = 24'h030600;
                5'd 6: glyph = 24'h070300;
                5'd 7: glyph = 24'h060300;
                5'd 8: glyph = 24'h067FF8;
                5'd 9: glyph = 24'h0E7FF8;
                5'd10: glyph = 24'h0E0000;
                5'd11: glyph = 24'h1E0060;
                5'd12: glyph = 24'h1E3060;
                5'd13: glyph = 24'h363060;
                5'd14: glyph = 24'h3618E0;
                5'd15: glyph = 24'h0618C0;
                5'd16: glyph = 24'h0618C0;
                5'd17: glyph = 24'h0618C0;
                5'd18: glyph = 24'h060C80;
                5'd19: glyph = 24'h060D80;
                5'd20: glyph = 24'h060180;
                5'd21: glyph = 24'h06FFFC;
                5'd22: glyph = 24'h06FFFC;
                5'd23: glyph = 24'h060000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd39: begin // 空
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h001800;
                5'd 5: glyph = 24'h001800;
                5'd 6: glyph = 24'h001800;
                5'd 7: glyph = 24'h1FFFF8;
                5'd 8: glyph = 24'h1FFFF8;
                5'd 9: glyph = 24'h180018;
                5'd10: glyph = 24'h19C318;
                5'd11: glyph = 24'h0383C0;
                5'd12: glyph = 24'h0700F0;
                5'd13: glyph = 24'h1C0038;
                5'd14: glyph = 24'h180010;
                5'd15: glyph = 24'h07FFE0;
                5'd16: glyph = 24'h07FFE0;
                5'd17: glyph = 24'h001800;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h001800;
                5'd20: glyph = 24'h001800;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h3FFFFC;
                5'd23: glyph = 24'h3FFFFC;
                default: glyph = 24'h000000;
            endcase
        end
        6'd40: begin // 间
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h060000;
                5'd 5: glyph = 24'h073FF8;
                5'd 6: glyph = 24'h033FF8;
                5'd 7: glyph = 24'h010018;
                5'd 8: glyph = 24'h180018;
                5'd 9: glyph = 24'h180018;
                5'd10: glyph = 24'h18FF18;
                5'd11: glyph = 24'h18C318;
                5'd12: glyph = 24'h188118;
                5'd13: glyph = 24'h188318;
                5'd14: glyph = 24'h18FF18;
                5'd15: glyph = 24'h18C318;
                5'd16: glyph = 24'h188118;
                5'd17: glyph = 24'h188118;
                5'd18: glyph = 24'h18FF18;
                5'd19: glyph = 24'h18FF18;
                5'd20: glyph = 24'h180018;
                5'd21: glyph = 24'h180018;
                5'd22: glyph = 24'h180078;
                5'd23: glyph = 24'h180070;
                default: glyph = 24'h000000;
            endcase
        end
        6'd41: begin // 站
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h060100;
                5'd 5: glyph = 24'h060100;
                5'd 6: glyph = 24'h030100;
                5'd 7: glyph = 24'h030100;
                5'd 8: glyph = 24'h0001FC;
                5'd 9: glyph = 24'h3FE1FC;
                5'd10: glyph = 24'h000100;
                5'd11: glyph = 24'h000100;
                5'd12: glyph = 24'h18C100;
                5'd13: glyph = 24'h18C100;
                5'd14: glyph = 24'h0CDFF8;
                5'd15: glyph = 24'h0CDFF8;
                5'd16: glyph = 24'h0C9818;
                5'd17: glyph = 24'h049818;
                5'd18: glyph = 24'h019818;
                5'd19: glyph = 24'h01F818;
                5'd20: glyph = 24'h3FD818;
                5'd21: glyph = 24'h3C1FF8;
                5'd22: glyph = 24'h001818;
                5'd23: glyph = 24'h001818;
                default: glyph = 24'h000000;
            endcase
        end
        6'd42: begin // T
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h01FF00;
                5'd 6: glyph = 24'h01FF80;
                5'd 7: glyph = 24'h003800;
                5'd 8: glyph = 24'h001800;
                5'd 9: glyph = 24'h001800;
                5'd10: glyph = 24'h001800;
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
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd43: begin // 字
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h003000;
                5'd 5: glyph = 24'h003000;
                5'd 6: glyph = 24'h001800;
                5'd 7: glyph = 24'h1FFFF8;
                5'd 8: glyph = 24'h180018;
                5'd 9: glyph = 24'h180018;
                5'd10: glyph = 24'h080000;
                5'd11: glyph = 24'h03FFC0;
                5'd12: glyph = 24'h0003C0;
                5'd13: glyph = 24'h000700;
                5'd14: glyph = 24'h001C00;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h1FFFFC;
                5'd17: glyph = 24'h1FFFFC;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h001800;
                5'd20: glyph = 24'h001800;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h007800;
                5'd23: glyph = 24'h007800;
                default: glyph = 24'h000000;
            endcase
        end
        6'd44: begin // 构
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h020400;
                5'd 5: glyph = 24'h020C00;
                5'd 6: glyph = 24'h020C00;
                5'd 7: glyph = 24'h020C00;
                5'd 8: glyph = 24'h179FFC;
                5'd 9: glyph = 24'h1FD80C;
                5'd10: glyph = 24'h06300C;
                5'd11: glyph = 24'h06340C;
                5'd12: glyph = 24'h0E060C;
                5'd13: glyph = 24'h0F8C0C;
                5'd14: glyph = 24'h1FCD8C;
                5'd15: glyph = 24'h1AD98C;
                5'd16: glyph = 24'h3210CC;
                5'd17: glyph = 24'h323FC8;
                5'd18: glyph = 24'h023FC8;
                5'd19: glyph = 24'h020048;
                5'd20: glyph = 24'h020018;
                5'd21: glyph = 24'h020018;
                5'd22: glyph = 24'h0200F8;
                5'd23: glyph = 24'h0200E0;
                default: glyph = 24'h000000;
            endcase
        end
        6'd45: begin // 型
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000018;
                5'd 5: glyph = 24'h1FFC18;
                5'd 6: glyph = 24'h1FF998;
                5'd 7: glyph = 24'h023198;
                5'd 8: glyph = 24'h023198;
                5'd 9: glyph = 24'h023198;
                5'd10: glyph = 24'h3FFD98;
                5'd11: glyph = 24'h3FFD98;
                5'd12: glyph = 24'h063198;
                5'd13: glyph = 24'h063198;
                5'd14: glyph = 24'h0C3018;
                5'd15: glyph = 24'h1C3078;
                5'd16: glyph = 24'h181820;
                5'd17: glyph = 24'h001800;
                5'd18: glyph = 24'h0FFFF0;
                5'd19: glyph = 24'h07FFE0;
                5'd20: glyph = 24'h001800;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h3FFFFC;
                5'd23: glyph = 24'h3FFFFC;
                default: glyph = 24'h000000;
            endcase
        end
        6'd46: begin // 完
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h003000;
                5'd 5: glyph = 24'h003800;
                5'd 6: glyph = 24'h1FFFF8;
                5'd 7: glyph = 24'h3FFFF8;
                5'd 8: glyph = 24'h180018;
                5'd 9: glyph = 24'h180018;
                5'd10: glyph = 24'h13FF88;
                5'd11: glyph = 24'h03FFC0;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h000000;
                5'd14: glyph = 24'h3FFFFC;
                5'd15: glyph = 24'h3FFFFC;
                5'd16: glyph = 24'h00C600;
                5'd17: glyph = 24'h00C600;
                5'd18: glyph = 24'h00C600;
                5'd19: glyph = 24'h018600;
                5'd20: glyph = 24'h038618;
                5'd21: glyph = 24'h07061C;
                5'd22: glyph = 24'h1E07F8;
                5'd23: glyph = 24'h3C03F0;
                default: glyph = 24'h000000;
            endcase
        end
        6'd47: begin // 6
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000C00;
                5'd 6: glyph = 24'h000C00;
                5'd 7: glyph = 24'h001800;
                5'd 8: glyph = 24'h003800;
                5'd 9: glyph = 24'h003000;
                5'd10: glyph = 24'h006000;
                5'd11: glyph = 24'h007E00;
                5'd12: glyph = 24'h00FF00;
                5'd13: glyph = 24'h01C380;
                5'd14: glyph = 24'h018180;
                5'd15: glyph = 24'h018180;
                5'd16: glyph = 24'h018180;
                5'd17: glyph = 24'h018180;
                5'd18: glyph = 24'h01C180;
                5'd19: glyph = 24'h00E380;
                5'd20: glyph = 24'h00FF00;
                5'd21: glyph = 24'h003C00;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd48: begin // 8
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h003800;
                5'd 6: glyph = 24'h00FE00;
                5'd 7: glyph = 24'h00C700;
                5'd 8: glyph = 24'h018300;
                5'd 9: glyph = 24'h018300;
                5'd10: glyph = 24'h018300;
                5'd11: glyph = 24'h00C700;
                5'd12: glyph = 24'h00FE00;
                5'd13: glyph = 24'h00FE00;
                5'd14: glyph = 24'h01C700;
                5'd15: glyph = 24'h018380;
                5'd16: glyph = 24'h018180;
                5'd17: glyph = 24'h018180;
                5'd18: glyph = 24'h018380;
                5'd19: glyph = 24'h01C700;
                5'd20: glyph = 24'h00FE00;
                5'd21: glyph = 24'h003C00;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd49: begin // 朱
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h001800;
                5'd 5: glyph = 24'h031800;
                5'd 6: glyph = 24'h061800;
                5'd 7: glyph = 24'h061800;
                5'd 8: glyph = 24'h0FFFE0;
                5'd 9: glyph = 24'h0FFFE0;
                5'd10: glyph = 24'h1C1800;
                5'd11: glyph = 24'h001800;
                5'd12: glyph = 24'h001800;
                5'd13: glyph = 24'h3FFFFC;
                5'd14: glyph = 24'h007E00;
                5'd15: glyph = 24'h00DE00;
                5'd16: glyph = 24'h00DB00;
                5'd17: glyph = 24'h019B80;
                5'd18: glyph = 24'h0319C0;
                5'd19: glyph = 24'h0718E0;
                5'd20: glyph = 24'h0E1878;
                5'd21: glyph = 24'h3C183C;
                5'd22: glyph = 24'h181808;
                5'd23: glyph = 24'h001800;
                default: glyph = 24'h000000;
            endcase
        end
        6'd50: begin // 雀
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h001000;
                5'd 5: glyph = 24'h0110C0;
                5'd 6: glyph = 24'h0390F0;
                5'd 7: glyph = 24'h0713B8;
                5'd 8: glyph = 24'h0E1F18;
                5'd 9: glyph = 24'h003C00;
                5'd10: glyph = 24'h00FC00;
                5'd11: glyph = 24'h0FCC00;
                5'd12: glyph = 24'h3FFFF0;
                5'd13: glyph = 24'h07FFF0;
                5'd14: glyph = 24'h060400;
                5'd15: glyph = 24'h07FFE0;
                5'd16: glyph = 24'h07FFE0;
                5'd17: glyph = 24'h060400;
                5'd18: glyph = 24'h07FFE0;
                5'd19: glyph = 24'h07FFE0;
                5'd20: glyph = 24'h060400;
                5'd21: glyph = 24'h07FFF8;
                5'd22: glyph = 24'h07FFF8;
                5'd23: glyph = 24'h060000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd51: begin // 三
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h0FFFF0;
                5'd 7: glyph = 24'h0FFFF0;
                5'd 8: glyph = 24'h000000;
                5'd 9: glyph = 24'h000000;
                5'd10: glyph = 24'h000000;
                5'd11: glyph = 24'h000000;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h07FFC0;
                5'd14: glyph = 24'h07FFC0;
                5'd15: glyph = 24'h000000;
                5'd16: glyph = 24'h000000;
                5'd17: glyph = 24'h000000;
                5'd18: glyph = 24'h000000;
                5'd19: glyph = 24'h000000;
                5'd20: glyph = 24'h000000;
                5'd21: glyph = 24'h3FFFFC;
                5'd22: glyph = 24'h3FFFF8;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd52: begin // 遥
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000010;
                5'd 5: glyph = 24'h1007F0;
                5'd 6: glyph = 24'h18FF80;
                5'd 7: glyph = 24'h0C4010;
                5'd 8: glyph = 24'h044630;
                5'd 9: glyph = 24'h006320;
                5'd10: glyph = 24'h002020;
                5'd11: glyph = 24'h003000;
                5'd12: glyph = 24'h3C3FF0;
                5'd13: glyph = 24'h1C6300;
                5'd14: glyph = 24'h0C0300;
                5'd15: glyph = 24'h0CFFFC;
                5'd16: glyph = 24'h0CFFF8;
                5'd17: glyph = 24'h0C2310;
                5'd18: glyph = 24'h0C6310;
                5'd19: glyph = 24'h0C7FF0;
                5'd20: glyph = 24'h0C7FF0;
                5'd21: glyph = 24'h1F0010;
                5'd22: glyph = 24'h39FFFC;
                5'd23: glyph = 24'h303FFC;
                default: glyph = 24'h000000;
            endcase
        end
        6'd53: begin // 二
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h000000;
                5'd 6: glyph = 24'h000000;
                5'd 7: glyph = 24'h000000;
                5'd 8: glyph = 24'h0FFFF0;
                5'd 9: glyph = 24'h07FFE0;
                5'd10: glyph = 24'h000000;
                5'd11: glyph = 24'h000000;
                5'd12: glyph = 24'h000000;
                5'd13: glyph = 24'h000000;
                5'd14: glyph = 24'h000000;
                5'd15: glyph = 24'h000000;
                5'd16: glyph = 24'h000000;
                5'd17: glyph = 24'h000000;
                5'd18: glyph = 24'h000000;
                5'd19: glyph = 24'h000000;
                5'd20: glyph = 24'h3FFFFC;
                5'd21: glyph = 24'h3FFFFC;
                5'd22: glyph = 24'h000000;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd54: begin // 子
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h07FFE0;
                5'd 6: glyph = 24'h0FFFF0;
                5'd 7: glyph = 24'h0001E0;
                5'd 8: glyph = 24'h000380;
                5'd 9: glyph = 24'h000E00;
                5'd10: glyph = 24'h001800;
                5'd11: glyph = 24'h001800;
                5'd12: glyph = 24'h001800;
                5'd13: glyph = 24'h3FFFFC;
                5'd14: glyph = 24'h1FFFE0;
                5'd15: glyph = 24'h001800;
                5'd16: glyph = 24'h001800;
                5'd17: glyph = 24'h001800;
                5'd18: glyph = 24'h001800;
                5'd19: glyph = 24'h001800;
                5'd20: glyph = 24'h001800;
                5'd21: glyph = 24'h001800;
                5'd22: glyph = 24'h00F800;
                5'd23: glyph = 24'h007000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd55: begin // 级
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h060000;
                5'd 6: glyph = 24'h063FE0;
                5'd 7: glyph = 24'h0C0C60;
                5'd 8: glyph = 24'h0CC860;
                5'd 9: glyph = 24'h18C840;
                5'd10: glyph = 24'h398840;
                5'd11: glyph = 24'h3F08C0;
                5'd12: glyph = 24'h0308F8;
                5'd13: glyph = 24'h060C18;
                5'd14: glyph = 24'h040C10;
                5'd15: glyph = 24'h0C9E30;
                5'd16: glyph = 24'h1F9A30;
                5'd17: glyph = 24'h1C1B60;
                5'd18: glyph = 24'h0031E0;
                5'd19: glyph = 24'h07B1C0;
                5'd20: glyph = 24'h3F61C0;
                5'd21: glyph = 24'h10C3F0;
                5'd22: glyph = 24'h01CE3C;
                5'd23: glyph = 24'h001C1C;
                default: glyph = 24'h000000;
            endcase
        end
        6'd56: begin // 陆
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000100;
                5'd 5: glyph = 24'h1F8180;
                5'd 6: glyph = 24'h3F8180;
                5'd 7: glyph = 24'h318180;
                5'd 8: glyph = 24'h319FF8;
                5'd 9: glyph = 24'h330380;
                5'd10: glyph = 24'h330180;
                5'd11: glyph = 24'h320180;
                5'd12: glyph = 24'h323FFC;
                5'd13: glyph = 24'h333FFC;
                5'd14: glyph = 24'h318180;
                5'd15: glyph = 24'h318180;
                5'd16: glyph = 24'h30B198;
                5'd17: glyph = 24'h31B198;
                5'd18: glyph = 24'h37B198;
                5'd19: glyph = 24'h373198;
                5'd20: glyph = 24'h303118;
                5'd21: glyph = 24'h303FF8;
                5'd22: glyph = 24'h303FF8;
                5'd23: glyph = 24'h300018;
                default: glyph = 24'h000000;
            endcase
        end
        6'd57: begin // 地
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h040300;
                5'd 5: glyph = 24'h060300;
                5'd 6: glyph = 24'h061100;
                5'd 7: glyph = 24'h063100;
                5'd 8: glyph = 24'h063300;
                5'd 9: glyph = 24'h063178;
                5'd10: glyph = 24'h3FB3F8;
                5'd11: glyph = 24'h3FBF98;
                5'd12: glyph = 24'h067B18;
                5'd13: glyph = 24'h06F118;
                5'd14: glyph = 24'h063118;
                5'd15: glyph = 24'h063118;
                5'd16: glyph = 24'h063138;
                5'd17: glyph = 24'h063170;
                5'd18: glyph = 24'h07B300;
                5'd19: glyph = 24'h0FB100;
                5'd20: glyph = 24'h3E300C;
                5'd21: glyph = 24'h10381C;
                5'd22: glyph = 24'h001FF8;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd58: begin // 回
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h000000;
                5'd 5: glyph = 24'h0FFFF0;
                5'd 6: glyph = 24'h1FFFF0;
                5'd 7: glyph = 24'h180010;
                5'd 8: glyph = 24'h180010;
                5'd 9: glyph = 24'h180010;
                5'd10: glyph = 24'h18FF10;
                5'd11: glyph = 24'h18C310;
                5'd12: glyph = 24'h18C310;
                5'd13: glyph = 24'h18C310;
                5'd14: glyph = 24'h18C310;
                5'd15: glyph = 24'h18C310;
                5'd16: glyph = 24'h18FF10;
                5'd17: glyph = 24'h180010;
                5'd18: glyph = 24'h180010;
                5'd19: glyph = 24'h180010;
                5'd20: glyph = 24'h1FFFF0;
                5'd21: glyph = 24'h1FFFF0;
                5'd22: glyph = 24'h180010;
                5'd23: glyph = 24'h000000;
                default: glyph = 24'h000000;
            endcase
        end
        6'd59: begin // 收
            case (row)
                5'd 0: glyph = 24'h000000;
                5'd 1: glyph = 24'h000000;
                5'd 2: glyph = 24'h000000;
                5'd 3: glyph = 24'h000000;
                5'd 4: glyph = 24'h018600;
                5'd 5: glyph = 24'h018600;
                5'd 6: glyph = 24'h018600;
                5'd 7: glyph = 24'h118C00;
                5'd 8: glyph = 24'h318FFC;
                5'd 9: glyph = 24'h319FFC;
                5'd10: glyph = 24'h319860;
                5'd11: glyph = 24'h31BC60;
                5'd12: glyph = 24'h31BC60;
                5'd13: glyph = 24'h31A460;
                5'd14: glyph = 24'h318660;
                5'd15: glyph = 24'h3186C0;
                5'd16: glyph = 24'h3F82C0;
                5'd17: glyph = 24'h3F83C0;
                5'd18: glyph = 24'h318380;
                5'd19: glyph = 24'h018380;
                5'd20: glyph = 24'h0187C0;
                5'd21: glyph = 24'h019C70;
                5'd22: glyph = 24'h01B83C;
                5'd23: glyph = 24'h01B008;
                default: glyph = 24'h000000;
            endcase
        end
        default: glyph = 24'h000000;
    endcase
end

endmodule
