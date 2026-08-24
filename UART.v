module UART #(
    parameter CLOCK_FREQ = 100000000,
    parameter BAUD_RATE  = 9600
)(
    input        reset,
    input        clk,
    input        rx,
    output       tx,
    input        tx_start,
    input  [7:0] tx_data,
    output       tx_busy,
    output       tx_done,
    output [7:0] rx_data,
    output       rx_ready
);

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

    localparam integer CLKS_PER_BIT = CLOCK_FREQ / BAUD_RATE;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_reg;

    initial begin
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
            done <= 1'b0;

            case (state)
                S_IDLE: begin
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
                    state <= S_IDLE;
                    tx    <= 1'b1;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule

module UARTRx #(
    parameter CLOCK_FREQ = 100000000,
    parameter BAUD_RATE  = 9600
)(
    input        reset,
    input        clk,
    input        rx,
    output reg [7:0] data,
    output reg       ready
);

    localparam integer CLKS_PER_BIT      = CLOCK_FREQ / BAUD_RATE;
    localparam integer HALF_CLKS_PER_BIT = CLKS_PER_BIT / 2;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_reg;
    reg        rx_meta;
    reg        rx_sync;

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
            rx_meta <= rx;
            rx_sync <= rx_meta;
            ready   <= 1'b0;

            case (state)
                S_IDLE: begin
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync)
                        state <= S_START;
                end

                S_START: begin
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
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
