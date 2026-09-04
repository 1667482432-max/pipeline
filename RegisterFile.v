
// ============================================================================
// 32×32 位 MIPS 通用寄存器堆
//
// 两个读端口是组合逻辑，供 ID 阶段同时读取 rs、rt；一个写端口在
// 时钟上升沿工作，供 WB 阶段写回。$0 不实际存储，读取永远得到 0，
// 对 $0 的写操作也会被忽略。
// ============================================================================
module RegisterFile(
	input  reset                    , // 高有效异步复位
	input  clk                      ,
	input  RegWrite                 , // WB 阶段写使能
	input  [5 -1:0]  Read_register1 , // rs 编号
	input  [5 -1:0]  Read_register2 , // rt 编号
	input  [5 -1:0]  Write_register , // 目的寄存器编号
	input  [32 -1:0] Write_data     , // WB 写回数据
	output [32 -1:0] Read_data1     , // rs 当前值
	output [32 -1:0] Read_data2       // rt 当前值
);

	// 只为 $1~$31 分配存储单元；$0 由下面的读多路器直接产生常数 0。
	reg [31:0] RF_data[31:1];

	// 异步读：寄存器编号变化时，输出无需等待时钟。
	assign Read_data1 = (Read_register1 == 5'b00000)? 32'h00000000: RF_data[Read_register1];
	assign Read_data2 = (Read_register2 == 5'b00000)? 32'h00000000: RF_data[Read_register2];
	
	integer i;

	// 复位清空 $1~$31；正常运行时仅在 RegWrite=1 且目的非 $0 时写入。
	always @(posedge reset or posedge clk)
		if (reset)
			for (i = 1; i < 32; i = i + 1)
				RF_data[i] <= 32'h00000000;
		else if (RegWrite && (Write_register != 5'b00000))
			RF_data[Write_register] <= Write_data;

endmodule
