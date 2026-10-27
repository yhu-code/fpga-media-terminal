lab_ex5_canon_v2 工程包（卡农版最终工程）
================================================================

一、版本信息
  器件      ：安路 EG4S20BG256（AC601 核心板 + AC201 底板 / HX4S20C 平台）
  开发工具  ：Tang Dynasty 6.2（TD 6.2.168116）
  顶层模块  ：top（源文件 user_source/hdl_source/top_tf_hdmi_audio.v）
  预编译比特：bit/lab_ex5_canon_v2.bit
  MD5       ：51d2eacbde7ce578bd682f828f2a48d6
  综合结果  ：LUT 16572（84.55%）；video_clk +1.342ns、sd_card_clk -0.635ns，无违例
  音频      ：三声部波表 DDS，48kHz/16bit，循环 150.40s（卡农）

二、目录结构
  src/td_project/       TD 工程目录
      lab_ex5_i2s_v1.0.al   工程文件（双击/打开它）
      *.v                   本工程自有模块（OSD、转场、音频、频谱等）
      al_ip/                PLL IP
  src/user_source/
      hdl_source/          公共源码（顶层、SD 卡、HDMI、RTC、SDRAM 等）
          IP/              sys_pll / video_pll / afifo IP
          include/         SDRAM 控制器加密网表与全局定义
          hdmi1.4b_transmitter_core/  HDMI 发送 IP（加密网表）
      constraints_source/  pin.adc（引脚约束）、timing.sdc（时序约束）
  bit/                  预编译比特流 + 时序报告
  sample_bmp/           TF 卡内实际使用的素材（原样备份，与卡内一致）
      00_01_640x480.bmp       原生 640×480
      01_02_640x480.bmp       原生 640×480
      02_03_1280×960.bmp      ≈720P，演示 2× 降采样
      03_04_1920×1080.bmp     1080P，演示等比缩放 + 黑边
      shenzhou21.raw          板端播放的 RAW 视频（RAWV v1）
  tools/                PC 端脚本（见第五节）

三、打开与编译
  1. 启动 TD 6.2，File -> Open Project，选择 src/td_project/lab_ex5_i2s_v1.0.al
  2. 直接点 Flow 的 Run（Synthesis -> Place & Route -> Bitstream）即可重新生成比特流
  3. 若布局阶段报 mslice 超限（PHY-9009）或布线冲突（PHY-8023）：
     这是器件资源紧张导致的，改 Place&Route 的 seed 重新跑即可（脚本 tools/sweep_seeds.py 可批量扫）
  4. 工程内所有路径均为相对路径，整个文件夹可任意移动/改名，不影响打开

四、烧录
  方式一（推荐，不用重新编译）：
     在 TD 中打开工程后，Tools -> Download，选择 bit/lab_ex5_canon_v2.bit 下载到 FPGA
  方式二：
     Tools -> Download 中勾选“固化到 Flash”，上电自动加载
  下载线：USB Cable（JTAG），板卡上电后 TD 能识别到 EG4S20BG256 即可

五、SD 卡准备（必读）
  程序按“裸扇区”读取，不依赖文件系统：
    1. 用 tools/convert_images_to_bmp.py 把图片批量转为 640×480、24 位、无压缩 BMP
    2. 用 tools/sync_to_sd.py 写入 SD 卡（先把旧 BMP 的 "BM" 头破坏，避免被误识别）
    3. 卡内顺序即播放顺序，建议整卡专用，不要放其它 BMP 文件
  视频：RAWV 格式、320×240 RGB565，与图片混排时放在图片之后（按扇区顺序扫描）
  运行：上电约 1.5 秒出首帧；S0 手动切图，S1 自动轮播（每张 18 秒）

  随包素材（sample_bmp/，就是 TF 卡里那一套，原样备份）：

    图片 4 张，均为 24 位无压缩 BMP，顺序即 S0 切换顺序：
      文件名                 分辨率        大小     演示用途
      00_01_640x480.bmp      640×480      901 KB   原生分辨率，铺满 4:3 显示区
      01_02_640x480.bmp      640×480      901 KB   原生分辨率
      02_03_1280×960.bmp     1280×960     3.5 MB   2 倍降采样适配
      03_04_1920×1080.bmp    1920×1080    5.9 MB   3 倍降采样 + 等比缩放留黑边

    视频 1 个：
      shenzhou21.raw         320×240 RGB565、12 fps、323 帧、26.92 s、47.3 MB
      头部 512 B 为 RAWV 头（magic "RAWV"、ver=1、fmt=0、宽高、帧数、帧字节
      153600、data_start、循环标志），其后每帧按 512 B 对齐（300 扇区/帧）。

    卡内布局：4 张 BMP 放在 FAT32 分区根目录（按文件名排序扫描），
              视频写在 LBA 524288（约 256 MB 处，分区之外），二者互不干扰；
              所以换视频不会动到照片，换照片也不会动到视频。

    重新转码（换 mp4 素材时）：
      python tools/build_raw_video.py <视频.mp4> -o shenzhou21.raw --fps 12
      （需要 ffmpeg：pip install imageio-ffmpeg 即自带；另需 numpy、Pillow）

六、按键与开关
  S0：手动切图（视频段内按下立即回到照片组）
  S1：自动轮播开关
  拨码 SW[3:0]：亮度档位（最高位定方向，低 3 位定档，±7 档、每档 10%）
  拨码 SW[7:4]：对比度档位（同上），调节后屏幕左上角显示档位 2 秒

七、tools 说明
  convert_images_to_bmp.py  批量转 640×480/24bit 无压缩 BMP
  sync_to_sd.py             按扇区写卡并破坏旧 BMP 头
  make_canon.py             生成卡农三声部乐谱事件表
  gen_piano_v78.py          把乐谱转成 Verilog 事件表（piano_player 用）
  sim_v79.py                帧级行为模型，验证切图/转场逻辑
  sweep_seeds.py            批量扫布局种子，定位时序违例
  uart_s0_mon.py            串口监视按键与状态
  build_raw_video.py        mp4/GIF/图片序列 → RAWV 帧序列（素材转码用）

八、本包校验
  工程文件 lab_ex5_i2s_v1.0.al 与原开发工程（生成 bit/lab_ex5_canon_v2.bit 的那一版）
  逐字节一致，MD5 = 76e3cb98ab1f2fa5dd61a7ef84ee14e1；
  bit/lab_ex5_canon_v2.bit 即当时上板验证通过的比特流，MD5 = 51d2eacbde7ce578bd682f828f2a48d6。
  工程内已剔除 Runs 中间产物、备份文件与临时日志，仅保留编译与烧录所需的源文件、约束、IP 与脚本。

九、注意
  1. pin.adc / timing.sdc 是唯一正确的引脚与时序约束，替换会导致无法显示或不出声
  2. 编译时若提示找不到 ../user_source 下的文件，说明解压时丢了目录层级，请整包解压
  3. 本工程不含中间产物（Runs 目录），首次编译会比增量编译慢几分钟，属正常现象
