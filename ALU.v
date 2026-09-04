
// ============================================================================
// 32 位组合逻辑 ALU
//
// 本模块位于流水线的 EX 阶段。ALUControl 把指令的 opcode/funct 翻译成
// ALUCtl；CPU.v 在送入本模块之前已经完成数据转发以及操作数选择。
//
// 约定：
//   * 移位指令把移位量放在 in1[4:0]，待移位数据放在 in2。
//   * Sign 只影响“小于比较”：1 表示有符号比较，0 表示无符号比较。
//   * 本设计不产生溢出异常，因此 add/addu、sub/subu 共用运算电路。
// ============================================================================
module ALU(
	input [32 -1:0] in1      , // 第一操作数；移位时低 5 位是 shamt
	input [32 -1:0] in2      , // 第二操作数；移位时是待移位的数据
	input [5 -1:0] ALUCtl    , // ALU 操作选择码，定义见 ALUControl.v
	input Sign               , // 1：有符号比较；0：无符号比较
	output reg [32 -1:0] out , // 组合运算结果
	output zero                // 结果是否为 0
);
	// zero 可用于零值判断；当前分支逻辑直接比较转发后的操作数，
	// 因此该信号主要保留为标准 ALU 接口。
	assign zero = (out == 0);
	
	// 两个操作数的符号位组合：ss[1] 对应 in1，ss[0] 对应 in2。
	wire [1:0] ss;
    assign ss = {in1[31], in2[31]};
	
	// 当两个数符号相同时，比较低 31 位即可决定大小。
	wire lt_31;
	assign lt_31 = (in1[30:0] < in2[30:0]);

	// 有符号小于比较：
	//   符号不同：负数一定小于非负数；
	//   符号相同：比较剩余 31 位。
	wire lt_signed;
	assign lt_signed = (in1[31] ^ in2[31])? 
		((ss == 2'b01)? 0: 1): lt_31;

	// 纯组合译码。每个 ALUCtl 值只选择一种运算。
	always @(*)
		case (ALUCtl)
			5'b00000: out <= in1 & in2; // AND：and、andi
			5'b00001: out <= in1 | in2; // OR：or、ori
			5'b00010: out <= in1 + in2; // ADD：算术、地址计算
			5'b00110: out <= in1 - in2; // SUB：sub、subu
			5'b00111: out <= {31'h00000000, Sign? lt_signed: (in1 < in2)}; // SLT/SLTU
			5'b01100: out <= ~(in1 | in2); // NOR
			5'b01101: out <= in1 ^ in2; // XOR
			5'b10000: out <= (in2 << in1[4:0]); // SLL：逻辑左移
			5'b11000: out <= (in2 >> in1[4:0]); // SRL：逻辑右移
			// 先在左侧复制 32 个符号位，再逻辑右移，截取低 32 位后
			// 等价于对 32 位 in2 做算术右移。
			5'b11001: out <= ({{32{in2[31]}}, in2} >> in1[4:0]); // SRA
			5'b11010: out <= in1 * in2; // MUL：保留乘积低 32 位
			default: out <= 32'h00000000; // 未定义控制码输出 0
		endcase


	
	
endmodule
