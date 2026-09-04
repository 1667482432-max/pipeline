// ============================================================================
// 五级流水线 MIPS 处理器核心
//
// 数据通路按 IF（取指）→ ID（译码/读寄存器）→ EX（执行/分支判定）
// → MEM（数据存储器/外设访问）→ WB（寄存器写回）组织，并由 IF/ID、
// ID/EX、EX/MEM、MEM/WB 四组流水线寄存器隔开。
//
// 冒险处理策略：
//   * 一般 RAW 数据冒险：EX/MEM 或 MEM/WB 向 EX 阶段转发；
//   * load-use：冻结 PC 和 IF/ID 一拍，并向 ID/EX 插入 bubble；
//   * jr/jalr：在 ID 阶段旁路可用结果，结果尚不可用时暂停；
//   * 分支/跳转：改变 PC，同时把错误路径指令冲刷成 nop。
//
// 本实现没有 MIPS 延迟槽。jal/jalr 写回 PC+4，而不是 PC+8。
// ============================================================================
module CPU(
	input  reset,                         // 高有效异步复位
	input  clk,
	output MemRead,                       // 对外暴露的 MEM 阶段读使能
	output MemWrite,                      // 对外暴露的 MEM 阶段写使能
	output [32 -1:0] MemBus_Address,      // MEM 阶段地址观察端口
	output [32 -1:0] MemBus_Write_Data,   // MEM 阶段写数据观察端口
	input  [32 -1:0] Device_Read_Data,    // 预留外设读端口，当前版本未使用
	output [12 -1:0] digi,                // 存储映射数码管输出
	input  uart_rx,
	output uart_tx
);

	// ============================================================
	// IF stage
	// ============================================================

	reg  [31:0] PC;             // 当前正在 IF 阶段取指的字节地址
	wire [31:0] PC_next;        // 下一拍准备写入 PC 的地址
	wire [31:0] PC_plus_4;      // 顺序执行地址，也是链接指令的返回地址
	wire [31:0] IF_Instruction; // 指令 ROM 在当前 PC 处的组合输出
	
	// 分支在 EX 阶段才完成条件判定；跳转在 ID 阶段即可形成目标。
    wire        EX_BranchTaken;
    wire [31:0] EX_BranchTarget;
    
    wire        ID_Jump;
    wire [31:0] ID_JumpTarget;
	
	// 冒险控制信号：Write=0 表示冻结，Flush=1 表示插入/冲刷 nop。
    wire PCWrite;
    wire IF_ID_Write;
    wire ID_EX_Flush;
    wire ID_Stall;
    wire LoadUseHazard;
    wire JumpRegisterHazard;
    wire ID_JumpRaw;
    wire ID_IsRegisterJump;

	assign PC_plus_4 = PC + 32'd4;
	// PC 选择优先级：EX 阶段已成立分支 > ID 阶段有效跳转 > 顺序 PC+4。
	// 分支优先级更高，因为它对应更老的指令，必须覆盖年轻指令的跳转。
	assign PC_next =
        EX_BranchTaken ? EX_BranchTarget :
        ID_Jump        ? ID_JumpTarget    :
                         PC_plus_4;

    // 暂停时 PCWrite=0，PC 保持不变；控制转移成立时无条件改写 PC，
    // 即使同一周期 ID 阶段同时报告了冒险也不会阻止更老的分支生效。
    always @(posedge reset or posedge clk) begin
	   if (reset)
		  PC <= 32'h00000000;
	   else if (EX_BranchTaken || ID_Jump || PCWrite)
		  PC <= PC_next;
    end

	// 组合读指令 ROM：inst.mem 中的程序从地址 0 开始执行。
	InstructionMemory instruction_memory1(
		.Address     (PC),
		.Instruction (IF_Instruction)
	);

	// ============================================================
	// IF/ID pipeline register
	// ============================================================

	reg [31:0] IF_ID_PC_plus_4;   // 当前 ID 指令对应的 PC+4
	reg [31:0] IF_ID_Instruction; // 当前 ID 指令；全 0 按 nop 处理

	// IF/ID 更新规则：复位或控制转移时写入 nop；冒险暂停时保持旧值；
	// 正常情况下锁存本周期 IF 结果。这样被暂停的 ID 指令不会丢失。
	always @(posedge reset or posedge clk) begin
	   if (reset) begin
		  IF_ID_PC_plus_4   <= 32'h00000000;
		  IF_ID_Instruction <= 32'h00000000; // nop
	   end
	   else if (EX_BranchTaken || ID_Jump) begin
		  IF_ID_PC_plus_4   <= 32'h00000000;
		  IF_ID_Instruction <= 32'h00000000; // flush
	   end
	   else if (IF_ID_Write) begin
		  IF_ID_PC_plus_4   <= PC_plus_4;
		  IF_ID_Instruction <= IF_Instruction;
	   end
    end

	// ============================================================
	// ID stage
	// ============================================================

	// 将 32 位指令拆成 MIPS 固定字段。不同格式只使用其中一部分。
	wire [5:0] ID_OpCode;
	wire [5:0] ID_Funct;
	wire [4:0] ID_rs;
	wire [4:0] ID_rt;
	wire [4:0] ID_rd;
	wire [4:0] ID_shamt;

	assign ID_OpCode = IF_ID_Instruction[31:26];
	assign ID_rs     = IF_ID_Instruction[25:21];
	assign ID_rt     = IF_ID_Instruction[20:16];
	assign ID_rd     = IF_ID_Instruction[15:11];
	assign ID_shamt  = IF_ID_Instruction[10:6];
	assign ID_Funct  = IF_ID_Instruction[5:0];

	// ID 阶段主控制信号。这些信号随后与数据一起沿流水线向后传递。
	wire [1:0] ID_RegDst;
	wire [1:0] ID_PCSrc;
	wire       ID_Branch;
	wire [2:0] ID_BranchType;
	wire       ID_MemRead;
	wire       ID_MemWrite;
	wire [1:0] ID_MemtoReg;
	wire       ID_ALUSrc1;
	wire       ID_ALUSrc2;
	wire [3:0] ID_ALUOp;
	wire       ID_ExtOp;
	wire       ID_LuOp;
	wire       ID_RegWrite;

	Control control1(
	.OpCode     (ID_OpCode),
	.Funct      (ID_Funct),
	.Rt         (ID_rt),
	.PCSrc      (ID_PCSrc),
	.Branch     (ID_Branch),
	.BranchType (ID_BranchType),
	.RegWrite   (ID_RegWrite),
	.RegDst     (ID_RegDst),
	.MemRead    (ID_MemRead),
	.MemWrite   (ID_MemWrite),
	.MemtoReg   (ID_MemtoReg),
	.ALUSrc1    (ID_ALUSrc1),
	.ALUSrc2    (ID_ALUSrc2),
	.ExtOp      (ID_ExtOp),
	.LuOp       (ID_LuOp),
	.ALUOp      (ID_ALUOp)
);
	
	// ID 阶段跳转：
	//   j/jal 目标 = {当前指令 PC+4 的高 4 位, instr_index, 2'b00}；
	//   jr/jalr 目标 = rs 的值。
	// 寄存器跳转若读取目标值存在数据冒险，会等到旁路数据可用再生效。
    assign ID_IsRegisterJump = (ID_PCSrc == 2'b10);
    assign ID_JumpRaw = (ID_PCSrc == 2'b01) || ID_IsRegisterJump;
    assign ID_Jump = ID_JumpRaw && !ID_Stall;
    
    assign ID_JumpTarget =
        (ID_PCSrc == 2'b01) ?
            {IF_ID_PC_plus_4[31:28], IF_ID_Instruction[25:0], 2'b00} :
            ID_ReadData1;

// ============================================================
// 提前声明 WB 与 EX/MEM 信号
// ============================================================
// Verilog 中信号需要在使用前声明。寄存器堆位于 ID 段，但写端口来自
// WB；jr/jalr 的 ID 段旁路还要查看 EX/MEM，因此相关寄存器先在此声明。

    wire [31:0] WB_WriteData;

    reg [31:0] MEM_WB_ReadData;      // lw 从数据存储器得到的值
    reg [31:0] MEM_WB_ALU_out;       // 算术结果或有效地址
    reg [4:0]  MEM_WB_WriteRegister; // WB 的目的寄存器号

    reg [1:0]  MEM_WB_MemtoReg; // 写回数据选择
    reg        MEM_WB_RegWrite;; // 写回使能（原有双分号语法合法）

    // EX/MEM 的 ALU/链接结果可以直接旁路给 ID 阶段的 jr/jalr。
    reg [31:0] EX_MEM_ALU_out;
    reg [31:0] EX_MEM_WriteData;     // sw 将在 MEM 阶段写出的数据
    reg [4:0]  EX_MEM_WriteRegister;// 当前指令未来可能写回的寄存器号
    reg [31:0] EX_MEM_PC_plus_4;     // jal/jalr 的链接值

    reg        EX_MEM_MemRead;
    reg        EX_MEM_MemWrite;
    reg [1:0]  EX_MEM_MemtoReg;
    reg        EX_MEM_RegWrite;

    // EX/MEM 可供旁路的数据只有 ALU 结果或 PC+4。lw 的存储器读数据要到
    // MEM 末尾才产生，所以 EX_MEM_MemRead=1 时不能使用这条旁路。
    wire [31:0] EX_MEM_ForwardData;
    assign EX_MEM_ForwardData =
        (EX_MEM_MemtoReg == 2'b10) ? EX_MEM_PC_plus_4 :
                                     EX_MEM_ALU_out;

	// 寄存器堆在 ID 组合读，在 WB 时序写。读写可在同一周期发生。
    wire [31:0] ID_ReadData1_raw;
    wire [31:0] ID_ReadData2_raw;
    
    wire [31:0] ID_ReadData1;
    wire [31:0] ID_ReadData2;
    
    RegisterFile register_file1(
        .reset          (reset),
        .clk            (clk),
        .RegWrite       (MEM_WB_RegWrite),
        .Read_register1 (ID_rs),
        .Read_register2 (ID_rt),
        .Write_register (MEM_WB_WriteRegister),
        .Write_data     (WB_WriteData),
        .Read_data1     (ID_ReadData1_raw),
        .Read_data2     (ID_ReadData2_raw)
    );
    
    // ID 阶段旁路优先级：EX/MEM 非 load 结果 > 同周期 WB 写回值 > 寄存器堆。
    // 这不仅给 jr/jalr 提供最新目标，也消除“WB 写、ID 读同一寄存器”时
    // 对具体寄存器堆读写时序的依赖。
    assign ID_ReadData1 =
        (EX_MEM_RegWrite &&
         !EX_MEM_MemRead &&
         (EX_MEM_WriteRegister != 5'b00000) &&
         (EX_MEM_WriteRegister == ID_rs)) ? EX_MEM_ForwardData :
        (MEM_WB_RegWrite &&
         (MEM_WB_WriteRegister != 5'b00000) &&
         (MEM_WB_WriteRegister == ID_rs)) ? WB_WriteData :
                                            ID_ReadData1_raw;
    
    // rt 使用相同旁路规则；它可作为 ALU 第二源或 sw 写数据。
    assign ID_ReadData2 =
        (EX_MEM_RegWrite &&
         !EX_MEM_MemRead &&
         (EX_MEM_WriteRegister != 5'b00000) &&
         (EX_MEM_WriteRegister == ID_rt)) ? EX_MEM_ForwardData :
        (MEM_WB_RegWrite &&
         (MEM_WB_WriteRegister != 5'b00000) &&
         (MEM_WB_WriteRegister == ID_rt)) ? WB_WriteData :
                                            ID_ReadData2_raw;

	// 立即数扩展：ExtOp=1 时复制 imm[15] 做符号扩展，ExtOp=0 时补零。
	wire [31:0] ID_Ext_out;
	wire [31:0] ID_LU_out;

	assign ID_Ext_out = {
		ID_ExtOp ? {16{IF_ID_Instruction[15]}} : 16'h0000,
		IF_ID_Instruction[15:0]
	};

	// lui 覆盖普通扩展结果，把 imm16 放到高半字，低半字清零。
	assign ID_LU_out = ID_LuOp ?
		{IF_ID_Instruction[15:0], 16'h0000} :
		ID_Ext_out;

	// ============================================================
	// ID/EX pipeline register
	// ============================================================

	// ID/EX 同时保存数据、寄存器编号和控制信号，使它们在 EX 对齐。
	reg [31:0] ID_EX_PC_plus_4;
	reg [31:0] ID_EX_ReadData1; // ID 时读取/旁路后的 rs 值
	reg [31:0] ID_EX_ReadData2; // ID 时读取/旁路后的 rt 值
	reg [31:0] ID_EX_Imm;       // 已完成扩展或 lui 变换的立即数

	reg [4:0]  ID_EX_rs;
	reg [4:0]  ID_EX_rt;
	reg [4:0]  ID_EX_rd;
	reg [4:0]  ID_EX_shamt;
	reg [5:0]  ID_EX_funct;

	reg [1:0]  ID_EX_RegDst;
	reg        ID_EX_ALUSrc1;
	reg        ID_EX_ALUSrc2;
	reg [3:0]  ID_EX_ALUOp;
    reg        ID_EX_Branch;
    reg [2:0] ID_EX_BranchType;
	reg        ID_EX_MemRead;
	reg        ID_EX_MemWrite;
	reg [1:0]  ID_EX_MemtoReg;
	reg        ID_EX_RegWrite;
	
	// ============================================================
    // 冒险检测单元（ID 阶段）
    // ============================================================
    // 不能只比较指令字段：某些格式虽然含有 rs/rt 位域，却不真正读取它。
    // 因此先按指令类别计算 ID_UsesRs/ID_UsesRt，再做寄存器相关性比较。
    
    wire ID_IsRType;
    wire ID_IsSpecial2;
    wire ID_IsShift;
    wire ID_IsBranchTwoRegs;
    wire ID_IsBranchOneReg;
    wire ID_IsImmediateRs;
    wire ID_UsesRs;
    wire ID_UsesRt;
    wire [4:0] ID_EX_WriteRegister_Hazard;

    assign ID_IsRType = (ID_OpCode == 6'h00);
    assign ID_IsSpecial2 = (ID_OpCode == 6'h1c);
    // 固定移位 sll/srl/sra 只读取 rt，shamt 来自指令立即字段。
    assign ID_IsShift = ID_IsRType &&
        ((ID_Funct == 6'h00) || (ID_Funct == 6'h02) || (ID_Funct == 6'h03));
    // beq/bne 同时读取 rs、rt；blez/bgtz/bltz 只读取 rs。
    assign ID_IsBranchTwoRegs =
        (ID_OpCode == 6'h04) || (ID_OpCode == 6'h05);
    assign ID_IsBranchOneReg =
        (ID_OpCode == 6'h06) || (ID_OpCode == 6'h07) ||
        ((ID_OpCode == 6'h01) && (ID_rt == 5'b00000));
    // 算术/逻辑立即数和 lw/sw 都用 rs；lui 不需要 rs，故不在列表中。
    assign ID_IsImmediateRs =
        (ID_OpCode == 6'h08) || (ID_OpCode == 6'h09) ||
        (ID_OpCode == 6'h0a) || (ID_OpCode == 6'h0b) ||
        (ID_OpCode == 6'h0c) || (ID_OpCode == 6'h0d) ||
        (ID_OpCode == 6'h23) || (ID_OpCode == 6'h2b);

    // 汇总当前 ID 指令是否真实消费 rs。
    assign ID_UsesRs =
        ID_IsRegisterJump ||
        (ID_IsRType && !ID_IsShift && !ID_IsRegisterJump) ||
        ID_IsSpecial2 ||
        ID_IsImmediateRs ||
        ID_IsBranchTwoRegs ||
        ID_IsBranchOneReg;

    // 汇总当前 ID 指令是否真实消费 rt。sw 需要 rt 作为待写数据。
    assign ID_UsesRt =
        (ID_IsRType && !ID_IsRegisterJump) ||
        ID_IsSpecial2 ||
        (ID_OpCode == 6'h2b) ||
        ID_IsBranchTwoRegs;

    // 根据 ID/EX 中 RegDst 预先算出 EX 指令未来的目的寄存器。
    // jal 的固定目的寄存器为 $31。
    assign ID_EX_WriteRegister_Hazard =
        (ID_EX_RegDst == 2'b00) ? ID_EX_rt :
        (ID_EX_RegDst == 2'b01) ? ID_EX_rd :
                                  5'b11111;

    // load-use 冒险：EX 中的 lw 要到下一拍 MEM 结束才得到数据，无法从
    // EX/MEM 立即转发；若 ID 指令下一拍就要读取该寄存器，必须停一拍。
    assign LoadUseHazard =
        ID_EX_MemRead &&
        (ID_EX_WriteRegister_Hazard != 5'b00000) &&
        ((ID_UsesRs && (ID_EX_WriteRegister_Hazard == ID_rs)) ||
         (ID_UsesRt && (ID_EX_WriteRegister_Hazard == ID_rt)));

    // jr/jalr 在 ID 阶段就需要 rs 形成 PC，早于普通指令在 EX 使用操作数：
    //   * 生产者还在 EX：无论何种写回类型，都先暂停；
    //   * 生产者是 EX/MEM 中的 lw：数据仍不可用于 ID 旁路，再暂停一拍。
    // EX/MEM 的非 load 结果以及 MEM/WB 结果已能由上面的 ID 旁路获得。
    assign JumpRegisterHazard =
        ID_IsRegisterJump &&
        ((ID_EX_RegWrite &&
          (ID_EX_WriteRegister_Hazard != 5'b00000) &&
          (ID_EX_WriteRegister_Hazard == ID_rs)) ||
         (EX_MEM_RegWrite &&
          EX_MEM_MemRead &&
          (EX_MEM_WriteRegister != 5'b00000) &&
          (EX_MEM_WriteRegister == ID_rs)));

    // 暂停的三个动作必须同时发生：
    //   1. PCWrite=0，停止取新 PC；
    //   2. IF_ID_Write=0，保持当前 ID 指令；
    //   3. ID_EX_Flush=1，给 EX 插入无副作用 bubble，让旧指令继续前进。
    assign ID_Stall    = LoadUseHazard || JumpRegisterHazard;
    assign PCWrite     = ~ID_Stall;
    assign IF_ID_Write = ~ID_Stall;
    assign ID_EX_Flush =  ID_Stall;

	// ID/EX 的 flush 优先于正常锁存。分支在 EX 成立时，当前 ID 指令属于
	// 错误路径；发生数据冒险时，当前 ID 指令必须留在 IF/ID 等待，二者
	// 都通过把控制信号清零来阻止 bubble 写寄存器或访问存储器。
	always @(posedge reset or posedge clk) begin
		if (reset) begin
			ID_EX_PC_plus_4 <= 32'h00000000;
			ID_EX_ReadData1 <= 32'h00000000;
			ID_EX_ReadData2 <= 32'h00000000;
			ID_EX_Imm       <= 32'h00000000;

			ID_EX_rs        <= 5'b00000;
			ID_EX_rt        <= 5'b00000;
			ID_EX_rd        <= 5'b00000;
			ID_EX_shamt     <= 5'b00000;
			ID_EX_funct     <= 6'b000000;

			ID_EX_RegDst    <= 2'b00;
            ID_EX_ALUSrc1   <= 1'b0;
            ID_EX_ALUSrc2   <= 1'b0;
            ID_EX_ALUOp     <= 4'b0000;
            ID_EX_Branch     <= 1'b0;
            ID_EX_BranchType <= 3'd0;

			ID_EX_MemRead   <= 1'b0;
			ID_EX_MemWrite  <= 1'b0;
			ID_EX_MemtoReg  <= 2'b00;
			ID_EX_RegWrite  <= 1'b0;
		end
		else if (EX_BranchTaken || ID_EX_Flush) begin
                // 插入 bubble：数据字段一并清零便于观察，真正保证“无副作用”
                // 的关键是 Branch/MemRead/MemWrite/RegWrite 等控制位全部为 0。
                ID_EX_PC_plus_4 <= 32'h00000000;
                ID_EX_ReadData1 <= 32'h00000000;
                ID_EX_ReadData2 <= 32'h00000000;
                ID_EX_Imm       <= 32'h00000000;
                ID_EX_rs        <= 5'b00000;
                ID_EX_rt        <= 5'b00000;
                ID_EX_rd        <= 5'b00000;
                ID_EX_shamt     <= 5'b00000;
                ID_EX_funct     <= 6'b000000;
                ID_EX_RegDst    <= 2'b00;
                ID_EX_ALUSrc1   <= 1'b0;
                ID_EX_ALUSrc2   <= 1'b0;
                ID_EX_ALUOp     <= 4'b0000;
                ID_EX_Branch     <= 1'b0;
                ID_EX_BranchType <= 3'd0;
                ID_EX_MemRead   <= 1'b0;
                ID_EX_MemWrite  <= 1'b0;
                ID_EX_MemtoReg  <= 2'b00;
                ID_EX_RegWrite  <= 1'b0;
            end
		else begin
			// 正常推进：把当前 ID 指令及其控制信息完整锁存到 EX。
			ID_EX_PC_plus_4 <= IF_ID_PC_plus_4;
			ID_EX_ReadData1 <= ID_ReadData1;
			ID_EX_ReadData2 <= ID_ReadData2;
			ID_EX_Imm       <= ID_LU_out;

			ID_EX_rs        <= ID_rs;
			ID_EX_rt        <= ID_rt;
			ID_EX_rd        <= ID_rd;
			ID_EX_shamt     <= ID_shamt;
			ID_EX_funct     <= ID_Funct;

			ID_EX_RegDst    <= ID_RegDst;
			ID_EX_ALUSrc1   <= ID_ALUSrc1;
			ID_EX_ALUSrc2   <= ID_ALUSrc2;
			ID_EX_ALUOp     <= ID_ALUOp;
			ID_EX_Branch     <= ID_Branch;
            ID_EX_BranchType <= ID_BranchType;

			ID_EX_MemRead   <= ID_MemRead;
			ID_EX_MemWrite  <= ID_MemWrite;
			ID_EX_MemtoReg  <= ID_MemtoReg;
			ID_EX_RegWrite  <= ID_RegWrite;
		end
	end
	// ============================================================
	// EX stage
	// ============================================================

	wire [4:0] EX_ALUCtl;
	wire       EX_Sign;

	// 把主控制器产生的 ALUOp 和 funct 二次译码为具体 ALU 操作。
	ALUControl alu_control1(
		.ALUOp  (ID_EX_ALUOp),
		.Funct  (ID_EX_funct),
		.ALUCtl (EX_ALUCtl),
		.Sign   (EX_Sign)
	);

	wire [31:0] EX_ALU_in1;
    wire [31:0] EX_ALU_in2;
    wire [31:0] EX_ALU_out;
    wire        EX_Zero;

    // 转发控制编码：00 使用 ID/EX 原值；10 使用 EX/MEM；01 使用 MEM/WB。
    wire [1:0] ForwardA;
    wire [1:0] ForwardB;

    // rs 转发选择。EX/MEM 优先于 MEM/WB，因为它对应更近、更新的生产者。
    // EX/MEM 中若为 lw，ALU_out 只是地址而非加载值，因此禁止该级转发。
    assign ForwardA =
	   (EX_MEM_RegWrite &&
	    !EX_MEM_MemRead &&
	   (EX_MEM_WriteRegister != 5'b00000) &&
	   (EX_MEM_WriteRegister == ID_EX_rs)) ? 2'b10 :

	   (MEM_WB_RegWrite &&
	   (MEM_WB_WriteRegister != 5'b00000) &&
	   (MEM_WB_WriteRegister == ID_EX_rs)) ? 2'b01 :

	   2'b00;

    // rt 使用相同规则。转发后的 rt 既可进入 ALU，也会成为 sw 的写数据。
    assign ForwardB =
	   (EX_MEM_RegWrite &&
	   !EX_MEM_MemRead &&
	   (EX_MEM_WriteRegister != 5'b00000) &&
	   (EX_MEM_WriteRegister == ID_EX_rt)) ? 2'b10 :

	   (MEM_WB_RegWrite &&
	   (MEM_WB_WriteRegister != 5'b00000) &&
	   (MEM_WB_WriteRegister == ID_EX_rt)) ? 2'b01 :

	   2'b00;

    // 根据 ForwardA/ForwardB 得到最新操作数。
    wire [31:0] EX_ForwardData1;
    wire [31:0] EX_ForwardData2;

    assign EX_ForwardData1 =
	   (ForwardA == 2'b10) ? EX_MEM_ForwardData :
	   (ForwardA == 2'b01) ? WB_WriteData :
	                       ID_EX_ReadData1;

    assign EX_ForwardData2 =
	   (ForwardB == 2'b10) ? EX_MEM_ForwardData :
	   (ForwardB == 2'b01) ? WB_WriteData :
	                       ID_EX_ReadData2;

    // ALU 第一输入：普通指令取最新 rs，固定移位取零扩展 shamt。
    assign EX_ALU_in1 = ID_EX_ALUSrc1 ?
	   {27'b0, ID_EX_shamt} :
	   EX_ForwardData1;

    // ALU 第二输入：R 型/分支取最新 rt，I 型/访存取扩展立即数。
    assign EX_ALU_in2 = ID_EX_ALUSrc2 ?
	   ID_EX_Imm :
	   EX_ForwardData2;

	   ALU alu1(
		  .in1    (EX_ALU_in1),
		  .in2    (EX_ALU_in2),
		  .ALUCtl (EX_ALUCtl),
		  .Sign   (EX_Sign),
		  .out    (EX_ALU_out),
		  .zero   (EX_Zero)
	   );
	// ============================================================
    // EX 阶段条件分支判定
    // ============================================================
    // 分支目标 = 该分支指令的 PC+4 + (符号扩展 offset << 2)。
    // 左移两位是因为 MIPS 分支偏移以“指令字”为单位，而 PC 按字节编址。
    assign EX_BranchTarget =
        ID_EX_PC_plus_4 + {ID_EX_Imm[29:0], 2'b00};
        
    wire EX_rs_zero;
    wire EX_rs_negative;
        
    // 单寄存器分支根据 rs 的零标志和符号位判断。
    assign EX_rs_zero     = (EX_ForwardData1 == 32'h00000000);
    assign EX_rs_negative = EX_ForwardData1[31];
    
    // beq/bne 直接比较经过转发后的 rs、rt，避免旧寄存器值造成误判。
    wire EX_BranchEqual;
    assign EX_BranchEqual = (EX_ForwardData1 == EX_ForwardData2);
        
    // BranchType 由 Control.v 编码。只有 ID_EX_Branch=1 时条件才有效。
    assign EX_BranchTaken =
            ID_EX_Branch && (
                (ID_EX_BranchType == 3'd1 && EX_BranchEqual) ||                    // beq
                (ID_EX_BranchType == 3'd2 && !EX_BranchEqual) ||                   // bne
                (ID_EX_BranchType == 3'd3 && (EX_rs_negative || EX_rs_zero)) ||     // blez
                (ID_EX_BranchType == 3'd4 && (!EX_rs_negative && !EX_rs_zero)) ||   // bgtz
                (ID_EX_BranchType == 3'd5 && EX_rs_negative)                       // bltz
            );

	wire [4:0] EX_WriteRegister;

	// 目的寄存器选择：I 型/lw 为 rt，R 型/mul/jalr 为 rd，jal 为 $31。
	assign EX_WriteRegister =
		(ID_EX_RegDst == 2'b00) ? ID_EX_rt :
		(ID_EX_RegDst == 2'b01) ? ID_EX_rd :
		                          5'b11111;

	// ============================================================
	// EX/MEM 流水线寄存器
	// ============================================================
	// 保存 ALU 结果、sw 数据、目的寄存器以及 MEM/WB 控制。分支控制不再
	// 向后传，因为分支已经在 EX 判定完毕且不产生后续副作用。


	always @(posedge reset or posedge clk) begin
		if (reset) begin
		    EX_MEM_PC_plus_4     <= 32'h00000000;
			EX_MEM_ALU_out       <= 32'h00000000;
			EX_MEM_WriteData     <= 32'h00000000;
			EX_MEM_WriteRegister <= 5'b00000;

			EX_MEM_MemRead       <= 1'b0;
			EX_MEM_MemWrite      <= 1'b0;
			EX_MEM_MemtoReg      <= 2'b00;
			EX_MEM_RegWrite      <= 1'b0;
		end
		else begin
		    EX_MEM_PC_plus_4     <= ID_EX_PC_plus_4;
			EX_MEM_ALU_out       <= EX_ALU_out;
			// sw 必须保存转发后的 rt；否则紧随生产者的 sw 会写入旧值。
			EX_MEM_WriteData <= EX_ForwardData2;
			EX_MEM_WriteRegister <= EX_WriteRegister;

			EX_MEM_MemRead       <= ID_EX_MemRead;
			EX_MEM_MemWrite      <= ID_EX_MemWrite;
			EX_MEM_MemtoReg      <= ID_EX_MemtoReg;
			EX_MEM_RegWrite      <= ID_EX_RegWrite;
		end
	end

	// ============================================================
	// MEM 阶段
	// ============================================================
	// DataMemory 内部完成低地址 RAM 和数码管/UART 外设的地址译码。

	wire [31:0] MEM_ReadData;

	DataMemory data_memory1(
	.reset      (reset),
	.clk        (clk),
	.Address    (EX_MEM_ALU_out),
	.Write_data (EX_MEM_WriteData),
	.Read_data  (MEM_ReadData),
	.MemRead    (EX_MEM_MemRead),
	.MemWrite   (EX_MEM_MemWrite),
	.digi       (digi),
	.uart_rx    (uart_rx),
	.uart_tx    (uart_tx)
);

	// 同步导出当前 MEM 访问，便于顶层连接扩展设备或仿真观察。
	// 当前数据读回实际使用 MEM_ReadData，Device_Read_Data 为预留端口。
	assign MemRead           = EX_MEM_MemRead;
	assign MemWrite          = EX_MEM_MemWrite;
	assign MemBus_Address    = EX_MEM_ALU_out;
	assign MemBus_Write_Data = EX_MEM_WriteData;

	// ============================================================
	// MEM/WB 流水线寄存器
	// ============================================================
	// 同时保留三种可能的写回候选值，WB 再由 MemtoReg 选择其中之一。
    reg [31:0] MEM_WB_PC_plus_4;

	always @(posedge reset or posedge clk) begin
		if (reset) begin
		    MEM_WB_PC_plus_4 <= 32'h00000000;
			MEM_WB_ReadData      <= 32'h00000000;
			MEM_WB_ALU_out       <= 32'h00000000;
			MEM_WB_WriteRegister <= 5'b00000;

			MEM_WB_MemtoReg      <= 2'b00;
			MEM_WB_RegWrite      <= 1'b0;
		end
		else begin
		    MEM_WB_PC_plus_4 <= EX_MEM_PC_plus_4;
			MEM_WB_ReadData      <= MEM_ReadData;
			MEM_WB_ALU_out       <= EX_MEM_ALU_out;
			MEM_WB_WriteRegister <= EX_MEM_WriteRegister;

			MEM_WB_MemtoReg      <= EX_MEM_MemtoReg;
			MEM_WB_RegWrite      <= EX_MEM_RegWrite;
		end
	end

	// ============================================================
	// WB 阶段
	// ============================================================

	// 01：lw 的内存读数据；10：jal/jalr 的 PC+4；00：ALU 结果。
	// WB_WriteData 同时回送到寄存器堆和前递网络。
	assign WB_WriteData =
	(MEM_WB_MemtoReg == 2'b01) ? MEM_WB_ReadData :
	(MEM_WB_MemtoReg == 2'b10) ? MEM_WB_PC_plus_4 :
	                              MEM_WB_ALU_out;

endmodule
