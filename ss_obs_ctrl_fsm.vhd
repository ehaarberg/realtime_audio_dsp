-- ss_obs_ctrl_fsm.vhd
-- Observer-based SS Controller (Closed Loop)
--
-- Implements:
--   y_hat[k] = D*u[k] + C*x_hat[k]
--   e[k]     = y[k] - y_hat[k]
--   x_hat[k+1] = A*x_hat[k] + B*u[k] + g*L*e[k]
--   u_c[k]   = -alpha * K * x_hat[k]

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity ss_obs_ctrl_fsm is
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        u            : in  signed(WL-1 downto 0);  -- control input (monitor drive)
        y            : in  signed(WL-1 downto 0);  -- physical output (vocal mic)
        g_in         : in  signed(WL-1 downto 0);  -- confidence gate (sfix24_En22)
        alpha_in     : in  signed(WL-1 downto 0);  -- intervention factor (sfix24_En22)
        in_valid     : in  std_logic;               -- pulse: latch inputs and start computation
        pending_bank : in  ss_bank_sel_t;
        coeff_bank   : out ss_bank_sel_t;
        coeff_index  : out ss_coeff_index_t;
        coeff_data   : in  ss_coeff_word_t;
        active_bank  : out ss_bank_sel_t;
        busy         : out std_logic;
        u_c          : out signed(WL-1 downto 0);  -- controller output
        u_c_valid    : out std_logic;              -- pulses when u_c completes
        feat_modal   : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0); -- sum|x_hat| per sample
        feat_innov   : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0); -- |e| innovation per sample
        feat_valid   : out std_logic               -- pulses when feat_* update
    );
end entity ss_obs_ctrl_fsm;

architecture rtl of ss_obs_ctrl_fsm is

    constant ACC_WL : integer := WL * 2;
    constant ACC_FL : integer := FL * 2;

    function prod_trunc(a : signed(ACC_WL-1 downto 0)) return signed is
    begin
        return a(ACC_FL - FL + WL - 1 downto ACC_FL - FL);
    end function;

    -- Absolute magnitude of a WL-bit signed value as an SS_FEAT_WORD_W-bit
    -- non-negative quantity (saturates the single most-negative code).
    function mag32(s : signed(WL-1 downto 0)) return unsigned is
        variable t : signed(WL downto 0);
    begin
        t := resize(s, WL+1);
        if t < 0 then
            t := -t;
        end if;
        return resize(unsigned(t), SS_FEAT_WORD_W);
    end function;

    type state_vec_t is array (0 to N-1) of signed(WL-1 downto 0);
    signal x_reg  : state_vec_t := (others => (others => '0'));
    signal x_next : state_vec_t := (others => (others => '0'));
    signal bank_sel_reg : ss_bank_sel_t := (others => '0');

    type fsm_t is (IDLE, RUN_Y, OUT_Y, CALC_GE, RUN_K, OUT_K, CALC_UC, RUN_X, STORE_X, UPD_X);
    signal state : fsm_t := IDLE;

    signal row         : integer range 0 to N-1 := 0;
    signal row_times_n : integer range 0 to (N*N)-1 := 0;
    signal term        : integer range 0 to N+2 := 0;

    signal u_reg     : signed(WL-1 downto 0) := (others => '0');
    signal y_reg     : signed(WL-1 downto 0) := (others => '0');
    signal g_reg     : signed(WL-1 downto 0) := (others => '0');
    signal alpha_reg : signed(WL-1 downto 0) := (others => '0');

    signal y_hat_reg : signed(WL-1 downto 0) := (others => '0');
    signal e_reg     : signed(WL-1 downto 0) := (others => '0');
    signal g_e_reg   : signed(WL-1 downto 0) := (others => '0');
    signal u_c_raw   : signed(WL-1 downto 0) := (others => '0');

    signal u_c_out   : signed(WL-1 downto 0) := (others => '0');
    signal u_c_vld   : std_logic := '0';

    signal issue_operand_r1 : signed(WL-1 downto 0) := (others => '0');
    signal issue_valid_d1   : std_logic := '0';
    signal issue_operand_r2 : signed(WL-1 downto 0) := (others => '0');
    signal issue_valid_d2   : std_logic := '0';
    signal coeff_r         : signed(WL-1 downto 0) := (others => '0');
    signal operand_r       : signed(WL-1 downto 0) := (others => '0');
    signal coeff_valid     : std_logic := '0';

    signal prod_reg   : signed(WL-1 downto 0) := (others => '0');
    signal prod_valid : std_logic := '0';

    signal acc   : signed(WL-1 downto 0) := (others => '0');
    attribute use_dsp : string;
    attribute use_dsp of acc : signal is "yes";

    -- Feature extraction (thesis 5.3): per-sample modal energy + innovation.
    signal modal_acc  : unsigned(SS_FEAT_WORD_W-1 downto 0) := (others => '0');
    signal feat_modal_r : std_logic_vector(SS_FEAT_WORD_W-1 downto 0) := (others => '0');
    signal feat_innov_r : std_logic_vector(SS_FEAT_WORD_W-1 downto 0) := (others => '0');
    signal feat_vld     : std_logic := '0';


