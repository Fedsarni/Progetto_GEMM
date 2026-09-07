// Author: Federica
// Description:
//   Simulation testbench for the GEMM AXI-lite design (Tier 3, using the
//   AXI VIP master agent). Loads matrices A and B into their BRAMs via
//   AXI-lite, starts the computation, polls for completion, reads back
//   matrix C, and checks it against a golden model computed in this TB.
//
//   Coverage: since exhaustive input coverage is infeasible for a
//   multi-element component like this (128 independent 8-bit inputs ->
//   256^128 combinations, per the RTL guide's "Input Randomization"
//   section: "For non-elementary components, it is not always possible to
//   cover the space of all possible input values... randomize input
//   values"), this TB instead runs a fixed set of targeted corner cases
//   (saturation at both extremes, alternating-sign checkerboard, sparse
//   single-element) plus several randomized cases with a fresh seed each
//   run, checking every one of the M*L output elements bit-exact against
//   a golden model on every case.
 
//1 unit of time = 1 nanosecond
`timescale 1ns/1ps
 
import axi_vip_pkg::*;
import axi_vip_master_0_pkg::*;
 
module gemm_axi_vip_tb;
 
    localparam int ELEM_WIDTH = 8;
    localparam int N          = 8;
    localparam int M          = 8;
    localparam int L          = 8;
 
    localparam int RESULT_WIDTH  = 2*ELEM_WIDTH + $clog2(N);
    localparam int C_WORD_WIDTH  = ((RESULT_WIDTH+7)/8)*8;
 
    localparam int MIN_VAL = -(2**(ELEM_WIDTH-1));
    localparam int MAX_VAL =  (2**(ELEM_WIDTH-1)) - 1;
 
    localparam bit [31:0] BASE_A    = 32'h0000;
    localparam bit [31:0] BASE_B    = 32'h1000;
    localparam bit [31:0] BASE_C    = 32'h2000;
 
    localparam bit [31:0] BASE_CTRL       = 32'h3000;
    localparam bit [31:0] CTRL_REG        = BASE_CTRL;
    localparam bit [31:0] STATUS_REG      = BASE_CTRL + 32'h4;
    localparam bit [31:0] BASE_ADDR_A_REG = BASE_CTRL + 32'h8;
    localparam bit [31:0] BASE_ADDR_B_REG = BASE_CTRL + 32'hC;
    localparam bit [31:0] BASE_ADDR_C_REG = BASE_CTRL + 32'h10;
 
    localparam int ROW_BYTES = (N*ELEM_WIDTH)/8;
    localparam int C_BYTES   = 4;
 
    // Number of randomized cases run in addition to the fixed corner cases
    // below. Each random case uses a freshly drawn seed printed to the log
    // for reproducibility (re-run with the same seed via -sv_seed in
    // build.tcl / xsim to replay a specific failure).
    localparam int NUM_RANDOM_CASES = 5;
 
    logic clk_100mhz = 0;
    logic reset_n    = 0;
 
    always #5 clk_100mhz = ~clk_100mhz;
 
    initial begin
        reset_n = 1'b0;
        repeat (10) @(posedge clk_100mhz);
        reset_n = 1'b1;
    end
 
    gemm_top_sim_wrapper DUT (
        .clk100mhz_i (clk_100mhz),
        .ck_rst_ni   (reset_n)
    );
 
    axi_vip_master_0_mst_t master_agent;
    xil_axi_resp_t axi_resp;
 
    logic signed [ELEM_WIDTH-1:0] mat_a [M][N];
    logic signed [ELEM_WIDTH-1:0] mat_b [L][N];
    int mat_c_expected [M][L];
    int mat_c_read     [M][L];
 
    int total_cases  = 0;
    int total_errors = 0; // sum of per-element mismatches across all cases
    int failed_cases = 0; // count of cases with >=1 mismatch
 
    //////////////////////////////////////////
    // Golden model (shared by every case)   //
    //////////////////////////////////////////
 
    task automatic compute_golden_model();
        int sum;
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < L; j++) begin
                sum = 0;
                for (int k = 0; k < N; k++) begin
                    sum += int'(mat_a[i][k]) * int'(mat_b[j][k]);
                end
                mat_c_expected[i][j] = sum;
            end
        end
    endtask
 
    //////////////////////////////////////////////////////////////
    // Test case generators -- each fills mat_a/mat_b for one case
    //////////////////////////////////////////////////////////////
 
    // Deterministic pseudo-random baseline (original pattern, kept as a
    // fixed regression case so past behaviour stays checked every run).
    task automatic gen_case_baseline();
        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = signed'(MIN_VAL + ((i*7 + k*3) % (MAX_VAL - MIN_VAL + 1)));
        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = signed'(MIN_VAL + ((j*5 + k*11) % (MAX_VAL - MIN_VAL + 1)));
    endtask
 
    // Both operands at the most positive value everywhere: every partial
    // product and the final accumulation are at their largest positive
    // magnitude -- stresses the top end of the accumulator's dynamic range.
    task automatic gen_case_max_pos();
        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = MAX_VAL;
        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = MAX_VAL;
    endtask
 
    // A at max positive, B at max negative (asymmetric two's-complement
    // extreme: MIN_VAL has no positive counterpart, |MIN_VAL| > MAX_VAL).
    // Every partial product is at the most negative extreme possible --
    // the classic corner case for signed multiply/accumulate overflow bugs.
    task automatic gen_case_max_neg();
        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = MAX_VAL;
        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = MIN_VAL;
    endtask
 
    // Alternating-sign "checkerboard": stresses sign-extension logic and
    // sums with heavy positive/negative cancellation (as opposed to the
    // max cases above, where every term has the same sign).
    task automatic gen_case_checkerboard();
        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = ((i+k) % 2 == 0) ? MAX_VAL : MIN_VAL;
        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = ((j+k) % 2 == 0) ? MIN_VAL : MAX_VAL;
    endtask
 
    // Sparse: everything zero except one element of A and one element of
    // B that share the same k index (so exactly one C element is nonzero).
    // Verifies BRAM addressing / indexing in isolation, with no other
    // nonzero term able to mask an addressing bug via cancellation.
    task automatic gen_case_sparse();
        int sparse_i, sparse_k, sparse_j;
        sparse_i = 2 % M;
        sparse_k = 3 % N;
        sparse_j = 5 % L;
        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = 0;
        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = 0;
        mat_a[sparse_i][sparse_k] = 8'sd50;
        mat_b[sparse_j][sparse_k] = -8'sd30;
        // Expected: only C[sparse_i][sparse_j] = 50 * -30 = -1500 is nonzero.
    endtask
 
    // Uniformly random elements over the full signed ELEM_WIDTH range.
    // $urandom_range draws from Vivado xsim's per-run seed (override with
    // -sv_seed <N> in the simulator invocation to replay a specific case).
    task automatic gen_case_random();
        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = signed'($urandom_range(MAX_VAL, MIN_VAL));
        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = signed'($urandom_range(MAX_VAL, MIN_VAL));
    endtask
 
    //////////////////////////////////////////////////////////////
    // Common per-case flow: write A/B, set bases, start, poll,   //
    // read back C, compare against golden model.                //
    //////////////////////////////////////////////////////////////
 
    task automatic run_current_case(input string case_name);
        logic [63:0] row_word;
        int case_errors;
 
        compute_golden_model();
 
        for (int i = 0; i < M; i++) begin
            row_word = '0;
            for (int k = 0; k < N; k++)
                row_word[(k*ELEM_WIDTH) +: ELEM_WIDTH] = mat_a[i][k];
            master_agent.AXI4LITE_WRITE_BURST(BASE_A + i*ROW_BYTES,   0, row_word[31:0],  axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB][%s] Write error on A, row %0d (beat 0)", case_name, i);
            master_agent.AXI4LITE_WRITE_BURST(BASE_A + i*ROW_BYTES+4, 0, row_word[63:32], axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB][%s] Write error on A, row %0d (beat 1)", case_name, i);
        end
 
        for (int j = 0; j < L; j++) begin
            row_word = '0;
            for (int k = 0; k < N; k++)
                row_word[(k*ELEM_WIDTH) +: ELEM_WIDTH] = mat_b[j][k];
            master_agent.AXI4LITE_WRITE_BURST(BASE_B + j*ROW_BYTES,   0, row_word[31:0],  axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB][%s] Write error on B, row %0d (beat 0)", case_name, j);
            master_agent.AXI4LITE_WRITE_BURST(BASE_B + j*ROW_BYTES+4, 0, row_word[63:32], axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB][%s] Write error on B, row %0d (beat 1)", case_name, j);
        end
 
        master_agent.AXI4LITE_WRITE_BURST(BASE_ADDR_A_REG, 0, BASE_A, axi_resp);
        assert (axi_resp == XIL_AXI_RESP_OKAY)
            else $error("[TB][%s] Write error on BASE_ADDR_A", case_name);
        master_agent.AXI4LITE_WRITE_BURST(BASE_ADDR_B_REG, 0, BASE_B, axi_resp);
        assert (axi_resp == XIL_AXI_RESP_OKAY)
            else $error("[TB][%s] Write error on BASE_ADDR_B", case_name);
        master_agent.AXI4LITE_WRITE_BURST(BASE_ADDR_C_REG, 0, BASE_C, axi_resp);
        assert (axi_resp == XIL_AXI_RESP_OKAY)
            else $error("[TB][%s] Write error on BASE_ADDR_C", case_name);
 
        master_agent.AXI4LITE_WRITE_BURST(CTRL_REG, 0, 32'h0000_0001, axi_resp);
        @(posedge clk_100mhz);
        master_agent.AXI4LITE_WRITE_BURST(CTRL_REG, 0, 32'h0000_0000, axi_resp);
 
        begin
            logic [31:0] done_val;
            int poll_count;
            done_val = 0;
            poll_count = 0;
            while (done_val[0] == 1'b0 && poll_count < 2000) begin
                master_agent.AXI4LITE_READ_BURST(STATUS_REG, 0, done_val, axi_resp);
                poll_count++;
                #100;
            end
            if (done_val[0] == 1'b0) begin
                $error("[TB][%s] TIMEOUT: done never went high after %0d polls @ %0t",
                       case_name, poll_count, $time);
                total_cases++;
                failed_cases++;
                return;
            end
        end
 
        case_errors = 0;
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < L; j++) begin
                automatic logic [31:0] read_val;
                automatic int          read_signed;
                master_agent.AXI4LITE_READ_BURST(BASE_C + (i*L + j)*C_BYTES, 0, read_val, axi_resp);
                read_signed = $signed(read_val[C_WORD_WIDTH-1:0]);
                mat_c_read[i][j] = read_signed;
                if (read_signed !== mat_c_expected[i][j]) begin
                    case_errors++;
                    $error("[TB][%s] Mismatch at C[%0d][%0d]: got %0d, expected %0d",
                           case_name, i, j, read_signed, mat_c_expected[i][j]);
                end
            end
        end
 
        total_cases++;
        total_errors += case_errors;
        if (case_errors == 0) begin
            $display("[TB][%s] PASS - all %0d elements of C match", case_name, M*L);
        end else begin
            failed_cases++;
            $display("[TB][%s] FAIL - %0d/%0d mismatches", case_name, case_errors, M*L);
        end
    endtask
 
    initial begin : stim_proc
        int seed_used;
 
        master_agent = new("master_vip", DUT.AXI_VIP_INST.inst.IF);
        master_agent.start_master();
 
        wait (reset_n == 1'b1);
        repeat (5) @(posedge clk_100mhz);
 
        $display("[TB] ==== Starting coverage suite: 5 fixed corner cases + %0d random cases ====",
                  NUM_RANDOM_CASES);
 
        gen_case_baseline();     run_current_case("baseline");
        gen_case_max_pos();      run_current_case("max_positive_saturation");
        gen_case_max_neg();      run_current_case("max_negative_saturation");
        gen_case_checkerboard(); run_current_case("sign_checkerboard");
        gen_case_sparse();       run_current_case("sparse_single_element");
 
        for (int r = 0; r < NUM_RANDOM_CASES; r++) begin
            seed_used = $urandom; // just for the log message, doesn't reseed
            gen_case_random();
            run_current_case($sformatf("random_%0d", r));
        end
 
        $display("[TB] ==== Coverage suite summary ====");
        $display("[TB] Cases run: %0d, cases failed: %0d, total element mismatches: %0d",
                  total_cases, failed_cases, total_errors);
        if (failed_cases == 0) begin
            $display("[TB] OVERALL PASS - all %0d test cases passed", total_cases);
        end else begin
            $display("[TB] OVERALL FAIL - %0d of %0d test cases failed", failed_cases, total_cases);
        end
 
        $display("[TB] Simulation finished");
        $finish;
    end : stim_proc
 
endmodule
 
