----------------------------------------------------------------------------------
--Author: Federica Sarnataro
--
-- Module Name: axi_master_engine - Behavioral
-- Description:
--   M_AXI master engine for gemm_top. Sits behind the LSUs: takes local,
--   level-held requests (one row of A, one row of B, one word of C) and
--   turns each into a sequence of single-beat AXI4-Lite transactions
--   towards external memory, using the base addresses coming from the
--   S_AXI control registers (axi4lite_ctrl_regs.vhd).
--
--   Kept to AXI4-Lite (no burst) on purpose, as a first working version;
--   burst support (AXI4 full, ARLEN/AWLEN) is a possible future
--   optimization, not needed to get the design working end to end.
--
--   Sequencing: on a request to fetch, it reads all beats of A, then all
--   beats of B, then pulses ab_valid_o for one cycle. Writing one word of
--   C is a separate path that pulses c_done_o once acknowledged (BVALID).
--   gemm_controller's LOAD and WRITE states never overlap (it's a single
--   sequential FSM), so req_ab_i and req_c_i are never both asserted at
--   the same time -- a single shared FSM is enough here, no real
--   arbitration between the two paths is needed.

----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_master_engine is
    generic (
        ROW_WIDTH    : positive;  -- width of one row of A / one row of B
        C_WORD_WIDTH : positive;  -- width of one word of C (already byte-aligned)
        M            : positive;  -- rows of A
        L            : positive;  -- columns of B

        M_AXI_ADDR_WIDTH : positive := 32;
        M_AXI_DATA_WIDTH : positive := 32
    );
    port (
        clk_i   : in std_logic;
        reset_i : in std_logic;

        -- M_AXI: AXI4-Lite master
        m_axi_awaddr  : out std_logic_vector(M_AXI_ADDR_WIDTH-1 downto 0);
        m_axi_awvalid : out std_logic;
        m_axi_awready : in  std_logic;
        m_axi_wdata   : out std_logic_vector(M_AXI_DATA_WIDTH-1 downto 0);
        m_axi_wstrb   : out std_logic_vector((M_AXI_DATA_WIDTH/8)-1 downto 0);
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        m_axi_bresp   : in  std_logic_vector(1 downto 0);
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic;
        m_axi_araddr  : out std_logic_vector(M_AXI_ADDR_WIDTH-1 downto 0);
        m_axi_arvalid : out std_logic;
        m_axi_arready : in  std_logic;
        m_axi_rdata   : in  std_logic_vector(M_AXI_DATA_WIDTH-1 downto 0);
        m_axi_rresp   : in  std_logic_vector(1 downto 0);
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic;

        -- base addresses, from the S_AXI control registers
        base_addr_a_i : in std_logic_vector(M_AXI_ADDR_WIDTH-1 downto 0);
        base_addr_b_i : in std_logic_vector(M_AXI_ADDR_WIDTH-1 downto 0);
        base_addr_c_i : in std_logic_vector(M_AXI_ADDR_WIDTH-1 downto 0);

        -- local channel: read one row of A and one row of B
        req_ab_i   : in  std_logic;  -- level, held by gemm_controller during LOAD
        idx_a_i    : in  integer range 0 to M-1;
        idx_b_i    : in  integer range 0 to L-1;
        vector_a_o : out std_logic_vector(ROW_WIDTH-1 downto 0);
        vector_b_o : out std_logic_vector(ROW_WIDTH-1 downto 0);
        ab_valid_o : out std_logic;  -- 1-cycle pulse

        -- local channel: write one word of C
        req_c_i   : in  std_logic;  -- level, held by gemm_controller during WRITE
        idx_c_i   : in  integer range 0 to (M*L)-1;
        wdata_c_i : in  std_logic_vector(C_WORD_WIDTH-1 downto 0);
        c_done_o  : out std_logic   -- 1-cycle pulse
    );
end entity axi_master_engine;

