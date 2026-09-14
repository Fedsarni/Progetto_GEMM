# Author: Federica Sarnataro
# Description:
#   Generates the Xilinx IP (.xci) for Pynq-Z1 PL-Only Target:
#   jtag_axi_0, clk_wiz_0, axi_crossbar_0, axi_bram_ctrl_0/1/2 + blk_mem_gen_0/1/2.
#
# NOTE on verifying IP properties before batch set_property:
#   The exact property names/formats below (esp. MEM_DEPTH on axi_bram_ctrl,
#   and the M<mm>_A<aa>_* address-block key numbering on axi_crossbar) can
#   shift across IP core versions. Before trusting a set_property call on an
#   IP you haven't generated before, create it once and inspect its real
#   property list, e.g.:
#     create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name tmp_check
#     report_property -all [get_ips tmp_check] | grep -i depth
#   then delete tmp_check. This catches silently-wrong keys (set_property on
#   a nonexistent property name fails loudly, but a *renamed-but-similar*
#   property may not).

# Shared BRAM/crossbar sizing (identical to the PS+PL target) -- see
# scripts/bd/tier2_config.tcl. Mechanism here is unchanged: still
# standalone .xci IP cores, no block design.
source [file join [file dirname [info script]] .. .. shared tier2_config.tcl]

proc generate_ip_run {ip_name} {
    set prj_name [current_project]
    set prj_path "[get_property directory [current_project]]"
    set xci_file "$prj_path/$prj_name.srcs/sources_1/ip/$ip_name/$ip_name.xci"
    puts "\[UTILS\] Targeting IP: $ip_name"
    generate_target all [get_files [list $xci_file]]
    create_ip_run [get_files [list $xci_file]]
    catch { config_ip_cache -export [get_ips -all $ip_name] }
    export_ip_user_files -of_objects [get_files [list $xci_file]] -no_script -sync -force -quiet
    launch_runs ${ip_name}_synth_1
}

set_property target_language VHDL [current_project]
array set bram_depth [array get gemm_bram_depth]

########################
# clk_wiz_0 (125MHz -> 50MHz)
########################
# 100MHz failed timing on this Tier 1 design (critical path inside
# dot_product_optimized) -- 50MHz fixes it.
#
# The output port keeps the name clk_100MHz_o (matches clk_wiz_0's port
# declaration in gemm_top_pynq_pl_wrapper.vhd) even though it now actually
# outputs 50MHz -- functionally correct, just a stale/misleading name if
# you go looking at it later.
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_0
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {125.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.CLK_OUT1_PORT {clk_100MHz_o} \
    CONFIG.USE_RESET {false} \
    CONFIG.USE_LOCKED {true} \
] [get_ips clk_wiz_0]
generate_ip_run "clk_wiz_0"

########################
# jtag_axi_0 (AXI Master via JTAG)
########################
create_ip -name jtag_axi -vendor xilinx.com -library ip -version 1.2 -module_name jtag_axi_0
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.M_AXI_DATA_WIDTH {32} \
    CONFIG.M_AXI_ADDR_WIDTH {32} \
] [get_ips jtag_axi_0]
generate_ip_run "jtag_axi_0"

########################
# axi_crossbar_0
########################
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0
set gemm_addr_a    [format {0x%08X} $gemm_addr_offset_a]
set gemm_addr_b    [format {0x%08X} $gemm_addr_offset_b]
set gemm_addr_c    [format {0x%08X} $gemm_addr_offset_c]
set gemm_addr_ctrl [format {0x%08X} $gemm_addr_offset_ctrl]
set_property -dict [list \
    CONFIG.NUM_SI $gemm_crossbar_num_si \
    CONFIG.NUM_MI $gemm_crossbar_num_mi \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.M00_A00_BASE_ADDR $gemm_addr_a \
    CONFIG.M00_A00_ADDR_WIDTH {12} \
    CONFIG.M01_A00_BASE_ADDR $gemm_addr_b \
    CONFIG.M01_A00_ADDR_WIDTH {12} \
    CONFIG.M02_A00_BASE_ADDR $gemm_addr_c \
    CONFIG.M02_A00_ADDR_WIDTH {12} \
    CONFIG.M03_A00_BASE_ADDR $gemm_addr_ctrl \
    CONFIG.M03_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]
generate_ip_run "axi_crossbar_0"

########################################
# axi_bram_ctrl + blk_mem_gen (A / B / C)
########################################
foreach idx {0 1 2} mat {a b c} {
    create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name axi_bram_ctrl_$idx
    set_property -dict [list \
        CONFIG.PROTOCOL {AXI4LITE} \
        CONFIG.DATA_WIDTH {32} \
        CONFIG.SINGLE_PORT_BRAM {1} \
        CONFIG.MEM_DEPTH $bram_depth($mat) \
    ] [get_ips axi_bram_ctrl_$idx]
    generate_ip_run "axi_bram_ctrl_$idx"

    create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name blk_mem_gen_$idx
    set_property -dict [list \
        CONFIG.Memory_Type {Single_Port_RAM} \
        CONFIG.Interface_Type {Native} \
        CONFIG.Write_Width_A 32 \
        CONFIG.Read_Width_A  32 \
        CONFIG.Write_Depth_A $bram_depth($mat) \
        CONFIG.Enable_A {Use_ENA_Pin} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    ] [get_ips blk_mem_gen_$idx]
    generate_ip_run "blk_mem_gen_$idx"
}

# Wait for IP synthesis runs
foreach ip {clk_wiz_0 jtag_axi_0 axi_crossbar_0 \
            axi_bram_ctrl_0 blk_mem_gen_0 \
            axi_bram_ctrl_1 blk_mem_gen_1 \
            axi_bram_ctrl_2 blk_mem_gen_2} {
    wait_on_run ${ip}_synth_1
}

generate_target {synthesis} [get_ips]
puts "\[REPORT\] gen_ip_pynq_pl.tcl: Hardware IPs generated successfully."
