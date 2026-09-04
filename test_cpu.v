// ============================================================================
// CPU 基础仿真测试平台
//
// 该 testbench 产生复位和周期时钟，让 CPU 从 inst.mem 开始连续执行。
// UART 接收线保持空闲高电平，因此本测试主要验证 input.mem 预装数据下
// 的流水线运行；需要测试串口装载时，可在 uart_rx 上另行施加串行波形。
// ============================================================================
module test_cpu();
	
	reg reset; // 高有效复位激励
	reg clk;   // 仿真时钟

	// 以下信号用于在波形窗口观察 CPU 的 MEM 阶段访问。
	wire        MemRead; 
	wire        MemWrite;
	wire [31:0] MemBus_Address;
	wire [31:0] MemBus_Write_Data;
	wire [31:0] Device_Read_Data;
	wire [11:0] digi;
	wire uart_rx;
	wire uart_tx;

	// 当前 CPU 使用内部 DataMemory，未连接外部设备读数据。
	assign Device_Read_Data = 32'h00000000;
	// UART 空闲电平为高；这里不注入串口字节。
	assign uart_rx = 1'b1;
	
	// 被测设计（DUT）。
	CPU cpu1(  
		.reset              (reset), 
		.clk                (clk),
		.MemBus_Address     (MemBus_Address),
		.Device_Read_Data   (Device_Read_Data), 
		.MemBus_Write_Data  (MemBus_Write_Data), 
		.MemRead            (MemRead), 
		.MemWrite           (MemWrite),
		.digi               (digi),
		.uart_rx            (uart_rx),
		.uart_tx            (uart_tx)
	);
	
	initial begin
		// 从复位状态启动。#100 后解除复位，CPU 从 PC=0 开始取指。
		reset = 1;
		clk   = 1;
		#100 reset = 0;
		// 给算法程序足够长的运行时间后结束仿真。
		#1000000000 $finish;
	end
	
	// 每 50 个仿真时间单位翻转一次，完整时钟周期为 100 个时间单位。
	always #50 clk = ~clk;
		
endmodule
