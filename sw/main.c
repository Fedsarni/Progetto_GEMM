/*
 * main.c
 *
 * Tier 3 HIL test suite for the 8x8 int8 GEMM on Pynq-Z1 (PS+PL).
 *
 * Mirrors the same targeted corner cases used in the PL-only simulation
 * testbench (gemm_axi_vip_tb.sv): baseline (deterministic pseudo-random),
 * max positive saturation, max negative saturation, sign checkerboard,
 * sparse single-element, plus a couple of randomized cases. Exhaustive
 * coverage is infeasible for a 128-independent-input component (see the
 * RTL guide's "Input Randomization" section), so this follows the same
 * corner-case + randomization strategy already established for PL-only.
 *
 * Each case computes a golden model on the ARM itself (plain int32
 * multiply-accumulate) and compares every one of the M*L result elements
 * bit-exact against what the accelerator produced.
 */

#include <stdlib.h>
#include "platform.h"
#include "xil_printf.h"
#include "gemm.h"

#define MIN_VAL (-128)
#define MAX_VAL (127)

static int8_t mat_a[GEMM_M][GEMM_N];
static int8_t mat_b[GEMM_L][GEMM_N];
static int32_t mat_c_expected[GEMM_M][GEMM_L];
static int32_t mat_c_read[GEMM_M][GEMM_L];

static int total_cases = 0;
static int total_errors = 0;
static int failed_cases = 0;

/* -------------------------------------------------------------- */
/* Golden model (shared by every case)                            */
/* -------------------------------------------------------------- */

static void compute_golden_model(void) {
    for (int i = 0; i < GEMM_M; i++) {
        for (int j = 0; j < GEMM_L; j++) {
            int32_t sum = 0;
            for (int k = 0; k < GEMM_N; k++) {
                sum += (int32_t)mat_a[i][k] * (int32_t)mat_b[j][k];
            }
            mat_c_expected[i][j] = sum;
        }
    }
}

/* -------------------------------------------------------------- */
/* Test case generators -- same cases as gemm_axi_vip_tb.sv       */
/* -------------------------------------------------------------- */

/* Deterministic pseudo-random baseline (matches the sim TB formula). */
static void gen_case_baseline(void) {
    for (int i = 0; i < GEMM_M; i++)
        for (int k = 0; k < GEMM_N; k++)
            mat_a[i][k] = (int8_t)(MIN_VAL + ((i * 7 + k * 3) % (MAX_VAL - MIN_VAL + 1)));
    for (int j = 0; j < GEMM_L; j++)
        for (int k = 0; k < GEMM_N; k++)
            mat_b[j][k] = (int8_t)(MIN_VAL + ((j * 5 + k * 11) % (MAX_VAL - MIN_VAL + 1)));
}

/* Both operands at the most positive value everywhere -- stresses the top
 * end of the accumulator's dynamic range. */
static void gen_case_max_pos(void) {
    for (int i = 0; i < GEMM_M; i++)
        for (int k = 0; k < GEMM_N; k++)
            mat_a[i][k] = MAX_VAL;
    for (int j = 0; j < GEMM_L; j++)
        for (int k = 0; k < GEMM_N; k++)
            mat_b[j][k] = MAX_VAL;
}

/* A at max positive, B at max negative -- classic corner case for signed
 * multiply/accumulate overflow bugs (|MIN_VAL| > MAX_VAL). */
static void gen_case_max_neg(void) {
    for (int i = 0; i < GEMM_M; i++)
        for (int k = 0; k < GEMM_N; k++)
            mat_a[i][k] = MAX_VAL;
    for (int j = 0; j < GEMM_L; j++)
        for (int k = 0; k < GEMM_N; k++)
            mat_b[j][k] = MIN_VAL;
}

/* Alternating-sign checkerboard -- stresses sign-extension logic and sums
 * with heavy positive/negative cancellation. */
static void gen_case_checkerboard(void) {
    for (int i = 0; i < GEMM_M; i++)
        for (int k = 0; k < GEMM_N; k++)
            mat_a[i][k] = ((i + k) % 2 == 0) ? MAX_VAL : MIN_VAL;
    for (int j = 0; j < GEMM_L; j++)
        for (int k = 0; k < GEMM_N; k++)
            mat_b[j][k] = ((j + k) % 2 == 0) ? MIN_VAL : MAX_VAL;
}

