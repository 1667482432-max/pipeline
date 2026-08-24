module test_cpu();
	
	reg reset;
	reg clk;

	wire        MemRead; 
	wire        MemWrite;
	wire [31:0] MemBus_Address;
	wire [31:0] MemBus_Write_Data;
	wire [31:0] Device_Read_Data;
	wire [11:0] digi;
	wire uart_rx;
	wire uart_tx;

	assign Device_Read_Data = 32'h00000000;
	assign uart_rx = 1'b1;
	
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
		reset = 1;
		clk   = 1;
		#100 reset = 0;
		#1000000000 $finish;
	end
	
	always #50 clk = ~clk;
		
endmodule
