
// ============================================================================
// ALU 二级译码器
//
// Control.v 先根据 opcode 产生 4 位 ALUOp；本模块再结合 R 型指令的
// funct 字段，产生 ALU.v 直接使用的 5 位 ALUCtl。
// 这样主控制器只负责识别“指令类别”，具体 R 型运算集中在这里译码。
// ============================================================================
module ALUControl(
	input  [4 -1:0] ALUOp      , // 主控制器给出的运算类别/有无符号信息
	input  [6 -1:0] Funct      , // R 型指令 funct 字段
	output reg [5 -1:0] ALUCtl , // 送往 ALU 的具体操作选择码
	output Sign                  // 1：有符号比较；0：无符号比较
);

	// ALUCtl 编码。编码值与 ALU.v 中 case 分支一一对应。
	parameter aluAND = 5'b00000;
	parameter aluOR  = 5'b00001;
	parameter aluADD = 5'b00010;
	parameter aluSUB = 5'b00110;
	parameter aluSLT = 5'b00111;
	parameter aluNOR = 5'b01100;
	parameter aluXOR = 5'b01101;
	parameter aluSLL = 5'b10000;
	parameter aluSRL = 5'b11000;
	parameter aluSRA = 5'b11001;
	parameter aluMUL = 5'b11010; 

	// R 型指令利用 funct[0] 区分 signed/unsigned（如 slt/sltu）；
	// I 型比较利用 ALUOp[3]（它来自 opcode[0]）区分 slti/sltiu。
	// 对加减、逻辑和移位指令而言，Sign 的值不会改变 ALU 结果。
	assign Sign = (ALUOp[2:0] == 3'b010)? ~Funct[0]: ~ALUOp[3];

	// 第一级：只对 R 型 funct 译码。add/addu 与 sub/subu 分别共用
	// 同一运算码，因为本处理器没有实现算术溢出异常。
	reg [4:0] aluFunct;
	always @(*)
		case (Funct)
			6'b00_0000: aluFunct <= aluSLL;
			6'b00_0010: aluFunct <= aluSRL;
			6'b00_0011: aluFunct <= aluSRA;
			6'b10_0000: aluFunct <= aluADD;
			6'b10_0001: aluFunct <= aluADD;
			6'b10_0010: aluFunct <= aluSUB;
			6'b10_0011: aluFunct <= aluSUB;
			6'b10_0100: aluFunct <= aluAND;
			6'b10_0101: aluFunct <= aluOR;
			6'b10_0110: aluFunct <= aluXOR;
			6'b10_0111: aluFunct <= aluNOR;
			6'b10_1010: aluFunct <= aluSLT;
			6'b10_1011: aluFunct <= aluSLT;
			default: aluFunct <= aluADD; // 未识别 funct 使用安全默认值
		endcase

	// 第二级：根据 ALUOp 的低 3 位选择运算类别。
	//   000 加法/地址计算  001 分支比较  010 R 型 funct
	//   100 AND           101 小于比较  110 MUL
	//   111 OR
	always @(*)
        case (ALUOp[2:0])
            3'b000: ALUCtl <= aluADD;
            3'b001: ALUCtl <= aluSUB;
            3'b100: ALUCtl <= aluAND;
            3'b101: ALUCtl <= aluSLT;
            3'b010: ALUCtl <= aluFunct;
            3'b110: ALUCtl <= aluMUL;
            3'b111: ALUCtl <= aluOR;
            default: ALUCtl <= aluADD;
        endcase


endmodule
