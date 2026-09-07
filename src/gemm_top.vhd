----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
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
use ieee.numeric_std.all;
use ieee.math_real.all;
 
entity gemm_top is
    generic (
        ELEM_WIDTH : positive := 8;   -- width of a single matrix element
        N          : positive := 8;   -- shared dimension (MxN, NxL)
        M          : positive := 8;   -- rows of A 
        L          : positive := 8;   -- columns of B

        C_S_AXI_ADDR_WIDTH : positive := 32;  
        C_S_AXI_DATA_WIDTH : positive := 32;

        C_M_AXI_ADDR_WIDTH : positive := 32;  -- M_AXI: access to A/B/C in memory
        C_M_AXI_DATA_WIDTH : positive := 32
    );
    port (
        clk_i   : in  std_logic;
        reset_i : in  std_logic;

        -- AXI4-Lite slave: control/configuration registers 
        --(start/done, A/B/C base addresses). 
        s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        -- M_AXI: AXI4-Lite master to external memory (A, B, C).
        m_axi_awaddr  : out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
        m_axi_awvalid : out std_logic;
        m_axi_awready : in  std_logic;
        m_axi_wdata   : out std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
        m_axi_wstrb   : out std_logic_vector((C_M_AXI_DATA_WIDTH/8)-1 downto 0);
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        m_axi_bresp   : in  std_logic_vector(1 downto 0);
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic;
        m_axi_araddr  : out std_logic_vector(C_M_AXI_ADDR_WIDTH-1 downto 0);
        m_axi_arvalid : out std_logic;
        m_axi_arready : in  std_logic;
        m_axi_rdata   : in  std_logic_vector(C_M_AXI_DATA_WIDTH-1 downto 0);
        m_axi_rresp   : in  std_logic_vector(1 downto 0);
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic

    );
end gemm_top;
 
architecture Behavioral of gemm_top is
 
    -- width of one full row of A / one full column of B (packed together)
    constant ROW_WIDTH    : positive := N * ELEM_WIDTH;

    -- width of the dot_product result 
    constant RESULT_WIDTH : positive := 2*ELEM_WIDTH + integer(ceil(log2(real(N))));

    -- width of one word of SRAM C, rounded up to a whole number of bytes
    constant C_WORD_WIDTH : positive := ((RESULT_WIDTH+7)/8)*8;

    -- Controller <-> LSUs / dot_product
    signal cont_i     : integer range 0 to M-1;
    signal cont_j     : integer range 0 to L-1;
    signal dp_start   : std_logic;
    signal dp_done    : std_logic;
    signal write_en   : std_logic;

    -- LSU A/B <-> dot_product
    signal vector_a : std_logic_vector(ROW_WIDTH-1 downto 0);
    signal vector_b : std_logic_vector(ROW_WIDTH-1 downto 0);
    signal result   : std_logic_vector(RESULT_WIDTH-1 downto 0);
 
    -- Support signals for correctly mapping types to LSU C
    signal sram_c_index   : integer range 0 to (M*L)-1; --holds the calculated position where data is to be written in memory.
    signal result_resized : std_logic_vector(C_WORD_WIDTH-1 downto 0);--creates a vector of the exact width required by the SRAM C memory.

    -- start_i/done_o: now generated/read by the S_AXI block (axi4lite_ctrl_regs). 
    signal start_i : std_logic;
    signal done_o  : std_logic;

    -- A/B/C base addresses in memory, from the S_AXI block
    signal base_addr_a : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    signal base_addr_b : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    signal base_addr_c : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);

    -- bram_a/b/c_*: now they are internal signals connecting the LSUs to the M_AXI engine 
    signal bram_a_addr_o  : std_logic_vector(integer(ceil(log2(real(M))))-1 downto 0);
    signal bram_a_en_o    : std_logic;
    signal bram_a_rdata_i : std_logic_vector(N*ELEM_WIDTH-1 downto 0);

    signal bram_b_addr_o  : std_logic_vector(integer(ceil(log2(real(L))))-1 downto 0);
    signal bram_b_en_o    : std_logic;
    signal bram_b_rdata_i : std_logic_vector(N*ELEM_WIDTH-1 downto 0);

    signal bram_c_addr_o  : std_logic_vector(integer(ceil(log2(real(M*L))))-1 downto 0);
    signal bram_c_en_o    : std_logic;
    signal bram_c_we_o    : std_logic_vector(((((2*ELEM_WIDTH+integer(ceil(log2(real(N))))+7)/8)*8)/8)-1 downto 0); -- no longer used by the M_AXI engine (retained to avoid altering the underlying logic)
    signal bram_c_wdata_o : std_logic_vector(((2*ELEM_WIDTH+integer(ceil(log2(real(N))))+7)/8)*8-1 downto 0);

    -- gemm_controller <-> motore M_AXI
    signal mem_req  : std_logic; -- A/B read request, high for the entire LOAD
    signal ab_valid : std_logic; -- A and B ready.
    signal c_done   : std_logic; -- C write confirmed
 
