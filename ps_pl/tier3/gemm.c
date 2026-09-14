/*
 * Author: Federica Sarnataro
 * gemm.c
 *
 * Tier 3 driver for the GEMM accelerator -- see gemm.h for the address
 * map and the assumptions about the memory layout.
 */

#include "gemm.h"

static inline void gemm_reg_write(uint32_t offset, uint32_t value) {
    *(volatile uint32_t *)(GEMM_CTRL_BASEADDR + offset) = value;
}

static inline uint32_t gemm_reg_read(uint32_t offset) {
    return *(volatile uint32_t *)(GEMM_CTRL_BASEADDR + offset);
}

void gemm_write_matrix(uint32_t bram_base, const int8_t *data, int rows, int cols) {
    /* Real layout (verified in gemm_top.vhd/axi_master_engine.vhd): the
     * hardware fetches an entire row as a ROW_WIDTH = cols*8 bit vector in
     * one shot -- int8 elements are packed 4 per 32-bit word (1 byte
     * each). IMPORTANT: writes must be full 32-bit words, not individual
     * bytes -- the BRAM (blk_mem_gen) isn't configured with byte-write
     * enable in the block design, so a narrow (single-byte) AXI write
     * overwrites the whole word instead of merging into it. Assemble each
     * word from up to 4 packed bytes in software and write it in one shot. */
    volatile uint32_t *mem = (volatile uint32_t *)bram_base;
    int beats_per_row = (cols + 3) / 4; /* BEATS_ROW */
    for (int r = 0; r < rows; r++) {
        for (int w = 0; w < beats_per_row; w++) {
            uint32_t word = 0;
            for (int b = 0; b < 4; b++) {
                int col = w * 4 + b;
                if (col < cols) {
                    word |= ((uint32_t)(uint8_t)data[r * cols + col]) << (b * 8);
                }
            }
            mem[r * beats_per_row + w] = word;
        }
    }
}

void gemm_read_result(uint32_t bram_base, int32_t *out, int rows, int cols) {
    volatile uint32_t *mem = (volatile uint32_t *)bram_base;
    int n = rows * cols;
    for (int i = 0; i < n; i++) {
        uint32_t raw = mem[i] & 0x00FFFFFFU; /* only the low 3 bytes (24 bits) matter */
        /* Sign-extend from 24 to 32 bits: if bit 23 is 1, the number is
         * negative -- fill the high bits with 1. */
        if (raw & 0x00800000U) {
            raw |= 0xFF000000U;
        }
        out[i] = (int32_t)raw;
    }
}

void gemm_set_base_addrs(uint32_t addr_a, uint32_t addr_b, uint32_t addr_c) {
    gemm_reg_write(GEMM_BASE_ADDR_A_OFFSET, addr_a);
    gemm_reg_write(GEMM_BASE_ADDR_B_OFFSET, addr_b);
    gemm_reg_write(GEMM_BASE_ADDR_C_OFFSET, addr_c);
}

void gemm_start(void) {
    gemm_reg_write(GEMM_CTRL_OFFSET, 1U);
}

void gemm_wait_done(void) {
    while ((gemm_reg_read(GEMM_STATUS_OFFSET) & 0x1U) == 0U) {
        /* polling */
    }
}

/* Normally provided by the toolchain's crti.o/crtn.o, excluded here by
 * -nostartfiles. */
void _init(void) {}
void _fini(void) {}
