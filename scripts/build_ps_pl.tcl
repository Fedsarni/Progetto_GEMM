# Author: Federica Sarnataro
# scripts/build_ps_pl.tcl
#
# Builds the GEMM PS+PL target end to end: project creation, block design
# (gemm_top imported as a plain RTL module reference -- no IP packaging
# needed), synthesis, implementation, bitstream, and hardware export
# (.xsa) for Vitis/xsct.
#
# Run from the project root:
#   vivado -mode batch -source scripts/build_ps_pl.tcl

set proj_dir   [pwd]
set part       xc7z020clg400-1
set board_part {www.digilentinc.com:pynq-z1:part0:1.0}

set gemm_srcs [list \
    src/gemm_top.vhd \
    src/gemm_controller.vhd \
    src/lsu.vhd \
    src/dot_product_optimized.vhd \
    src/axi4lite_ctrl_regs.vhd \
    src/axi_master_engine.vhd \
]

#############################################
# 1. Project                                #
#############################################

create_project gemm_ps_pl $proj_dir/vivado_prj -part $part -force
set_property board_part $board_part [current_project]
set_property target_language VHDL [current_project]

add_files -norecurse $gemm_srcs
update_compile_order -fileset sources_1

#############################################
# 2. Block design                           #
#    (gemm_top imported as RTL module ref,  #
#    crossbar/BRAM as native BD IP, PS7 +   #
#    AXI3->AXI4LITE protocol converter --   #
#    see scripts/hw/bd/gen_bd_ps.tcl)       #
#############################################

source scripts/bd/gen_bd_ps.tcl

#############################################
# 3. Synthesis, implementation, bitstream   #
#############################################

update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "ERROR: synth_1 did not complete successfully, aborting build."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "ERROR: impl_1 did not complete successfully, aborting build."
}

#############################################
# 4. Export hardware for Vitis/xsct         #
#############################################

write_hw_platform -fixed -include_bit -force $proj_dir/gemm_ps_pl.xsa

puts "Build complete: $proj_dir/gemm_ps_pl.xsa"
puts "PS-side address map (see gen_bd_ps.tcl REPORT lines above for confirmation):"
puts "  BRAM A = 0x40000000, BRAM B = 0x40001000, BRAM C = 0x40002000"
puts "  gemm_top_0 S_AXI (CTRL/STATUS/BASE_ADDR_*) = 0x40003000"
