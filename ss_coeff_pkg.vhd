library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;

package ss_coeff_pkg is

    constant SS_CTRL_COUNT       : integer := 4;
    constant SS_CTRL_SEL_W       : integer := 2;
    constant SS_BANK_COUNT       : integer := 8;
    constant SS_BANK_SEL_W       : integer := 3;
    constant SS_A_COUNT          : integer := N * N;
    constant SS_B_COUNT          : integer := N;
    constant SS_C_COUNT          : integer := N;
    constant SS_D_COUNT          : integer := 1;
    constant SS_L_COUNT          : integer := N;
    constant SS_K_COUNT          : integer := N;
    constant SS_COEFFS_PER_BANK  : integer := 1024; -- padded to power of 2 for shift-based addressing
    constant SS_COEFF_MEM_DEPTH  : integer := SS_BANK_COUNT * SS_COEFFS_PER_BANK;
    constant SS_COEFF_INDEX_W    : integer := 11;  -- 2^11=2048 >= 1021=SS_COEFFS_PER_BANK for N=30

    constant SS_A_BASE : integer := 0;
    constant SS_B_BASE : integer := SS_A_BASE + SS_A_COUNT;
    constant SS_C_BASE : integer := SS_B_BASE + SS_B_COUNT;
    constant SS_D_BASE : integer := SS_C_BASE + SS_C_COUNT;
    constant SS_L_BASE : integer := SS_D_BASE + SS_D_COUNT;
    constant SS_K_BASE : integer := SS_L_BASE + SS_L_COUNT;

    -- Real-time feedback-risk feature bus (thesis 5.3 / 5.8.1).
    -- Per controller the PL exports three 32-bit smoothed energy words:
    --   word 0 = modal energy   (observer state magnitude sum)
    --   word 1 = innovation     (|y - y_hat| residual)
    --   word 2 = band energy    (crossover band output magnitude)
    constant SS_FEAT_WORD_W   : integer := 32;
    constant SS_FEAT_PER_CTRL : integer := 3;
    constant SS_FEAT_BUS_W    : integer := SS_CTRL_COUNT * SS_FEAT_PER_CTRL * SS_FEAT_WORD_W;
    constant SS_FEAT_MODAL    : integer := 0;
    constant SS_FEAT_INNOV    : integer := 1;
    constant SS_FEAT_BAND     : integer := 2;

    subtype ss_ctrl_sel_t    is unsigned(SS_CTRL_SEL_W-1 downto 0);
    subtype ss_bank_sel_t    is unsigned(SS_BANK_SEL_W-1 downto 0);
    subtype ss_coeff_index_t is unsigned(SS_COEFF_INDEX_W-1 downto 0);
    subtype ss_coeff_word_t  is signed(WL-1 downto 0);

    type ss_coeff_bank_t is array (0 to SS_COEFFS_PER_BANK - 1) of ss_coeff_word_t;
    type ss_coeff_mem_t  is array (0 to SS_COEFF_MEM_DEPTH - 1) of ss_coeff_word_t;

    function coeff_addr(bank : natural; index : natural) return natural;
    function default_bank(ctrl_slot : natural) return ss_coeff_bank_t;
    function default_mem(ctrl_slot : natural) return ss_coeff_mem_t;

end package ss_coeff_pkg;

