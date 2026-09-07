----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Module Name: axi4lite_ctrl_regs - Behavioral
-- Description:
--   AXI4-Lite (S_AXI) control register block for gemm_top. Replaces the old
--   "bare" start_i/done_o and the future axi_gpio: exposes a register map
--   with start/done plus the base addresses of A/B/C in memory, which the
--   M_AXI engine needs to know where to read/write the matrices.
--
--   Register map (32-bit word, byte offset):
--     0x00  CTRL         bit0 = start (write; generates a 1-cycle pulse)
--     0x04  STATUS       bit0 = done  (read-only)
--     0x08  BASE_ADDR_A  base address of A
--     0x0C  BASE_ADDR_B  base address of B
--     0x10  BASE_ADDR_C  base address of C
--
-- Revision:
-- Revision 0.01 - File Created
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi4lite_ctrl_regs is
    generic (
        C_S_AXI_ADDR_WIDTH : positive := 32;  -- 32 bit, same as the Tier 1 example in the RTL guide
        C_S_AXI_DATA_WIDTH : positive := 32
    );
    port (
        clk_i   : in std_logic;
        reset_i : in std_logic;

        -- AXI4-Lite slave
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

        -- towards the compute core (gemm_controller)
        start_o : out std_logic;                                   -- 1-cycle pulse
        done_i  : in  std_logic;                                   -- level

        -- towards the M_AXI engine
        base_addr_a_o : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        base_addr_b_o : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        base_addr_c_o : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0)
    );
end entity axi4lite_ctrl_regs;

