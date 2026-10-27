`timescale 1ns/1ps

// ============================================================
// video_bc_adjust —— 亮度 / 对比度实时调节引擎（扩展要求 4）
//
// 公式（逐通道，围绕中值 128 做对比度拉伸）：
//     out = clamp( ((in - 128) * K / 100) + 128 + B )
//
// 拨码开关低 3 位 = 档位数 m（0~7），最高位 = 方向（1=负）：
//   每一档的调节幅度按二进制加权：bit0=10%，bit1=20%，bit2=40%
//   组合出的幅度 = m * 10%，即 0/10/20/30/40/50/60/70%
//   全部 OFF（0x0）= 原始画面；bit3=1 时为负方向。
//   例：SW=0b0011(+3) -> 亮度 +30%、对比度 +30%；
//       SW=0b1100(-4) -> 幅度 40%，负方向。
//
//   亮度 B = 幅度% * 128 / 100  （约 ±90 灰阶 @70%）
//   对比度 K = 100% + 幅度%      （30%..170%，100=原始）
//
// 除以 100 用乘 41 右移 12 近似（41/4096 = 1/99.76，误差 <0.25%）。
// 注意 Verilog 乘法结果位宽 = 操作数最大位宽，所有中间量显式扩位。
// K41/B 只依赖开关状态，不依赖像素，综合时提为公共项。
// 拨码开关改动的下一个像素就生效，属于"实时调节"。
// 纯组合逻辑，不改变 HS/VS/DE，也不改变像素时序。
// ============================================================
module video_bc_adjust (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,          // 1 = 使能调节，0 = 原图直通

    input  wire [3:0]  bright_lvl,      // {方向, m[2:0]}，0 = 原始亮度
    input  wire [3:0]  contrast_lvl,    // {方向, m[2:0]}，0 = 原始对比度

    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);

    // ---- 幅度百分比（有符号，-70..+70，1 档 = 10%） ----
    // m*10 = m*8 + m*2，最大 70
    wire [7:0] b_m10 = ({1'b0, bright_lvl[2:0], 3'b000}) + ({2'b0, bright_lvl[2:0], 1'b0});
    wire [7:0] c_m10 = ({1'b0, contrast_lvl[2:0], 3'b000}) + ({2'b0, contrast_lvl[2:0], 1'b0});

    wire signed [8:0] b_pct = bright_lvl[3]   ? -$signed({1'b0, b_m10}) : $signed({1'b0, b_m10});
    wire signed [8:0] c_pct = contrast_lvl[3] ? -$signed({1'b0, c_m10}) : $signed({1'b0, c_m10});

    // 亮度偏移 B = pct * 128/100 ≈ pct * 41 / 32   （-90..+89）
    // 9bit * 15bit -> 15bit 结果，±2870 无溢出
    wire signed [14:0] bright_off = (b_pct * $signed(15'd41)) >>> 5;

    // 对比度系数：K = 100 + pct（30..170），K41 = K * 41（1230..6970）
    // 10bit * 15bit -> 15bit 结果，6970 无溢出
    wire signed [9:0]  c_k   = $signed(10'd100) + c_pct;
    wire signed [14:0] c_k41 = c_k * $signed(15'd41);

    function [7:0] bc_apply;
        input [7:0] ch;
        reg signed [10:0] d;
        reg signed [14:0] k41;
        reg signed [21:0] p;
        reg signed [21:0] pr;
        reg signed [22:0] v;
        begin
            d   = $signed({3'd0, ch}) - $signed(11'd128);
            // 显式扩位到 22bit 再相乘：11bit * 22bit -> 22bit，±89 万无溢出
            k41 = $signed({{7{c_k41[14]}}, c_k41});
            p   = d * k41;                       // = (in-128)*K*41
            // >>12 ≈ /100，先加 2048 做四舍五入，避免负方向整体偏暗 1 灰阶
            pr  = p + $signed(22'd2048);
            v   = $signed({{11{pr[21]}}, pr[21:12]})
                + $signed({{8{bright_off[14]}}, bright_off})
                + $signed(23'd128);
            if (v > $signed(23'd255))
                bc_apply = 8'd255;
            else if (v < $signed(23'd0))
                bc_apply = 8'd0;
            else
                bc_apply = v[7:0];
        end
    endfunction

    always @* begin
        if (enable) begin
            rgb_out[23:16] = bc_apply(rgb_in[23:16]);
            rgb_out[15:8]  = bc_apply(rgb_in[15:8]);
            rgb_out[7:0]   = bc_apply(rgb_in[7:0]);
        end else begin
            rgb_out = rgb_in;
        end
    end

endmodule
