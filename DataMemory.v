module DataMemory(
    input  reset,
    input  clk,
    input  MemRead,
    input  MemWrite,
    input  [31:0] Address,
    input  [31:0] Write_data,
    output [31:0] Read_data,
    output [11:0] digi,
    input  uart_rx,
    output uart_tx
);

    parameter RAM_SIZE      = 1024;
    parameter RAM_SIZE_BIT  = 10;

    reg [31:0] RAM_data [0:RAM_SIZE - 1];

    reg [11:0] digi_reg;
    assign digi = digi_reg;

    localparam DIGI_ADDR     = 32'h4000_0010;
    localparam UART_TXD_ADDR = 32'h4000_0018;
    localparam UART_RXD_ADDR = 32'h4000_001c;
    localparam UART_CON_ADDR = 32'h4000_0020;

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

    wire [RAM_SIZE_BIT-1:0] ram_word_addr;
    assign ram_word_addr = Address[RAM_SIZE_BIT + 1 : 2];

    wire ram_addr_in_range;
    assign ram_addr_in_range = is_ram_addr && (Address[31:2] < RAM_SIZE);

    wire       uart_tx_busy;
    wire       uart_tx_done;
    wire [7:0] uart_rx_data;
    wire       uart_rx_ready;

    reg uart_tx_done_status;
    reg uart_rx_ready_status;

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
        .reset (1'b0),
        .clk   (clk),
        .rx    (uart_rx),
        .data  (uart_rx_data),
        .ready (uart_rx_ready)
    );

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
    reg reset_d;
    reg [RAM_SIZE_BIT:0] loader_word_addr;
    reg [31:0] loader_value;
    reg loader_negative;
    reg loader_in_token;
    reg loader_has_digit;

    wire loader_is_digit;
    wire loader_is_minus;
    wire loader_is_plus;
    wire [31:0] loader_digit_value;
    wire [31:0] loader_accum_next;
    wire [31:0] loader_store_value;

    assign loader_is_digit = (uart_rx_data >= 8'h30) && (uart_rx_data <= 8'h39);
    assign loader_is_minus = (uart_rx_data == 8'h2d);
    assign loader_is_plus  = (uart_rx_data == 8'h2b);
    assign loader_digit_value = {28'b0, uart_rx_data - 8'h30};
    assign loader_accum_next = (loader_value << 3) + (loader_value << 1) + loader_digit_value;
    assign loader_store_value = loader_negative ? (~loader_value + 32'd1) : loader_value;

    initial begin
        for (i = 0; i < RAM_SIZE; i = i + 1)
            RAM_data[i] = 32'h00000000;
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

    always @(posedge clk) begin
        reset_d <= reset;

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
        else if (reset) begin
            if (uart_rx_ready && (loader_word_addr < RAM_SIZE)) begin
                if (loader_is_digit) begin
                    loader_value <= loader_in_token ? loader_accum_next : loader_digit_value;
                    loader_in_token <= 1'b1;
                    loader_has_digit <= 1'b1;
                end
                else if ((loader_is_minus || loader_is_plus) && !loader_in_token) begin
                    loader_value <= 32'h00000000;
                    loader_negative <= loader_is_minus;
                    loader_in_token <= 1'b1;
                    loader_has_digit <= 1'b0;
                end
                else begin
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
        else if (!reset && reset_d) begin
            if (loader_in_token && loader_has_digit && (loader_word_addr < RAM_SIZE)) begin
                RAM_data[loader_word_addr[RAM_SIZE_BIT-1:0]] <= loader_store_value;
            end
        end
        else begin
            if (uart_tx_done)
                uart_tx_done_status <= 1'b1;

            if (uart_rx_ready)
                uart_rx_ready_status <= 1'b1;

            if (MemRead && is_uart_con_addr) begin
                uart_tx_done_status <= 1'b0;
                uart_rx_ready_status <= 1'b0;
            end

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