architecture Behavioral of axi4lite_ctrl_regs is

    -- register offsets (used as comments in the case statements below):
    -- 0=CTRL, 4=STATUS, 8=BASE_ADDR_A, 12=BASE_ADDR_B, 16=BASE_ADDR_C

    -- write channel
    signal axi_awready : std_logic := '0';
    signal axi_wready  : std_logic := '0';
    signal axi_bvalid  : std_logic := '0';
    signal write_addr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);

    -- read channel
    signal axi_arready : std_logic := '0';
    signal axi_rvalid  : std_logic := '0';
    signal axi_rdata   : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');

    -- the actual registers
    signal reg_base_addr_a : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal reg_base_addr_b : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal reg_base_addr_c : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');

    signal start_pulse : std_logic := '0';

    -- done_i (from gemm_controller) is a single-cycle pulse: returning it
    -- as-is on STATUS could mean a polling master never sees it (if the
    -- read doesn't land exactly on that cycle, it would wait forever).
    -- Latch it here into a stable level, auto-cleared on the next start.
    signal done_latched : std_logic := '0';

    signal write_en : std_logic; -- goes high for one cycle once both AW and W have arrived

    -- Set the same cycle AW/W are accepted; BVALID is raised the cycle
    -- AFTER this, never in the same cycle as AWREADY -- the AXI4 protocol
    -- checker (correctly) flags same-cycle AWREADY+BVALID as a violation
    -- ("a slave must not give a write response before the write address").
    signal bvalid_pending : std_logic := '0';

    -- Same idea, for the read channel: RVALID must follow ARREADY by one
    -- cycle, never coincide with it.
    signal rvalid_pending : std_logic := '0';

begin

    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bvalid  <= axi_bvalid;
    s_axi_bresp   <= "00"; -- OKAY, always
    s_axi_arready <= axi_arready;
    s_axi_rvalid  <= axi_rvalid;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= "00"; -- OKAY, always

    start_o       <= start_pulse;
    base_addr_a_o <= reg_base_addr_a;
    base_addr_b_o <= reg_base_addr_b;
    base_addr_c_o <= reg_base_addr_c;

    ----------------------------------------------------------------------
    -- Write channel: accepts AW and W only when they arrive together
    -- (simple version, valid for a "well-behaved" AXI4-Lite master such
    -- as the VIP or a PS: no need to handle AW and W arriving on
    -- different cycles for a control register block like this one).
    ----------------------------------------------------------------------
    write_en <= s_axi_awvalid and s_axi_wvalid and (not axi_bvalid) and (not bvalid_pending);

    WRITE_PROC: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if reset_i = '1' then
                axi_awready    <= '0';
                axi_wready     <= '0';
                axi_bvalid     <= '0';
                bvalid_pending <= '0';
                start_pulse    <= '0';
                reg_base_addr_a <= (others => '0');
                reg_base_addr_b <= (others => '0');
                reg_base_addr_c <= (others => '0');
            else
                -- start is a pulse: back to 0 by default every cycle
                start_pulse <= '0';

                if write_en = '1' then
                    axi_awready    <= '1';
                    axi_wready     <= '1';
                    bvalid_pending <= '1'; -- BVALID follows one cycle later, not now
                    write_addr     <= s_axi_awaddr;

                    case to_integer(unsigned(s_axi_awaddr(4 downto 0))) is
                        when 0 =>       -- ADDR_CTRL
                            start_pulse <= s_axi_wdata(0);
                        when 8 =>       -- ADDR_BASE_ADDR_A
                            reg_base_addr_a <= s_axi_wdata;
                        when 12 =>      -- ADDR_BASE_ADDR_B
                            reg_base_addr_b <= s_axi_wdata;
                        when 16 =>      -- ADDR_BASE_ADDR_C
                            reg_base_addr_c <= s_axi_wdata;
                        when others =>
                            null; -- STATUS and unmapped addresses: write ignored
                    end case;
                else
                    axi_awready <= '0';
                    axi_wready  <= '0';
                end if;

                -- raise BVALID exactly one cycle after AW/W were accepted
                if bvalid_pending = '1' then
                    axi_bvalid     <= '1';
                    bvalid_pending <= '0';
                elsif axi_bvalid = '1' and s_axi_bready = '1' then
                    axi_bvalid <= '0';
                end if;
            end if;
        end if;
    end process WRITE_PROC;

    ----------------------------------------------------------------------
    -- Latches the done_i pulse into a stable level
    ----------------------------------------------------------------------
    ----------------------------------------------------------------------
    -- Debug only: prints when done_i (the raw pulse from gemm_controller)
    -- or done_latched change, to see exactly where the signal gets lost
    ----------------------------------------------------------------------
    DONE_DEBUG: process(done_i, done_latched)
    begin
        report "axi4lite_ctrl_regs: done_i=" & std_logic'image(done_i) &
               " done_latched=" & std_logic'image(done_latched);
    end process DONE_DEBUG;

    DONE_LATCH_PROC: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if reset_i = '1' then
                done_latched <= '0';
            else
                if start_pulse = '1' then
                    done_latched <= '0';  -- a new start clears the previous done
                elsif done_i = '1' then
                    done_latched <= '1';  -- latch the end-of-computation pulse
                end if;
            end if;
        end if;
    end process DONE_LATCH_PROC;

    ----------------------------------------------------------------------
    -- Read channel
    ----------------------------------------------------------------------
    READ_PROC: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if reset_i = '1' then
                axi_arready   <= '0';
                axi_rvalid    <= '0';
                axi_rdata     <= (others => '0');
                rvalid_pending <= '0';
            else
                if s_axi_arvalid = '1' and axi_arready = '0' and axi_rvalid = '0'
                   and rvalid_pending = '0' then
                    axi_arready    <= '1';
                    rvalid_pending <= '1'; -- RVALID follows one cycle later, not now

                    report "axi4lite_ctrl_regs: READ request, araddr=" &
                           integer'image(to_integer(unsigned(s_axi_araddr))) &
                           " masked=" & integer'image(to_integer(unsigned(s_axi_araddr(4 downto 0)))) &
                           " done_latched=" & std_logic'image(done_latched);

                    case to_integer(unsigned(s_axi_araddr(4 downto 0))) is
                        when 4 =>       -- ADDR_STATUS
                            axi_rdata <= (0 => done_latched, others => '0');
                        when 8 =>       -- ADDR_BASE_ADDR_A
                            axi_rdata <= reg_base_addr_a;
                        when 12 =>      -- ADDR_BASE_ADDR_B
                            axi_rdata <= reg_base_addr_b;
                        when 16 =>      -- ADDR_BASE_ADDR_C
                            axi_rdata <= reg_base_addr_c;
                        when others =>
                            axi_rdata <= (others => '0'); -- CTRL and unmapped addresses read 0
                    end case;
                else
                    axi_arready <= '0';
                end if;

                -- raise RVALID exactly one cycle after ARREADY was accepted
                if rvalid_pending = '1' then
                    axi_rvalid     <= '1';
                    rvalid_pending <= '0';
                elsif axi_rvalid = '1' and s_axi_rready = '1' then
                    axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process READ_PROC;

end architecture Behavioral;
