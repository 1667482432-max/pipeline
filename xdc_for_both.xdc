set_property PACKAGE_PIN R4 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk [get_ports clk]

set_property PACKAGE_PIN J22 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

set_property PACKAGE_PIN N2 [get_ports {digi[0]}]
set_property PACKAGE_PIN P5 [get_ports {digi[1]}]
set_property PACKAGE_PIN V5 [get_ports {digi[2]}]
set_property PACKAGE_PIN U5 [get_ports {digi[3]}]
set_property PACKAGE_PIN T5 [get_ports {digi[4]}]
set_property PACKAGE_PIN P1 [get_ports {digi[5]}]
set_property PACKAGE_PIN W4 [get_ports {digi[6]}]
set_property PACKAGE_PIN V3 [get_ports {digi[7]}]

set_property PACKAGE_PIN Y3 [get_ports {digi[8]}]
set_property PACKAGE_PIN R1 [get_ports {digi[9]}]
set_property PACKAGE_PIN P2 [get_ports {digi[10]}]
set_property PACKAGE_PIN M2 [get_ports {digi[11]}]

set_property IOSTANDARD LVCMOS33 [get_ports {digi[*]}]

set_property PACKAGE_PIN B20 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

set_property PACKAGE_PIN A20 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
