# GEMM Accelerator over AXI4-Lite

This repository contains the hardware design, simulation testbench, and
Hardware-in-the-Loop (HIL) automation scripts for a General Matrix
Multiply (GEMM) hardware accelerator, communicating via **AXI4-Lite**,
targeted for the **Digilent Pynq-Z1** (Xilinx Zynq-7020) board.

The design computes `C = A x B^T` for two 8x8 matrices of signed 8-bit
elements, driven through a small set of AXI4-Lite control registers
(start/done, base addresses of A/B/C).

The project follows a **Three-tier Verification Architecture** (see
`Architecture` below), so the exact same core design (Tier 1) is verified
both in simulation and on real hardware, with the outer layers swapped
depending on the target. Two hardware targets (platforms) are supported
side by side in this same repository: **PL-only** (host on a PC, driving
the design over JTAG) and **PS+PL** (the Zynq's own ARM processor drives
the design in bare-metal C, no external host needed at runtime).

---

## 🛠️ Prerequisites

- **Xilinx Vivado 2025.2** (or newer), with **Vitis** (command-line
  tools, `xsct`) for the PS+PL target
- Digilent Pynq-Z1 board (Zynq-7020, part `xc7z020clg400-1`)
- Micro-USB cable for JTAG programming and AXI communication (PL-only)
  or UART + JTAG programming (PS+PL)
- `arm-none-eabi-gcc` (bundled with the Vitis install) for the PS+PL
  Tier 3 software

---

## 📂 Repository Structure

To keep version control clean and lightweight, the Vivado project
directories (`gemm_*_prj/`, `workspace/`) and generated artifacts
(`*.xsa`) are ignored -- projects are dynamically generated from the Tcl
scripts on every run.

Following the guide's "Three-tier Verification Architecture", the layout
makes the tier structure explicit in the folder names: Tier 1 (the DUT)
is shared and lives on its own, outside any target-specific folder; each
target/platform (simulation, PL-only, PS+PL) has its own `tier2/` and
`tier3/` subfolders.

- **`tier1/`**: `gemm_top.vhd` and its sub-modules (`gemm_controller.vhd`,
  `lsu.vhd`, `dot_product_optimized.vhd`, `axi4lite_ctrl_regs.vhd`,
  `axi_master_engine.vhd`) -- the core design under test, identical and
  never duplicated across every target and platform.
- **`shared/`**: values/components genuinely reused across two or more
  targets, but not part of the DUT itself:
  * `tier2_config.tcl` -- BRAM sizing, crossbar port count, and address
    offsets, read by all three targets' Tier 2 generation scripts.
  * `gemm_axi_ip_components_pkg.vhd` -- shared VHDL component
    declarations (AXI crossbar, BRAM controllers), reused by the
    simulation and PL-only Tier 2 wrappers.
- **`simulation/`**:
  * `tier2/gemm_top_sim_wrapper.vhd`, `tier2/gen_ip_sim.tcl` -- DUT + AXI
    VIP + crossbar + BRAM A/B/C, hand-wired VHDL.
  * `tier3/gemm_axi_vip_tb.sv` -- SystemVerilog testbench, the Tier 3
    stimuli generator for simulation. Shared by both hardware platforms,
    since it only exercises Tier 1.
- **`pl_only/`**:
  * `tier2/gemm_top_pynq_pl_wrapper.vhd`, `tier2/gen_ip_pynq_pl.tcl` --
    DUT + JTAG-to-AXI Master + crossbar + BRAM A/B/C.
  * `tier3/program_and_test_pynq_pl.tcl` -- host-side Tcl script, drives
    the JTAG-to-AXI Master via Vivado Hardware Manager.
- **`ps_pl/`**:
  * `tier2/gen_bd_ps.tcl` -- the block design itself: PS7 + AXI3→
    AXI4-Lite protocol converter + crossbar + BRAMs + `gemm_top`
    (imported as a bare RTL module reference, no VHDL wrapper needed).
  * `tier3/main.c`, `tier3/gemm.c`/`gemm.h`, `tier3/lscript.ld` --
    bare-metal C sources, compiled with `arm-none-eabi-gcc` (no Vitis
    IDE/`app create` involved), and `tier3/program_and_test_ps_pl.ps1`
    -- end-to-end HIL automation: BSP generation, software build, board
    programming, UART result capture.
- **`scripts/`**: top-level build orchestrators (not tier/target-specific
  themselves, they just call into the folders above): `build.tcl`
  (simulation), `build_pynq_pl.tcl` (PL-only), `build_ps_pl.tcl` (PS+PL).
- **`xdc/`**: Physical constraints for the Pynq-Z1 (clock, reset) --
  PL-only only; PS+PL needs no physical pin constraints, all
  communication is internal AXI between PS and PL.
- **`.github/workflows/`**: GitHub Actions CI pipeline definition,
  covering both platforms.

---

## 🏗️ Architecture: Three-tier Verification

Following the internal RTL Coding/Design/Verification guide, every
target/platform shares the same core design but differs in how it's
driven:

1. **Tier 1 -- Design Under Test**: `gemm_top.vhd`. No stimulus IP, no
   knowledge of simulation vs. hardware, nor of PL-only vs. PS+PL --
   just AXI4-Lite ports in and out. Never duplicated, never modified per
   target or platform.
