module bmp_read #(
    // 扩展3：图片缩放适配引擎 —— 允许任意分辨率的 BMP
    // v26：2048 -> 4096，覆盖 1920x1080 / 2560x1440 / 3840x2160
    parameter [15:0] MAX_IMG_W = 16'd4096,
    parameter [15:0] MAX_IMG_H = 16'd4096,
    parameter [15:0] MIN_IMG_W = 16'd16,
    parameter [15:0] MIN_IMG_H = 16'd16
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    output wire [4:0]           sd_sec_read_cnt,
    input                       burst_ok,       // 下游缓冲有余量时才允许发起新的读突发
    input  [4:0]                burst_cnt,      // 本次装载每笔突发连读的扇区数（旁路=2/缩放=4）
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // 扩展3：把当前这张图的真实分辨率 + 像素流起止脉冲交给缩放引擎
    output reg [15:0]           img_w,
    output reg [15:0]           img_h,
    output reg                  frame_start,
    output reg                  frame_end
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
// v22：每笔突发的扇区数在 ST_LOAD_WAIT 锁存
// 原来 sd_sec_read_addr 的加法器直接用 burst_cnt，而 burst_cnt 由
// bypass_active(=img_w/img_h 比较) 组合选出 —— 时序报告里最差路径正是
//   height_reg -> bypass_active -> burst_cnt -> sd_sec_read_addr(+32位加法器)
// 10.9ns/10ns 违例。扇区地址一旦在时钟沿附近被打错就会读错扇区（整段花屏）。
reg  [4:0]  load_burst_latched;
reg [31:0]  load_addr_next;      // 预算好的下一个扇区地址（加法器移出使能路径）
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;

// BMP 行填充：每行字节数必须 4 字节对齐，多出来的字节要丢掉
reg [15:0] row_bidx;

// 行长度在文件头解析完就锁存，避免 100MHz 下 W*3 的乘法器进入关键路径
reg [15:0] pix_bytes_r;     // 每行有效像素字节数 = W*3
reg [15:0] row_last_r;      // 每行最后一个字节的下标 = row_bytes-1

wire [15:0] hdr_w;
wire [15:0] hdr_h;
wire        pix_byte_valid;

wire header_match;
wire bmp_data_valid;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

assign hdr_w = width[15:0];
assign hdr_h = height[15:0];