architecture Behavioral of axi_master_engine is

    function max_int(a, b : integer) return integer is
    begin
        if a > b then
            return a;
        else
            return b;
        end if;
    end function;

    constant BYTES_PER_BEAT : positive := M_AXI_DATA_WIDTH/8;

    constant ROW_BYTES : positive := (ROW_WIDTH+7)/8;      -- for WSTRB byte-count only, NOT address stride
    constant C_BYTES   : positive := C_WORD_WIDTH/8;        -- for WSTRB byte-count only, NOT address stride

    constant BEATS_ROW : positive := (ROW_WIDTH+M_AXI_DATA_WIDTH-1)/M_AXI_DATA_WIDTH;
    constant BEATS_C   : positive := (C_WORD_WIDTH+M_AXI_DATA_WIDTH-1)/M_AXI_DATA_WIDTH;
    constant BEATS_MAX : positive := max_int(BEATS_ROW, BEATS_C);

    -- address stride between consecutive rows of A/B, or consecutive words
    -- of C: always a whole number of beats (matches how the target memory
    -- reserves one aligned slot per element), NOT the "tightly packed"
    -- byte count (ROW_BYTES/C_BYTES) -- those are only used below to size
    -- WSTRB on the last, possibly partial, beat.
    constant ROW_STRIDE : positive := BEATS_ROW * BYTES_PER_BEAT;
    constant C_STRIDE   : positive := BEATS_C   * BYTES_PER_BEAT;

    type state_t is (IDLE,
                      AR_A, R_A, AR_B, R_B, PULSE_AB,
                      AW_C, B_C, PULSE_C);
    signal state_q : state_t := IDLE;

    -- range widened by 1 vs. the actual max beat index reached at runtime
    -- (BEATS_MAX-1): synthesis checks "beat_q + 1" against beat_q's full
    -- declared type range regardless of which control-flow path is taken,
    -- so the type itself needs headroom for that worst-case increment.
    signal beat_q : integer range 0 to BEATS_MAX := 0;

    -- registered M_AXI outputs (a master should hold *VALID until the
    -- matching *READY arrives, so these are proper registers, not
    -- combinational pulses)
    signal araddr_q  : unsigned(M_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal arvalid_q : std_logic := '0';
    signal rready_q  : std_logic := '0';

    signal awaddr_q  : unsigned(M_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal awvalid_q : std_logic := '0';
    signal wdata_q   : std_logic_vector(M_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal wstrb_q   : std_logic_vector(BYTES_PER_BEAT-1 downto 0) := (others => '0');
    signal wvalid_q  : std_logic := '0';
    signal bready_q  : std_logic := '0';

    -- assembled/captured data
    signal vector_a_reg : std_logic_vector(ROW_WIDTH-1 downto 0) := (others => '0');
    signal vector_b_reg : std_logic_vector(ROW_WIDTH-1 downto 0) := (others => '0');
    signal wdata_c_reg  : std_logic_vector(C_WORD_WIDTH-1 downto 0) := (others => '0');

    signal ab_valid_reg : std_logic := '0';
    signal c_done_reg   : std_logic := '0';

begin

    m_axi_araddr  <= std_logic_vector(araddr_q);
    m_axi_arvalid <= arvalid_q;
    m_axi_rready  <= rready_q;

    m_axi_awaddr  <= std_logic_vector(awaddr_q);
    m_axi_awvalid <= awvalid_q;
    m_axi_wdata   <= wdata_q;
    m_axi_wstrb   <= wstrb_q;
    m_axi_wvalid  <= wvalid_q;
    m_axi_bready  <= bready_q;

    vector_a_o <= vector_a_reg;
    vector_b_o <= vector_b_reg;
    ab_valid_o <= ab_valid_reg;
    c_done_o   <= c_done_reg;

    

    ----------------------------------------------------------------------
    MAIN_PROC: process(clk_i)
        variable v_addr        : unsigned(M_AXI_ADDR_WIDTH-1 downto 0);
        variable v_width       : integer;
        variable v_lo           : integer;
        variable v_bytes       : integer;
        variable v_aw_pending  : boolean;
        variable v_w_pending   : boolean;
    begin
        if rising_edge(clk_i) then
            if reset_i = '1' then
                state_q      <= IDLE;
                beat_q       <= 0;
                arvalid_q    <= '0';
                rready_q     <= '0';
                awvalid_q    <= '0';
                wvalid_q     <= '0';
                bready_q     <= '0';
                ab_valid_reg <= '0';
                c_done_reg   <= '0';
            else
                -- ab_valid_o/c_done_o are 1-cycle pulses: low by default,
                -- set explicitly below only in the cycle they fire
                ab_valid_reg <= '0';
                c_done_reg   <= '0';

                case state_q is

                    ------------------------------------------------------
                    when IDLE =>
                        if req_ab_i = '1' then
                            v_addr    := unsigned(base_addr_a_i) + to_unsigned(idx_a_i*ROW_STRIDE, M_AXI_ADDR_WIDTH);
                            araddr_q  <= v_addr;
                            arvalid_q <= '1';
                            beat_q    <= 0;
                            state_q   <= AR_A;

                        elsif req_c_i = '1' then
                            wdata_c_reg <= wdata_c_i; -- latch the value for the whole write

                            v_addr   := unsigned(base_addr_c_i) + to_unsigned(idx_c_i*C_STRIDE, M_AXI_ADDR_WIDTH);
                            awaddr_q <= v_addr;
                            awvalid_q <= '1';

                            v_bytes := C_BYTES;
                            if v_bytes > BYTES_PER_BEAT then
                                v_bytes := BYTES_PER_BEAT;
                            elsif v_bytes < 1 then
                                v_bytes := 1;
                            end if;
                            wdata_q                       <= (others => '0');
                            wdata_q(v_bytes*8-1 downto 0) <= wdata_c_i(v_bytes*8-1 downto 0);
                            wstrb_q                       <= (others => '0');
                            wstrb_q(v_bytes-1 downto 0)   <= (others => '1');
                            wvalid_q <= '1';

                            beat_q  <= 0;
                            state_q <= AW_C;
                        end if;

                    ------------------------------------------------------
                    -- read one row of A
                    ------------------------------------------------------
                    when AR_A =>
                        if arvalid_q = '1' and m_axi_arready = '1' then
                            arvalid_q <= '0';
                            rready_q  <= '1';
                            state_q   <= R_A;
                        end if;

                    when R_A =>
                        if rready_q = '1' and m_axi_rvalid = '1' then
                            rready_q <= '0';

                            v_lo    := beat_q*M_AXI_DATA_WIDTH;
                            v_width := ROW_WIDTH - v_lo;
                            if v_width > M_AXI_DATA_WIDTH then
                                v_width := M_AXI_DATA_WIDTH;
                            elsif v_width < 1 then
                                v_width := 1;
                            end if;

                            -- bit-by-bit instead of a variable-bounds slice:
                            -- some tools handle "vec(hi downto lo) <= ..."
                            -- with runtime hi/lo differently than others.
                            -- A single-bit dynamic index is unambiguous
                            -- everywhere.
                            for b in 0 to M_AXI_DATA_WIDTH-1 loop
                                if b < v_width then
                                    vector_a_reg(v_lo+b) <= m_axi_rdata(b);
                                end if;
                            end loop;

                            if beat_q = BEATS_ROW-1 then
                                -- row of A complete, move on to B, beat 0
                                v_addr    := unsigned(base_addr_b_i) + to_unsigned(idx_b_i*ROW_STRIDE, M_AXI_ADDR_WIDTH);
                                araddr_q  <= v_addr;
                                arvalid_q <= '1';
                                beat_q    <= 0;
                                state_q   <= AR_B;
                            else
                                araddr_q  <= araddr_q + to_unsigned(BYTES_PER_BEAT, M_AXI_ADDR_WIDTH);
                                arvalid_q <= '1';
                                beat_q    <= beat_q + 1;
                                state_q   <= AR_A;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- read one row of B (same structure as A)
                    ------------------------------------------------------
                    when AR_B =>
                        if arvalid_q = '1' and m_axi_arready = '1' then
                            arvalid_q <= '0';
                            rready_q  <= '1';
                            state_q   <= R_B;
                        end if;

                    when R_B =>
                        if rready_q = '1' and m_axi_rvalid = '1' then
                            rready_q <= '0';

                            v_lo    := beat_q*M_AXI_DATA_WIDTH;
                            v_width := ROW_WIDTH - v_lo;
                            if v_width > M_AXI_DATA_WIDTH then
                                v_width := M_AXI_DATA_WIDTH;
                            elsif v_width < 1 then
                                v_width := 1;
                            end if;

                            for b in 0 to M_AXI_DATA_WIDTH-1 loop
                                if b < v_width then
                                    vector_b_reg(v_lo+b) <= m_axi_rdata(b);
                                end if;
                            end loop;

                            if beat_q = BEATS_ROW-1 then
                                -- both A and B are now fully assembled
                                ab_valid_reg <= '1';
                                state_q      <= PULSE_AB;
                            else
                                araddr_q  <= araddr_q + to_unsigned(BYTES_PER_BEAT, M_AXI_ADDR_WIDTH);
                                arvalid_q <= '1';
                                beat_q    <= beat_q + 1;
                                state_q   <= AR_B;
                            end if;
                        end if;

                    when PULSE_AB =>
                        -- wait for gemm_controller to drop the request
                        -- (it will, once it samples ab_valid_o = '1' and
                        -- leaves LOAD) before accepting a new one
                        if req_ab_i = '0' then
                            state_q <= IDLE;
                        end if;

                    ------------------------------------------------------
                    -- write one word of C
                    ------------------------------------------------------
                    when AW_C =>
                        v_aw_pending := (awvalid_q = '1') and (m_axi_awready /= '1');
                        v_w_pending  := (wvalid_q  = '1') and (m_axi_wready  /= '1');

                        if awvalid_q = '1' and m_axi_awready = '1' then
                            awvalid_q <= '0';
                        end if;
                        if wvalid_q = '1' and m_axi_wready = '1' then
                            wvalid_q <= '0';
                        end if;

                        if not v_aw_pending and not v_w_pending then
                            -- both AW and W have been accepted (possibly on
                            -- different cycles) -- move on to the response
                            bready_q <= '1';
                            state_q  <= B_C;
                        end if;

                    when B_C =>
                        if bready_q = '1' and m_axi_bvalid = '1' then
                            bready_q <= '0';

                            if beat_q = BEATS_C-1 then
                                c_done_reg <= '1';
                                state_q    <= PULSE_C;
                            else
                                awaddr_q  <= awaddr_q + to_unsigned(BYTES_PER_BEAT, M_AXI_ADDR_WIDTH);
                                awvalid_q <= '1';

                                v_lo    := (beat_q+1)*BYTES_PER_BEAT*8;
                                v_bytes := C_BYTES - (beat_q+1)*BYTES_PER_BEAT;
                                if v_bytes > BYTES_PER_BEAT then
                                    v_bytes := BYTES_PER_BEAT;
                                elsif v_bytes < 1 then
                                    v_bytes := 1;
                                end if;
                                wdata_q                       <= (others => '0');
                                wdata_q(v_bytes*8-1 downto 0) <= wdata_c_reg(v_lo+v_bytes*8-1 downto v_lo);
                                wstrb_q                       <= (others => '0');
                                wstrb_q(v_bytes-1 downto 0)   <= (others => '1');
                                wvalid_q <= '1';

                                beat_q  <= beat_q + 1;
                                state_q <= AW_C;
                            end if;
                        end if;

                    when PULSE_C =>
                        if req_c_i = '0' then
                            state_q <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process MAIN_PROC;

end architecture Behavioral;
