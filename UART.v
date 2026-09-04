// ============================================================================
// UART 收发器封装
//
// 帧格式为常见的 8N1：1 个低电平起始位、8 个数据位（低位先发）、
// 无校验位、1 个高电平停止位。UARTTx 和 UARTRx 也可以像 DataMemory.v
// 那样分别实例化。
// ============================================================================
module UART #(
    parameter CLOCK_FREQ = 100000000, // 输入时钟频率，默认 100 MHz
    parameter BAUD_RATE  = 9600       // 串口波特率
)(
    input        reset,    // 高有效异步复位
    input        clk,
    input        rx,       // 异步串行输入
    output       tx,       // 串行输出，空闲时为高
    input        tx_start, // 拉高一个周期，请求发送 tx_data
    input  [7:0] tx_data,
    output       tx_busy,  // 1 表示当前帧尚未发送完毕
    output       tx_done,  // 发送完成的单周期脉冲
    output [7:0] rx_data,  // 最近接收的完整字节
    output       rx_ready  // 接收完成的单周期脉冲
);

    // 发送与接收相互独立，可以同时工作（全双工）。
    UARTTx #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) uart_tx1 (
        .reset (reset),
        .clk   (clk),
        .start (tx_start),
        .data  (tx_data),
        .tx    (tx),
        .busy  (tx_busy),
        .done  (tx_done)
    );

    UARTRx #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) uart_rx1 (
        .reset (reset),
        .clk   (clk),
        .rx    (rx),
        .data  (rx_data),
        .ready (rx_ready)
    );

endmodule

// ============================================================================
// UART 发送状态机
//
// start 只在空闲态采样。采样后锁存 data，依次输出 START、DATA[0:7]、
// STOP，每一位恰好保持 CLKS_PER_BIT 个系统时钟周期。
// ============================================================================
module UARTTx #(
    parameter CLOCK_FREQ = 100000000,
    parameter BAUD_RATE  = 9600
)(
    input        reset,
    input        clk,
    input        start,
    input  [7:0] data,
    output reg   tx,
    output reg   busy,
    output reg   done
);

    // 整数分频得到每个串口位包含的系统时钟数。
    // 100 MHz / 9600 ≈ 10416，截断带来的误差远小于 UART 容许范围。
    localparam integer CLKS_PER_BIT = CLOCK_FREQ / BAUD_RATE;

    // 四个状态分别对应线路空闲、起始位、8 个数据位和停止位。
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count; // 当前串口位已经保持的系统时钟数
    reg [2:0]  bit_index; // 当前发送 data_reg[bit_index]
    reg [7:0]  data_reg;  // 启动时锁存，发送过程中不受输入变化影响

    initial begin
        // 给仿真和 FPGA 上电初始化一个确定的 UART 空闲状态。
        state     = S_IDLE;
        clk_count = 32'd0;
        bit_index = 3'd0;
        data_reg  = 8'd0;
        tx        = 1'b1;
        busy      = 1'b0;
        done      = 1'b0;
    end

    always @(posedge reset or posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
            data_reg  <= 8'd0;
            tx        <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b0;
        end
        else begin
            // done 默认每拍清零，仅在 STOP 完成时拉高一个周期。
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    // 线路空闲为高，busy=0；start 有效时立即输出起始位。
                    tx        <= 1'b1;
                    busy      <= 1'b0;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (start) begin
                        data_reg <= data;
                        busy     <= 1'b1;
                        tx       <= 1'b0;
                        state    <= S_START;
                    end
                end

                S_START: begin
                    // 起始位保持一个完整位周期。
                    busy <= 1'b1;
                    tx   <= 1'b0;
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        state     <= S_DATA;
                        tx        <= data_reg[0];
                    end
                    else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                S_DATA: begin
                    // 数据低位先发；每满一个位周期切换到下一位。
                    busy <= 1'b1;
                    tx   <= data_reg[bit_index];
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= S_STOP;
                            tx        <= 1'b1;
                        end
                        else begin
                            bit_index <= bit_index + 3'd1;
                            tx        <= data_reg[bit_index + 3'd1];
                        end
                    end
                    else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                S_STOP: begin
                    // 停止位保持高电平。结束时给出 done 脉冲并回到空闲。
                    busy <= 1'b1;
                    tx   <= 1'b1;
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        busy      <= 1'b0;
                        done      <= 1'b1;
                        state     <= S_IDLE;
                    end
                    else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                default: begin
                    // 非法状态自恢复到线路空闲状态。
                    state <= S_IDLE;
                    tx    <= 1'b1;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule

// ============================================================================
// UART 接收状态机
//
// rx 来自芯片外部，与 clk 异步，因此先经过两级触发器同步。检测到下降沿
// 后等待半个位周期，在起始位中心再次确认低电平；随后每隔一个位周期
// 在各数据位中心采样，从而提高对边沿抖动和相位偏差的容忍度。
// ============================================================================
module UARTRx #(
    parameter CLOCK_FREQ = 100000000,
    parameter BAUD_RATE  = 9600
)(
    input        reset,
    input        clk,
    input        rx,
    output reg [7:0] data,  // 最近成功接收的字节
    output reg       ready  // 新字节到达的单周期脉冲
);

    // 一个完整位周期和半个位周期对应的系统时钟数。
    localparam integer CLKS_PER_BIT      = CLOCK_FREQ / BAUD_RATE;
    localparam integer HALF_CLKS_PER_BIT = CLKS_PER_BIT / 2;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count; // 距离下一采样点的计数
    reg [2:0]  bit_index; // 下一次写入 data_reg 的位编号
    reg [7:0]  data_reg;  // 正在接收的字节
    reg        rx_meta;   // 第一级同步器，允许亚稳态在此级消退
    reg        rx_sync;   // 第二级同步器，状态机只读取该稳定信号

    initial begin
        state     = S_IDLE;
        clk_count = 32'd0;
        bit_index = 3'd0;
        data_reg  = 8'd0;
        data      = 8'd0;
        ready     = 1'b0;
        rx_meta   = 1'b1;
        rx_sync   = 1'b1;
    end

    always @(posedge reset or posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
            data_reg  <= 8'd0;
            data      <= 8'd0;
            ready     <= 1'b0;
            rx_meta   <= 1'b1;
            rx_sync   <= 1'b1;
        end
        else begin
            // 两级同步降低异步 rx 直接进入同步逻辑造成亚稳态的风险。
            rx_meta <= rx;
            rx_sync <= rx_meta;
            // ready 与发送端 done 一样，只维持一个时钟周期。
            ready   <= 1'b0;

            case (state)
                S_IDLE: begin
                    // UART 空闲为高；观察到低电平后认为可能出现起始位。
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync)
                        state <= S_START;
                end

                S_START: begin
                    // 在半个位周期处复核：仍为低才是真起始位，否则当作毛刺。
                    if (clk_count == HALF_CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        if (!rx_sync)
                            state <= S_DATA;
                        else
                            state <= S_IDLE;
                    end
                    else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                S_DATA: begin
                    // 此时采样点落在每个数据位中心，按 LSB-first 写入。
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count           <= 32'd0;
                        data_reg[bit_index] <= rx_sync;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= S_STOP;
                        end
                        else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end
                    else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                S_STOP: begin
                    // 等待停止位周期结束，再一次性发布 data 和 ready。
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        data      <= data_reg;
                        ready     <= 1'b1;
                        state     <= S_IDLE;
                    end
                    else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                default: begin
                    // 非法状态回到空闲，等待下一帧。
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