// ---------------------------------------------------------------
// v26：同时支持 24bpp(BGR) 与 32bpp(BGRA)。
//   1080p 的 BMP 很多是 32 位的（很多导出工具默认带 alpha），
//   原来 header_match 只认 bit_count==24，这类文件会被整个跳过 ——
//   卡里明明有图却"扫不出来"，而且还会连带把换图逻辑饿死。
//   两种格式的像素字节顺序都是 B,G,R(,A)，所以装配逻辑完全一样，
//   只有"每行字节数 / 每像素字节数 / 字节下标回绕点"三个地方不同。
// ---------------------------------------------------------------
wire        bpp32 = (bit_count == 16'd32);      // 32bpp 标志（文件头解析后一直稳定）
wire [1:0]  bidx_last = bpp32 ? 2'd3 : 2'd2;    // 每像素最后一个字节的下标

// 一行实际占用的字节数 = ceil(W*bytes_per_px / 4) * 4
wire [31:0] pix_bytes24 = {16'd0, hdr_w} * 32'd3;
wire [31:0] pix_bytes32 = {16'd0, hdr_w} << 2;
wire [31:0] pix_bytes   = bpp32 ? pix_bytes32 : pix_bytes24;
wire [31:0] row_bytes   = (pix_bytes + 32'd3) & 32'hFFFFFFFC;

// 只有落在每行前 W*bytes_per_px 个字节里的才是像素数据，其余是填充字节
assign pix_byte_valid = bmp_data_valid && (row_bidx < pix_bytes_r);

// ---------------------------------------------------------------
// v21：像素有效判定改成"两个已寄存的旗标"，把 32 位比较从像素数据通路上摘掉。
// 旧式子 bmp_data_valid = valid && (bmp_len_cnt >= pixel_offset) && (bmp_len_cnt < file_len)
// 把两次 32 位比较直接串在 pix_byte_valid -> bmp_byte_idx -> bmp_data -> 写帧 FIFO
// 这条组合链上，在 sd_card_clk(100MHz) 上实测是 -1ns 级的违例路径，
// 比较结果抖动会让个别字节被误判成/误判成非像素 → 像素三字节错位 → 整幅花屏。
// 等价改写：
//   hdr_skip 递减到 0       <=>  bmp_len_cnt >= pixel_offset
//   data_end 寄存（跨过末尾）<=>  bmp_len_cnt <  file_len
// 两条判据都只在字节到达时更新，所以每拍只需 3 个门即可得到判定结果。
// ---------------------------------------------------------------
reg [15:0] hdr_skip;      // 仍需要跳过的文件头字节数
reg        data_end;      // 已经跨过文件末尾
// v26：file_len-1 在进入像素流时锁存一次。
// 原来写 (bmp_len_cnt + 1) >= file_len，32 位加法器 + 32 位比较串在一起，
// 实测 9.83ns（sd_card_clk 只有 10ns）→ -0.111ns / 2 个终点。
// 预存 file_len-1 之后只剩一个纯比较器（无加法器）。
reg [31:0] file_len_m1;
wire       stream_on = (hdr_skip == 16'd0);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) && stream_on && ~data_end;

// 装载路径按突发连读（CMD18），扫描/头解析仍单扇区（CMD17）
assign sd_sec_read_cnt = (state == ST_LOAD_DATA) ? load_burst_latched : 5'd1;

assign ready = (state == ST_IDLE);
// v27g：把"宽高范围检查"单独打一拍。
//   height_reg -> ... -> scan_found_sector.ce 布线后 10.346ns（走线占 74%），
//   链上有 4 个范围比较器（2 个 ADDER）。
//   注意不能把整个 header_match 打拍：它驱动 img_w/img_h/write_req/scan_found_*
//   几十个 .ce，固化成单个寄存器后两次布线都在 u_audio_viz 附近剩 1 条网布不通
//   （PHY-8023）。只固化"范围检查"这一小项（扇出 = 1 个与门）既不加热点，
//   又把比较器从使能链上摘掉。
//   时序上安全：header_match 只在 sd_sec_read_end 用，比文件头字节晚几百拍。
reg hdr_wh_ok;
always @(posedge clk or posedge rst) begin
    if (rst) hdr_wh_ok <= 1'b0;
    else     hdr_wh_ok <= (hdr_w >= MIN_IMG_W) && (hdr_w <= MAX_IMG_W) &&
                          (hdr_h >= MIN_IMG_H) && (hdr_h <= MAX_IMG_H);
end

assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      ((bit_count == 16'd24) || (bit_count == 16'd32)) &&
                      (compression  == 32'd0) &&
                      (file_len     != 32'd0) &&
                      hdr_wh_ok;
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);

// v27f：中间量打一拍。
//   原来 next_scan_sector_if_match = scan_sector + ((file_len+511)>>9) 是
//   "32bit 加 -> 32bit 加 -> 32bit 比较"三步串起来的组合链，
//   布线后 9.865ns（sd_card_clk 只有 10ns）→ -0.145ns。
//   file_len 只在解析文件头时变化，而这条判据在 sd_sec_read_end（几十拍后）
//   才用，所以错一拍完全无影响。
reg [31:0] fsc_r;
always @(posedge clk or posedge rst) begin
    if (rst) fsc_r <= 32'd1;
    else     fsc_r <= file_sector_count;
end

assign next_scan_sector_if_match = scan_sector + fsc_r;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

// v22：下一扇区地址提前算好。加法器从"触发沿上才成立的组合链"变成
// "常驻一拍"的加法器，扇区末只需一次寄存器装载，彻底消除该违例。
always @(posedge clk or posedge rst) begin
    if (rst)
        load_addr_next <= 32'd0;
    else
        load_addr_next <= sd_sec_read_addr + {27'd0, load_burst_latched};
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

// ---------------------------------------------------------------
// v26：LOAD_DATA 阶段"源流停滞"计数（200ms @100MHz）
//   正常读数时两个突发之间的空档只有几十微秒，200ms 有 1e4 倍余量。
// ---------------------------------------------------------------
reg [24:0] load_stall_cnt;
wire       load_stall = (load_stall_cnt >= 25'd20_000_000);

always @(posedge clk or posedge rst) begin
    if (rst)
        load_stall_cnt <= 25'd0;
    else if (state != ST_LOAD_DATA)
        load_stall_cnt <= 25'd0;
    else if (sd_sec_read_data_valid)
        load_stall_cnt <= 25'd0;
    else
        load_stall_cnt <= load_stall_cnt + 25'd1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (pix_byte_valid)
            bmp_byte_idx <= (bmp_byte_idx == bidx_last) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

// 行内字节计数（含填充字节），用于剔除 4 字节对齐产生的 padding
always @(posedge clk or posedge rst) begin
    if (rst) begin
        row_bidx <= 16'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            if (row_bidx == row_last_r)
                row_bidx <= 16'd0;
            else
                row_bidx <= row_bidx + 16'd1;
        end
    end else begin
        row_bidx <= 16'd0;
    end
end

// 缩放引擎需要的图像分辨率 + 起止脉冲
reg load_data_d;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        frame_start  <= 1'b0;
        frame_end    <= 1'b0;
        load_data_d  <= 1'b0;
    end else begin
        load_data_d <= (state == ST_LOAD_DATA);
        frame_start <= 1'b0;
        frame_end   <= 1'b0;

        // 进入像素流的第一拍给出 start，此刻 img_w/img_h 已经锁好
        if (!load_data_d && (state == ST_LOAD_DATA))
            frame_start <= 1'b1;

        // 离开像素流（读完 / 被中止）时给出 end
        if (load_data_d && (state != ST_LOAD_DATA))
            frame_end <= 1'b1;
    end
end

// v21：像素有效旗标的推进（只在字节到达时动，且输出全部寄存）。
// 全部写在这里（唯一驱动源），避免和状态机里的赋值造成多驱动。
wire load_data_start = (!load_data_d) && (state == ST_LOAD_DATA);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hdr_skip    <= 16'hFFFF;
        data_end    <= 1'b0;
        file_len_m1 <= 32'd0;
    end else if (load_data_start) begin
        // 像素流从文件第 pixel_offset 个字节开始
        hdr_skip    <= (pixel_offset[31:16] != 16'd0) ? 16'hFFFF : pixel_offset[15:0];
        data_end    <= 1'b0;
        file_len_m1 <= file_len - 32'd1;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid) begin
            if (hdr_skip != 16'd0)
                hdr_skip <= hdr_skip - 16'd1;
            // 当前字节(idx=bmp_len_cnt)是最后一个有效字节时，下一拍起 data_end=1
            // (bmp_len_cnt+1) >= file_len  <=>  bmp_len_cnt >= file_len-1
            if (bmp_len_cnt >= file_len_m1)
                data_end <= 1'b1;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (pix_byte_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        img_w             <= 16'd640;
        img_h             <= 16'd480;
        pix_bytes_r       <= 16'd1920;
        row_last_r        <= 16'd1919;
    end else if (!sd_init_done) begin
        // 卡被拔掉 / 初始化丢失：所有状态归零（含 scan_done）
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        img_w             <= 16'd640;
        img_h             <= 16'd480;
        pix_bytes_r       <= 16'd1920;
        row_last_r        <= 16'd1919;
    end else if (load_abort) begin
        // v58【修复】：中止一次装载只清数据通路，**不能清 scan_done**。
        //   扫描在上电只做一次（sd_card_bmp 的 scan_kicked 只置一次），
        //   而 scan_ok = scan_done || (img_found_count == 4)。
        //   卡上不足 4 张 BMP 时，清掉 scan_done 会让 scan_ok 永久变 0，
        //   于是 S0 / S1 / 轮播 / 交棒全部失灵 —— 且再也没有机会恢复。
        //   （v46 的"装载中按 S0 立即中止"正好会频繁走这条路径，属高危。）
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        img_w             <= 16'd640;
        img_h             <= 16'd480;
        pix_bytes_r       <= 16'd1920;
        row_last_r        <= 16'd1919;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                        // 扩展3：把真实分辨率交给缩放引擎
                        img_w            <= hdr_w;
                        img_h            <= hdr_h;
                        // 行长度锁存（此时 hdr_w 已稳定，避免乘法器进关键路径）
                        pix_bytes_r      <= pix_bytes[15:0];
                        // v26：row_last_r 的 4 字节对齐+减一挪到 ST_LOAD_WAIT 再算。
                        // 原来和乘法器挤在同一拍：width_reg -> mux(bpp) -> *3
                        // -> +3 & ~3 -> -1 -> row_last_r_reg，实测 -0.212ns。
                        // 挪过去之后两段都是"寄存器到寄存器"，各占一拍。
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                // 行尾下标 = 4 字节对齐后的行字节数 - 1（与 row_bytes 同义）
                row_last_r <= (((pix_bytes_r + 16'd3) & 16'hFFFC) - 16'd1);
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    // 此处 img_w/img_h 已在 ST_LOAD_HDR 锁好，burst_cnt 取值稳定
                    load_burst_latched <= (burst_cnt == 5'd0) ? 5'd1 : burst_cnt;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;

                // v26：源流停滞看门狗。
                // 板上实测出现过 bmp_read 永久停在 LOAD_DATA 的状态（串口抓到
                // "bmp状态=LOADING" 而 load_busy=0）：此时 ready=0，而所有换图
                // 分支都要等 bmp_ready —— 结果就是"图能看，但 key1/key2 全失效"。
                // 这里给一条自愈出口：连续 200ms 没有一个字节进来就回 IDLE。
                // 正常读数时两个突发之间的空档只有几十微秒（受 burst_ok 节流影响），
                // 200ms 有 1e4 倍余量，绝不会误触发。
                if (load_stall) begin
                    sd_sec_read <= 1'b0;
                    state       <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    // v26b：原来写 (bmp_len_cnt >= file_len)，是"32 位寄存器 vs
                    // 32 位寄存器"的大于比较，综合成 32 位减法链，实测 10.26ns
                    // （sd_card_clk 只有 10ns）→ -0.612ns / 16 个终点。
                    // data_end 就是"已经吃到文件最后一个字节"的粘滞标志，
                    // 在按扇区读完的场景下与本条件完全等价，但它是寄存器输出，
                    // 状态机这条路上不再有 32 位比较链。
                    if (data_end) begin
                        state <= ST_IDLE;
                    end else begin
                        // 突发读：地址按本次连读的扇区数推进（用预算值，见 load_addr_next）
                        sd_sec_read_addr <= load_addr_next;
                    end
                end else begin
                    // 读节流：下游缓冲有余量才发起/维持读请求。
                    // CMD18 连续流若不加节流，会灌爆下游 FIFO 丢像素，
                    // 导致写帧计数凑不满、写帧完成永远不来（v12 实测确认）。
                    sd_sec_read <= burst_ok;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
