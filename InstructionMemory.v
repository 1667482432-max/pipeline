// ============================================================================
// 只读指令存储器（IF 阶段）
//
// inst.mem 中每行是一条 32 位机器指令。CPU 的 PC 是字节地址，而 ROM
// 以 32 位字为单位寻址，因此使用 Address[11:2]：丢弃低两位并得到
// 0~1023 的字下标。本模块采用组合读，PC 改变后指令随之更新。
// ============================================================================
module InstructionMemory(
	input      [32 -1:0] Address,     // 当前 PC，按字节编址
	output reg [32 -1:0] Instruction // 取出的 32 位机器指令
);

	parameter ROM_SIZE     = 1024; // 共 1024 个 32 位字，即 4 KiB
	parameter ROM_ADDR_BIT = 10;   // 1024 个字需要 10 位字地址

	reg [31:0] ROM_data [ROM_SIZE - 1:0];

	integer i;

	initial begin
		// 先清零，确保 inst.mem 未覆盖的区域表现为 nop（0x00000000）。
		for (i = 0; i < ROM_SIZE; i = i + 1)
			ROM_data[i] = 32'h00000000;

		// 仿真/综合初始化时把算法程序装入指令 ROM。
		$readmemh("inst.mem", ROM_data);
	end

	// 32 位指令按 4 字节对齐，Address[1:0] 不参与寻址。
	always @(*) begin
		Instruction = ROM_data[Address[ROM_ADDR_BIT + 1 : 2]];
	end

endmodule
