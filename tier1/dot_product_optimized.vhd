----------------------------------------------------------------------------------
-- Author: Federica Sarnataro
-- Module Name: dot_product_optimized - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: Computes the dot product of two LENGTH-element vectors
--   (DATA_WIDTH bits each) using a K_PARALLEL=4-wide multiply-accumulate
--   tree: 4 multipliers per cycle, 2-stage adder tree, accumulated across
--   NUM_SLICES = LENGTH/K_PARALLEL cycles. FSM: IDLE -> LOAD -> COMPUTE
--   (loops until all slices processed) -> DONE.
-- 

-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use ieee.math_real.all;



entity dot_product_optimized is
    generic (
        DATA_WIDTH : positive := 8;
        LENGTH     : positive := 8
    );
    port (
        clk_i      : in   std_logic;
        reset_i    : in   std_logic;
        start_i    : in   std_logic;
        vector_a_i : in   std_logic_vector(LENGTH*DATA_WIDTH-1 downto 0);
        vector_b_i : in   std_logic_vector(LENGTH*DATA_WIDTH-1 downto 0);
        result_o   : out  std_logic_vector(2*DATA_WIDTH + integer(ceil(log2(real(LENGTH))))-1 downto 0);
        done_o     : out  std_logic
    );
end dot_product_optimized;

architecture Behavioral of dot_product_optimized is
 
    constant ACC_WIDTH : positive := 2*DATA_WIDTH + integer(ceil(log2(real(LENGTH))));
    
    constant K_PARALLEL : positive := 4;
    constant NUM_SLICES : positive := LENGTH / K_PARALLEL;
 
    type state_t is (IDLE, LOAD, COMPUTE, DONE);
    signal state_q, state_d : state_t;
 
    signal load_en   : std_logic; 
    signal cnt_en    : std_logic; 
    signal acc_en    : std_logic; 
    signal acc_clr   : std_logic; 
    
    --now it no longer counts the individual elements of the vector.
    signal cnt_q : integer range 0 to NUM_SLICES-1;
    
    signal vector_a_q : std_logic_vector(LENGTH*DATA_WIDTH-1 downto 0); 
    signal vector_b_q : std_logic_vector(LENGTH*DATA_WIDTH-1 downto 0); 
    
    signal acc_q : signed(ACC_WIDTH-1 downto 0);
    

    -- a_slice will simultaneously contain the 4 elements extracted from vector A, and b_slice the 4 elements from vector B.    
    type slice_array is array (0 to K_PARALLEL-1) of signed(DATA_WIDTH-1 downto 0);
    signal a_slice, b_slice : slice_array;
    
    -- to contain the outputs of the mul
    type prod_array is array (0 to K_PARALLEL-1) of signed(2*DATA_WIDTH-1 downto 0);
    signal products : prod_array;
    
    --First stage of the tree, sum_stage1_0 receives the result of products(0) + products(1)
    signal sum_stage1_0 : signed(ACC_WIDTH-1 downto 0); -- sized with the max. possible width of the acc
    signal sum_stage1_1 : signed(ACC_WIDTH-1 downto 0);
    
    -- Second stage of the tree (the output)
    signal tree_output  : signed(ACC_WIDTH-1 downto 0); 
    
    --next_acc = tree_output + acc_q
    signal next_acc     : signed(ACC_WIDTH-1 downto 0); -- output of the extra adder

     
 
begin
 
    -- State register
    process(clk_i, reset_i)
    begin
        if reset_i = '1' then
            state_q <= IDLE;
        elsif rising_edge(clk_i) then
            state_q <= state_d;
        end if;
    end process;
 
    -- Next-state logic
    process(state_q, start_i, cnt_q)
    begin
        state_d <= state_q; 
        case state_q is
            when IDLE =>
                if start_i = '1' then
                    state_d <= LOAD;
                end if;
            when LOAD =>
                state_d <= COMPUTE;
            when COMPUTE =>
                if cnt_q = NUM_SLICES - 1 then
                    state_d <= DONE;
                else
                    state_d <= COMPUTE;
                end if;
            when DONE =>
                state_d <= IDLE;
        end case;
    end process;
 
    -- Control signals logic
    load_en <= '1' when state_q = LOAD else '0';
    acc_clr <= '1' when state_q = LOAD else '0';
    acc_en  <= '1' when state_q = COMPUTE else '0';
    cnt_en  <= '1' when (state_q = COMPUTE and cnt_q < NUM_SLICES - 1) else '0';
 
    -- Input vector registers
    process(clk_i, reset_i)
    begin
        if reset_i = '1' then
            vector_a_q <= (others => '0');
            vector_b_q <= (others => '0');
        elsif rising_edge(clk_i) then
            if load_en = '1' then
                vector_a_q <= vector_a_i;
                vector_b_q <= vector_b_i;
            end if;
        end if;
    end process;

    -- Element counter
    process(clk_i, reset_i)
    begin
        if reset_i = '1' then
            cnt_q <= 0;
        elsif rising_edge(clk_i) then
            if load_en = '1' then
                cnt_q <= 0;
            elsif cnt_en = '1' then
                cnt_q <= cnt_q + 1;
            end if;
        end if;
    end process;
 
 
    -- multiplexer that selects a slice of 4 elements
    process(cnt_q, vector_a_q, vector_b_q)
        variable base_idx : integer;
    begin
        base_idx := cnt_q * K_PARALLEL; --starting index of the slice: 0*4,1*4
        
        for i in 0 to K_PARALLEL-1 loop
            --i = 0->(0+0+1)×8−1=7 to (0+0)×8=0
            a_slice(i) <= signed(vector_a_q((base_idx + i + 1)*DATA_WIDTH-1 downto (base_idx + i)*DATA_WIDTH)); 
            b_slice(i) <= signed(vector_b_q((base_idx + i + 1)*DATA_WIDTH-1 downto (base_idx + i)*DATA_WIDTH));
        end loop;
    end process;
 
    -- instantiating four physical hardware multipliers
    products(0) <= a_slice(0) * b_slice(0);
    products(1) <= a_slice(1) * b_slice(1);
    products(2) <= a_slice(2) * b_slice(2);
    products(3) <= a_slice(3) * b_slice(3);
 
    -- first stage
    sum_stage1_0 <= resize(products(0), ACC_WIDTH) + resize(products(1), ACC_WIDTH);
    sum_stage1_1 <= resize(products(2), ACC_WIDTH) + resize(products(3), ACC_WIDTH);
    
    tree_output <= sum_stage1_0 + sum_stage1_1;
 
    -- Extra adder before the register
    next_acc <= tree_output + acc_q;
 
    -- Accumulator register
    process(clk_i, reset_i)
    begin
        if reset_i = '1' then
            acc_q <= (others => '0');
        elsif rising_edge(clk_i) then
            if acc_clr = '1' then
                acc_q <= (others => '0');
            elsif acc_en = '1' then
                acc_q <= next_acc;--directly load the calculated value
            end if;
        end if;
    end process;
 
    -- Outputs
    result_o <= std_logic_vector(acc_q);
    done_o   <= '1' when state_q = DONE else '0';
 
end Behavioral;
