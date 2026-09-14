# Author: Federica Sarnataro
# Description:
#   Generates the Xilinx IP (.xci) instantiated by gemm_top_sim_wrapper.vhd:
#   axi_vip_master_0, axi_crossbar_0, axi_bram_ctrl_0/1/2 + blk_mem_gen_0/1/2.
#
#   The IP are Xilinx-generated but wired by hand in VHDL
#   (gemm_top_sim_wrapper.vhd) instead of on the IP Integrator canvas, so
#   the Tier 2 wrapper is a real, reusable, diffable RTL file.
#
#   Address map (must match gemm_axi_vip_tb.sv and gemm_top_sim_wrapper.vhd):
#     M00 0x0000_0000 - 0x0000_0FFF  BRAM A
#     M01 0x0000_1000 - 0x0000_1FFF  BRAM B
#     M02 0x0000_2000 - 0x0000_2FFF  BRAM C
#     M03 0x0000_3000 - 0x0000_3FFF  gemm_top S_AXI (ctrl registers)

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

# BRAM depth (32-bit words). Uniform 1024 words / 4 KiB for A, B and C:
# axi_bram_ctrl's own MEM_DEPTH is clamped to a minimum of 1024 anyway
# (see below), so there's no benefit to keeping blk_mem_gen artificially
# smaller (16/64) -- and that odd small-depth + byte-write-enable
# combination is a plausible trigger for the XSim kernel crash seen in
# blk_mem_gen's behavioural model generator. 1024 words is a completely
# standard, well-tested BRAM configuration.
array set bram_depth {a 1024 b 1024 c 1024}

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
set_property -dict [list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {4} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.M00_A00_BASE_ADDR {0x00000000} \
    CONFIG.M00_A00_ADDR_WIDTH {12} \
    CONFIG.M01_A00_BASE_ADDR {0x00001000} \
    CONFIG.M01_A00_ADDR_WIDTH {12} \
    CONFIG.M02_A00_BASE_ADDR {0x00002000} \
    CONFIG.M02_A00_ADDR_WIDTH {12} \
    CONFIG.M03_A00_BASE_ADDR {0x00003000} \
    CONFIG.M03_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]
generate_ip_run "axi_crossbar_0"

########################################
# axi_bram_ctrl_0/1/2 + blk_mem_gen_0/1/2 (A / B / C)
########################################
# Same BRAM controller/memory pair used for the PL-only target -- only
# how they're generated changes (create_ip here, not create_bd_cell).
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