package body ss_coeff_pkg is

    function ctrl_pkg_index(ctrl_slot : natural) return integer is
    begin
        -- Returns 1-based index (1..8) for ctrl_slot 0..7
        if ctrl_slot >= SS_CTRL_COUNT then
            return 1;
        else
            return integer(ctrl_slot) + 1;
        end if;
    end function;

    function sel_default_A(ctrl_slot : natural) return coeff_mat_t is
        constant ctrl_idx : integer := ctrl_pkg_index(ctrl_slot);
    begin
        case ctrl_idx is
            when 1      => return A1;
            when 2      => return A2;
            when 3      => return A3;
            when others => return A4;
        end case;
    end function;

    function sel_default_B(ctrl_slot : natural) return coeff_vec_t is
        constant ctrl_idx : integer := ctrl_pkg_index(ctrl_slot);
    begin
        case ctrl_idx is
            when 1      => return B1;
            when 2      => return B2;
            when 3      => return B3;
            when others => return B4;
        end case;
    end function;

    function sel_default_C(ctrl_slot : natural) return coeff_vec_t is
        constant ctrl_idx : integer := ctrl_pkg_index(ctrl_slot);
    begin
        case ctrl_idx is
            when 1      => return C1;
            when 2      => return C2;
            when 3      => return C3;
            when others => return C4;
        end case;
    end function;

    function sel_default_D(ctrl_slot : natural) return signed is
        constant ctrl_idx : integer := ctrl_pkg_index(ctrl_slot);
    begin
        case ctrl_idx is
            when 1      => return D1;
            when 2      => return D2;
            when 3      => return D3;
            when others => return D4;
        end case;
    end function;

    function sel_default_L(ctrl_slot : natural) return coeff_vec_t is
        constant ctrl_idx : integer := ctrl_pkg_index(ctrl_slot);
    begin
        case ctrl_idx is
            when 1      => return L1;
            when 2      => return L2;
            when 3      => return L3;
            when others => return L4;
        end case;
    end function;

    function sel_default_K(ctrl_slot : natural) return coeff_vec_t is
        constant ctrl_idx : integer := ctrl_pkg_index(ctrl_slot);
    begin
        case ctrl_idx is
            when 1      => return K1;
            when 2      => return K2;
            when 3      => return K3;
            when others => return K4;
        end case;
    end function;

    function coeff_addr(bank : natural; index : natural) return natural is
        variable safe_bank  : natural := bank;
        variable safe_index : natural := index;
    begin
        if safe_bank >= SS_BANK_COUNT then
            safe_bank := 0;
        end if;

        if safe_index >= SS_COEFFS_PER_BANK then
            safe_index := 0;
        end if;

        return (safe_bank * SS_COEFFS_PER_BANK) + safe_index;
    end function;

    function default_bank(ctrl_slot : natural) return ss_coeff_bank_t is
        variable bank     : ss_coeff_bank_t := (others => (others => '0'));
        variable a_coeffs : coeff_mat_t(0 to SS_A_COUNT - 1);
        variable b_coeffs : coeff_vec_t(0 to SS_B_COUNT - 1);
        variable c_coeffs : coeff_vec_t(0 to SS_C_COUNT - 1);
        variable d_coeff  : signed(WL-1 downto 0);
        variable l_coeffs : coeff_vec_t(0 to SS_L_COUNT - 1);
        variable k_coeffs : coeff_vec_t(0 to SS_K_COUNT - 1);
    begin
        a_coeffs := sel_default_A(ctrl_slot);
        b_coeffs := sel_default_B(ctrl_slot);
        c_coeffs := sel_default_C(ctrl_slot);
        d_coeff  := sel_default_D(ctrl_slot);
        l_coeffs := sel_default_L(ctrl_slot);
        k_coeffs := sel_default_K(ctrl_slot);

        for coeff_idx in 0 to SS_A_COUNT - 1 loop
            bank(SS_A_BASE + coeff_idx) := a_coeffs(coeff_idx);
        end loop;

        for coeff_idx in 0 to SS_B_COUNT - 1 loop
            bank(SS_B_BASE + coeff_idx) := b_coeffs(coeff_idx);
        end loop;

        for coeff_idx in 0 to SS_C_COUNT - 1 loop
            bank(SS_C_BASE + coeff_idx) := c_coeffs(coeff_idx);
        end loop;

        bank(SS_D_BASE) := d_coeff;
        
        for coeff_idx in 0 to SS_L_COUNT - 1 loop
            bank(SS_L_BASE + coeff_idx) := l_coeffs(coeff_idx);
        end loop;

        for coeff_idx in 0 to SS_K_COUNT - 1 loop
            bank(SS_K_BASE + coeff_idx) := k_coeffs(coeff_idx);
        end loop;

        return bank;
    end function;

    function default_mem(ctrl_slot : natural) return ss_coeff_mem_t is
        variable mem   : ss_coeff_mem_t := (others => (others => '0'));
        variable bank0 : ss_coeff_bank_t := default_bank(ctrl_slot);
    begin
        for bank_idx in 0 to SS_BANK_COUNT - 1 loop
            for coeff_idx in 0 to SS_COEFFS_PER_BANK - 1 loop
                mem(coeff_addr(bank_idx, coeff_idx)) := bank0(coeff_idx);
            end loop;
        end loop;

        return mem;
    end function;

end package body ss_coeff_pkg;