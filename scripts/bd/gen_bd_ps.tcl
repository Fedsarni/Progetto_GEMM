# Author: Federica
# Description:
#   Creates the block design for the GEMM PS+PL project (Pynq-Z1).
#
#   Same architecture as the PL-only version (gen_bd_hw.tcl), with ONE
#   difference: the JTAG-to-AXI Master is replaced by the ZYNQ7 Processing
#   System's own M_AXI_GP0 -- the ARM Cortex-A9 (PS) now drives S_AXI
#   directly via software, instead of a host PC over JTAG.
#
#   Everything downstream (crossbar, BRAM A/B/C, gemm_top_0's S_AXI/M_AXI)
#   is untouched -- same address map logic, same register map
#   (axi4lite_ctrl_regs.vhd: CTRL/STATUS/BASE_ADDR_A/B/C).
#
#   Clock: FCLK_CLK0 from the PS, set to 50MHz -- same frequency validated
#   on the PL-only board (100MHz failed timing there; no reason to expect
#   a different critical path here, so starting directly at 50MHz).
#
#   UPDATE (Fase B adaptation): BRAM depth corrected to match the current
#   shared package gemm_axi_ip_components_pkg.vhd (uniform 1024-word/4KB
#   windows for A/B/C), which superseded the hand-sized 16/16/64 depths
#   this script originally used. Everything else (topology, protocol
#   converter, address map) verified still consistent and left unchanged.

set prj_name [current_project]
set bd_name $prj_name
create_bd_design $bd_name

######################
# Import RTL modules #
######################

create_bd_cell -type module -reference gemm_top gemm_top_0

# gemm_top is an RTL module reference (not a packaged IP): force FREQ_HZ
# directly on its AXI interfaces, matching the PS clock below. Without
# this, Vivado can't propagate the clock frequency automatically (lesson
# learned on the PL-only board: same fix as gen_bd_hw.tcl).
set_property CONFIG.FREQ_HZ 50000000 [get_bd_intf_pins gemm_top_0/m_axi]
set_property CONFIG.FREQ_HZ 50000000 [get_bd_intf_pins gemm_top_0/s_axi]

############################
# Zynq Processing System   #
############################

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

# Apply the Pynq-Z1 board preset (DDR/FIXED_IO config from the board file --
# same "Run Block Automation" step used for the hello-world project) and
# make DDR/FIXED_IO external.
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
              Master "Disable" Slave "Disable"} \
    [get_bd_cells processing_system7_0]

set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
] [get_bd_cells processing_system7_0]

# Processor System Reset: generates a clean, synchronized peripheral_aresetn
# for the PL side from the PS's FCLK_RESET0_N -- Xilinx's recommended way
# to reset AXI peripherals driven by the PS (see SOC0 slide: "Use
# PS-provided clocks and resets for the PL design").
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]

############################
# Import and configure IPs #
############################

# AXI crossbar: 2 masters (PS's M_AXI_GP0 + gemm_top_0's own M_AXI) -> 4
# slaves (BRAM A/B/C, gemm_top_0's S_AXI ctrl regs). Same topology as
# PL-only; addresses are assigned automatically below (PS GP0 has a fixed
# valid address range, unlike jtag_axi's free-form space).
# AXI Protocol Converter: the Zynq-7000 PS's M_AXI_GP0 is natively AXI3,
# not AXI4/AXI4LITE -- incompatible with the AXI4LITE crossbar without
# translation. Same category of issue as jtag_axi's default AXI4 protocol
# on the PL-only board, different component.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_protocol_conv_0
set_property -dict [list \
  CONFIG.SI_PROTOCOL {AXI3} \
  CONFIG.MI_PROTOCOL {AXI4LITE} \
] [get_bd_cells axi_protocol_conv_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_crossbar:2.1 axi_crossbar_0
set_property -dict [list \
  CONFIG.NUM_SI {2} \
  CONFIG.NUM_MI {4} \
  CONFIG.PROTOCOL {AXI4LITE} \
] [get_bd_cells axi_crossbar_0]

# BRAM A/B/C: sizing updated to match the current shared package
# (gemm_axi_ip_components_pkg.vhd: BRAM_x_ADDR_WIDTH = 10 for all three,
# i.e. 1024 words / 4KB AXI window each -- uniform, not hand-sized to the
# 8x8 matrices as in the original version of this script).
array set bram_depth {a 1024 b 1024 c 1024}
array set bram_width {a 32 b 32 c 32}

foreach mat {a b c} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 bram_$mat
    set_property -dict [list \
        CONFIG.Memory_Type {Single_Port_RAM} \
        CONFIG.Interface_Type {Native} \
        CONFIG.Write_Width_A $bram_width($mat) \
        CONFIG.Read_Width_A  $bram_width($mat) \
        CONFIG.Write_Depth_A $bram_depth($mat) \
    ] [get_bd_cells bram_$mat]

    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_to_bram_$mat
    set_property -dict [list \
      CONFIG.PROTOCOL {AXI4LITE} \
      CONFIG.SINGLE_PORT_BRAM {1} \
      CONFIG.DATA_WIDTH $bram_width($mat) \
    ] [get_bd_cells axi_to_bram_$mat]

    connect_bd_intf_net [get_bd_intf_pins axi_to_bram_$mat/BRAM_PORTA] \
                         [get_bd_intf_pins bram_$mat/BRAM_PORTA]
}