begin

    process(state, in_valid, pending_bank, bank_sel_reg, term, row, row_times_n)
        variable next_idx : integer := 0;
    begin
        coeff_bank  <= bank_sel_reg;
        coeff_index <= (others => '0');

        case state is
            when IDLE =>
                if in_valid = '1' then
                    coeff_bank <= pending_bank;
                end if;

            when RUN_Y =>
                if term = 0 then
                    coeff_index <= to_unsigned(SS_D_BASE, SS_COEFF_INDEX_W);
                elsif term <= N then
                    next_idx := SS_C_BASE + term - 1;
                    coeff_index <= to_unsigned(next_idx, SS_COEFF_INDEX_W);
                end if;

            when RUN_K =>
                if term <= N and term >= 1 then
                    next_idx := SS_K_BASE + term - 1;
                    coeff_index <= to_unsigned(next_idx, SS_COEFF_INDEX_W);
                end if;

            when RUN_X =>
                if term = 0 then
                    next_idx := SS_B_BASE + row;
                    coeff_index <= to_unsigned(next_idx, SS_COEFF_INDEX_W);
                elsif term <= N then
                    next_idx := SS_A_BASE + row_times_n + term - 1;
                    coeff_index <= to_unsigned(next_idx, SS_COEFF_INDEX_W);
                elsif term = N+1 then
                    next_idx := SS_L_BASE + row;
                    coeff_index <= to_unsigned(next_idx, SS_COEFF_INDEX_W);
                end if;

            when others =>
                null;
        end case;
    end process;

    process(clk)
        variable issue_active       : boolean;
        variable issue_operand      : signed(WL-1 downto 0);
        variable final_accumulating : boolean;
    begin
        if rising_edge(clk) then
            u_c_vld  <= '0';
            feat_vld <= '0';

            if reset = '1' then
                state  <= IDLE;
                row    <= 0;
                row_times_n <= 0;
                term   <= 0;
                x_reg  <= (others => (others => '0'));
                x_next <= (others => (others => '0'));
                bank_sel_reg <= (others => '0');
                u_reg     <= (others => '0');
                y_reg     <= (others => '0');
                g_reg     <= (others => '0');
                alpha_reg <= (others => '0');
                y_hat_reg <= (others => '0');
                e_reg     <= (others => '0');
                g_e_reg   <= (others => '0');
                u_c_raw   <= (others => '0');
                u_c_out   <= (others => '0');
                issue_operand_r1 <= (others => '0');
                issue_valid_d1   <= '0';
                issue_operand_r2 <= (others => '0');
                issue_valid_d2   <= '0';
                coeff_r         <= (others => '0');
                operand_r       <= (others => '0');
                coeff_valid     <= '0';
                prod_reg <= (others => '0');
                prod_valid <= '0';
                acc      <= (others => '0');
                modal_acc    <= (others => '0');
                feat_modal_r <= (others => '0');
                feat_innov_r <= (others => '0');
            else
                case state is

                    when IDLE =>
                        term           <= 0;
                        row            <= 0;
                        row_times_n    <= 0;
                        issue_valid_d1 <= '0';
                        issue_valid_d2 <= '0';
                        coeff_valid    <= '0';
                        prod_valid     <= '0';
                        if in_valid = '1' then
                            u_reg       <= u;
                            y_reg       <= y;
                            g_reg       <= g_in;
                            alpha_reg   <= alpha_in;
                            bank_sel_reg <= pending_bank;
                            acc         <= (others => '0');
                            modal_acc   <= (others => '0');
                            state       <= RUN_Y;
                        end if;

                    when RUN_Y | RUN_K | RUN_X =>
                        issue_active := false;
                        if state = RUN_Y then
                            issue_active := term <= N;
                        elsif state = RUN_K then
                            issue_active := term >= 1 and term <= N;
                        elsif state = RUN_X then
                            issue_active := term <= N+1;
                        end if;

                        issue_operand := (others => '0');
                        if issue_active then
                            if state = RUN_Y then
                                if term = 0 then issue_operand := u_reg;
                                else issue_operand := x_reg(term - 1); end if;
                            elsif state = RUN_K then
                                issue_operand := x_reg(term - 1);
                            elsif state = RUN_X then
                                if term = 0 then issue_operand := u_reg;
                                elsif term <= N then issue_operand := x_reg(term - 1);
                                else issue_operand := g_e_reg; end if;
                            end if;
                        end if;

                        final_accumulating := false;
                        if state = RUN_Y or state = RUN_K then
                            final_accumulating := (term = N+1) and (issue_valid_d1 = '0') and (issue_valid_d2 = '0') and (coeff_valid = '0') and (prod_valid = '1');
                        elsif state = RUN_X then
                            final_accumulating := (term = N+2) and (issue_valid_d1 = '0') and (issue_valid_d2 = '0') and (coeff_valid = '0') and (prod_valid = '1');
                        end if;

                        if prod_valid = '1' then
                            acc <= acc + prod_reg;
                        end if;

                        if coeff_valid = '1' then
                            prod_reg <= prod_trunc(resize(coeff_r * operand_r, ACC_WL));
                        end if;
                        prod_valid <= coeff_valid;

                        if issue_valid_d2 = '1' then
                            coeff_r   <= coeff_data;
                            operand_r <= issue_operand_r2;
                        end if;
                        coeff_valid <= issue_valid_d2;
                        
                        issue_operand_r2 <= issue_operand_r1;
                        issue_valid_d2   <= issue_valid_d1;

                        if issue_active then
                            issue_operand_r1 <= issue_operand;
                            issue_valid_d1   <= '1';
                            term             <= term + 1;
                        else
                            issue_operand_r1 <= (others => '0');
                            issue_valid_d1   <= '0';
                        end if;

                        if final_accumulating then
                            if state = RUN_Y then
                                state <= OUT_Y;
                            elsif state = RUN_K then
                                state <= OUT_K;
                            else
                                state <= STORE_X;
                            end if;
                        end if;

                    when OUT_Y =>
                        y_hat_reg <= acc;
                        e_reg     <= y_reg - acc;
                        acc       <= (others => '0');
                        state     <= CALC_GE;

                    when CALC_GE =>
                        g_e_reg <= prod_trunc(resize(g_reg * e_reg, ACC_WL));
                        term    <= 1;
                        state   <= RUN_K;

                    when OUT_K =>
                        u_c_raw <= acc;
                        acc     <= (others => '0');
                        state   <= CALC_UC;

                    when CALC_UC =>
                        -- u_c = -alpha * K * x
                        u_c_out <= -prod_trunc(resize(alpha_reg * u_c_raw, ACC_WL));
                        u_c_vld <= '1';
                        term    <= 0;
                        state   <= RUN_X;

                    when STORE_X =>
                        x_next(row) <= acc;
                        modal_acc   <= modal_acc + mag32(acc);
                        if row = N-1 then
                            state <= UPD_X;
                        else
                            row   <= row + 1;
                            row_times_n <= row_times_n + N;
                            term  <= 0;
                            acc   <= (others => '0');
                            issue_valid_d1 <= '0';
                            issue_valid_d2 <= '0';
                            coeff_valid    <= '0';
                            prod_valid     <= '0';
                            state <= RUN_X;
                        end if;

                    when UPD_X =>
                        x_reg <= x_next;
                        feat_modal_r <= std_logic_vector(modal_acc);
                        feat_innov_r <= std_logic_vector(mag32(e_reg));
                        feat_vld     <= '1';
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

    active_bank <= bank_sel_reg;
    busy        <= '1' when state /= IDLE else '0';
    u_c         <= u_c_out;
    u_c_valid   <= u_c_vld;
    feat_modal  <= feat_modal_r;
    feat_innov  <= feat_innov_r;
    feat_valid  <= feat_vld;

end rtl;