// ============================================================================
// FPGA 工程顶层
//
// 板级时钟、复位、数码管接口和 UART 引脚从这里接入 CPU。CPU 内部已经
// 实例化 InstructionMemory 与 DataMemory，因此这里的存储器总线信号仅
// 引出用于观察/调试，没有再连接外部存储设备。
// ============================================================================
module top(
    input clk,          // 系统时钟；约束文件将其绑定到板载 100 MHz 时钟
    input reset,        // 高有效复位；复位期间也可通过 UART 装载输入数据
    output [11:0] digi, // 12 位结果显示接口，由存储映射寄存器驱动
    input uart_rx,      // 串口接收引脚
    output uart_tx      // 串口发送引脚
);

    // CPU 的通用存储器总线观察信号。
    // 实际 RAM/外设访问已在 CPU 内部的 DataMemory 模块中完成。
    wire        MemRead;
    wire        MemWrite;
    wire [31:0] MemBus_Address;
    wire [31:0] MemBus_Write_Data;
    wire [31:0] Device_Read_Data;

    // 当前版本没有外挂总线从设备，故外部读数据固定为 0。
    // CPU.v 保留该端口是为了后续扩展，不参与本项目的数据读回路径。
    assign Device_Read_Data = 32'h00000000;

    // 五级流水线处理器实例。
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
