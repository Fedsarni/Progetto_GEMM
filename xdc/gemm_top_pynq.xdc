# gemm_top_pynq.xdc
# Constraints for the GEMM PL-only project on the Pynq-Z1 (Zynq-7020,
# xc7z020clg400-1).
#
# gemm_top_pynq_pl_wrapper has exactly ONE physical port: the board's
# 125 MHz oscillator, feeding clk_wiz_0 (which derives the 100 MHz PL clock
# and, via its `locked` output, the dirty reset workaround -- see the
# wrapper's file header). No reset button, no LEDs: this is a PL-only
# design driven entirely over JTAG-to-AXI Master from Hardware Manager,
# not from board switches/buttons.
#
# Pin/period taken as-is from the board's master XDC (pynqZ1-Z2.xdc):
#   PACKAGE_PIN H16, IO_L13P_T2_MRCC_35, Sch=sysclk

## Clock signal: 125 MHz onboard oscillator
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { sysclk_125MHz_i }];
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk_125MHz_i }];
