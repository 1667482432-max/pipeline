
// ============================================================================
// 主控制器（ID 阶段）
//
// 输入是 IF/ID 中指令的 opcode、funct 和 rt 字段，输出控制信号会随
// 数据一起写入 ID/EX、EX/MEM、MEM/WB 流水线寄存器。控制信号最终决定：
//   1. 下一条 PC 来自顺序、立即数跳转还是寄存器跳转；
//   2. ALU 的操作数和具体运算；
//   3. 是否访问存储器、是否写回寄存器以及写回数据来源。
// ============================================================================
module Control(
	input  [6 -1:0] OpCode   , // 指令 [31:26]
	input  [6 -1:0] Funct    , // R 型指令 [5:0]
	input  [5 -1:0] Rt       , // 用于识别 REGIMM 类中的 bltz
	output [2 -1:0] PCSrc    , // 00 顺序/分支，01 j/jal，10 jr/jalr
	output Branch            , // 当前指令是否属于条件分支
	output [3 -1:0] BranchType, // 条件分支种类，供 EX 阶段判定
	output RegWrite          , // WB 阶段是否写寄存器堆
	output [2 -1:0] RegDst   , // 00 rt，01 rd，10 $31
	output MemRead           , // MEM 阶段读数据存储器
	output MemWrite          , // MEM 阶段写数据存储器/外设
	output [2 -1:0] MemtoReg , // 00 ALU，01 内存，10 PC+4
	output ALUSrc1           , // 0 rs，1 shamt
	output ALUSrc2           , // 0 rt，1 扩展后的立即数
	output ExtOp             , // 1 符号扩展，0 零扩展
	output LuOp              , // 1 表示 lui：立即数放到高 16 位
	output [4 -1:0] ALUOp      // 送往 ALUControl 的中间控制码
);

	// 无条件跳转在 ID 阶段即可形成目标地址。
	// 条件分支仍保持 PCSrc=00，实际是否跳转由 EX_BranchTaken 决定。
	assign PCSrc = 
        (OpCode == 6'h02 || OpCode == 6'h03) ? 2'b01 : // j or jal
        (OpCode == 6'h00 && (Funct == 6'h08 || Funct == 6'h09)) ? 2'b10 : // jr or jalr
        2'b00;
	
	// Branch 只标记条件分支；j/jal/jr/jalr 不属于此信号。
	assign Branch =
            (OpCode == 6'h04 ||  // beq
             OpCode == 6'h05 ||  // bne
             OpCode == 6'h06 ||  // blez
             OpCode == 6'h07 ||  // bgtz
             (OpCode == 6'h01 && Rt == 5'b00000)) ? 1'b1 : // bltz
            1'b0;
            
	// BranchType 编码：
	//   1 beq，2 bne，3 blez，4 bgtz，5 bltz，0 非条件分支。
    assign BranchType =
                (OpCode == 6'h04) ? 3'd1 :                       // beq
                (OpCode == 6'h05) ? 3'd2 :                       // bne
                (OpCode == 6'h06) ? 3'd3 :                       // blez
                (OpCode == 6'h07) ? 3'd4 :                       // bgtz
                (OpCode == 6'h01 && Rt == 5'b00000) ? 3'd5 :     // bltz
                3'd0;

	// sw、条件分支、j 和 jr 没有寄存器写回，其余已实现指令均写回。
	// jal/jalr 不在禁写列表中，它们需要把 PC+4 写入链接寄存器。
	assign RegWrite = 
	(OpCode == 6'h2b ||      // sw
	 Branch ||               // all branch
	 OpCode == 6'h02 ||      // j
	 (OpCode == 6'h00 && Funct == 6'h08)) ? 1'b0 : // jr
	1'b1;

	// 写回目的寄存器选择：
	//   普通 I 型/lw -> rt；R 型/mul/jalr -> rd；jal -> $31。
	assign RegDst =
		(OpCode == 6'h00 || OpCode == 6'h1c)? 2'b01: //R, mul
		(OpCode == 6'h03)? 2'b10: //jal
		2'b00; //others

	// 只有 lw 发起数据读。
	assign MemRead = 
		(OpCode == 6'h23)? 1'b1: //lw
		1'b0; //others

	// 只有 sw 发起数据写；DataMemory 再根据地址决定写 RAM 还是外设。
	assign MemWrite = 
		(OpCode == 6'h2b)? 1'b1: //sw
		1'b0; //others

	// 写回数据来源：
	//   lw 取内存数据；jal/jalr 取该指令的 PC+4；其余取 ALU 结果。
	assign MemtoReg = 
	(OpCode == 6'h23) ? 2'b01 : // lw
	(OpCode == 6'h03 || (OpCode == 6'h00 && Funct == 6'h09)) ? 2'b10 : // jal or jalr
	2'b00;

	// 固定移位指令使用指令中的 shamt 作为 ALU 第一操作数。
	assign ALUSrc1 =
		(OpCode == 6'h00 && (Funct == 6'h00 || Funct == 6'h02 || Funct == 6'h03))? 1'b1: //sll, slrl, sra
		1'b0; //others

	// R 型、mul 和条件分支使用寄存器 rt；其余 I 型指令使用立即数。
	// sw 的写数据仍单独来自 rt，ALU 的立即数只用于计算访存地址。
	assign ALUSrc2 =
	(OpCode == 6'h00 || OpCode == 6'h1c ||
	 OpCode == 6'h04 || OpCode == 6'h05 ||
	 OpCode == 6'h06 || OpCode == 6'h07 ||
	 OpCode == 6'h01)? 1'b0:
	1'b1;

	// andi/ori 按零扩展处理；包括 sltiu 在内的其他 I 型指令按
	// MIPS 规则先符号扩展立即数，再决定有符号/无符号比较。
	assign ExtOp =
	(OpCode == 6'h0c || OpCode == 6'h0d)? 1'b0: // andi, ori
	1'b1;

	// lui 不做普通符号扩展，而是把 imm16 放入结果的高半字。
	assign LuOp = 
		(OpCode == 6'h0f)? 1'b1: //lui
		1'b0; //others

	// ALUOp[2:0] 表示运算类别，详细编码见 ALUControl.v。
	assign ALUOp[2:0] = 
        (OpCode == 6'h00)? 3'b010: 
        (OpCode == 6'h04 || OpCode == 6'h05 ||
         OpCode == 6'h06 || OpCode == 6'h07 ||
         OpCode == 6'h01)? 3'b001:
        (OpCode == 6'h0c)? 3'b100: // andi
        (OpCode == 6'h0d)? 3'b111: // ori
        (OpCode == 6'h0a || OpCode == 6'h0b)? 3'b101:
        (OpCode == 6'h1c && Funct == 6'h02)? 3'b110:
        3'b000;
		
	// 高位保存 opcode 的最低位，使 ALUControl 能区分
	// addi/addiu、slti/sltiu 等 signed/unsigned 成对指令。
	assign ALUOp[3] = OpCode[0];


	
	
endmodule