/* Sparse: everything zero except one element of A and one of B sharing the
 * same k index, so exactly one C element is nonzero -- isolates BRAM
 * addressing/indexing bugs with no other term able to mask them. */
static void gen_case_sparse(void) {
    int sparse_i = 2 % GEMM_M;
    int sparse_k = 3 % GEMM_N;
    int sparse_j = 5 % GEMM_L;
    for (int i = 0; i < GEMM_M; i++)
        for (int k = 0; k < GEMM_N; k++)
            mat_a[i][k] = 0;
    for (int j = 0; j < GEMM_L; j++)
        for (int k = 0; k < GEMM_N; k++)
            mat_b[j][k] = 0;
    mat_a[sparse_i][sparse_k] = 50;
    mat_b[sparse_j][sparse_k] = -30;
    /* Expected: only C[sparse_i][sparse_j] = 50 * -30 = -1500 is nonzero. */
}

/* Uniformly random elements over the full signed int8 range. */
static void gen_case_random(void) {
    for (int i = 0; i < GEMM_M; i++)
        for (int k = 0; k < GEMM_N; k++)
            mat_a[i][k] = (int8_t)(MIN_VAL + (rand() % (MAX_VAL - MIN_VAL + 1)));
    for (int j = 0; j < GEMM_L; j++)
        for (int k = 0; k < GEMM_N; k++)
            mat_b[j][k] = (int8_t)(MIN_VAL + (rand() % (MAX_VAL - MIN_VAL + 1)));
}

/* -------------------------------------------------------------- */
/* Common per-case flow                                           */
/* -------------------------------------------------------------- */

static void run_current_case(const char *case_name) {
    compute_golden_model();

    gemm_write_matrix(GEMM_BRAM_A_BASEADDR, &mat_a[0][0], GEMM_M, GEMM_N);
    gemm_write_matrix(GEMM_BRAM_B_BASEADDR, &mat_b[0][0], GEMM_L, GEMM_N);
    gemm_set_base_addrs(GEMM_BRAM_A_BASEADDR, GEMM_BRAM_B_BASEADDR, GEMM_BRAM_C_BASEADDR);

    gemm_start();
    gemm_wait_done();

    gemm_read_result(GEMM_BRAM_C_BASEADDR, &mat_c_read[0][0], GEMM_M, GEMM_L);

    int case_errors = 0;
    for (int i = 0; i < GEMM_M; i++) {
        for (int j = 0; j < GEMM_L; j++) {
            if (mat_c_read[i][j] != mat_c_expected[i][j]) {
                case_errors++;
                xil_printf("[TB][%s] Mismatch at C[%d][%d]: got %d, expected %d\r\n",
                           case_name, i, j, (int)mat_c_read[i][j], (int)mat_c_expected[i][j]);
            }
        }
    }

    total_cases++;
    total_errors += case_errors;
    if (case_errors == 0) {
        xil_printf("[TB][%s] PASS - all %d elements of C match\r\n", case_name, GEMM_M * GEMM_L);
    } else {
        failed_cases++;
        xil_printf("[TB][%s] FAIL - %d/%d mismatches\r\n", case_name, case_errors, GEMM_M * GEMM_L);
    }
}

int main() {
    init_platform();

    print("GEMM PS+PL HIL test suite -- Pynq-Z1\r\n");
    print("==== Starting coverage suite: 5 fixed corner cases + 2 random cases ====\r\n\r\n");

    srand(12345); /* fixed seed: reproducible run-to-run, override if needed */

    gen_case_baseline();     run_current_case("baseline");
    gen_case_max_pos();      run_current_case("max_positive_saturation");
    gen_case_max_neg();      run_current_case("max_negative_saturation");
    gen_case_checkerboard(); run_current_case("sign_checkerboard");
    gen_case_sparse();       run_current_case("sparse_single_element");

    gen_case_random(); run_current_case("random_0");
    gen_case_random(); run_current_case("random_1");

    print("\r\n==== Coverage suite summary ====\r\n");
    xil_printf("Cases run: %d, cases failed: %d, total element mismatches: %d\r\n",
               total_cases, failed_cases, total_errors);
    if (failed_cases == 0) {
        xil_printf("OVERALL PASS - all %d test cases passed\r\n", total_cases);
    } else {
        xil_printf("OVERALL FAIL - %d of %d test cases failed\r\n", failed_cases, total_cases);
    }

    while (1) {
        /* done */
    }

    cleanup_platform();
    return 0;
}
