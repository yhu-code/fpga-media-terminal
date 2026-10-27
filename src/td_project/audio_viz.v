`timescale 1ns/1ps

// ============================================================
// audio_viz —— 扩展6：I2S/PCM 音频频谱可视化（彩虹竖条 / 频域）
//
// 与 v27 版本的区别：
//   v27：右下角 264x124 面板，内含示波器波形 + 16 段单色三段（绿/黄/红）柱
//   v28：只有频域竖条，32 段，每段固定一种彩虹色（颜色代表频率，不随音量变），
//         以水平中线为轴上下对称生长，位置移到字幕条正下方居中
//
// 数据链（全部在 video_clk 25MHz 域，无新增时钟域）：
//   I2S_receiver 解串的 24bit PCM（48kHz，每帧一个 audio_valid）
//     -> audio_left[23:12] 作为 12bit 有符号样本 x[n]
//     -> 32 通道定点 Goertzel（单频点 DFT）：
//            s[n] = x[n] + (cQ18*s[n-1] >> 18) - s[n-2]
//        每 N=1024 点（21.3ms -> 刷新 46.9Hz）收一次功率：
//            p = (a-b)^2 + (2-c')*a*b ,  a = s1>>8 , b = s2>>8
//     -> level = 4*log2(p)（1 单位 = 1.5dB），柱高 = (level-LO)*7/16
//     -> 峰值保持 + 线性回落（每块回落 DECAY）
//
// 为什么 x 轴用"对数频率"：
//   人耳对频率的感知是对数的，线性频谱会把 90% 的柱子浪费在 5k~24kHz。
//   32 个频点按对数铺满 140.6Hz ~ 6.5kHz（k=3..140，bin=46.875Hz）。
//   最低几段受 1024 点分辨率限制只能线性取 k=3..17，之后转为标准对数。
//
// 为什么用 Goertzel 而不是整块 FFT：
//   只需 32 个频点的能量，Goertzel 用 1 个乘法器 + 32 组状态寄存器顺序算完，
//   不需要 512 点复数存储、位翻转寻址和旋转因子表，省 BRAM 和 DSP，
//   结果与 DFT 对应频点完全等价（这就是"用 DFT 做频谱分析"的一种实现）。
//
// 时序预算：每个音频样本有 25e6/48e3 = 520 拍，
//   32 段 x 2 拍 = 64 拍，占用 12.3%；块末的功率统计每 21.3ms 才做一次。
//
// 显示：64 根柱 x 8px = 512px 宽，柱宽 5px、间隙 3px，居中于 640 宽屏，
//       以中线为中心上下对称（镜像柱）。
//       v31：柱数 32 -> 64。分析仍是 32 个 Goertzel 频段（不改算法、不改资源），
//       偶数柱直接取该段柱高，奇数柱取相邻两段的平均（线性插值）——
//       视觉上是 64 根连续渐变柱，频谱细节与 32 段完全一致。
//       同时去掉面板的黑色压暗底与中线：非柱像素直接透出画面（rgb = rgb_in）。
// ============================================================
module audio_viz #(
    parameter integer PANEL_X   = 64,      // 面板左上角 X（512 宽居中 -> (640-512)/2）
    parameter integer PANEL_Y   = 430,     // 面板左上角 Y（字幕条 392..425 之下）
    parameter integer PANEL_W   = 512,     // = 64 柱 x 8px
    parameter integer PANEL_H   = 46,
    parameter integer BAR_W     = 5,       // 每根柱子宽 5px（间隙 8-5=3px）
    parameter integer CEN_Y     = 23,      // 中线在面板内的相对行（0..45 的中间）
    parameter integer MAXH      = 22,      // 柱半高上限（上下各 22px -> 总高 45px）
    parameter integer LO_LEVEL  = 34,      // 噪声门限（level 单位，1 = 1.5dB，实测标定）
    parameter integer DECAY     = 2        // 每块柱回落量
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,          // display_valid

    input  wire        vs,              // 保留（本版不再画波形，无需帧同步）
    input  wire        de,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out,

    // 音频输入（I2S 解串结果，与 clk 同域）
    input  wire        audio_valid,
    input  wire [23:0] audio_left,

    // 调试（供 UART 明文输出；dbg_tgl 用于跨到 sd_card_clk）
    output reg  [15:0] dbg_cnt,         // 已处理样本计数（每块锁存）
    output reg  [7:0]  dbg_blk,         // 已完成的块计数
    output reg         dbg_seen,        // 曾经收到过 audio_valid
    output reg  [63:0] dbg_bands,       // 32 段压缩成 16 个 4bit（相邻两段取最大>>1）
    output reg         dbg_tgl          // 数据锁存完成翻转（跨域握手）
);

    localparam [4:0]   KMAX = 5'd31;
    localparam integer NBLK = 1024;

    // ---------------------------------------------------------
    // 0. 样本格式（24bit 左对齐 -> 12bit 有符号）
    // ---------------------------------------------------------
    wire signed [11:0] x12 = $signed(audio_left[23:12]);

    // ---------------------------------------------------------
    // 1. Goertzel 状态机
    // ---------------------------------------------------------
    localparam [2:0] A_IDLE = 3'd0, A_MUL = 3'd1, A_ACC = 3'd2,
                     P_M1   = 3'd3, P_M2  = 3'd4, P_M3  = 3'd5, P_LVL = 3'd6,
                     P_LVL2 = 3'd7;

    reg  [2:0]         ast;
    reg  [4:0]         kidx;
    reg  [9:0]         scnt;
    reg  signed [11:0] xs;

    // 中间状态 26bit：低频段的两极点谐振器本质是积分器，
    // 实测 |s1| 峰值 1.18e7，而最终 |X(k)| 只有 2.4e5。
    // 23bit（±4.19e6）会被饱和钳死，26bit（±3.35e7）有 2.8 倍余量。
    // 注意：这两组 26bit x 32 阵列会被综合成分布式 RAM（LUT-RAM）。
    //   它们就是布线 PHY-8023（ramread0 vs ramread1 抢同一 local 资源）
    //   的来源。试过 (* syn_ramstyle = "registers" *) 与 "block"，
    //   安路 TD 6.2.1 都不识别（资源计数完全不变），因此只能靠扫布线种子。
    //   若要根治，得把 s1/s2 拆成 32 个独立寄存器变量（组合读必须用 LUT，
    //   不能用 BRAM，否则读会变成同步读、改变时序语义）。
    reg  signed [25:0] s1 [0:31];
    reg  signed [25:0] s2 [0:31];

    // 系数 2cos(2*pi*k/1024) 的 Q18 定点。低频段对系数精度极敏感：
    // k=3 时 2cos(w)=1.9996573，Q14 量化成 1.9998779 会让谐振点偏 10%，
    // 算出的 |X| 差 2 倍以上。Q18 后误差 < 0.05dB。
    reg  signed [20:0] coef;
    always @* begin
        case (kidx)
            5'd0 : coef = 21'sd524199;   // k=3   ->   140.6Hz
            5'd1 : coef = 21'sd524130;   // k=4   ->   187.5Hz
            5'd2 : coef = 21'sd524041;   // k=5   ->   234.4Hz
            5'd3 : coef = 21'sd523933;   // k=6   ->   281.2Hz
            5'd4 : coef = 21'sd523804;   // k=7   ->   328.1Hz
            5'd5 : coef = 21'sd523656;   // k=8   ->   375.0Hz
            5'd6 : coef = 21'sd523489;   // k=9   ->   421.9Hz
            5'd7 : coef = 21'sd523301;   // k=10  ->   468.8Hz
            5'd8 : coef = 21'sd523094;   // k=11  ->   515.6Hz
            5'd9 : coef = 21'sd522867;   // k=12  ->   562.5Hz
            5'd10: coef = 21'sd522621;   // k=13  ->   609.4Hz
            5'd11: coef = 21'sd522355;   // k=14  ->   656.2Hz
            5'd12: coef = 21'sd522069;   // k=15  ->   703.1Hz
            5'd13: coef = 21'sd521763;   // k=16  ->   750.0Hz
            5'd14: coef = 21'sd521438;   // k=17  ->   796.9Hz
            5'd15: coef = 21'sd520729;   // k=19  ->   890.6Hz
            5'd16: coef = 21'sd519518;   // k=22  ->  1031.2Hz
            5'd17: coef = 21'sd518132;   // k=25  ->  1171.9Hz
            5'd18: coef = 21'sd516569;   // k=28  ->  1312.5Hz
            5'd19: coef = 21'sd514214;   // k=32  ->  1500.0Hz
            5'd20: coef = 21'sd511549;   // k=36  ->  1687.5Hz
            5'd21: coef = 21'sd507785;   // k=41  ->  1921.9Hz
            5'd22: coef = 21'sd503542;   // k=46  ->  2156.2Hz
            5'd23: coef = 21'sd497826;   // k=52  ->  2437.5Hz
            5'd24: coef = 21'sd490305;   // k=59  ->  2765.6Hz
            5'd25: coef = 21'sd480604;   // k=67  ->  3140.6Hz
            5'd26: coef = 21'sd469744;   // k=75  ->  3515.6Hz
            5'd27: coef = 21'sd454582;   // k=85  ->  3984.4Hz
            5'd28: coef = 21'sd434134;   // k=97  ->  4546.9Hz
            5'd29: coef = 21'sd411334;   // k=109 ->  5109.4Hz
            5'd30: coef = 21'sd379714;   // k=124 ->  5812.5Hz
            default: coef = 21'sd342451; // k=140 ->  6562.5Hz
        endcase
    end

    wire signed [25:0] s1w = s1[kidx];
    wire signed [25:0] s2w = s2[kidx];

    reg  signed [47:0] prod;
    wire signed [29:0] sr   = prod >>> 18;
    wire signed [29:0] sxx  = {{18{xs[11]}}, xs};
    wire signed [29:0] s2x  = {{4{s2w[25]}}, s2w};
    wire signed [29:0] ssum = sxx + sr - s2x;
    wire signed [25:0] snew = (ssum >  30'sd33554431) ?  26'sd33554431 :
                              (ssum < -30'sd33554432) ? -26'sd33554432 : ssum[25:0];

    // 功率统计阶段
    //
    // 原式 p = a^2 + b^2 - c'*a*b 在低频段是"大数相减"：要保留的 p 只有 6e3，
    // 而 a^2 约 1.4e8，a,b 的 0.5LSB 量化误差就把 p 淹没（实测柱高错 16px）。
    // 恒等变形为 p = (a-b)^2 + (2-c')*a*b，其中 (a-b)^2 整数精确、无相消。
    wire signed [20:0] dc     = 21'sd524288 - coef;  // (2-c') 的 Q18 表示

    reg  signed [35:0] tca;      // dc*a（精确，不预移位：dc 跨 4 个数量级）
    reg  signed [35:0] tcb;      // (dc*a*b)>>18
    wire signed [53:0] tcb_p = tca * b_r;   // 单独声明，避免上下文位宽截断
    reg  signed [17:0] b_r;
    reg  signed [18:0] d_r;
    reg  signed [37:0] dd_r;
    reg  signed [37:0] pwr;

    // a = s1>>8：s1 最大 ±2^25，右移 8 位后 ±2^17，18bit 装得下
    wire signed [17:0] a_now = s1w >>> 8;
    wire signed [17:0] b_now = s2w >>> 8;
    wire signed [18:0] d_now = a_now - b_now;

    // 功率 -> level -> 柱高（组合）
    wire [36:0] pmag = pwr[37] ? 37'd0 : pwr[36:0];

    reg [5:0] msb;
    integer mi;
    always @* begin
        msb = 6'd0;
        for (mi = 0; mi < 37; mi = mi + 1)
            if (pmag[mi]) msb = mi[5:0];
    end

    wire [36:0] pshift = pmag >> ((msb >= 6'd2) ? (msb - 6'd2) : 6'd0);
    wire [1:0]  frac   = (msb >= 6'd2) ? pshift[1:0] : 2'b00;
    wire [7:0]  lvl    = {msb, 2'b00} + {6'd0, frac};      // 0..147，1 = 1.5dB

    // 线性映射：bar = (lvl - LO) * 7 / 16
    //   实测（内置 8 音方波）level 分布 p10=20 / p50=41 / p90=65 / max=81。
    //   取 LO=34 时：p50 -> 3px（弱频段可见）、p90 -> 13px、峰值 -> 20px，
    //   既不会把一半柱子压成 0，峰值也接近 22px 上限，层次与参考图一致。
    localparam [7:0] LO8  = LO_LEVEL;
    localparam [7:0] MAX8 = MAXH;
    localparam [4:0] MAX5 = MAXH;
    wire [7:0]  t8     = (lvl > LO8) ? (lvl - LO8) : 8'd0;
    wire [7:0]  bar8   = (t8 * 7) >> 4;
    wire [4:0]  bar_c  = (bar8 > MAX8) ? MAX5 : bar8[4:0];

    reg [4:0] disp [0:31];
    localparam [4:0] DEC5 = DECAY;

    // v32：把"功率 -> 柱高"和"柱高 -> disp 写回"切开。
    // 原来两者在同一拍组合完成（pwr -> 37 位前导零 mux -> 变长右移 -> *7 -> 比较 -> 32 路译码），
    // 40ns 的 video_clk 周期里实测差 0.113ns。这里插一级寄存器，各占一半。
    reg [4:0] barh_r;      // 打拍后的柱高
    reg [4:0] disp_i;      // 打拍后的段索引（kidx 在 P_LVL 后才推进）

    integer ci, cj;

    always @(posedge clk) begin
        if (rst) begin
            ast  <= A_IDLE;
            kidx <= 5'd0;
            scnt <= 10'd0;
            xs   <= 12'sd0;
            prod <= 48'sd0;
            for (ci = 0; ci < 32; ci = ci + 1) begin
                s1[ci] <= 26'sd0;
                s2[ci] <= 26'sd0;
                disp[ci] <= 5'd0;
            end
        end else begin
            case (ast)
                A_IDLE: begin
                    if (audio_valid) begin
                        xs   <= x12;
                        kidx <= 5'd0;
                        ast  <= A_MUL;
                    end
                end

                A_MUL: begin
                    prod <= coef * s1w;
                    ast  <= A_ACC;
                end

                A_ACC: begin
                    s2[kidx] <= s1w;
                    s1[kidx] <= snew;
                    if (kidx == KMAX) begin
                        if (scnt == NBLK - 1) begin
                            scnt <= 10'd0;
                            kidx <= 5'd0;
                            ast  <= P_M1;       // 一块结束，进入功率统计
                        end else begin
                            scnt <= scnt + 10'd1;
                            ast  <= A_IDLE;
                        end
                    end else begin
                        kidx <= kidx + 5'd1;
                        ast  <= A_MUL;
                    end
                end

                P_M1: begin
                    d_r <= d_now;
                    b_r <= b_now;
                    tca <= dc * a_now;                    // 21x18 -> 36bit，精确
                    ast <= P_M2;
                end

                P_M2: begin
                    dd_r <= d_r * d_r;                    // (a-b)^2：整数精确，无相消
                    tcb  <= tcb_p >>> 18;                 // (2-c')*a*b
                    ast  <= P_M3;
                end

                P_M3: begin
                    pwr <= dd_r + tcb;                    // p = (a-b)^2 + (2-c')*a*b
                    ast <= P_LVL;
                end

                P_LVL2: begin    // 柱高已打拍：写 disp，并推进到下一段
                    if (barh_r >= disp[disp_i])
                        disp[disp_i] <= barh_r;
                    else if (disp[disp_i] > DEC5)
                        disp[disp_i] <= disp[disp_i] - DEC5;
                    else
                        disp[disp_i] <= 5'd0;
                    if (disp_i == KMAX) begin
                        kidx <= 5'd0;
                        ast  <= A_IDLE;
                    end else begin
                        kidx <= disp_i + 5'd1;
                        ast  <= P_M1;
                    end
                end

                default: begin    // P_LVL：功率 -> 柱高，打一拍；清分段累加器
                    s1[kidx] <= 26'sd0;
                    s2[kidx] <= 26'sd0;
                    barh_r   <= bar_c;
                    disp_i   <= kidx;
                    ast      <= P_LVL2;
                end
            endcase
        end
    end

    // 柱高更新（每段算完更新一次）：追高立即、回落每块减 DECAY
    // v32：挪进主状态机的 P_LVL2 分支，拆开组合链（见上方 barh_r 注释）

    // ---------------------------------------------------------
    // 2. 调试锁存
    // ---------------------------------------------------------
    reg [15:0] asmp;
    reg        aseen;
    reg        blk_end;
    reg        blk_end_d;

    always @(posedge clk) begin
        if (rst) begin
            asmp  <= 16'd0;
            aseen <= 1'b0;
        end else if (audio_valid) begin
            asmp  <= asmp + 16'd1;
            aseen <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            blk_end   <= 1'b0;
            blk_end_d <= 1'b0;
        end else begin
            blk_end   <= (ast == P_LVL) && (kidx == KMAX);
            blk_end_d <= blk_end;
        end
    end

    // 32 段压成 16 个 4bit：相邻两段取较大者 >>1（0..11），够看出频谱轮廓
    wire [4:0] d00 = disp[0];  wire [4:0] d01 = disp[1];
    wire [4:0] d02 = disp[2];  wire [4:0] d03 = disp[3];
    wire [4:0] d04 = disp[4];  wire [4:0] d05 = disp[5];
    wire [4:0] d06 = disp[6];  wire [4:0] d07 = disp[7];
    wire [4:0] d08 = disp[8];  wire [4:0] d09 = disp[9];
    wire [4:0] d10 = disp[10]; wire [4:0] d11 = disp[11];
    wire [4:0] d12 = disp[12]; wire [4:0] d13 = disp[13];
    wire [4:0] d14 = disp[14]; wire [4:0] d15 = disp[15];
    wire [4:0] d16 = disp[16]; wire [4:0] d17 = disp[17];
    wire [4:0] d18 = disp[18]; wire [4:0] d19 = disp[19];
    wire [4:0] d20 = disp[20]; wire [4:0] d21 = disp[21];
    wire [4:0] d22 = disp[22]; wire [4:0] d23 = disp[23];
    wire [4:0] d24 = disp[24]; wire [4:0] d25 = disp[25];
    wire [4:0] d26 = disp[26]; wire [4:0] d27 = disp[27];
    wire [4:0] d28 = disp[28]; wire [4:0] d29 = disp[29];
    wire [4:0] d30 = disp[30]; wire [4:0] d31 = disp[31];

    function [3:0] pack2;
        input [4:0] a;
        input [4:0] b;
        reg   [4:0] m;
        begin
            m = (a > b) ? a : b;
            pack2 = m[4:1];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            dbg_cnt   <= 16'd0;
            dbg_blk   <= 8'd0;
            dbg_seen  <= 1'b0;
            dbg_bands <= 64'd0;
            dbg_tgl   <= 1'b0;
        end else begin
            if (blk_end) begin
                dbg_cnt   <= asmp;
                dbg_blk   <= dbg_blk + 8'd1;
                dbg_seen  <= aseen;
                dbg_bands <= {pack2(d30,d31), pack2(d28,d29),
                              pack2(d26,d27), pack2(d24,d25),
                              pack2(d22,d23), pack2(d20,d21),
                              pack2(d18,d19), pack2(d16,d17),
                              pack2(d14,d15), pack2(d12,d13),
                              pack2(d10,d11), pack2(d08,d09),
                              pack2(d06,d07), pack2(d04,d05),
                              pack2(d02,d03), pack2(d00,d01)};
            end
            // 数据稳定一拍之后再翻握手位，保证跨域采样时数据已稳定
            if (blk_end_d) dbg_tgl <= ~dbg_tgl;
        end
    end

    // ---------------------------------------------------------
    // 3. 光栅化：32 段彩虹镜像竖条
    // ---------------------------------------------------------
    wire [9:0] px;
    wire [8:0] py;

    video_coord_gen_640x480 u_video_coord_gen (
        .clk      (clk),
        .rst      (rst),
        .vs       (vs),
        .de       (de),
        .pixel_x  (px),
        .pixel_y  (py)
    );

    wire in_panel = enable && de &&
                    (px >= PANEL_X) && (px < (PANEL_X + PANEL_W)) &&
                    (py >= PANEL_Y) && (py < (PANEL_Y + PANEL_H));

    wire [9:0] rx = px - PANEL_X;
    wire [8:0] ry = py - PANEL_Y;

    // 柱索引：pitch = 8px（2 的幂，直接截位，无需除法器）-> bi = 0..63
    wire [5:0] bi     = rx[8:3];
    wire [2:0] binner = rx[2:0];

    // 分析段索引：bi/2 -> 0..31
    //   偶数柱 = 该段原值；奇数柱 = 相邻两段平均（四舍五入）
    //   这样 64 根柱子是连续渐变，而不是成对重复
    wire [4:0] seg   = bi[5:1];
    wire [4:0] seg_n = (seg == 5'd31) ? 5'd31 : (seg + 5'd1);   // 钳位，避免 disp[32] 越界
    wire [4:0] hA    = disp[seg];
    wire [4:0] hB    = disp[seg_n];
    wire [5:0] hsum  = {1'b0, hA} + {1'b0, hB};
    wire [5:0] hmid6 = {1'b0, hsum[5:1]} + {5'd0, hsum[0]};   // 6 位中间值，防溢出
    // 饱和到 31：hA/hB 都取 31 时 31+1=32 会回绕成 0，柱子会突然消失
    // （当前 MAXH=22 时不会发生，这里只是把参数可调范围护住）
    wire [4:0] h_mid = (hmid6 > 6'd31) ? 5'd31 : hmid6[4:0];
    wire [4:0] h_cur = bi[0] ? h_mid : hA;

    // 上下对称：[CEN_Y-h, CEN_Y+h]；CEN_Y=23、h<=22，不会下溢。
    // 常量先收成 9 位再相减，避免 CEN_Y(integer) 把减法拉成 32 位。
    localparam [8:0] CY9 = CEN_Y;
    wire [8:0] h9    = {4'd0, h_cur};
    wire [8:0] y_top = CY9 - h9;
    wire [8:0] y_bot = CY9 + h9;

    wire bar_on  = in_panel && (binner < BAR_W) && (h_cur != 5'd0) &&
                   (ry >= y_top) && (ry <= y_bot);

    // 彩虹色表：色相 = 340° + i*11.25°，完整 360° 循环
    //   i=0 品红 -> 红 -> 橙 -> 黄 -> 绿 -> 青 -> 蓝 -> 紫 -> i=31 品红
    //   颜色只由"段号（频率）"决定，与柱高无关，这正是参考图的着色方式
    reg [23:0] col;
    always @* begin
        case (seg)
            5'd0 : col = 24'hFF0055;
            5'd1 : col = 24'hFF0025;
            5'd2 : col = 24'hFF0B00;
            5'd3 : col = 24'hFF3A00;
            5'd4 : col = 24'hFF6A00;
            5'd5 : col = 24'hFF9A00;
            5'd6 : col = 24'hFFCA00;
            5'd7 : col = 24'hFFFA00;
            5'd8 : col = 24'hD4FF00;
            5'd9 : col = 24'hA5FF00;
            5'd10: col = 24'h75FF00;
            5'd11: col = 24'h45FF00;
            5'd12: col = 24'h15FF00;
            5'd13: col = 24'h00FF1B;
            5'd14: col = 24'h00FF4A;
            5'd15: col = 24'h00FF7A;
            5'd16: col = 24'h00FFAA;
            5'd17: col = 24'h00FFDA;
            5'd18: col = 24'h00F4FF;
            5'd19: col = 24'h00C5FF;
            5'd20: col = 24'h0095FF;
            5'd21: col = 24'h0065FF;
            5'd22: col = 24'h0035FF;
            5'd23: col = 24'h0005FF;
            5'd24: col = 24'h2A00FF;
            5'd25: col = 24'h5A00FF;
            5'd26: col = 24'h8A00FF;
            5'd27: col = 24'hBA00FF;
            5'd28: col = 24'hEA00FF;
            5'd29: col = 24'hFF00E4;
            5'd30: col = 24'hFF00B5;
            default: col = 24'hFF0085;
        endcase
    end

    // v31：去掉黑色压暗底和基线，非柱像素完全透出背景
    always @* begin
        if (in_panel && bar_on)
            rgb_out = col;
        else
            rgb_out = rgb_in;
    end

endmodule
