// ============================================================================
// 数据存储器与存储器映射外设
//
// 本模块位于流水线 MEM 阶段，将统一的 lw/sw 地址空间分成三部分：
//   * 低地址 4 KiB RAM：保存 2-2 放大器算法的输入、中间量和结果；
//   * 数码管寄存器：软件通过 sw 更新 12 位显示值；
//   * UART 数据/状态寄存器：软件按普通访存方式收发字节。
//
// reset 还承担“串口装载窗口”的作用：reset=1 时 CPU 停止运行，本模块
// 把 UART 收到的 ASCII 十进制整数依次写入 RAM；reset 从 1 变为 0 后，
// CPU 再从 PC=0 开始处理已经装载好的数据。
// ============================================================================
module DataMemory(
    input  reset,             // 高电平：复位运行状态并允许 UART 装载 RAM
    input  clk,
    input  MemRead,           // 来自 EX/MEM 的读使能
    input  MemWrite,          // 来自 EX/MEM 的写使能
    input  [31:0] Address,    // ALU 计算出的字节地址
    input  [31:0] Write_data, // sw 的 rt 数据（已在 EX 阶段完成转发）
    output [31:0] Read_data,  // 返回给 MEM/WB 的组合读数据
    output [11:0] digi,       // 板级 12 位显示输出
    input  uart_rx,
    output uart_tx
);

    parameter RAM_SIZE      = 1024; // 1024 个 32 位字，共 4 KiB
    parameter RAM_SIZE_BIT  = 10;   // RAM 字地址宽度

    reg [31:0] RAM_data [0:RAM_SIZE - 1];

    // 数码管是一个可读写的存储映射寄存器。
    reg [11:0] digi_reg;
    assign digi = digi_reg;

    // 存储器映射表（均为字节地址）：
    //   0x4000_0010  数码管数据，低 12 位有效
    //   0x4000_0018  UART 发送数据，写低 8 位启动发送
    //   0x4000_001C  UART 接收数据，读低 8 位
    //   0x4000_0020  UART 状态，bit4/bit3/bit2 见 Read_data 注释
    localparam DIGI_ADDR     = 32'h4000_0010;
    localparam UART_TXD_ADDR = 32'h4000_0018;
    localparam UART_RXD_ADDR = 32'h4000_001c;
    localparam UART_CON_ADDR = 32'h4000_0020;

    // 地址比较器先确定本次访问命中的设备。
    wire is_digi_addr;
    wire is_uart_txd_addr;
    wire is_uart_rxd_addr;
    wire is_uart_con_addr;
    wire is_ram_addr;

    assign is_digi_addr     = (Address == DIGI_ADDR);
    assign is_uart_txd_addr = (Address == UART_TXD_ADDR);
    assign is_uart_rxd_addr = (Address == UART_RXD_ADDR);
    assign is_uart_con_addr = (Address == UART_CON_ADDR);
    assign is_ram_addr      = (Address[31:30] == 2'b00);

    // CPU 给出字节地址，RAM_data 使用字下标，所以忽略对齐的低两位。
    wire [RAM_SIZE_BIT-1:0] ram_word_addr;
    assign ram_word_addr = Address[RAM_SIZE_BIT + 1 : 2];

    // 既检查低地址区域，也检查实际字下标，避免数组越界访问。
    wire ram_addr_in_range;
    assign ram_addr_in_range = is_ram_addr && (Address[31:2] < RAM_SIZE);

    // UARTTx/UARTRx 的单周期事件与状态信号。
    wire       uart_tx_busy;  // 发送状态机正在工作
    wire       uart_tx_done;
    wire [7:0] uart_rx_data;
    wire       uart_rx_ready;

    // done/ready 在 UART 内只保持一个时钟周期。这里锁存成“粘滞位”，
    // 直到软件读取 UART_CON_ADDR 才清零，避免 CPU 轮询时漏掉事件。
    reg uart_tx_done_status;
    reg uart_rx_ready_status;

    // 向 UART_TXD_ADDR 执行 sw 即请求发送低 8 位。
    // busy 时拒绝重复启动，防止正在发送的数据被覆盖。
    wire uart_tx_start;
    assign uart_tx_start = !reset && MemWrite && is_uart_txd_addr && !uart_tx_busy;

    UARTTx uart_tx1(
        .reset (reset),
        .clk   (clk),
        .start (uart_tx_start),
        .data  (Write_data[7:0]),
        .tx    (uart_tx),
        .busy  (uart_tx_busy),
        .done  (uart_tx_done)
    );

    UARTRx uart_rx1(
        // 接收器故意不连接系统 reset：系统复位期间正是串口装载阶段，
        // 因此 UART 接收状态机必须继续运行并产生 uart_rx_ready 脉冲。
        .reset (1'b0),
        .clk   (clk),
        .rx    (uart_rx),
        .data  (uart_rx_data),
        .ready (uart_rx_ready)
    );

    // 组合读多路器，地址命中优先级为外设后 RAM。
    // UART_CON_ADDR 返回：bit4=tx_busy，bit3=收到过新字节，
    // bit2=上一字节发送完成，bit1:0=0，其余高位=0。
    assign Read_data =
        (MemRead && is_digi_addr)     ? {20'b0, digi_reg} :
        (MemRead && is_uart_rxd_addr) ? {24'b0, uart_rx_data} :
        (MemRead && is_uart_con_addr) ? {27'b0, uart_tx_busy,
                                         uart_rx_ready_status,
                                         uart_tx_done_status,
                                         2'b00} :
        (MemRead && ram_addr_in_range) ? RAM_data[ram_word_addr] :
                                        32'h00000000;

    integer i;
    reg reset_d;                           // reset 的一拍延迟，用于检测下降沿
    reg [RAM_SIZE_BIT:0] loader_word_addr; // 下一待写字下标，多一位用于防溢出
    reg [31:0] loader_value;               // 当前十进制 token 的绝对值累加器
    reg loader_negative;                   // 当前 token 是否带负号
    reg loader_in_token;                   // 已看到符号或数字，正在解析 token
    reg loader_has_digit;                  // 至少收到一位数字，防止单独符号写入

    wire loader_is_digit;
    wire loader_is_minus;
    wire loader_is_plus;
    wire [31:0] loader_digit_value;
    wire [31:0] loader_accum_next;
    wire [31:0] loader_store_value;

    // ASCII 分类：'0'~'9'、'-'、'+'。
    assign loader_is_digit = (uart_rx_data >= 8'h30) && (uart_rx_data <= 8'h39);
    assign loader_is_minus = (uart_rx_data == 8'h2d);
    assign loader_is_plus  = (uart_rx_data == 8'h2b);
    assign loader_digit_value = {28'b0, uart_rx_data - 8'h30};
    // value*10+digit 用移位加法实现：value*8 + value*2 + digit。
    assign loader_accum_next = (loader_value << 3) + (loader_value << 1) + loader_digit_value;
    // 负数在写入 RAM 前转换为 32 位二进制补码。
    assign loader_store_value = loader_negative ? (~loader_value + 32'd1) : loader_value;

    initial begin
        // 为仿真与 FPGA RAM 初始化提供确定的上电内容。
        for (i = 0; i < RAM_SIZE; i = i + 1)
            RAM_data[i] = 32'h00000000;
        // input.mem 是没有使用串口时的默认测试输入。
        $readmemh("input.mem", RAM_data);
        reset_d = 1'b0;
        loader_word_addr = {(RAM_SIZE_BIT + 1){1'b0}};
        loader_value = 32'h00000000;
        loader_negative = 1'b0;
        loader_in_token = 1'b0;
        loader_has_digit = 1'b0;
        digi_reg = 12'h000;
        uart_tx_done_status = 1'b0;
        uart_rx_ready_status = 1'b0;
    end

    // ------------------------------------------------------------------------
    // 时序控制分为四种状态：
    //   1. reset 刚拉高：清空装载器状态和外设状态；
    //   2. reset 持续为高：接收并解析 ASCII 十进制整数；
    //   3. reset 刚拉低：提交最后一个可能没有分隔符的整数；
    //   4. 正常运行：处理 CPU 的 RAM/外设访问。
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        reset_d <= reset;

        // reset 上升后的第一个时钟周期，装载从 RAM[0] 重新开始。
        if (reset && !reset_d) begin
            digi_reg <= 12'h000;
            uart_tx_done_status <= 1'b0;
            uart_rx_ready_status <= 1'b0;
            loader_word_addr <= {(RAM_SIZE_BIT + 1){1'b0}};
            loader_value <= 32'h00000000;
            loader_negative <= 1'b0;
            loader_in_token <= 1'b0;
            loader_has_digit <= 1'b0;
        end
        // 装载阶段：每次 uart_rx_ready 表示完整收到一个 ASCII 字节。
        else if (reset) begin
            if (uart_rx_ready && (loader_word_addr < RAM_SIZE)) begin
                if (loader_is_digit) begin
                    // 第一个数字直接赋值，后续数字按十进制累加。
                    loader_value <= loader_in_token ? loader_accum_next : loader_digit_value;
                    loader_in_token <= 1'b1;
                    loader_has_digit <= 1'b1;
                end
                // 正负号只在 token 开始位置有效。
                else if ((loader_is_minus || loader_is_plus) && !loader_in_token) begin
                    loader_value <= 32'h00000000;
                    loader_negative <= loader_is_minus;
                    loader_in_token <= 1'b1;
                    loader_has_digit <= 1'b0;
                end
                else begin
                    // 空格、换行等任意非数字字符都视为 token 分隔符。
                    // 只有真正含有数字的 token 才写入 RAM。
                    if (loader_in_token && loader_has_digit) begin
                        RAM_data[loader_word_addr[RAM_SIZE_BIT-1:0]] <= loader_store_value;
                        loader_word_addr <= loader_word_addr + {{RAM_SIZE_BIT{1'b0}}, 1'b1};
                    end
                    loader_value <= 32'h00000000;
                    loader_negative <= 1'b0;
                    loader_in_token <= 1'b0;
                    loader_has_digit <= 1'b0;
                end
            end
        end
        // reset 下降沿：若最后一个数字后没有分隔符，也要把它写入 RAM。
        else if (!reset && reset_d) begin
            if (loader_in_token && loader_has_digit && (loader_word_addr < RAM_SIZE)) begin
                RAM_data[loader_word_addr[RAM_SIZE_BIT-1:0]] <= loader_store_value;
            end
        end
        // CPU 正常运行阶段。
        else begin
            // 把 UART 的单周期完成脉冲保存成可供软件轮询的状态位。
            if (uart_tx_done)
                uart_tx_done_status <= 1'b1;

            if (uart_rx_ready)
                uart_rx_ready_status <= 1'b1;

            // 读取状态寄存器同时确认并清除两个事件状态位。
            if (MemRead && is_uart_con_addr) begin
                uart_tx_done_status <= 1'b0;
                uart_rx_ready_status <= 1'b0;
            end

            // sw 的地址译码：数码管取低 12 位，其余低地址写入 RAM。
            // UART 发送由 uart_tx_start 组合逻辑单独触发，不在此处保存数据。
            if (MemWrite) begin
                if (is_digi_addr) begin
                    digi_reg <= Write_data[11:0];
                end
                else if (ram_addr_in_range) begin
                    RAM_data[ram_word_addr] <= Write_data;
                end
            end
        end
    end

endmodule
