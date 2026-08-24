module top(
    input clk,
    input reset,
    output [11:0] digi,
    input uart_rx,
    output uart_tx
);

    wire        MemRead;
    wire        MemWrite;
    wire [31:0] MemBus_Address;
    wire [31:0] MemBus_Write_Data;
    wire [31:0] Device_Read_Data;

    assign Device_Read_Data = 32'h00000000;

    CPU cpu1(
        .reset              (reset),
        .clk                (clk),
        .MemRead            (MemRead),
        .MemWrite           (MemWrite),
        .MemBus_Address     (MemBus_Address),
        .MemBus_Write_Data  (MemBus_Write_Data),
        .Device_Read_Data   (Device_Read_Data),
        .digi               (digi),
        .uart_rx            (uart_rx),
        .uart_tx            (uart_tx)
    );

endmodule
