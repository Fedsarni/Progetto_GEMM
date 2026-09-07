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
depending on the target.

---

## 🛠️ Prerequisites

- **Xilinx Vivado 2025.2** (or newer)
- Digilent Pynq-Z1 board (Zynq-7020, part `xc7z020clg400-1`)
- Micro-USB cable for JTAG programming and AXI communication

---

## 📂 Repository Structure

To keep version control clean and lightweight, the Vivado project
directories (`gemm_*_prj/`) are ignored -- projects are dynamically
generated from the Tcl scripts on every run.

- **`src/`**: VHDL sources.
  - `gemm_top.vhd` and its sub-modules (`gemm_controller.vhd`, `lsu.vhd`,
    `dot_product_optimized.vhd`, `axi4lite_ctrl_regs.vhd`,
    `axi_master_engine.vhd`) -- **Tier 1**, the core design under test,
    identical across every target.
  - `gemm_axi_ip_components_pkg.vhd` -- shared VHDL component
    declarations (AXI crossbar, BRAM controllers) reused by every Tier 2
    wrapper, so they aren't duplicated between targets.
  - `gemm_top_sim_wrapper.vhd`, `gemm_top_pynq_pl_wrapper.vhd` -- **Tier
    2**, one test wrapper per target (see `Architecture` below).
- **`sim/`**: SystemVerilog testbench (`gemm_axi_vip_tb.sv`), using the
  AXI Verification IP (VIP) as the golden-model driver -- **Tier 3** for
  simulation.
- **`scripts/`**: Modular Tcl automation -- generate IPs, build the
  project, run simulation, build the bitstream, run the HIL test.
- **`xdc/`**: Physical constraints for the Pynq-Z1 (clock, reset).
- **`.github/workflows/`**: GitHub Actions CI pipeline definition.

---

## 🏗️ Architecture: Three-tier Verification

Following the internal RTL Coding/Design/Verification guide, the
synthesis and simulation flows share the same core design but differ in
how it's driven:

1. **Tier 1 -- Design Under Test**: `gemm_top.vhd`. No stimulus IP, no
   knowledge of simulation vs. hardware -- just AXI4-Lite ports in and
   out. Never duplicated, never modified per target.
2. **Tier 2 -- Test wrapper**: wraps the Tier 1 DUT together with the
   driving IP appropriate for the target:
   - `gemm_top_sim_wrapper.vhd`: DUT + **AXI VIP** (simulation-only,
     driven directly by the testbench).
   - `gemm_top_pynq_pl_wrapper.vhd`: DUT + **JTAG-to-AXI Master** (for
     real hardware, driven by a host-side Tcl script over JTAG), plus the
     PL-only clock/reset workaround needed on Zynq when the Processing
     System is never booted (see comments in the wrapper source).
3. **Tier 3 -- Stimuli generation**: drives Tier 2 and checks results
   against a golden model computed independently in the same language as
   the driver:
   - Simulation: `sim/gemm_axi_vip_tb.sv` (SystemVerilog, drives the AXI
     VIP directly).
   - HIL: `scripts/program_and_test_pynq_pl.tcl` (Tcl, drives the
     JTAG-to-AXI Master via Vivado Hardware Manager).

Both Tier 3 drivers run the **same test suite**: a deterministic baseline
case plus targeted corner cases (maximum positive/negative saturation,
alternating-sign checkerboard, sparse single-element) and several
randomized cases. Exhaustive input coverage isn't attempted -- with 128
independent 8-bit inputs (64 elements each in A and B), the input space
is `256^128` combinations, far beyond what's feasible to exhaust; this
follows the guide's "Input Randomization" approach for non-elementary
components.

---

## 🚀 How to Run

Make sure Vivado 2025.2 is on your PATH (or use the full path to
`vivado.bat`/`vivado`), and, for the HIL step, that the Pynq-Z1 is
connected via USB and powered on.

### Simulation

```powershell
vivado -mode batch -source scripts/build.tcl
```

Runs RTL simulation using the AXI VIP golden model. Check the log for
`[TB] OVERALL PASS` / `[TB] OVERALL FAIL`.

### Build (synthesis + implementation + bitstream)

```powershell
vivado -mode batch -source scripts/build_pynq_pl.tcl
```

### Hardware-in-the-Loop test

```powershell
vivado -mode batch -source scripts/program_and_test_pynq_pl.tcl
```

Programs the bitstream onto the Pynq-Z1 and runs the full test suite over
JTAG-to-AXI. Check the log for `[TEST] OVERALL PASS` / `[TEST] OVERALL
FAIL`.

---

## ⚙️ Continuous Integration

The pipeline (`.github/workflows/gemm-ci.yml`) runs on a **self-hosted
GitHub Actions runner**, installed on a PC with Vivado and the Pynq-Z1
permanently connected, so that both simulation and the HIL test can run
automatically on every push:

1. **`build`**: synthesizes and implements the design, generates the
   bitstream, uploads it as an artifact.
2. **`simulate`**: runs the RTL simulation (Tier 3, AXI VIP).
3. **`hil_test`**: downloads the bitstream artifact, programs the board,
   runs the HIL test suite (Tier 3, JTAG-to-AXI).

All error paths in the Tcl scripts explicitly `exit 1` on failure (rather
than a bare `return`), so a failed build, a disconnected board, or a
mismatched result all show up as a red X in the pipeline instead of a
false-green checkmark.

---

## About

Author: Federica Sarnataro
