/*
 * Author: Federica Sarnataro
 * gemm.h
 *
 * Tier 3 driver for the GEMM accelerator (8x8, signed int8 elements,
 * AXI4-Lite), PS+PL on Pynq-Z1.
 *
 * Address map (PS side, after the address assignment in the block design):
 *   BRAM A            0x40000000
 *   BRAM B            0x40001000
 *   BRAM C            0x40002000
 *   CTRL (start)      0x40003000
 *   STATUS (done)     0x40003004
 *   BASE_ADDR_A       0x40003008
 *   BASE_ADDR_B       0x4000300C
 *   BASE_ADDR_C       0x40003010
 *
 * Memory layout (verified in axi_master_engine.vhd/gemm_top.vhd):
 *   - Matrices A/B: the hardware fetches an entire row (ROW_WIDTH =
 *     N*ELEM_WIDTH = 64 bits) in one shot, so the 8 int8 elements of a row
 *     are packed 4 per 32-bit word (1 byte each), tightly, with the row
 *     stride rounded up to the nearest beat (word) boundary.
 *   - Matrix C: one element per 32-bit word, but the value is a signed
 *     24-bit integer (RESULT_WIDTH=19 rounded up to C_WORD_WIDTH=24) in
 *     the low 3 bytes -- needs sign-extension to 32 bits on read.
 */

#ifndef GEMM_H_
#define GEMM_H_

#include <inttypes.h>

#define GEMM_N 8
#define GEMM_M 8
#define GEMM_L 8

#define GEMM_BRAM_A_BASEADDR 0x40000000U
#define GEMM_BRAM_B_BASEADDR 0x40001000U
#define GEMM_BRAM_C_BASEADDR 0x40002000U
#define GEMM_CTRL_BASEADDR   0x40003000U

#define GEMM_CTRL_OFFSET       0x00U
#define GEMM_STATUS_OFFSET     0x04U
#define GEMM_BASE_ADDR_A_OFFSET 0x08U
#define GEMM_BASE_ADDR_B_OFFSET 0x0CU
#define GEMM_BASE_ADDR_C_OFFSET 0x10U

/* Writes an MxN int8 matrix (row-major) into the given BRAM window, using
 * the tightly-packed-within-a-row layout described above. */
void gemm_write_matrix(uint32_t bram_base, const int8_t *data, int rows, int cols);

/* Reads the result matrix (rows x cols) from the BRAM C window,
 * sign-extending each element from 24 to 32 bits. */
void gemm_read_result(uint32_t bram_base, int32_t *out, int rows, int cols);

/* Configures the BASE_ADDR_A/B/C registers of the control block -- used by
 * gemm_top's internal AXI master to know where to read/write. */
void gemm_set_base_addrs(uint32_t addr_a, uint32_t addr_b, uint32_t addr_c);

/* Writes 1 to the CTRL register (starts the computation). */
void gemm_start(void);

/* Polls the STATUS register until the done bit (bit 0) is set. */
void gemm_wait_done(void);

#endif /* GEMM_H_ */
