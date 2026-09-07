----------------------------------------------------------------------------------
-- Author: Federica
-- Module Name: gemm_top_sim_wrapper - structural
-- Description:
--   [Tier 2] Simulation test wrapper for gemm_top: DUT + AXI VIP (master) +
--   AXI crossbar + BRAM A/B/C, per the "Three-tier Verification
--   Architecture" section of the internal RTL Coding/Design/Verification
--   guide.
--
--   IP instantiation uses "component ... end component" (implicit/
--   default binding), NOT "entity work.X": in this project, after many
--   rebuilds of the same project/IP-instance names, explicit "entity
--   work.X" binding triggered a reproducible XSim kernel crash inside
--   blk_mem_gen's behavioural simulation model (FATAL_ERROR at
--   blk_mem_gen_v8_4.v:3300, Time 0 / Iteration 0), while the same
--   design elaborates and simulates correctly with component-based
--   default binding. Root cause not fully confirmed, but suspected: the
--   "work" library may have held a stale/mismatched compiled entity from
--   an earlier IP configuration that explicit "entity work.X" bound to
--   directly, while default binding re-resolves through the current
--   compile order instead. gemm_top itself is still instantiated via
--   "entity work.gemm_top" (that one caused no issues -- it's plain
--   project RTL, not Tcl-generated IP).
--
-- Revision:
-- Revision 0.02 - Reverted IP instantiation to component-based binding
--                 (fixes XSim kernel crash). Fixed VIP hierarchical path
--                 case (DUT.AXI_VIP_INST, not DUT.axi_vip_inst).
-- Revision 0.01 - File Created
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gemm_top_sim_wrapper is
    generic (
        ELEM_WIDTH : positive := 8;
        N          : positive := 8;
        M          : positive := 8;
        L          : positive := 8;

        C_S_AXI_ADDR_WIDTH : positive := 32;
        C_S_AXI_DATA_WIDTH : positive := 32;
        C_M_AXI_ADDR_WIDTH : positive := 32;
        C_M_AXI_DATA_WIDTH : positive := 32
    );
    port (
        clk100mhz_i : in std_logic;
        ck_rst_ni   : in std_logic
    );
end gemm_top_sim_wrapper;

