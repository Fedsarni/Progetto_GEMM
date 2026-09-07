# Author: Federica
# Description:
#   Create a Vivado project for GEMM - PYNQ-Z1 PL-ONLY TARGET.
#   Performs Synthesis, Implementation and Bitstream Generation.

set PROJECT_NAME gemm_pynq_pl_prj

# Target FPGA Device: Zynq-7000 (Pynq-Z1 board)
set PART xc7z020clg400-1

set SRC_DIR ../src/
set SCRIPTS_DIR ../scripts/
set XDC_DIR ../xdc/
set TOP_LEVEL gemm_top_pynq_pl_wrapper

exec mkdir -p $PROJECT_NAME
cd $PROJECT_NAME

create_project $PROJECT_NAME . -part $PART -force

set project_dir [get_property directory [current_project]]
set report_dir "$project_dir/reports"
exec mkdir -p reports

set src_file_list [ list \
    $SRC_DIR/gemm_axi_ip_components_pkg.vhd \
    $SRC_DIR/gemm_top.vhd \
    $SRC_DIR/gemm_controller.vhd \
    $SRC_DIR/lsu.vhd \
    $SRC_DIR/dot_product_optimized.vhd \
    $SRC_DIR/axi4lite_ctrl_regs.vhd \
    $SRC_DIR/axi_master_engine.vhd \
    $SRC_DIR/gemm_top_pynq_pl_wrapper.vhd \
]
add_files -norecurse -fileset [current_fileset] $src_file_list
set_property FILE_TYPE VHDL [get_files *.vhd]

# Constraints file for Pynq-Z1 (Clock pin H16)
add_files -norecurse -fileset [current_fileset -constrset] [list "$XDC_DIR/gemm_top_pynq.xdc"]

set_property top $TOP_LEVEL [current_fileset]

# Generate PL IP cores
source $SCRIPTS_DIR/ip/gen_ip_pynq_pl.tcl

update_compile_order -fileset sources_1

###############################
# Synthesis & Implementation  #
###############################
puts "\[BUILD\] Starting Synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

puts "\[BUILD\] Starting Implementation & Bitstream Generation..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

puts "\[REPORT\] Bitstream generated successfully at:"
puts "\[REPORT\] $project_dir/$PROJECT_NAME.runs/impl_1/$TOP_LEVEL.bit"
