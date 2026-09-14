# Author: Federica Sarnataro
# Description:
#   Generates the Xilinx IP (.xci) instantiated by gemm_top_sim_wrapper.vhd:
#   axi_vip_master_0, axi_crossbar_0, axi_bram_ctrl_0/1/2 + blk_mem_gen_0/1/2.
#
#   The IP are Xilinx-generated but wired by hand in VHDL
#   (gemm_top_sim_wrapper.vhd) instead of on the IP Integrator canvas, so
#   the Tier 2 wrapper is a real, reusable, diffable RTL file.
#
#   BRAM sizing, crossbar port count, and address offsets are shared with
#   the PL-only and PS+PL targets via scripts/bd/tier2_config.tcl.

source [file join [file dirname [info script]] .. .. shared tier2_config.tcl]

# Utility function to generate IP runs and artifacts.
proc generate_ip_run {ip_name} {
    set prj_name [current_project]
    set prj_path "[get_property directory [current_project]]"
    set xci_file "$prj_path/$prj_name.srcs/sources_1/ip/$ip_name/$ip_name.xci"

    puts "\[UTILS\] Targeting IP: $ip_name"

    # [list $xci_file] forces Tcl to treat the whole path as ONE list
    # element, even if it contains spaces (e.g. a project folder like
    # "GEMM AXI_Lite Simulazione") -- without it, get_files silently
    # word-splits the path on every space and each fragment fails to
    # match anything ("No sub-design file provided").
    generate_target all [get_files [list $xci_file]]
    create_ip_run [get_files [list $xci_file]]
    catch { config_ip_cache -export [get_ips -all $ip_name] }
    export_ip_user_files -of_objects [get_files [list $xci_file]] -no_script -sync -force -quiet

    launch_runs ${ip_name}_synth_1
}

set_property target_language VHDL [current_project]

# BRAM depth (32-bit words), shared with the other targets.
array set bram_depth [array get gemm_bram_depth]

########################
# axi_vip_master_0     #
########################
create_ip -name axi_vip -vendor xilinx.com -library ip -version 1.1 -module_name axi_vip_master_0
set_property -dict [list \
    CONFIG.INTERFACE_MODE {MASTER} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
] [get_ips axi_vip_master_0]
generate_ip_run "axi_vip_master_0"

########################
# axi_crossbar_0       #
########################
# 2 SI (axi_vip_master_0, gemm_top.m_axi) -> 4 MI (BRAM A/B/C, gemm_top.s_axi)
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
# axi_bram_ctrl_0/1/2 + blk_mem_gen_0/1/2 (A / B / C)
########################################
foreach idx {0 1 2} mat {a b c} {
    create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 \
        -module_name axi_bram_ctrl_$idx
    set_property -dict [list \
        CONFIG.PROTOCOL {AXI4LITE} \
        CONFIG.DATA_WIDTH {32} \
        CONFIG.SINGLE_PORT_BRAM {1} \
        CONFIG.MEM_DEPTH $bram_depth($mat) \
    ] [get_ips axi_bram_ctrl_$idx]
    generate_ip_run "axi_bram_ctrl_$idx"

    create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
        -module_name blk_mem_gen_$idx
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

# Wait on all runs
foreach ip {axi_vip_master_0 axi_crossbar_0 \
            axi_bram_ctrl_0 blk_mem_gen_0 \
            axi_bram_ctrl_1 blk_mem_gen_1 \
            axi_bram_ctrl_2 blk_mem_gen_2} {
    wait_on_run ${ip}_synth_1
}

# Also generate simulation targets explicitly (incl. the SV package
# axi_vip_master_0_pkg.sv used by the tb's master_agent type)
generate_target {simulation synthesis} [get_ips]

puts "\[REPORT\] gen_ip_sim.tcl: IP generated standalone for gemm_top_sim_wrapper (no block design)."
