----------------------------------------------------------------------------------
-- Author: Federica
-- Package Name: gemm_axi_ip_components_pkg
-- Description:
--   Shared component declarations (and matching address-width constants) for
--   the Vivado-generated IP blocks reused, unmodified, across every Tier-2
--   GEMM wrapper (simulation, Pynq-Z1 PL-only, ...):
--     - 1x AXI crossbar (2 slave ports -> 4 master ports)
--     - 3x AXI BRAM Controller (BRAM A / B / C)
--     - 3x Block Memory Generator (BRAM A / B / C)
--   together with the fixed 0x0000/0x1000/0x2000/0x3000 4 KB-per-slave
--   address map these components imply.
--
--   Only the "master" side of the crossbar (AXI VIP for simulation,
--   JTAG-to-AXI Master for Pynq-Z1 PL-only hardware, ...) is wrapper-
--   specific and stays declared locally in each wrapper, together with any
--   clock/reset generation logic.
--
--   NOTE on binding style: these are "component ... end component"
--   declarations (default binding), NOT "entity work.X". This matches
--   gemm_top_sim_wrapper's Revision 0.02 note: explicit "entity work.X"
--   binding on Tcl-generated IP reproducibly crashed the XSim kernel inside
--   blk_mem_gen's behavioural model after repeated project/IP rebuilds,
--   while component-based default binding did not. Keep this style for any
--   IP declared here.
--
-- Revision:
-- Revision 0.01 - File Created (factored out of gemm_top_sim_wrapper.vhd)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package gemm_axi_ip_components_pkg is

    ----------------------------------------------------------------------
    -- Address map widths
    ----------------------------------------------------------------------
    -- BRAM word-address widths, as seen by blk_mem_gen (one 32-bit word
    -- per address; 2**10 = 1024 words per memory)
    constant BRAM_A_ADDR_WIDTH : positive := 10;
    constant BRAM_B_ADDR_WIDTH : positive := 10;
    constant BRAM_C_ADDR_WIDTH : positive := 10;

    -- BRAM byte-address widths, as seen on the AXI side through
    -- axi_bram_ctrl (BRAM_x_ADDR_WIDTH + 2 for word->byte). This is what
    -- defines the 4 KB (0x1000) per-slave window in the crossbar's
    -- 0x0000/0x1000/0x2000/0x3000 address map.
    constant BRAM_A_AXI_ADDR_WIDTH : positive := 12;
    constant BRAM_B_AXI_ADDR_WIDTH : positive := 12;
    constant BRAM_C_AXI_ADDR_WIDTH : positive := 12;

    ----------------------------------------------------------------------
    -- AXI crossbar: 2 slave ports (master IP + gemm_top's M_AXI),
    -- 4 master ports (BRAM A, BRAM B, BRAM C, gemm_top's S_AXI)
    ----------------------------------------------------------------------
    component axi_crossbar_0
        port (
            aclk    : in std_logic;
            aresetn : in std_logic;

            s_axi_awaddr  : in  std_logic_vector(63 downto 0);
            s_axi_awprot  : in  std_logic_vector(5 downto 0);
            s_axi_awvalid : in  std_logic_vector(1 downto 0);
            s_axi_awready : out std_logic_vector(1 downto 0);
            s_axi_wdata   : in  std_logic_vector(63 downto 0);
            s_axi_wstrb   : in  std_logic_vector(7 downto 0);
            s_axi_wvalid  : in  std_logic_vector(1 downto 0);
            s_axi_wready  : out std_logic_vector(1 downto 0);
            s_axi_bresp   : out std_logic_vector(3 downto 0);
            s_axi_bvalid  : out std_logic_vector(1 downto 0);
            s_axi_bready  : in  std_logic_vector(1 downto 0);
            s_axi_araddr  : in  std_logic_vector(63 downto 0);
            s_axi_arprot  : in  std_logic_vector(5 downto 0);
            s_axi_arvalid : in  std_logic_vector(1 downto 0);
            s_axi_arready : out std_logic_vector(1 downto 0);
            s_axi_rdata   : out std_logic_vector(63 downto 0);
            s_axi_rresp   : out std_logic_vector(3 downto 0);
            s_axi_rvalid  : out std_logic_vector(1 downto 0);
            s_axi_rready  : in  std_logic_vector(1 downto 0);

            m_axi_awaddr  : out std_logic_vector(127 downto 0);
            m_axi_awprot  : out std_logic_vector(11 downto 0);
            m_axi_awvalid : out std_logic_vector(3 downto 0);
            m_axi_awready : in  std_logic_vector(3 downto 0);
            m_axi_wdata   : out std_logic_vector(127 downto 0);
            m_axi_wstrb   : out std_logic_vector(15 downto 0);
            m_axi_wvalid  : out std_logic_vector(3 downto 0);
            m_axi_wready  : in  std_logic_vector(3 downto 0);
            m_axi_bresp   : in  std_logic_vector(7 downto 0);
            m_axi_bvalid  : in  std_logic_vector(3 downto 0);
            m_axi_bready  : out std_logic_vector(3 downto 0);
            m_axi_araddr  : out std_logic_vector(127 downto 0);
            m_axi_arprot  : out std_logic_vector(11 downto 0);
            m_axi_arvalid : out std_logic_vector(3 downto 0);
            m_axi_arready : in  std_logic_vector(3 downto 0);
            m_axi_rdata   : in  std_logic_vector(127 downto 0);
            m_axi_rresp   : in  std_logic_vector(7 downto 0);
            m_axi_rvalid  : in  std_logic_vector(3 downto 0);
            m_axi_rready  : out std_logic_vector(3 downto 0)
        );
    end component;

    ----------------------------------------------------------------------
    -- AXI BRAM controllers (AXI4-Lite <-> native BRAM port), one per matrix
    ----------------------------------------------------------------------
    component axi_bram_ctrl_0
        port (
            s_axi_aclk    : in  std_logic;
            s_axi_aresetn : in  std_logic;
            s_axi_awaddr  : in  std_logic_vector(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_awprot  : in  std_logic_vector(2 downto 0);
            s_axi_awvalid : in  std_logic;
            s_axi_awready : out std_logic;
            s_axi_wdata   : in  std_logic_vector(31 downto 0);
            s_axi_wstrb   : in  std_logic_vector(3 downto 0);
            s_axi_wvalid  : in  std_logic;
            s_axi_wready  : out std_logic;
            s_axi_bresp   : out std_logic_vector(1 downto 0);
            s_axi_bvalid  : out std_logic;
            s_axi_bready  : in  std_logic;
            s_axi_araddr  : in  std_logic_vector(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_arprot  : in  std_logic_vector(2 downto 0);
            s_axi_arvalid : in  std_logic;
            s_axi_arready : out std_logic;
            s_axi_rdata   : out std_logic_vector(31 downto 0);
            s_axi_rresp   : out std_logic_vector(1 downto 0);
            s_axi_rvalid  : out std_logic;
            s_axi_rready  : in  std_logic;
            bram_addr_a   : out std_logic_vector(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
            bram_clk_a    : out std_logic;
            bram_en_a     : out std_logic;
            bram_we_a     : out std_logic_vector(3 downto 0);
            bram_wrdata_a : out std_logic_vector(31 downto 0);
            bram_rddata_a : in  std_logic_vector(31 downto 0)
        );
    end component;

    component axi_bram_ctrl_1
        port (
            s_axi_aclk    : in  std_logic;
            s_axi_aresetn : in  std_logic;
            s_axi_awaddr  : in  std_logic_vector(BRAM_B_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_awprot  : in  std_logic_vector(2 downto 0);
            s_axi_awvalid : in  std_logic;
            s_axi_awready : out std_logic;
            s_axi_wdata   : in  std_logic_vector(31 downto 0);
            s_axi_wstrb   : in  std_logic_vector(3 downto 0);
            s_axi_wvalid  : in  std_logic;
            s_axi_wready  : out std_logic;
            s_axi_bresp   : out std_logic_vector(1 downto 0);
            s_axi_bvalid  : out std_logic;
            s_axi_bready  : in  std_logic;
            s_axi_araddr  : in  std_logic_vector(BRAM_B_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_arprot  : in  std_logic_vector(2 downto 0);
            s_axi_arvalid : in  std_logic;
            s_axi_arready : out std_logic;
            s_axi_rdata   : out std_logic_vector(31 downto 0);
            s_axi_rresp   : out std_logic_vector(1 downto 0);
            s_axi_rvalid  : out std_logic;
            s_axi_rready  : in  std_logic;
            bram_addr_a   : out std_logic_vector(BRAM_B_AXI_ADDR_WIDTH-1 downto 0);
            bram_clk_a    : out std_logic;
            bram_en_a     : out std_logic;
            bram_we_a     : out std_logic_vector(3 downto 0);
            bram_wrdata_a : out std_logic_vector(31 downto 0);
            bram_rddata_a : in  std_logic_vector(31 downto 0)
        );
    end component;

    component axi_bram_ctrl_2
        port (
            s_axi_aclk    : in  std_logic;
            s_axi_aresetn : in  std_logic;
            s_axi_awaddr  : in  std_logic_vector(BRAM_C_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_awprot  : in  std_logic_vector(2 downto 0);
            s_axi_awvalid : in  std_logic;
            s_axi_awready : out std_logic;
            s_axi_wdata   : in  std_logic_vector(31 downto 0);
            s_axi_wstrb   : in  std_logic_vector(3 downto 0);
            s_axi_wvalid  : in  std_logic;
            s_axi_wready  : out std_logic;
            s_axi_bresp   : out std_logic_vector(1 downto 0);
            s_axi_bvalid  : out std_logic;
            s_axi_bready  : in  std_logic;
            s_axi_araddr  : in  std_logic_vector(BRAM_C_AXI_ADDR_WIDTH-1 downto 0);
            s_axi_arprot  : in  std_logic_vector(2 downto 0);
            s_axi_arvalid : in  std_logic;
            s_axi_arready : out std_logic;
            s_axi_rdata   : out std_logic_vector(31 downto 0);
            s_axi_rresp   : out std_logic_vector(1 downto 0);
            s_axi_rvalid  : out std_logic;
            s_axi_rready  : in  std_logic;
            bram_addr_a   : out std_logic_vector(BRAM_C_AXI_ADDR_WIDTH-1 downto 0);
            bram_clk_a    : out std_logic;
            bram_en_a     : out std_logic;
            bram_we_a     : out std_logic_vector(3 downto 0);
            bram_wrdata_a : out std_logic_vector(31 downto 0);
            bram_rddata_a : in  std_logic_vector(31 downto 0)
        );
    end component;

    ----------------------------------------------------------------------
    -- Block Memory Generator (behind each AXI BRAM controller)
    ----------------------------------------------------------------------
    component blk_mem_gen_0
        port (
            clka  : in  std_logic;
            ena   : in  std_logic;
            wea   : in  std_logic;
            addra : in  std_logic_vector(BRAM_A_ADDR_WIDTH-1 downto 0);
            dina  : in  std_logic_vector(31 downto 0);
            douta : out std_logic_vector(31 downto 0)
        );
    end component;

    component blk_mem_gen_1
        port (
            clka  : in  std_logic;
            ena   : in  std_logic;
            wea   : in  std_logic;
            addra : in  std_logic_vector(BRAM_B_ADDR_WIDTH-1 downto 0);
            dina  : in  std_logic_vector(31 downto 0);
            douta : out std_logic_vector(31 downto 0)
        );
    end component;

    component blk_mem_gen_2
        port (
            clka  : in  std_logic;
            ena   : in  std_logic;
            wea   : in  std_logic;
            addra : in  std_logic_vector(BRAM_C_ADDR_WIDTH-1 downto 0);
            dina  : in  std_logic_vector(31 downto 0);
            douta : out std_logic_vector(31 downto 0)
        );
    end component;

end package gemm_axi_ip_components_pkg;
