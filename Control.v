
module Control(
	input  [6 -1:0] OpCode   ,
	input  [6 -1:0] Funct    ,
	input  [5 -1:0] Rt       ,
	output [2 -1:0] PCSrc    ,
	output Branch            ,
	output [3 -1:0] BranchType,
	output RegWrite          ,
	output [2 -1:0] RegDst   ,
	output MemRead           ,
	output MemWrite          ,
	output [2 -1:0] MemtoReg ,
	output ALUSrc1           ,
	output ALUSrc2           ,
	output ExtOp             ,
	output LuOp              ,
	output [4 -1:0] ALUOp
);

	assign PCSrc = 
        (OpCode == 6'h02 || OpCode == 6'h03) ? 2'b01 : // j or jal
        (OpCode == 6'h00 && (Funct == 6'h08 || Funct == 6'h09)) ? 2'b10 : // jr or jalr
        2'b00;
	
	assign Branch =
            (OpCode == 6'h04 ||  // beq
             OpCode == 6'h05 ||  // bne
             OpCode == 6'h06 ||  // blez
             OpCode == 6'h07 ||  // bgtz
             (OpCode == 6'h01 && Rt == 5'b00000)) ? 1'b1 : // bltz
            1'b0;
            
    assign BranchType =
                (OpCode == 6'h04) ? 3'd1 :                       // beq
                (OpCode == 6'h05) ? 3'd2 :                       // bne
                (OpCode == 6'h06) ? 3'd3 :                       // blez
                (OpCode == 6'h07) ? 3'd4 :                       // bgtz
                (OpCode == 6'h01 && Rt == 5'b00000) ? 3'd5 :     // bltz
                3'd0;

	assign RegWrite = 
	(OpCode == 6'h2b ||      // sw
	 Branch ||               // all branch
	 OpCode == 6'h02 ||      // j
	 (OpCode == 6'h00 && Funct == 6'h08)) ? 1'b0 : // jr
	1'b1;

	assign RegDst =
		(OpCode == 6'h00 || OpCode == 6'h1c)? 2'b01: //R, mul
		(OpCode == 6'h03)? 2'b10: //jal
		2'b00; //others

	assign MemRead = 
		(OpCode == 6'h23)? 1'b1: //lw
		1'b0; //others

	assign MemWrite = 
		(OpCode == 6'h2b)? 1'b1: //sw
		1'b0; //others

	assign MemtoReg = 
	(OpCode == 6'h23) ? 2'b01 : // lw
	(OpCode == 6'h03 || (OpCode == 6'h00 && Funct == 6'h09)) ? 2'b10 : // jal or jalr
	2'b00;

	assign ALUSrc1 =
		(OpCode == 6'h00 && (Funct == 6'h00 || Funct == 6'h02 || Funct == 6'h03))? 1'b1: //sll, slrl, sra
		1'b0; //others

	assign ALUSrc2 =
	(OpCode == 6'h00 || OpCode == 6'h1c ||
	 OpCode == 6'h04 || OpCode == 6'h05 ||
	 OpCode == 6'h06 || OpCode == 6'h07 ||
	 OpCode == 6'h01)? 1'b0:
	1'b1;

	assign ExtOp =
	(OpCode == 6'h0c || OpCode == 6'h0d)? 1'b0: // andi, ori
	1'b1;

	assign LuOp = 
		(OpCode == 6'h0f)? 1'b1: //lui
		1'b0; //others

	// set ALUOp
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
		
	assign ALUOp[3] = OpCode[0];


	
	
endmodule