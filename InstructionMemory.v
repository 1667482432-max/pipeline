module InstructionMemory(
	input      [32 -1:0] Address,
	output reg [32 -1:0] Instruction
);

	parameter ROM_SIZE     = 1024;
	parameter ROM_ADDR_BIT = 10;

	reg [31:0] ROM_data [ROM_SIZE - 1:0];

	integer i;

	initial begin
		for (i = 0; i < ROM_SIZE; i = i + 1)
			ROM_data[i] = 32'h00000000;

		$readmemh("inst.mem", ROM_data);
	end

	always @(*) begin
		Instruction = ROM_data[Address[ROM_ADDR_BIT + 1 : 2]];
	end

endmodule
