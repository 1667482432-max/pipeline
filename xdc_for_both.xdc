# ============================================================================
# FPGA 引脚与时序约束
#
# PACKAGE_PIN 把 top.v 的逻辑端口绑定到芯片封装引脚；IOSTANDARD 指定
# 3.3 V LVCMOS 电气标准。若更换开发板，必须按新板卡原理图修改引脚号。
# ============================================================================

# 系统时钟：R4 引脚，周期 10 ns，即 100 MHz。
set_property PACKAGE_PIN R4 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk [get_ports clk]

# 高有效复位输入。
set_property PACKAGE_PIN J22 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

# digi[7:0]：显示接口的低 8 位。
set_property PACKAGE_PIN N2 [get_ports {digi[0]}]
set_property PACKAGE_PIN P5 [get_ports {digi[1]}]
set_property PACKAGE_PIN V5 [get_ports {digi[2]}]
set_property PACKAGE_PIN U5 [get_ports {digi[3]}]
set_property PACKAGE_PIN T5 [get_ports {digi[4]}]
set_property PACKAGE_PIN P1 [get_ports {digi[5]}]
set_property PACKAGE_PIN W4 [get_ports {digi[6]}]
set_property PACKAGE_PIN V3 [get_ports {digi[7]}]

# digi[11:8]：显示接口的高 4 位。
set_property PACKAGE_PIN Y3 [get_ports {digi[8]}]
set_property PACKAGE_PIN R1 [get_ports {digi[9]}]
set_property PACKAGE_PIN P2 [get_ports {digi[10]}]
set_property PACKAGE_PIN M2 [get_ports {digi[11]}]

set_property IOSTANDARD LVCMOS33 [get_ports {digi[*]}]

# UART 接收输入，对应 top.v 的 uart_rx。
set_property PACKAGE_PIN B20 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

# UART 发送输出，对应 top.v 的 uart_tx。
set_property PACKAGE_PIN A20 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
