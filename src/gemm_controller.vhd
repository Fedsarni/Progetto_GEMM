----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 07/20/2026 08:10:43 AM
-- Design Name: 
-- Module Name: gemm_controller - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
 
entity gemm_controller is
    generic (
        M : positive := 4;   -- number of rows of A 
        L : positive := 4    -- number of columns of B 
    );
    port (
        clk_i        : in  std_logic;
        reset_i      : in  std_logic;
        start_i      : in  std_logic;
        done_o       : out std_logic;
 
        -- current indices
        cont_i_o     : out integer range 0 to M-1;
        cont_j_o     : out integer range 0 to L-1;
 
        -- dot_product signal
        dp_start_o   : out std_logic;
        dp_done_i    : in  std_logic;
 
        -- to LSU C, write into C[i][j]
        write_en_o   : out std_logic;

        -- to the M_AXI engine: request to fetch A and B, held high for the
        -- whole LOAD state (was: the old lsu_en_i wiring used dp_start,
        -- which only pulses in START_DP -- too late to trigger the fetch
        -- that LOAD is now waiting on)
        mem_req_o : out std_logic;

        -- from the M_AXI engine: replaces the old fixed 1-cycle wait.
        -- mem_ab_valid_i: high when both A and B have arrived from memory
        -- mem_c_done_i  : high when the write of C has been acknowledged (BVALID)
        mem_ab_valid_i : in std_logic;
        mem_c_done_i   : in std_logic
    );
end gemm_controller;
 
architecture Behavioral of gemm_controller is
 
    type state_t is (IDLE, LOAD, START_DP, WAIT_DONE, WRITE, DONE_ST);
    signal state_q, state_d : state_t;
 
    signal cont_i_q, cont_i_d : integer range 0 to M-1;
    signal cont_j_q, cont_j_d : integer range 0 to L-1;
 
begin
 
    -- State and counter registers
    process(clk_i, reset_i)
    begin
        if reset_i = '1' then
            state_q  <= IDLE;
            cont_i_q <= 0;
            cont_j_q <= 0;
        elsif rising_edge(clk_i) then
            if state_d /= state_q then
                report "gemm_controller: " & state_t'image(state_q) & " -> " & state_t'image(state_d) &
                       " (i=" & integer'image(cont_i_d) & " j=" & integer'image(cont_j_d) & ")";
            end if;
            state_q  <= state_d;
            cont_i_q <= cont_i_d;
            cont_j_q <= cont_j_d;
        end if;
    end process;
 
    -- Next-state and output logic
    process(state_q, start_i, dp_done_i, cont_i_q, cont_j_q, mem_ab_valid_i, mem_c_done_i)
    begin

        state_d    <= state_q;
        cont_i_d   <= cont_i_q;
        cont_j_d   <= cont_j_q;
        dp_start_o <= '0';
        write_en_o <= '0';
        done_o     <= '0';
        mem_req_o  <= '0';
 
        case state_q is
 
            when IDLE =>
                cont_i_d <= 0;
                cont_j_d <= 0;
                if start_i = '1' then
                    state_d <= LOAD;
                end if;
 
            when LOAD =>
                -- hold the request to memory active for as long as we're
                -- waiting: this is what actually triggers the M_AXI engine
                -- to go fetch A and B (was: no request signal existed here
                -- at all, since lsu_en_i used to be driven by dp_start)
                mem_req_o <= '1';
                if mem_ab_valid_i = '1' then
                    state_d <= START_DP;
                end if;
 
            when START_DP =>
                dp_start_o <= '1';   
                state_d    <= WAIT_DONE;
 
            when WAIT_DONE =>
                if dp_done_i = '1' then
                    state_d <= WRITE;
                end if;
 
            when WRITE =>
                write_en_o <= '1'; 

                -- only move on once the write of C has actually been
                -- acknowledged by memory (was: assumed done after 1 cycle)
                if mem_c_done_i = '1' then
                    if (cont_i_q = M-1) and (cont_j_q = L-1) then
                        state_d <= DONE_ST;
                    else
                        state_d <= LOAD;
                        if cont_j_q = L-1 then
                            cont_j_d <= 0;
                            cont_i_d <= cont_i_q + 1;
                        else
                            cont_j_d <= cont_j_q + 1;
                        end if;
                    end if;
                end if;
 
            when DONE_ST =>
                done_o  <= '1';
                state_d <= IDLE;   -- ready to accept a new start_i 
 
        end case;
    end process;
 
    cont_i_o <= cont_i_q;
    cont_j_o <= cont_j_q;
 
end Behavioral;
