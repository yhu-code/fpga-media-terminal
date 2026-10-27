`timescale 1ns/1ps

// ============================================================
// osd_alpha_blend
// 轻量级 RGB Alpha 混合器。
//
// ALPHA 范围 0~16：
//   0  = 完全显示背景
//   4  = 前景 25%
//   8  = 前景 50%
//   12 = 前景 75%
//   16 = 完全显示前景
//
// 默认使用 ALPHA=8，仅由移位/加法实现，不使用乘法器。
// ============================================================
module osd_alpha_blend #(
    parameter integer ALPHA = 8
)(
    input  [23:0] bg_rgb,
    input  [23:0] fg_rgb,
    output reg [23:0] out_rgb
);

    function [7:0] blend_channel;
        input [7:0] bg;
        input [7:0] fg;
        begin
            case (ALPHA)
                0: begin
                    blend_channel = bg;
                end
                4: begin
                    // (3*bg + 1*fg) / 4
                    blend_channel = ((bg << 1) + bg + fg) >> 2;
                end
                8: begin
                    // (bg + fg) / 2，精确到整数像素
                    blend_channel = (bg >> 1) + (fg >> 1) + (bg[0] & fg[0]);
                end
                12: begin
                    // (1*bg + 3*fg) / 4
                    blend_channel = (bg + (fg << 1) + fg) >> 2;
                end
                16: begin
                    blend_channel = fg;
                end
                default: begin
                    // 为了保持组合逻辑轻量，未支持的 Alpha 值回退到 50%。
                    blend_channel = (bg >> 1) + (fg >> 1) + (bg[0] & fg[0]);
                end
            endcase
        end
    endfunction

    always @* begin
        out_rgb = {
            blend_channel(bg_rgb[23:16], fg_rgb[23:16]),
            blend_channel(bg_rgb[15:8],  fg_rgb[15:8]),
            blend_channel(bg_rgb[7:0],   fg_rgb[7:0])
        };
    end

endmodule
