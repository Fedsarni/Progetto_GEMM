// Author: Federica
// Description:
//   Simulation testbench for the GEMM AXI-lite design (Tier 3, using the
//   AXI VIP master agent). Loads matrices A and B into their BRAMs via
//   AXI-lite, starts the computation, polls for completion, reads back
//   matrix C, and checks it against a golden model computed in this TB.

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

    initial begin : stim_proc
        logic [63:0] row_word;
        int errors;

        // MODIFICA FONDAMENTALE: Collegamento gerarchico al driver SystemVerilog dell'IP
        master_agent = new("master_vip", DUT.AXI_VIP_INST.inst.IF);
        master_agent.start_master();

        wait (reset_n == 1'b1);
        repeat (5) @(posedge clk_100mhz);

        for (int i = 0; i < M; i++)
            for (int k = 0; k < N; k++)
                mat_a[i][k] = signed'(MIN_VAL + ((i*7 + k*3) % (MAX_VAL - MIN_VAL + 1)));

        for (int j = 0; j < L; j++)
            for (int k = 0; k < N; k++)
                mat_b[j][k] = signed'(MIN_VAL + ((j*5 + k*11) % (MAX_VAL - MIN_VAL + 1)));

        compute_golden_model();

        for (int i = 0; i < M; i++) begin
            row_word = '0;
            for (int k = 0; k < N; k++)
                row_word[(k*ELEM_WIDTH) +: ELEM_WIDTH] = mat_a[i][k];

            $display("[TB] About to write A row %0d at address 0x%0h @ %0t", i, BASE_A + i*ROW_BYTES, $time);
            master_agent.AXI4LITE_WRITE_BURST(BASE_A + i*ROW_BYTES,   0, row_word[31:0],  axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB] Write error on A, row %0d (beat 0)", i);
            master_agent.AXI4LITE_WRITE_BURST(BASE_A + i*ROW_BYTES+4, 0, row_word[63:32], axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB] Write error on A, row %0d (beat 1)", i);
            $display("[TB] Done writing A row %0d @ %0t", i, $time);
        end

        for (int j = 0; j < L; j++) begin
            row_word = '0;
            for (int k = 0; k < N; k++)
                row_word[(k*ELEM_WIDTH) +: ELEM_WIDTH] = mat_b[j][k];
            $display("[TB] About to write B col %0d at address 0x%0h @ %0t", j, BASE_B + j*ROW_BYTES, $time);
            master_agent.AXI4LITE_WRITE_BURST(BASE_B + j*ROW_BYTES,   0, row_word[31:0],  axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB] Write error on B, row %0d (beat 0)", j);
            master_agent.AXI4LITE_WRITE_BURST(BASE_B + j*ROW_BYTES+4, 0, row_word[63:32], axi_resp);
            assert (axi_resp == XIL_AXI_RESP_OKAY)
                else $error("[TB] Write error on B, row %0d (beat 1)", j);
            $display("[TB] Done writing B col %0d @ %0t", j, $time);
        end

        master_agent.AXI4LITE_WRITE_BURST(BASE_ADDR_A_REG, 0, BASE_A, axi_resp);
        assert (axi_resp == XIL_AXI_RESP_OKAY)
            else $error("[TB] Write error on BASE_ADDR_A");
        $display("[TB] Done writing BASE_ADDR_A @ %0t", $time);
        master_agent.AXI4LITE_WRITE_BURST(BASE_ADDR_B_REG, 0, BASE_B, axi_resp);
        assert (axi_resp == XIL_AXI_RESP_OKAY)
            else $error("[TB] Write error on BASE_ADDR_B");
        $display("[TB] Done writing BASE_ADDR_B @ %0t", $time);
        master_agent.AXI4LITE_WRITE_BURST(BASE_ADDR_C_REG, 0, BASE_C, axi_resp);
        assert (axi_resp == XIL_AXI_RESP_OKAY)
            else $error("[TB] Write error on BASE_ADDR_C");
        $display("[TB] Done writing BASE_ADDR_C @ %0t", $time);

        master_agent.AXI4LITE_WRITE_BURST(CTRL_REG, 0, 32'h0000_0001, axi_resp);
        @(posedge clk_100mhz);
        master_agent.AXI4LITE_WRITE_BURST(CTRL_REG, 0, 32'h0000_0000, axi_resp);
        $display("[TB] Start pulse sent");

        begin
            logic [31:0] done_val;
            int poll_count;
            done_val = 0;
            poll_count = 0;
            while (done_val[0] == 1'b0 && poll_count < 2000) begin
                master_agent.AXI4LITE_READ_BURST(STATUS_REG, 0, done_val, axi_resp);
                if (poll_count % 100 == 0)
                    $display("[TB] poll #%0d, done_val=0x%0h @ %0t", poll_count, done_val, $time);
                poll_count++;
                #100;
            end
            if (done_val[0] == 1'b0) begin
                $display("[TB] TIMEOUT: done never went high after %0d polls @ %0t", poll_count, $time);
                $finish;
            end
        end
        $display("[TB] done_o observed high, computation finished");

        errors = 0;
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < L; j++) begin
                automatic logic [31:0] read_val;
                automatic int          read_signed;
                master_agent.AXI4LITE_READ_BURST(BASE_C + (i*L + j)*C_BYTES, 0, read_val, axi_resp);
                read_signed = $signed(read_val[C_WORD_WIDTH-1:0]);
                mat_c_read[i][j] = read_signed;
                if (read_signed !== mat_c_expected[i][j]) begin
                    errors++;
                    $error("[TB] Mismatch at C[%0d][%0d]: got %0d, expected %0d",
                           i, j, read_signed, mat_c_expected[i][j]);
                end
            end
        end

        if (errors == 0)
            $display("[TB] PASS - all %0d elements of C match", M*L);
        else
            $display("[TB] FAIL - %0d mismatches out of %0d elements", errors, M*L);

        $display("[TB] Simulation finished");
        $finish;
    end : stim_proc

endmodule
