module RTC8563_Driver(
	Clk,
	Rst_n,
	
	Set_Time,
	Time_to_Set,
	
	Set_Date,
	Date_to_Set,
	
	Read,
	Time_Read,
	Date_Read,
	
	Cmd_Done,
	
//	i2c_sclk,
//	i2c_sdat
	pcf8563_scl,
	pcf8563_i,
	pcf8563_o,
	pcf8563_oe
);

	input Clk;
	input Rst_n;

	input Set_Time;
	input [23:0]Time_to_Set;

	input Set_Date;
	input [31:0]Date_to_Set;

	input Read;
	output reg[23:0]Time_Read;
	output reg[31:0]Date_Read;
	
	output reg Cmd_Done;
	
//	output i2c_sclk;
//	inout i2c_sdat;
	
	output pcf8563_scl;
	input pcf8563_i;
	output pcf8563_o;
	output pcf8563_oe;
	
	localparam PCF8563_Address_Control_Status_1 = 8'h00;  //控制/状态寄存器1
	localparam PCF8563_Address_Control_Status_2 = 8'h01;  //控制/状态寄存器2
	localparam PCF8563_Address_CLKOUT    = 8'h0d;  //CLKOUT频率寄存器
	localparam PCF8563_Address_Timer     = 8'h0e;  //定时器控制寄存器
	localparam PCF8563_Address_Timer_VAL = 8'h0f;  //定时器倒计数寄存器

	localparam PCF8563_Address_Years     = 8'h08;  //年
	localparam PCF8563_Address_Months    = 8'h07;  //月
	localparam PCF8563_Address_Days      = 8'h05;  //日
	localparam PCF8563_Address_WeekDays  = 8'h06;  //星期
	localparam PCF8563_Address_Hours     = 8'h04;  //小时
	localparam PCF8563_Address_Minutes   = 8'h03;  //分钟
	localparam PCF8563_Address_Seconds   = 8'h02;  //秒

	localparam PCF8563_Alarm_Minutes     = 8'h09;  //分钟报警
	localparam PCF8563_Alarm_Hours       = 8'h0a;  //小时报警
	localparam PCF8563_Alarm_Days        = 8'h0b;  //日报警
	localparam PCF8563_Alarm_WeekDays    = 8'h0c;  //星期报警
	
	reg wrreg_req, rdreg_req;
	reg [7:0]addr,wrdata;
	wire RW_Done;
	wire [7:0]rddata;
	
	i2c_control_8563 i2c_control_8563(
		.Clk(Clk),
		.Rst_n(Rst_n),
		.wrreg_req(wrreg_req),
		.rdreg_req(rdreg_req),
		.addr(addr),
		.addr_mode(0),
		.wrdata(wrdata),
		.rddata(rddata),
		.device_id(8'ha2),
		.RW_Done(RW_Done),
		.ack(),	
//		.i2c_sclk(i2c_sclk),
//		.i2c_sdat(i2c_sdat)
		.pcf8563_scl(pcf8563_scl),
		.pcf8563_i(pcf8563_i),
		.pcf8563_o(pcf8563_o),
		.pcf8563_oe(pcf8563_oe)
	);
	
	reg [8:0]state;
	reg [3:0]cnt;
	
	localparam
		IDLE          = 9'b000000001,
		SET_TIME      = 9'b000000010,
		TIME_SET_DONE = 9'b000000100,
		SET_DATE      = 9'b000001000,
		DATE_SET_DONE = 9'b000010000,
		READ          = 9'b000100000,
		READ_DONE     = 9'b001000000,
		INIT_RTC      = 9'b010000000,
		INIT_DONE     = 9'b100000000;
	
	reg init_state;
	always@(posedge Clk or negedge Rst_n)
	if(!Rst_n)begin
		state <= IDLE;
		cnt <= 0;
		Cmd_Done <= 1'b0;
		wrreg_req <= 1'b0;
		rdreg_req <= 1'b0;
		init_state <= 0;
	end else begin
		case(state)
            IDLE:
				begin
					Cmd_Done <= 1'b0;
					wrreg_req <= 1'b0;
					rdreg_req <= 1'b0;
					cnt <= 0;
					if(!init_state)
						state <= INIT_RTC;
					else if(Set_Time)
						state <= SET_TIME;
					else if(Set_Date)
						state <= SET_DATE;
					else if(Read)
						state <= READ;
				end
			
            SET_TIME:
				begin
					state <= TIME_SET_DONE;
					case(cnt)
						0:write_reg(PCF8563_Address_Seconds, Time_to_Set[7:0]);
						1:write_reg(PCF8563_Address_Minutes, Time_to_Set[15:8]);
						2:write_reg(PCF8563_Address_Hours, Time_to_Set[23:16]);
						default:;
					endcase
				end
			
            TIME_SET_DONE:
				begin
					wrreg_req <= 1'b0;
					if(RW_Done)begin
						if(cnt < 2)begin
							cnt <= cnt + 1'b1;
							state <= SET_TIME;
						end else begin
							cnt <= 0;
							Cmd_Done <= 1'b1;
							state <= IDLE;
						end
					end else
						state <= TIME_SET_DONE;
				end
			
			SET_DATE:
				begin
					state <= DATE_SET_DONE;
					case(cnt)
						0:write_reg(PCF8563_Address_Days, Date_to_Set[7:0]);
						1:write_reg(PCF8563_Address_WeekDays, Date_to_Set[15:8]);
						2:write_reg(PCF8563_Address_Months, Date_to_Set[23:16]);
						3:write_reg(PCF8563_Address_Years, Date_to_Set[31:24]);
						default:;
					endcase
				end
			
			DATE_SET_DONE:
				begin
					wrreg_req <= 1'b0;
					if(RW_Done)begin
						if(cnt < 3)begin
							cnt <= cnt + 1'b1;
							state <= SET_DATE;
						end else begin
							cnt <= 0;
							Cmd_Done <= 1'b1;
							state <= IDLE;
						end
					end else
						state <= DATE_SET_DONE;
				end
			
			READ:
				begin
				state <= READ_DONE;
					case(cnt)
						0:read_reg(PCF8563_Address_Days);
						1:read_reg(PCF8563_Address_WeekDays);
						2:read_reg(PCF8563_Address_Months);
						3:read_reg(PCF8563_Address_Years);
						4:read_reg(PCF8563_Address_Seconds);
						5:read_reg(PCF8563_Address_Minutes);
						6:read_reg(PCF8563_Address_Hours);
						default:;
					endcase
				end
			
			READ_DONE:
				begin
					rdreg_req <= 1'b0;
					if(RW_Done)begin
						case(cnt)
							0:Date_Read[7:0] <= rddata & 8'b0011_1111;
							1:Date_Read[15:8] <= rddata & 8'b0000_0111;
							2:Date_Read[23:16] <= rddata & 8'b0001_1111;
							3:Date_Read[31:24] <= rddata & 8'b1111_1111;
							4:Time_Read[7:0] <= rddata & 8'b0111_1111;
							5:Time_Read[15:8] <= rddata & 8'b0111_1111;
							6:Time_Read[23:16] <= rddata & 8'b0011_1111;
							default:;
						endcase
						if(cnt < 6)begin
							cnt <= cnt + 1'b1;
							state <= READ;
						end else begin
							cnt <= 0;
							Cmd_Done <= 1'b1;
							state <= IDLE;
						end
					end else
						state <= READ_DONE;
				end
			
			INIT_RTC:
				begin
					write_reg(PCF8563_Address_Control_Status_1, 0);
					state <= INIT_DONE;
				end
			
			INIT_DONE:
				begin
					wrreg_req <= 1'b0;
					if(RW_Done)begin
						state <= IDLE;
						init_state <= 1;
					end else
						state <= INIT_DONE;
				end
			
			default:;
		endcase
	end
	
	task write_reg;
		input [7:0]reg_addr;
		input [7:0]reg_data;
		begin
			wrreg_req <= 1'b1;
			addr = reg_addr;
			wrdata = reg_data;
		end
	endtask
	
	task read_reg;
		input [7:0]reg_addr;
		begin
			rdreg_req <= 1'b1;
			addr = reg_addr;
		end
	endtask
	
endmodule