begin

    ----------------------------------------------------------------------
    -- S_AXI: control/configuration registers
    ----------------------------------------------------------------------
    CTRL_REGS_INST: entity work.axi4lite_ctrl_regs
        generic map (
            C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH,
            C_S_AXI_DATA_WIDTH => C_S_AXI_DATA_WIDTH
        )
        port map (
            clk_i         => clk_i,
            reset_i       => reset_i,
            s_axi_awaddr  => s_axi_awaddr,
            s_axi_awvalid => s_axi_awvalid,
            s_axi_awready => s_axi_awready,
            s_axi_wdata   => s_axi_wdata,
            s_axi_wstrb   => s_axi_wstrb,
            s_axi_wvalid  => s_axi_wvalid,
            s_axi_wready  => s_axi_wready,
            s_axi_bresp   => s_axi_bresp,
            s_axi_bvalid  => s_axi_bvalid,
            s_axi_bready  => s_axi_bready,
            s_axi_araddr  => s_axi_araddr,
            s_axi_arvalid => s_axi_arvalid,
            s_axi_arready => s_axi_arready,
            s_axi_rdata   => s_axi_rdata,
            s_axi_rresp   => s_axi_rresp,
            s_axi_rvalid  => s_axi_rvalid,
            s_axi_rready  => s_axi_rready,
            start_o       => start_i,
            done_i        => done_o,
            base_addr_a_o => base_addr_a,
            base_addr_b_o => base_addr_b,
            base_addr_c_o => base_addr_c
        );

    -- linear index calculation and clean resizing of the result
    sram_c_index   <= (integer(cont_i) * integer(L)) + integer(cont_j); 
    result_resized <= std_logic_vector(resize(signed(result), C_WORD_WIDTH));
 
    ----------------------------------------------------------------------
    -- Controller
    ----------------------------------------------------------------------
    CTRL: entity work.gemm_controller
        generic map (
            M => M,
            L => L
        )
        port map (
            clk_i          => clk_i,
            reset_i        => reset_i,
            start_i        => start_i,
            done_o         => done_o,
            cont_i_o       => cont_i,
            cont_j_o       => cont_j,
            dp_start_o     => dp_start,
            dp_done_i      => dp_done,
            write_en_o     => write_en,
            mem_req_o      => mem_req,
            mem_ab_valid_i => ab_valid,
            mem_c_done_i   => c_done
        );
 
    ----------------------------------------------------------------------
    -- LSU A + M_AXI engine (reads one row of A per request, via AXI)
    ----------------------------------------------------------------------
    LSU_A_INST: entity work.lsu
        generic map (
            WORDS      => M,
            DATA_WIDTH => ROW_WIDTH
        )
        port map (
            lsu_en_i    => mem_req,         -- was dp_start; see note above CTRL_REGS_INST
            addr_idx_i  => cont_i,
            sram_addr_o => bram_a_addr_o,   -- straight to the new output port
            sram_cs_o   => bram_a_en_o,     -- straight to the new output port
            data_in_i   => bram_a_rdata_i,  -- data now comes from outside gemm_top
            data_out_o  => vector_a
        );
 
    ----------------------------------------------------------------------
    -- LSU B + M_AXI engine (reads one column of B per request, via AXI) 
    ----------------------------------------------------------------------
    LSU_B_INST: entity work.lsu
        generic map (
            WORDS      => L,
            DATA_WIDTH => ROW_WIDTH
        )
        port map (
            lsu_en_i    => mem_req,         
            addr_idx_i  => cont_j,
            sram_addr_o => bram_b_addr_o,   
            sram_cs_o   => bram_b_en_o,     
            data_in_i   => bram_b_rdata_i, 
            data_out_o  => vector_b
        );
 
    ----------------------------------------------------------------------
    -- dot_product 
    ----------------------------------------------------------------------
    DP_INST: entity work.dot_product_optimized
        generic map (
            DATA_WIDTH => ELEM_WIDTH,
            LENGTH     => N
        )
        port map (
            clk_i      => clk_i,
            reset_i    => reset_i,
            start_i    => dp_start,
            vector_a_i => vector_a,
            vector_b_i => vector_b,
            result_o   => result,
            done_o     => dp_done
        );
 
    ----------------------------------------------------------------------
    -- LSU C + M_AXI engine (writes one word of C per request, via AXI)
    ----------------------------------------------------------------------
    LSU_C_INST: entity work.lsu
        generic map (
            WORDS      => M*L,
            DATA_WIDTH => C_WORD_WIDTH
        )
        port map (
            lsu_en_i    => write_en,
            addr_idx_i  => sram_c_index,
            sram_addr_o => bram_c_addr_o,   
            sram_cs_o   => bram_c_en_o,     
            data_in_i   => result_resized,
            data_out_o  => bram_c_wdata_o  
        );

    -- byte write enable now goes straight to the output port
    bram_c_we_o <= (others => '1') when write_en = '1' else (others => '0');

    ----------------------------------------------------------------------
    -- M_AXI: engine that translates LSU_A/B/C requests into AXI4-Lite transactions
    -- to external memory
    ----------------------------------------------------------------------
    AXI_ENGINE_INST: entity work.axi_master_engine
        generic map (
            ROW_WIDTH        => ROW_WIDTH,
            C_WORD_WIDTH     => C_WORD_WIDTH,
            M                => M,
            L                => L,
            M_AXI_ADDR_WIDTH => C_M_AXI_ADDR_WIDTH,
            M_AXI_DATA_WIDTH => C_M_AXI_DATA_WIDTH
        )
        port map (
            clk_i         => clk_i,
            reset_i       => reset_i,

            m_axi_awaddr  => m_axi_awaddr,
            m_axi_awvalid => m_axi_awvalid,
            m_axi_awready => m_axi_awready,
            m_axi_wdata   => m_axi_wdata,
            m_axi_wstrb   => m_axi_wstrb,
            m_axi_wvalid  => m_axi_wvalid,
            m_axi_wready  => m_axi_wready,
            m_axi_bresp   => m_axi_bresp,
            m_axi_bvalid  => m_axi_bvalid,
            m_axi_bready  => m_axi_bready,
            m_axi_araddr  => m_axi_araddr,
            m_axi_arvalid => m_axi_arvalid,
            m_axi_arready => m_axi_arready,
            m_axi_rdata   => m_axi_rdata,
            m_axi_rresp   => m_axi_rresp,
            m_axi_rvalid  => m_axi_rvalid,
            m_axi_rready  => m_axi_rready,

            base_addr_a_i => base_addr_a,
            base_addr_b_i => base_addr_b,
            base_addr_c_i => base_addr_c,

            req_ab_i   => bram_a_en_o,   -- = mem_req (LSU_A/B passthrough)
            idx_a_i    => cont_i,
            idx_b_i    => cont_j,
            vector_a_o => bram_a_rdata_i,
            vector_b_o => bram_b_rdata_i,
            ab_valid_o => ab_valid,

            req_c_i   => bram_c_en_o,    -- = write_en (LSU_C passthrough)
            idx_c_i   => sram_c_index,
            wdata_c_i => bram_c_wdata_o,
            c_done_o  => c_done
        );

end Behavioral;