module CPU(
	input  reset,
	input  clk,
	output MemRead,
	output MemWrite,
	output [32 -1:0] MemBus_Address,
	output [32 -1:0] MemBus_Write_Data,
	input  [32 -1:0] Device_Read_Data,
	output [12 -1:0] digi,
	input  uart_rx,
	output uart_tx
);

	// ============================================================
	// IF stage
	// ============================================================

	reg  [31:0] PC;
	wire [31:0] PC_next;
	wire [31:0] PC_plus_4;
	wire [31:0] IF_Instruction;
	
	// Branch and jump control
    wire        EX_BranchTaken;
    wire [31:0] EX_BranchTarget;
    
    wire        ID_Jump;
    wire [31:0] ID_JumpTarget;
	
	// Hazard control signals
    wire PCWrite;
    wire IF_ID_Write;
    wire ID_EX_Flush;
    wire ID_Stall;
    wire LoadUseHazard;
    wire JumpRegisterHazard;
    wire ID_JumpRaw;
    wire ID_IsRegisterJump;

	assign PC_plus_4 = PC + 32'd4;
	assign PC_next =
        EX_BranchTaken ? EX_BranchTarget :
        ID_Jump        ? ID_JumpTarget    :
                         PC_plus_4;

    always @(posedge reset or posedge clk) begin
	   if (reset)
		  PC <= 32'h00000000;
	   else if (EX_BranchTaken || ID_Jump || PCWrite)
		  PC <= PC_next;
    end

	InstructionMemory instruction_memory1(
		.Address     (PC),
		.Instruction (IF_Instruction)
	);

	// ============================================================
	// IF/ID pipeline register
	// ============================================================

	reg [31:0] IF_ID_PC_plus_4;
	reg [31:0] IF_ID_Instruction;

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

	// Control signals generated in ID stage
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
	
	// Jump target is calculated in ID stage.
    // Register jumps are held until their target register can be read safely.
    assign ID_IsRegisterJump = (ID_PCSrc == 2'b10);
    assign ID_JumpRaw = (ID_PCSrc == 2'b01) || ID_IsRegisterJump;
    assign ID_Jump = ID_JumpRaw && !ID_Stall;
    
    assign ID_JumpTarget =
        (ID_PCSrc == 2'b01) ?
            {IF_ID_PC_plus_4[31:28], IF_ID_Instruction[25:0], 2'b00} :
            ID_ReadData1;

// ============================================================
// WB related signals
// These signals are used by RegisterFile in ID stage,
// so declare them before RegisterFile instance.
// ============================================================

    wire [31:0] WB_WriteData;

    reg [31:0] MEM_WB_ReadData;
    reg [31:0] MEM_WB_ALU_out;
    reg [4:0]  MEM_WB_WriteRegister;

    reg [1:0]  MEM_WB_MemtoReg;
    reg        MEM_WB_RegWrite;;

    // EX/MEM signals are also used by ID-stage forwarding for jr/jalr.
    reg [31:0] EX_MEM_ALU_out;
    reg [31:0] EX_MEM_WriteData;
    reg [4:0]  EX_MEM_WriteRegister;
    reg [31:0] EX_MEM_PC_plus_4;

    reg        EX_MEM_MemRead;
    reg        EX_MEM_MemWrite;
    reg [1:0]  EX_MEM_MemtoReg;
    reg        EX_MEM_RegWrite;

    wire [31:0] EX_MEM_ForwardData;
    assign EX_MEM_ForwardData =
        (EX_MEM_MemtoReg == 2'b10) ? EX_MEM_PC_plus_4 :
                                     EX_MEM_ALU_out;

	// Register File read in ID, write in WB
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
    
    // ID-stage bypass for register jumps and same-cycle WB reads.
    assign ID_ReadData1 =
        (EX_MEM_RegWrite &&
         !EX_MEM_MemRead &&
         (EX_MEM_WriteRegister != 5'b00000) &&
         (EX_MEM_WriteRegister == ID_rs)) ? EX_MEM_ForwardData :
        (MEM_WB_RegWrite &&
         (MEM_WB_WriteRegister != 5'b00000) &&
         (MEM_WB_WriteRegister == ID_rs)) ? WB_WriteData :
                                            ID_ReadData1_raw;
    
    assign ID_ReadData2 =
        (EX_MEM_RegWrite &&
         !EX_MEM_MemRead &&
         (EX_MEM_WriteRegister != 5'b00000) &&
         (EX_MEM_WriteRegister == ID_rt)) ? EX_MEM_ForwardData :
        (MEM_WB_RegWrite &&
         (MEM_WB_WriteRegister != 5'b00000) &&
         (MEM_WB_WriteRegister == ID_rt)) ? WB_WriteData :
                                            ID_ReadData2_raw;

	// Immediate extend
	wire [31:0] ID_Ext_out;
	wire [31:0] ID_LU_out;

	assign ID_Ext_out = {
		ID_ExtOp ? {16{IF_ID_Instruction[15]}} : 16'h0000,
		IF_ID_Instruction[15:0]
	};

	assign ID_LU_out = ID_LuOp ?
		{IF_ID_Instruction[15:0], 16'h0000} :
		ID_Ext_out;

	// ============================================================
	// ID/EX pipeline register
	// ============================================================

	reg [31:0] ID_EX_PC_plus_4;
	reg [31:0] ID_EX_ReadData1;
	reg [31:0] ID_EX_ReadData2;
	reg [31:0] ID_EX_Imm;

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
    // Hazard Detection Unit
    // Detect load-use hazard
    // ============================================================
    
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
    assign ID_IsShift = ID_IsRType &&
        ((ID_Funct == 6'h00) || (ID_Funct == 6'h02) || (ID_Funct == 6'h03));
    assign ID_IsBranchTwoRegs =
        (ID_OpCode == 6'h04) || (ID_OpCode == 6'h05);
    assign ID_IsBranchOneReg =
        (ID_OpCode == 6'h06) || (ID_OpCode == 6'h07) ||
        ((ID_OpCode == 6'h01) && (ID_rt == 5'b00000));
    assign ID_IsImmediateRs =
        (ID_OpCode == 6'h08) || (ID_OpCode == 6'h09) ||
        (ID_OpCode == 6'h0a) || (ID_OpCode == 6'h0b) ||
        (ID_OpCode == 6'h0c) || (ID_OpCode == 6'h0d) ||
        (ID_OpCode == 6'h23) || (ID_OpCode == 6'h2b);

    assign ID_UsesRs =
        ID_IsRegisterJump ||
        (ID_IsRType && !ID_IsShift && !ID_IsRegisterJump) ||
        ID_IsSpecial2 ||
        ID_IsImmediateRs ||
        ID_IsBranchTwoRegs ||
        ID_IsBranchOneReg;

    assign ID_UsesRt =
        (ID_IsRType && !ID_IsRegisterJump) ||
        ID_IsSpecial2 ||
        (ID_OpCode == 6'h2b) ||
        ID_IsBranchTwoRegs;

    assign ID_EX_WriteRegister_Hazard =
        (ID_EX_RegDst == 2'b00) ? ID_EX_rt :
        (ID_EX_RegDst == 2'b01) ? ID_EX_rd :
                                  5'b11111;

    assign LoadUseHazard =
        ID_EX_MemRead &&
        (ID_EX_WriteRegister_Hazard != 5'b00000) &&
        ((ID_UsesRs && (ID_EX_WriteRegister_Hazard == ID_rs)) ||
         (ID_UsesRt && (ID_EX_WriteRegister_Hazard == ID_rt)));

    assign JumpRegisterHazard =
        ID_IsRegisterJump &&
        ((ID_EX_RegWrite &&
          (ID_EX_WriteRegister_Hazard != 5'b00000) &&
          (ID_EX_WriteRegister_Hazard == ID_rs)) ||
         (EX_MEM_RegWrite &&
          EX_MEM_MemRead &&
          (EX_MEM_WriteRegister != 5'b00000) &&
          (EX_MEM_WriteRegister == ID_rs)));

    assign ID_Stall    = LoadUseHazard || JumpRegisterHazard;
    assign PCWrite     = ~ID_Stall;
    assign IF_ID_Write = ~ID_Stall;
    assign ID_EX_Flush =  ID_Stall;

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
                // 插入 bubble，也就是把控制信号清零
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

    // Forwarding control signals
    wire [1:0] ForwardA;
    wire [1:0] ForwardB;

    // ForwardA controls source register rs
    assign ForwardA =
	   (EX_MEM_RegWrite &&
	    !EX_MEM_MemRead &&
	   (EX_MEM_WriteRegister != 5'b00000) &&
	   (EX_MEM_WriteRegister == ID_EX_rs)) ? 2'b10 :

	   (MEM_WB_RegWrite &&
	   (MEM_WB_WriteRegister != 5'b00000) &&
	   (MEM_WB_WriteRegister == ID_EX_rs)) ? 2'b01 :

	   2'b00;

    // ForwardB controls source register rt
    assign ForwardB =
	   (EX_MEM_RegWrite &&
	   !EX_MEM_MemRead &&
	   (EX_MEM_WriteRegister != 5'b00000) &&
	   (EX_MEM_WriteRegister == ID_EX_rt)) ? 2'b10 :

	   (MEM_WB_RegWrite &&
	   (MEM_WB_WriteRegister != 5'b00000) &&
	   (MEM_WB_WriteRegister == ID_EX_rt)) ? 2'b01 :

	   2'b00;

    // Data after forwarding
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

    // ALU input selection
    assign EX_ALU_in1 = ID_EX_ALUSrc1 ?
	   {27'b0, ID_EX_shamt} :
	   EX_ForwardData1;

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
    // Branch decision in EX stage
    // Currently only support beq
    // ============================================================
    assign EX_BranchTarget =
        ID_EX_PC_plus_4 + {ID_EX_Imm[29:0], 2'b00};
        
    wire EX_rs_zero;
    wire EX_rs_negative;
        
    assign EX_rs_zero     = (EX_ForwardData1 == 32'h00000000);
    assign EX_rs_negative = EX_ForwardData1[31];
    
    wire EX_BranchEqual;
    assign EX_BranchEqual = (EX_ForwardData1 == EX_ForwardData2);
        
    assign EX_BranchTaken =
            ID_EX_Branch && (
                (ID_EX_BranchType == 3'd1 && EX_BranchEqual) ||                    // beq
                (ID_EX_BranchType == 3'd2 && !EX_BranchEqual) ||                   // bne
                (ID_EX_BranchType == 3'd3 && (EX_rs_negative || EX_rs_zero)) ||     // blez
                (ID_EX_BranchType == 3'd4 && (!EX_rs_negative && !EX_rs_zero)) ||   // bgtz
                (ID_EX_BranchType == 3'd5 && EX_rs_negative)                       // bltz
            );

	wire [4:0] EX_WriteRegister;

	assign EX_WriteRegister =
		(ID_EX_RegDst == 2'b00) ? ID_EX_rt :
		(ID_EX_RegDst == 2'b01) ? ID_EX_rd :
		                          5'b11111;

	// ============================================================
	// EX/MEM pipeline register
	// ============================================================


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
			EX_MEM_WriteData <= EX_ForwardData2;
			EX_MEM_WriteRegister <= EX_WriteRegister;

			EX_MEM_MemRead       <= ID_EX_MemRead;
			EX_MEM_MemWrite      <= ID_EX_MemWrite;
			EX_MEM_MemtoReg      <= ID_EX_MemtoReg;
			EX_MEM_RegWrite      <= ID_EX_RegWrite;
		end
	end

	// ============================================================
	// MEM stage
	// ============================================================

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

	assign MemRead           = EX_MEM_MemRead;
	assign MemWrite          = EX_MEM_MemWrite;
	assign MemBus_Address    = EX_MEM_ALU_out;
	assign MemBus_Write_Data = EX_MEM_WriteData;

	// ============================================================
	// MEM/WB pipeline register
	// ============================================================
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
	// WB stage
	// ============================================================

	assign WB_WriteData =
	(MEM_WB_MemtoReg == 2'b01) ? MEM_WB_ReadData :
	(MEM_WB_MemtoReg == 2'b10) ? MEM_WB_PC_plus_4 :
	                              MEM_WB_ALU_out;

endmodule
