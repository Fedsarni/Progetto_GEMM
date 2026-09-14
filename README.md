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

- **`src/`**: VHDL sources.
  * `gemm_top.vhd` and its sub-modules (`gemm_controller.vhd`, `lsu.vhd`,
    `dot_product_optimized.vhd`, `axi4lite_ctrl_regs.vhd`,
    `axi_master_engine.vhd`) -- **Tier 1**, the core design under test,
    identical across every target and platform.
  * `gemm_axi_ip_components_pkg.vhd` -- shared VHDL component
    declarations (AXI crossbar, BRAM controllers) reused by the
    simulation and PL-only Tier 2 wrappers.
  * `gemm_top_sim_wrapper.vhd`, `gemm_top_pynq_pl_wrapper.vhd` -- **Tier
    2** for simulation and PL-only (see `Architecture` below). The PS+PL
    target does not need a VHDL wrapper file at all: `gemm_top` is
    imported directly as an RTL module reference inside a native Vivado
    block design (see `scripts/bd/gen_bd_ps.tcl`).
- **`sim/`** (or `tb/`): SystemVerilog testbench (`gemm_axi_vip_tb.sv`),
  using the AXI Verification IP (VIP) as the golden-model driver --
  **Tier 3** for simulation. Shared by both platforms, since it only
  exercises Tier 1.
- **`sw/`**: bare-metal C sources for the PS+PL target's Tier 3
  (`main.c`, `gemm.c`/`gemm.h`, `lscript.ld`) -- the PS-side stimuli
  generator and HIL test suite, compiled with `arm-none-eabi-gcc` (no
  Vitis IDE/`app create` involved).
- **`scripts/`**: Modular Tcl (and PowerShell, for PS+PL) automation --
  generate IPs, build the project, run simulation, build the bitstream,
  run the HIL test, for both platforms.
  * PL-only: `build_pynq_pl.tcl`, `ip/gen_ip_pynq_pl.tcl` (standalone
    IP generation), `program_and_test_pynq_pl.tcl`.
  * PS+PL: `build_ps_pl.tcl` (project + block design + bitstream + `.xsa`
    export), `bd/gen_bd_ps.tcl` (the block design itself: PS7 + AXI3→
    AXI4-Lite protocol converter + crossbar + BRAMs + `gemm_top`),
    `program_and_test_ps_pl.ps1` (end-to-end HIL: BSP generation,
    software build, board programming, UART result capture).
  * `bd/tier2_config.tcl`: BRAM sizing, crossbar port count, and address
    offsets shared between the PL-only and PS+PL IP/BD generation
    scripts -- the only genuinely duplicated numbers between the two
    targets, kept in one place (mechanism stays different per target).
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
   - Simulation: `sim/gemm_axi_vip_tb.sv` (SystemVerilog, drives the AXI
     VIP directly).
   - PL-only HIL: `scripts/program_and_test_pynq_pl.tcl` (Tcl, drives the
     JTAG-to-AXI Master via Vivado Hardware Manager).
   - PS+PL HIL: `sw/main.c` (bare-metal C, running on the Zynq's own ARM
     Cortex-A9) -- generates stimuli by writing directly to memory-mapped
     AXI addresses (`volatile` pointer stores), starts the computation,
     polls for completion, and checks the result, printing progress over
     UART.

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
vivado -mode batch -source scripts/program_and_test_pynq_pl.tcl
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
powershell -ExecutionPolicy Bypass -File scripts/program_and_test_ps_pl.ps1
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
