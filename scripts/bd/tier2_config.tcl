# Author: Federica Sarnataro
# scripts/bd/tier2_config.tcl
#
# Shared configuration values for the GEMM Tier 2 crossbar/BRAM topology,
# used by both targets (PL-only and PS+PL). Only the values that are
# genuinely identical between the two are here -- this file does not
# change how either target builds its hardware (PL-only keeps generating
# standalone .xci IP cores wired in VHDL; PS+PL keeps using a native block
# design), it only removes the duplicated numbers between the two scripts.

array set gemm_bram_depth {a 1024 b 1024 c 1024}
array set gemm_bram_width {a 32 b 32 c 32}

set gemm_crossbar_num_si 2
set gemm_crossbar_num_mi 4

# Address map offsets, relative to whatever base each target uses
# (PL-only: 0x00000000, jtag_axi's free address space. PS+PL: 0x40000000,
# the fixed valid range for the PS's M_AXI_GP0).
set gemm_addr_offset_a    0x0000
set gemm_addr_offset_b    0x1000
set gemm_addr_offset_c    0x2000
set gemm_addr_offset_ctrl 0x3000