###############
# Connections #
###############

foreach cell {axi_crossbar_0 axi_to_bram_a axi_to_bram_b axi_to_bram_c axi_protocol_conv_0} {
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins $cell/*aclk*] \
        -quiet
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins $cell/*aresetn*] \
        -quiet
}
connect_bd_net [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] [get_bd_pins processing_system7_0/FCLK_CLK0]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins gemm_top_0/clk_i]
# NOTE: gemm_top's reset_i is ACTIVE-HIGH (verified in axi4lite_ctrl_regs.vhd:
# "if reset_i = '1' then ... axi_awready <= '0' ..."), while
# proc_sys_reset_0/peripheral_aresetn is ACTIVE-LOW (Xilinx standard: '1' =
# running, '0' = in reset). Connecting them directly holds gemm_top in
# permanent reset during normal operation -- its S_AXI slave never asserts
# awready/arready, and any AXI transaction to it hangs the bus. Fix: invert.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 reset_inverter_0
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells reset_inverter_0]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins reset_inverter_0/Op1]
connect_bd_net [get_bd_pins reset_inverter_0/Res] [get_bd_pins gemm_top_0/reset_i]

# PS's M_AXI_GP0 -> protocol converter (AXI3->AXI4LITE) -> crossbar (S00)
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                     [get_bd_intf_pins axi_protocol_conv_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_protocol_conv_0/M_AXI] \
                     [get_bd_intf_pins axi_crossbar_0/S00_AXI]

# gemm_top_0's own M_AXI -> crossbar (S01)
connect_bd_intf_net [get_bd_intf_pins gemm_top_0/m_axi] \
                     [get_bd_intf_pins axi_crossbar_0/S01_AXI]

# Crossbar -> BRAM A/B/C + gemm_top_0's own S_AXI ctrl regs
connect_bd_intf_net [get_bd_intf_pins axi_crossbar_0/M00_AXI] [get_bd_intf_pins axi_to_bram_a/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_crossbar_0/M01_AXI] [get_bd_intf_pins axi_to_bram_b/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_crossbar_0/M02_AXI] [get_bd_intf_pins axi_to_bram_c/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_crossbar_0/M03_AXI] [get_bd_intf_pins gemm_top_0/s_axi]

##############################
# Address map (auto-assign)  #
##############################

# Unlike jtag_axi (free address space), the PS's M_AXI_GP0 has a fixed
# valid range (0x40000000-0xBFFFFFFF for general-purpose slaves). Let
# Vivado pick valid offsets automatically instead of forcing the same
# 0x0000/0x1000/... used in PL-only -- the actual addresses are printed at
# the end of this script and MUST be copied into the C application
# (gemm_ps_app.c) before building it in Vitis.

set ps_space [get_bd_addr_spaces -of_objects [get_bd_cells processing_system7_0]]
set gemm_space [lsearch -inline -glob [get_bd_addr_spaces -of_objects [get_bd_cells gemm_top_0]] "*m_axi*"]

# Force explicit, matching offsets on BOTH address spaces that point at the
# same physical BRAMs (PS's M_AXI_GP0 space and gemm_top_0's own m_axi
# space) -- letting them auto-assign independently gave two different,
# "disjoint" mappings for the same memory and made validate_bd_design fail
# with "Found more than one disjointed assignments". M_AXI_GP0's valid
# range starts at 0x4000_0000, so offsets are shifted there but otherwise
# follow the same 0x0000/0x1000/0x2000/0x3000 pattern used in PL-only.

assign_bd_address -target_address_space $ps_space [get_bd_addr_segs axi_to_bram_a/S_AXI/Mem0] -force
set_property offset 0x40000000 [get_bd_addr_segs "${ps_space}/SEG_axi_to_bram_a_Mem0"]
set_property range 4K          [get_bd_addr_segs "${ps_space}/SEG_axi_to_bram_a_Mem0"]

assign_bd_address -target_address_space $ps_space [get_bd_addr_segs axi_to_bram_b/S_AXI/Mem0] -force
set_property offset 0x40001000 [get_bd_addr_segs "${ps_space}/SEG_axi_to_bram_b_Mem0"]
set_property range 4K          [get_bd_addr_segs "${ps_space}/SEG_axi_to_bram_b_Mem0"]

assign_bd_address -target_address_space $ps_space [get_bd_addr_segs axi_to_bram_c/S_AXI/Mem0] -force
set_property offset 0x40002000 [get_bd_addr_segs "${ps_space}/SEG_axi_to_bram_c_Mem0"]
set_property range 4K          [get_bd_addr_segs "${ps_space}/SEG_axi_to_bram_c_Mem0"]

set gemm_reg_seg      [get_bd_addr_segs -of_objects [get_bd_cells gemm_top_0]]
set gemm_reg_seg_name [lindex [split $gemm_reg_seg /] end]

assign_bd_address -target_address_space $ps_space $gemm_reg_seg -force
set_property offset 0x40003000 [get_bd_addr_segs "${ps_space}/SEG_gemm_top_0_${gemm_reg_seg_name}"]
set_property range 4K          [get_bd_addr_segs "${ps_space}/SEG_gemm_top_0_${gemm_reg_seg_name}"]

assign_bd_address -target_address_space $gemm_space [get_bd_addr_segs axi_to_bram_a/S_AXI/Mem0] -force
set_property offset 0x40000000 [get_bd_addr_segs "${gemm_space}/SEG_axi_to_bram_a_Mem0"]
set_property range 4K          [get_bd_addr_segs "${gemm_space}/SEG_axi_to_bram_a_Mem0"]
assign_bd_address -target_address_space $gemm_space [get_bd_addr_segs axi_to_bram_b/S_AXI/Mem0] -force
set_property offset 0x40001000 [get_bd_addr_segs "${gemm_space}/SEG_axi_to_bram_b_Mem0"]
set_property range 4K          [get_bd_addr_segs "${gemm_space}/SEG_axi_to_bram_b_Mem0"]
assign_bd_address -target_address_space $gemm_space [get_bd_addr_segs axi_to_bram_c/S_AXI/Mem0] -force
set_property offset 0x40002000 [get_bd_addr_segs "${gemm_space}/SEG_axi_to_bram_c_Mem0"]
set_property range 4K          [get_bd_addr_segs "${gemm_space}/SEG_axi_to_bram_c_Mem0"]

validate_bd_design
save_bd_design

# Print the actual assigned addresses on the PS side -- these are the ones
# to copy into gemm_ps_app.c (BRAM_A_BASE / BRAM_B_BASE / BRAM_C_BASE /
# GEMM_CTRL_BASE).
# Address map is now fixed (forced above, not auto-assigned):
#   BRAM A            0x40000000
#   BRAM B            0x40001000
#   BRAM C            0x40002000
#   gemm_top_0 S_AXI  0x40003000  (CTRL=+0x00, STATUS=+0x04, BASE_A=+0x08, BASE_B=+0x0C, BASE_C=+0x10)
puts "\n\[REPORT\] PS-side address map (fixed, already in gemm_ps_app.c):"
puts "\[REPORT\]   BRAM A = 0x40000000, BRAM B = 0x40001000, BRAM C = 0x40002000"
puts "\[REPORT\]   gemm_top_0 S_AXI (CTRL/STATUS/BASE_ADDR_*) = 0x40003000"

set_property target_language VHDL [current_project]
set prj_dir [get_property directory [current_project]]

make_wrapper -files [get_files $bd_name.bd] -top
add_files -norecurse [list "$prj_dir/$prj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.vhd"]
update_compile_order -fileset sources_1
set_property top ${bd_name}_wrapper [current_fileset]
