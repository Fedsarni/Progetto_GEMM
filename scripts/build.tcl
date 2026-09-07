# Author: Federica
# Description:
#   Create a Vivado project for GEMM - SIMULATION VERSION (AXI VIP).
#   No bitstream: RTL elaboration and behavioural simulation only.
#   The AXI-lite master is an AXI VIP, standing in for the PS until
#   a real board is available.

################
## Parameters ##
################

# set creates a variable
set PROJECT_NAME gemm_sim_vip_prj
# No actual card is involved now.
set PART xc7a100tcsg324-1

# Paths relative to the project folder
set SRC_DIR ../src/
set SCRIPTS_DIR ../scripts/
set TB_DIR ../tb/

set TOP_LEVEL gemm_top

##########################
## Vivado project setup  #
##########################

exec mkdir -p $PROJECT_NAME
cd $PROJECT_NAME

#overwrite if it already exists
create_project $PROJECT_NAME . -part $PART -force

set project_dir [get_property directory [current_project]]
#create a subfolder inside
set report_dir "$project_dir/reports"
exec mkdir -p reports

# Do not include sram.vhd anymore, it will be replaced by blk_mem_gen (IP).
# gemm_top_sim_wrapper.vhd is the Tier 2 test wrapper (DUT + AXI VIP +
# crossbar + BRAM A/B/C), hand-written RTL -- replaces the old block
# design / make_wrapper output.
set src_file_list [ list \
    $SRC_DIR/gemm_top.vhd \
    $SRC_DIR/gemm_controller.vhd \
    $SRC_DIR/lsu.vhd \
    $SRC_DIR/dot_product_optimized.vhd \
    $SRC_DIR/axi4lite_ctrl_regs.vhd \
    $SRC_DIR/axi_master_engine.vhd \
    $SRC_DIR/gemm_top_sim_wrapper.vhd \
]

# adds those 4 files to current_fileset(the default "sources" file group)
#norecurse = not search recursively through subfolders
add_files -norecurse -fileset [current_fileset] $src_file_list
set_property FILE_TYPE VHDL [get_files *.vhd]
set_property top $TOP_LEVEL [current_fileset]

# Generate the Xilinx IP used by gemm_top_sim_wrapper.vhd (AXI VIP,
# crossbar, BRAM A/B/C) as standalone .xci -- no block design, no
# make_wrapper: gemm_top_sim_wrapper.vhd (added to src_file_list above)
# is already a plain, compilable top-level entity.
source $SCRIPTS_DIR/ip/gen_ip_sim.tcl

#recalculates the correct order in which to compile the files
update_compile_order -fileset sources_1

###############
# Elaboration #
###############

#quick syntax/style check ,the result should be written to the report file.
set lint_filename "$report_dir/lint.log"
synth_design -lint -file [list $lint_filename]

synth_design -rtl -name rtl_1

#################
# Simulation    #
#################

# Add the AXI VIP testbench to the simulation fileset
add_files -fileset sim_1 -norecurse [list "$TB_DIR/gemm_axi_vip_tb.sv"]
set_property FILE_TYPE {SystemVerilog} [get_files gemm_axi_vip_tb.sv]
set_property top gemm_axi_vip_tb [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
run all

puts "\[REPORT\] GEMM simulation project (AXI VIP) created in: $project_dir"
puts "\[REPORT\] Testbench added and simulation launched - check the results above."
