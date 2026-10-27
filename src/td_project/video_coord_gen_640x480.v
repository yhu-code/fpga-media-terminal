`timescale 1ns/1ps

// ============================================================
// video_coord_gen_640x480
// 从已经与 RGB 对齐的 DE/VS 产生 640x480 有效区像素坐标
// pixel_x: 0~639
// pixel_y: 0~479
// 不修改原 HDMI 时序，仅提供 OSD 使用的坐标
// ============================================================
module video_coord_gen_640x480(
    input            clk,
    input            rst,
    input            vs,
    input            de,
    output reg [9:0] pixel_x,
    output reg [8:0] pixel_y
);

    reg de_d;
    reg vs_d;
    reg line_seen;

    wire de_rise = de & ~de_d;
    wire vs_edge = vs ^ vs_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            de_d      <= 1'b0;
            vs_d      <= 1'b0;
            line_seen <= 1'b0;
            pixel_x   <= 10'd0;
            pixel_y   <= 9'd0;
        end else begin
            de_d <= de;
            vs_d <= vs;

            // 垂直同步发生变化时清空坐标。
            // 640x480 时序的 VS 变化发生在垂直消隐区，下一次 DE 上升沿
            // 即为新帧第 0 行，因此不会影响有效图像区域。
            if (vs_edge) begin
                line_seen <= 1'b0;
                pixel_x   <= 10'd0;
                pixel_y   <= 9'd0;
            end else if (de_rise) begin
                pixel_x <= 10'd0;

                if (line_seen) begin
                    if (pixel_y < 9'd479)
                        pixel_y <= pixel_y + 9'd1;
                    else
                        pixel_y <= 9'd0;
                end else begin
                    pixel_y   <= 9'd0;
                    line_seen <= 1'b1;
                end
            end else if (de) begin
                if (pixel_x < 10'd639)
                    pixel_x <= pixel_x + 10'd1;
            end
        end
    end

endmodule