2. **Tier 2 -- Test wrapper / integration layer**: wraps the Tier 1 DUT
   together with the driving IP appropriate for the target:
   - `gemm_top_sim_wrapper.vhd`: DUT + **AXI VIP** (simulation-only,
     driven directly by the testbench).
   - `gemm_top_pynq_pl_wrapper.vhd`: DUT + **JTAG-to-AXI Master** (for
     PL-only hardware, driven by a host-side Tcl script over JTAG), plus
     the PL-only clock/reset workaround needed on Zynq when the
     Processing System is never booted (see comments in the wrapper
     source).
   - PS+PL: a **native Vivado block design** (`gen_bd_ps.tcl`) instead
     of a hand-written VHDL wrapper -- `gemm_top` is imported as a bare
     RTL module reference, alongside the Zynq Processing System (real
     clock/reset, no workaround needed), an AXI3→AXI4-Lite protocol
     converter (the PS's `M_AXI_GP0` speaks AXI3), and the same
     crossbar/BRAM topology as PL-only, built from native Xilinx IP
     cells directly in the block design.
3. **Tier 3 -- Stimuli generation**: drives Tier 2 and checks results
   against a golden model computed independently in the same language as
   the driver:
   - Simulation: `simulation/tier3/gemm_axi_vip_tb.sv` (SystemVerilog,
     drives the AXI VIP directly).
   - PL-only HIL: `pl_only/tier3/program_and_test_pynq_pl.tcl` (Tcl,
     drives the JTAG-to-AXI Master via Vivado Hardware Manager).
   - PS+PL HIL: `ps_pl/tier3/main.c` (bare-metal C, running on the
     Zynq's own ARM Cortex-A9) -- generates stimuli by writing directly
     to memory-mapped AXI addresses (`volatile` pointer stores), starts
     the computation, polls for completion, and checks the result,
     printing progress over UART.

All three Tier 3 drivers run the **same test suite**: a deterministic
baseline case plus targeted corner cases (maximum positive/negative
saturation, alternating-sign checkerboard, sparse single-element) and
several randomized cases. Exhaustive input coverage isn't attempted --
with 128 independent 8-bit inputs (64 elements each in A and B), the
input space is `256^128` combinations, far beyond what's feasible to
exhaust; this follows the guide's "Input Randomization" approach for
non-elementary components.

---

## 🚀 How to Run

Make sure Vivado 2025.2 is on your PATH (or use the full path to
`vivado.bat`/`vivado`), and, for any HIL step, that the Pynq-Z1 is
connected via USB and powered on.

### Simulation

```
vivado -mode batch -source scripts/build.tcl
```

Runs RTL simulation using the AXI VIP golden model (shared by both
platforms, since it only exercises Tier 1). Check the log for
`[TB] OVERALL PASS` / `[TB] OVERALL FAIL`.

### PL-only: Build (synthesis + implementation + bitstream)

```
vivado -mode batch -source scripts/build_pynq_pl.tcl
```

### PL-only: Hardware-in-the-Loop test

```
vivado -mode batch -source pl_only/tier3/program_and_test_pynq_pl.tcl
```

Programs the bitstream onto the Pynq-Z1 and runs the full test suite over
JTAG-to-AXI. Check the log for `[TEST] OVERALL PASS` / `[TEST] OVERALL FAIL`.

### PS+PL: Build (bitstream + hardware platform)

```
vivado -mode batch -source scripts/build_ps_pl.tcl
```

Generates the block design, bitstream, and exports `gemm_ps_pl.xsa` for
the BSP/software build step below.

### PS+PL: Hardware-in-the-Loop test

```
powershell -ExecutionPolicy Bypass -File ps_pl/tier3/program_and_test_ps_pl.ps1
```

Generates the BSP from `gemm_ps_pl.xsa` (no Vitis IDE involved),
compiles the Tier 3 software with `arm-none-eabi-gcc`, programs the
board, runs the test suite on the PS, and checks the UART output for
`OVERALL PASS` / `OVERALL FAIL`, exiting with the matching status code.

---

## ⚙️ Continuous Integration

The pipeline (`.github/workflows/gemm-ci.yml`) runs on a **self-hosted
GitHub Actions runner**, installed on a PC with Vivado and the Pynq-Z1
permanently connected, so that simulation and both platforms' HIL tests
can run automatically on every push:

1. **`build`**: synthesizes and implements the PL-only design, generates
   the bitstream, uploads it as an artifact.
2. **`simulate`**: runs the RTL simulation (Tier 3, AXI VIP).
3. **`hil_test`**: downloads the bitstream artifact, programs the board,
   runs the PL-only HIL test suite (Tier 3, JTAG-to-AXI).
4. **`build_ps_pl`**: builds the PS+PL bitstream and hardware platform
   (`.xsa`), uploads both as an artifact.
5. **`hil_test_ps_pl`**: downloads the PS+PL artifacts, generates the
   BSP, builds the Tier 3 software, programs the board, and runs the
   PS+PL HIL test suite over UART.

All error paths explicitly `exit 1` on failure (rather than a bare
`return`), so a failed build, a disconnected board, a mismatched result,
or a hung PS+PL test suite (no `OVERALL PASS`/`FAIL` seen within a
timeout) all show up as a red X in the pipeline instead of a false-green
checkmark.

---

## About

Author: Federica Sarnataro