architecture structural of gemm_top_sim_wrapper is

    constant BRAM_A_ADDR_WIDTH : positive := 10;
    constant BRAM_B_ADDR_WIDTH : positive := 10;
    constant BRAM_C_ADDR_WIDTH : positive := 10;

    constant BRAM_A_AXI_ADDR_WIDTH : positive := 12;
    constant BRAM_B_AXI_ADDR_WIDTH : positive := 12;
    constant BRAM_C_AXI_ADDR_WIDTH : positive := 12;

    signal clk_i   : std_logic;
    signal rst_ni  : std_logic;
    signal reset_i : std_logic;

    signal vip_awaddr  : std_logic_vector(31 downto 0);
    signal vip_awprot  : std_logic_vector(2 downto 0);
    signal vip_awvalid : std_logic;
    signal vip_awready : std_logic;
    signal vip_wdata   : std_logic_vector(31 downto 0);
    signal vip_wstrb   : std_logic_vector(3 downto 0);
    signal vip_wvalid  : std_logic;
    signal vip_wready  : std_logic;
    signal vip_bresp   : std_logic_vector(1 downto 0);
    signal vip_bvalid  : std_logic;
    signal vip_bready  : std_logic;
    signal vip_araddr  : std_logic_vector(31 downto 0);
    signal vip_arprot  : std_logic_vector(2 downto 0);
    signal vip_arvalid : std_logic;
    signal vip_arready : std_logic;
    signal vip_rdata   : std_logic_vector(31 downto 0);
    signal vip_rresp   : std_logic_vector(1 downto 0);
    signal vip_rvalid  : std_logic;
    signal vip_rready  : std_logic;

    signal gm_awaddr  : std_logic_vector(31 downto 0);
    signal gm_awvalid : std_logic;
    signal gm_awready : std_logic;
    signal gm_wdata   : std_logic_vector(31 downto 0);
    signal gm_wstrb   : std_logic_vector(3 downto 0);
    signal gm_wvalid  : std_logic;
    signal gm_wready  : std_logic;
    signal gm_bresp   : std_logic_vector(1 downto 0);
    signal gm_bvalid  : std_logic;
    signal gm_bready  : std_logic;
    signal gm_araddr  : std_logic_vector(31 downto 0);
    signal gm_arvalid : std_logic;
    signal gm_arready : std_logic;
    signal gm_rdata   : std_logic_vector(31 downto 0);
    signal gm_rresp   : std_logic_vector(1 downto 0);
    signal gm_rvalid  : std_logic;
    signal gm_rready  : std_logic;

    signal xbar_s_awaddr  : std_logic_vector(63 downto 0);
    signal xbar_s_awprot  : std_logic_vector(5 downto 0);
    signal xbar_s_awvalid : std_logic_vector(1 downto 0);
    signal xbar_s_awready : std_logic_vector(1 downto 0);
    signal xbar_s_wdata   : std_logic_vector(63 downto 0);
    signal xbar_s_wstrb   : std_logic_vector(7 downto 0);
    signal xbar_s_wvalid  : std_logic_vector(1 downto 0);
    signal xbar_s_wready  : std_logic_vector(1 downto 0);
    signal xbar_s_bresp   : std_logic_vector(3 downto 0);
    signal xbar_s_bvalid  : std_logic_vector(1 downto 0);
    signal xbar_s_bready  : std_logic_vector(1 downto 0);
    signal xbar_s_araddr  : std_logic_vector(63 downto 0);
    signal xbar_s_arprot  : std_logic_vector(5 downto 0);
    signal xbar_s_arvalid : std_logic_vector(1 downto 0);
    signal xbar_s_arready : std_logic_vector(1 downto 0);
    signal xbar_s_rdata   : std_logic_vector(63 downto 0);
    signal xbar_s_rresp   : std_logic_vector(3 downto 0);
    signal xbar_s_rvalid  : std_logic_vector(1 downto 0);
    signal xbar_s_rready  : std_logic_vector(1 downto 0);

    signal xbar_m_awaddr  : std_logic_vector(127 downto 0);
    signal xbar_m_awprot  : std_logic_vector(11 downto 0);
    signal xbar_m_awvalid : std_logic_vector(3 downto 0);
    signal xbar_m_awready : std_logic_vector(3 downto 0);
    signal xbar_m_wdata   : std_logic_vector(127 downto 0);
    signal xbar_m_wstrb   : std_logic_vector(15 downto 0);
    signal xbar_m_wvalid  : std_logic_vector(3 downto 0);
    signal xbar_m_wready  : std_logic_vector(3 downto 0);
    signal xbar_m_bresp   : std_logic_vector(7 downto 0);
    signal xbar_m_bvalid  : std_logic_vector(3 downto 0);
    signal xbar_m_bready  : std_logic_vector(3 downto 0);
    signal xbar_m_araddr  : std_logic_vector(127 downto 0);
    signal xbar_m_arprot  : std_logic_vector(11 downto 0);
    signal xbar_m_arvalid : std_logic_vector(3 downto 0);
    signal xbar_m_arready : std_logic_vector(3 downto 0);
    signal xbar_m_rdata   : std_logic_vector(127 downto 0);
    signal xbar_m_rresp   : std_logic_vector(7 downto 0);
    signal xbar_m_rvalid  : std_logic_vector(3 downto 0);
    signal xbar_m_rready  : std_logic_vector(3 downto 0);

    signal bram_a_awaddr : std_logic_vector(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_b_awaddr : std_logic_vector(BRAM_B_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_c_awaddr : std_logic_vector(BRAM_C_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_a_araddr : std_logic_vector(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_b_araddr : std_logic_vector(BRAM_B_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_c_araddr : std_logic_vector(BRAM_C_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_a_wdata,  bram_b_wdata,  bram_c_wdata  : std_logic_vector(31 downto 0);
    signal bram_a_wstrb,  bram_b_wstrb,  bram_c_wstrb  : std_logic_vector(3 downto 0);
    signal bram_a_rdata,  bram_b_rdata,  bram_c_rdata  : std_logic_vector(31 downto 0);
    signal bram_a_bresp,  bram_b_bresp,  bram_c_bresp  : std_logic_vector(1 downto 0);
    signal bram_a_rresp,  bram_b_rresp,  bram_c_rresp  : std_logic_vector(1 downto 0);
    signal bram_a_awvalid, bram_b_awvalid, bram_c_awvalid : std_logic;
    signal bram_a_awready, bram_b_awready, bram_c_awready : std_logic;
    signal bram_a_wvalid,  bram_b_wvalid,  bram_c_wvalid  : std_logic;
    signal bram_a_wready,  bram_b_wready,  bram_c_wready  : std_logic;
    signal bram_a_bvalid,  bram_b_bvalid,  bram_c_bvalid  : std_logic;
    signal bram_a_bready,  bram_b_bready,  bram_c_bready  : std_logic;
    signal bram_a_arvalid, bram_b_arvalid, bram_c_arvalid : std_logic;
    signal bram_a_arready, bram_b_arready, bram_c_arready : std_logic;
    signal bram_a_rvalid,  bram_b_rvalid,  bram_c_rvalid  : std_logic;
    signal bram_a_rready,  bram_b_rready,  bram_c_rready  : std_logic;

    signal gs_awaddr  : std_logic_vector(31 downto 0);
    signal gs_awvalid : std_logic;
    signal gs_awready : std_logic;
    signal gs_wdata   : std_logic_vector(31 downto 0);
    signal gs_wstrb   : std_logic_vector(3 downto 0);
    signal gs_wvalid  : std_logic;
    signal gs_wready  : std_logic;
    signal gs_bresp   : std_logic_vector(1 downto 0);
    signal gs_bvalid  : std_logic;
    signal gs_bready  : std_logic;
    signal gs_araddr  : std_logic_vector(31 downto 0);
    signal gs_arvalid : std_logic;
    signal gs_arready : std_logic;
    signal gs_rdata   : std_logic_vector(31 downto 0);
    signal gs_rresp   : std_logic_vector(1 downto 0);
    signal gs_rvalid  : std_logic;
    signal gs_rready  : std_logic;

    signal bram_a_ctrl_addr   : std_logic_vector(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_a_ctrl_clk    : std_logic;
    signal bram_a_ctrl_en     : std_logic;
    signal bram_a_ctrl_we     : std_logic_vector(3 downto 0);
    signal bram_a_ctrl_wrdata : std_logic_vector(31 downto 0);
    signal bram_a_ctrl_rddata : std_logic_vector(31 downto 0);

    signal bram_b_ctrl_addr   : std_logic_vector(BRAM_B_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_b_ctrl_clk    : std_logic;
    signal bram_b_ctrl_en     : std_logic;
    signal bram_b_ctrl_we     : std_logic_vector(3 downto 0);
    signal bram_b_ctrl_wrdata : std_logic_vector(31 downto 0);
    signal bram_b_ctrl_rddata : std_logic_vector(31 downto 0);

    signal bram_c_ctrl_addr   : std_logic_vector(BRAM_C_AXI_ADDR_WIDTH-1 downto 0);
    signal bram_c_ctrl_clk    : std_logic;
    signal bram_c_ctrl_en     : std_logic;
    signal bram_c_ctrl_we     : std_logic_vector(3 downto 0);
    signal bram_c_ctrl_wrdata : std_logic_vector(31 downto 0);
    signal bram_c_ctrl_rddata : std_logic_vector(31 downto 0);

    signal bram_a_wea1 : std_logic;
    signal bram_b_wea1 : std_logic;
    signal bram_c_wea1 : std_logic;

    component axi_vip_master_0
        port (
            aclk          : in  std_logic;
            aresetn       : in  std_logic;
            m_axi_awaddr  : out std_logic_vector(31 downto 0);
            m_axi_awprot  : out std_logic_vector(2 downto 0);
            m_axi_awvalid : out std_logic;
            m_axi_awready : in  std_logic;
            m_axi_wdata   : out std_logic_vector(31 downto 0);
            m_axi_wstrb   : out std_logic_vector(3 downto 0);
            m_axi_wvalid  : out std_logic;
            m_axi_wready  : in  std_logic;
            m_axi_bresp   : in  std_logic_vector(1 downto 0);
            m_axi_bvalid  : in  std_logic;
            m_axi_bready  : out std_logic;
            m_axi_araddr  : out std_logic_vector(31 downto 0);
            m_axi_arprot  : out std_logic_vector(2 downto 0);
            m_axi_arvalid : out std_logic;
            m_axi_arready : in  std_logic;
            m_axi_rdata   : in  std_logic_vector(31 downto 0);
            m_axi_rresp   : in  std_logic_vector(1 downto 0);
            m_axi_rvalid  : in  std_logic;
            m_axi_rready  : out std_logic
        );
    end component;

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

begin

    clk_i   <= clk100mhz_i;
    rst_ni  <= ck_rst_ni;
    reset_i <= not ck_rst_ni;

    AXI_VIP_INST: axi_vip_master_0
        port map (
            aclk          => clk_i,
            aresetn       => rst_ni,
            m_axi_awaddr  => vip_awaddr,
            m_axi_awprot  => vip_awprot,
            m_axi_awvalid => vip_awvalid,
            m_axi_awready => vip_awready,
            m_axi_wdata   => vip_wdata,
            m_axi_wstrb   => vip_wstrb,
            m_axi_wvalid  => vip_wvalid,
            m_axi_wready  => vip_wready,
            m_axi_bresp   => vip_bresp,
            m_axi_bvalid  => vip_bvalid,
            m_axi_bready  => vip_bready,
            m_axi_araddr  => vip_araddr,
            m_axi_arprot  => vip_arprot,
            m_axi_arvalid => vip_arvalid,
            m_axi_arready => vip_arready,
            m_axi_rdata   => vip_rdata,
            m_axi_rresp   => vip_rresp,
            m_axi_rvalid  => vip_rvalid,
            m_axi_rready  => vip_rready
        );

    xbar_s_awaddr  <= gm_awaddr  & vip_awaddr;
    xbar_s_awprot  <= "000"      & vip_awprot;
    xbar_s_awvalid <= gm_awvalid & vip_awvalid;
    vip_awready    <= xbar_s_awready(0);
    gm_awready     <= xbar_s_awready(1);

    xbar_s_wdata   <= gm_wdata  & vip_wdata;
    xbar_s_wstrb   <= gm_wstrb  & vip_wstrb;
    xbar_s_wvalid  <= gm_wvalid & vip_wvalid;
    vip_wready     <= xbar_s_wready(0);
    gm_wready      <= xbar_s_wready(1);

    vip_bresp      <= xbar_s_bresp(1 downto 0);
    gm_bresp       <= xbar_s_bresp(3 downto 2);
    vip_bvalid     <= xbar_s_bvalid(0);
    gm_bvalid      <= xbar_s_bvalid(1);
    xbar_s_bready  <= gm_bready & vip_bready;

    xbar_s_araddr  <= gm_araddr  & vip_araddr;
    xbar_s_arprot  <= "000"      & vip_arprot;
    xbar_s_arvalid <= gm_arvalid & vip_arvalid;
    vip_arready    <= xbar_s_arready(0);
    gm_arready     <= xbar_s_arready(1);

    vip_rdata      <= xbar_s_rdata(31 downto 0);
    gm_rdata       <= xbar_s_rdata(63 downto 32);
    vip_rresp      <= xbar_s_rresp(1 downto 0);
    gm_rresp       <= xbar_s_rresp(3 downto 2);
    vip_rvalid     <= xbar_s_rvalid(0);
    gm_rvalid      <= xbar_s_rvalid(1);
    xbar_s_rready  <= gm_rready & vip_rready;

    CROSSBAR_INST: axi_crossbar_0
        port map (
            aclk    => clk_i,
            aresetn => rst_ni,

            s_axi_awaddr  => xbar_s_awaddr,
            s_axi_awprot  => xbar_s_awprot,
            s_axi_awvalid => xbar_s_awvalid,
            s_axi_awready => xbar_s_awready,
            s_axi_wdata   => xbar_s_wdata,
            s_axi_wstrb   => xbar_s_wstrb,
            s_axi_wvalid  => xbar_s_wvalid,
            s_axi_wready  => xbar_s_wready,
            s_axi_bresp   => xbar_s_bresp,
            s_axi_bvalid  => xbar_s_bvalid,
            s_axi_bready  => xbar_s_bready,
            s_axi_araddr  => xbar_s_araddr,
            s_axi_arprot  => xbar_s_arprot,
            s_axi_arvalid => xbar_s_arvalid,
            s_axi_arready => xbar_s_arready,
            s_axi_rdata   => xbar_s_rdata,
            s_axi_rresp   => xbar_s_rresp,
            s_axi_rvalid  => xbar_s_rvalid,
            s_axi_rready  => xbar_s_rready,

            m_axi_awaddr  => xbar_m_awaddr,
            m_axi_awprot  => xbar_m_awprot,
            m_axi_awvalid => xbar_m_awvalid,
            m_axi_awready => xbar_m_awready,
            m_axi_wdata   => xbar_m_wdata,
            m_axi_wstrb   => xbar_m_wstrb,
            m_axi_wvalid  => xbar_m_wvalid,
            m_axi_wready  => xbar_m_wready,
            m_axi_bresp   => xbar_m_bresp,
            m_axi_bvalid  => xbar_m_bvalid,
            m_axi_bready  => xbar_m_bready,
            m_axi_araddr  => xbar_m_araddr,
            m_axi_arprot  => xbar_m_arprot,
            m_axi_arvalid => xbar_m_arvalid,
            m_axi_arready => xbar_m_arready,
            m_axi_rdata   => xbar_m_rdata,
            m_axi_rresp   => xbar_m_rresp,
            m_axi_rvalid  => xbar_m_rvalid,
            m_axi_rready  => xbar_m_rready
        );

    bram_a_awaddr <= xbar_m_awaddr(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
    bram_b_awaddr <= xbar_m_awaddr(32+BRAM_B_AXI_ADDR_WIDTH-1 downto 32);
    bram_c_awaddr <= xbar_m_awaddr(64+BRAM_C_AXI_ADDR_WIDTH-1 downto 64);
    gs_awaddr     <= xbar_m_awaddr(127 downto 96);

    bram_a_awvalid <= xbar_m_awvalid(0);
    bram_b_awvalid <= xbar_m_awvalid(1);
    bram_c_awvalid <= xbar_m_awvalid(2);
    gs_awvalid     <= xbar_m_awvalid(3);

    xbar_m_awready <= gs_awready & bram_c_awready & bram_b_awready & bram_a_awready;

    bram_a_wdata <= xbar_m_wdata(31 downto 0);
    bram_b_wdata <= xbar_m_wdata(63 downto 32);
    bram_c_wdata <= xbar_m_wdata(95 downto 64);
    gs_wdata     <= xbar_m_wdata(127 downto 96);

    bram_a_wstrb <= xbar_m_wstrb(3 downto 0);
    bram_b_wstrb <= xbar_m_wstrb(7 downto 4);
    bram_c_wstrb <= xbar_m_wstrb(11 downto 8);
    gs_wstrb     <= xbar_m_wstrb(15 downto 12);

    bram_a_wvalid <= xbar_m_wvalid(0);
    bram_b_wvalid <= xbar_m_wvalid(1);
    bram_c_wvalid <= xbar_m_wvalid(2);
    gs_wvalid     <= xbar_m_wvalid(3);

    xbar_m_wready <= gs_wready & bram_c_wready & bram_b_wready & bram_a_wready;

    xbar_m_bresp  <= gs_bresp & bram_c_bresp & bram_b_bresp & bram_a_bresp;
    xbar_m_bvalid <= gs_bvalid & bram_c_bvalid & bram_b_bvalid & bram_a_bvalid;

    bram_a_bready <= xbar_m_bready(0);
    bram_b_bready <= xbar_m_bready(1);
    bram_c_bready <= xbar_m_bready(2);
    gs_bready     <= xbar_m_bready(3);

    bram_a_araddr <= xbar_m_araddr(BRAM_A_AXI_ADDR_WIDTH-1 downto 0);
    bram_b_araddr <= xbar_m_araddr(32+BRAM_B_AXI_ADDR_WIDTH-1 downto 32);
    bram_c_araddr <= xbar_m_araddr(64+BRAM_C_AXI_ADDR_WIDTH-1 downto 64);
    gs_araddr     <= xbar_m_araddr(127 downto 96);

    bram_a_arvalid <= xbar_m_arvalid(0);
    bram_b_arvalid <= xbar_m_arvalid(1);
    bram_c_arvalid <= xbar_m_arvalid(2);
    gs_arvalid     <= xbar_m_arvalid(3);

    xbar_m_arready <= gs_arready & bram_c_arready & bram_b_arready & bram_a_arready;

    xbar_m_rdata  <= gs_rdata & bram_c_rdata & bram_b_rdata & bram_a_rdata;
    xbar_m_rresp  <= gs_rresp & bram_c_rresp & bram_b_rresp & bram_a_rresp;
    xbar_m_rvalid <= gs_rvalid & bram_c_rvalid & bram_b_rvalid & bram_a_rvalid;

    bram_a_rready <= xbar_m_rready(0);
    bram_b_rready <= xbar_m_rready(1);
    bram_c_rready <= xbar_m_rready(2);
    gs_rready     <= xbar_m_rready(3);

    bram_a_wea1 <= bram_a_ctrl_we(0) or bram_a_ctrl_we(1) or bram_a_ctrl_we(2) or bram_a_ctrl_we(3);
    bram_b_wea1 <= bram_b_ctrl_we(0) or bram_b_ctrl_we(1) or bram_b_ctrl_we(2) or bram_b_ctrl_we(3);
    bram_c_wea1 <= bram_c_ctrl_we(0) or bram_c_ctrl_we(1) or bram_c_ctrl_we(2) or bram_c_ctrl_we(3);

    BRAM_A_CTRL_INST: axi_bram_ctrl_0
        port map (
            s_axi_aclk    => clk_i,
            s_axi_aresetn => rst_ni,
            s_axi_awaddr  => bram_a_awaddr,
            s_axi_awprot  => (others => '0'),
            s_axi_awvalid => bram_a_awvalid,
            s_axi_awready => bram_a_awready,
            s_axi_wdata   => bram_a_wdata,
            s_axi_wstrb   => bram_a_wstrb,
            s_axi_wvalid  => bram_a_wvalid,
            s_axi_wready  => bram_a_wready,
            s_axi_bresp   => bram_a_bresp,
            s_axi_bvalid  => bram_a_bvalid,
            s_axi_bready  => bram_a_bready,
            s_axi_araddr  => bram_a_araddr,
            s_axi_arprot  => (others => '0'),
            s_axi_arvalid => bram_a_arvalid,
            s_axi_arready => bram_a_arready,
            s_axi_rdata   => bram_a_rdata,
            s_axi_rresp   => bram_a_rresp,
            s_axi_rvalid  => bram_a_rvalid,
            s_axi_rready  => bram_a_rready,
            bram_addr_a   => bram_a_ctrl_addr,
            bram_clk_a    => bram_a_ctrl_clk,
            bram_en_a     => bram_a_ctrl_en,
            bram_we_a     => bram_a_ctrl_we,
            bram_wrdata_a => bram_a_ctrl_wrdata,
            bram_rddata_a => bram_a_ctrl_rddata
        );

    BRAM_A_MEM_INST: blk_mem_gen_0
        port map (
            clka  => bram_a_ctrl_clk,
            ena   => bram_a_ctrl_en,
            wea   => bram_a_wea1,
            addra => bram_a_ctrl_addr(2+BRAM_A_ADDR_WIDTH-1 downto 2),
            dina  => bram_a_ctrl_wrdata,
            douta => bram_a_ctrl_rddata
        );

    BRAM_B_CTRL_INST: axi_bram_ctrl_1
        port map (
            s_axi_aclk    => clk_i,
            s_axi_aresetn => rst_ni,
            s_axi_awaddr  => bram_b_awaddr,
            s_axi_awprot  => (others => '0'),
            s_axi_awvalid => bram_b_awvalid,
            s_axi_awready => bram_b_awready,
            s_axi_wdata   => bram_b_wdata,
            s_axi_wstrb   => bram_b_wstrb,
            s_axi_wvalid  => bram_b_wvalid,
            s_axi_wready  => bram_b_wready,
            s_axi_bresp   => bram_b_bresp,
            s_axi_bvalid  => bram_b_bvalid,
            s_axi_bready  => bram_b_bready,
            s_axi_araddr  => bram_b_araddr,
            s_axi_arprot  => (others => '0'),
            s_axi_arvalid => bram_b_arvalid,
            s_axi_arready => bram_b_arready,
            s_axi_rdata   => bram_b_rdata,
            s_axi_rresp   => bram_b_rresp,
            s_axi_rvalid  => bram_b_rvalid,
            s_axi_rready  => bram_b_rready,
            bram_addr_a   => bram_b_ctrl_addr,
            bram_clk_a    => bram_b_ctrl_clk,
            bram_en_a     => bram_b_ctrl_en,
            bram_we_a     => bram_b_ctrl_we,
            bram_wrdata_a => bram_b_ctrl_wrdata,
            bram_rddata_a => bram_b_ctrl_rddata
        );

    BRAM_B_MEM_INST: blk_mem_gen_1
        port map (
            clka  => bram_b_ctrl_clk,
            ena   => bram_b_ctrl_en,
            wea   => bram_b_wea1,
            addra => bram_b_ctrl_addr(2+BRAM_B_ADDR_WIDTH-1 downto 2),
            dina  => bram_b_ctrl_wrdata,
            douta => bram_b_ctrl_rddata
        );

    BRAM_C_CTRL_INST: axi_bram_ctrl_2
        port map (
            s_axi_aclk    => clk_i,
            s_axi_aresetn => rst_ni,
            s_axi_awaddr  => bram_c_awaddr,
            s_axi_awprot  => (others => '0'),
            s_axi_awvalid => bram_c_awvalid,
            s_axi_awready => bram_c_awready,
            s_axi_wdata   => bram_c_wdata,
            s_axi_wstrb   => bram_c_wstrb,
            s_axi_wvalid  => bram_c_wvalid,
            s_axi_wready  => bram_c_wready,
            s_axi_bresp   => bram_c_bresp,
            s_axi_bvalid  => bram_c_bvalid,
            s_axi_bready  => bram_c_bready,
            s_axi_araddr  => bram_c_araddr,
            s_axi_arprot  => (others => '0'),
            s_axi_arvalid => bram_c_arvalid,
            s_axi_arready => bram_c_arready,
            s_axi_rdata   => bram_c_rdata,
            s_axi_rresp   => bram_c_rresp,
            s_axi_rvalid  => bram_c_rvalid,
            s_axi_rready  => bram_c_rready,
            bram_addr_a   => bram_c_ctrl_addr,
            bram_clk_a    => bram_c_ctrl_clk,
            bram_en_a     => bram_c_ctrl_en,
            bram_we_a     => bram_c_ctrl_we,
            bram_wrdata_a => bram_c_ctrl_wrdata,
            bram_rddata_a => bram_c_ctrl_rddata
        );

    BRAM_C_MEM_INST: blk_mem_gen_2
        port map (
            clka  => bram_c_ctrl_clk,
            ena   => bram_c_ctrl_en,
            wea   => bram_c_wea1,
            addra => bram_c_ctrl_addr(2+BRAM_C_ADDR_WIDTH-1 downto 2),
            dina  => bram_c_ctrl_wrdata,
            douta => bram_c_ctrl_rddata
        );

    GEMM_TOP_INST: entity work.gemm_top
        generic map (
            ELEM_WIDTH => ELEM_WIDTH,
            N          => N,
            M          => M,
            L          => L,
            C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH,
            C_S_AXI_DATA_WIDTH => C_S_AXI_DATA_WIDTH,
            C_M_AXI_ADDR_WIDTH => C_M_AXI_ADDR_WIDTH,
            C_M_AXI_DATA_WIDTH => C_M_AXI_DATA_WIDTH
        )
        port map (
            clk_i   => clk_i,
            reset_i => reset_i,

            s_axi_awaddr  => gs_awaddr,
            s_axi_awvalid => gs_awvalid,
            s_axi_awready => gs_awready,
            s_axi_wdata   => gs_wdata,
            s_axi_wstrb   => gs_wstrb,
            s_axi_wvalid  => gs_wvalid,
            s_axi_wready  => gs_wready,
            s_axi_bresp   => gs_bresp,
            s_axi_bvalid  => gs_bvalid,
            s_axi_bready  => gs_bready,
            s_axi_araddr  => gs_araddr,
            s_axi_arvalid => gs_arvalid,
            s_axi_arready => gs_arready,
            s_axi_rdata   => gs_rdata,
            s_axi_rresp   => gs_rresp,
            s_axi_rvalid  => gs_rvalid,
            s_axi_rready  => gs_rready,

            m_axi_awaddr  => gm_awaddr,
            m_axi_awvalid => gm_awvalid,
            m_axi_awready => gm_awready,
            m_axi_wdata   => gm_wdata,
            m_axi_wstrb   => gm_wstrb,
            m_axi_wvalid  => gm_wvalid,
            m_axi_wready  => gm_wready,
            m_axi_bresp   => gm_bresp,
            m_axi_bvalid  => gm_bvalid,
            m_axi_bready  => gm_bready,
            m_axi_araddr  => gm_araddr,
            m_axi_arvalid => gm_arvalid,
            m_axi_arready => gm_arready,
            m_axi_rdata   => gm_rdata,
            m_axi_rresp   => gm_rresp,
            m_axi_rvalid  => gm_rvalid,
            m_axi_rready  => gm_rready
        );

end structural;
