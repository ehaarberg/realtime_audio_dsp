library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity ss_ctrl_runtime is
    generic (
        CTRL_SLOT : integer range 0 to SS_CTRL_COUNT - 1 := 0
    );
    port (
        clk                 : in  std_logic;
        reset               : in  std_logic;
        u                   : in  signed(WL-1 downto 0);
        y_mic               : in  signed(WL-1 downto 0);
        g_in                : in  signed(WL-1 downto 0);
        alpha_in            : in  signed(WL-1 downto 0);
        in_valid            : in  std_logic;
        host_bank           : in  ss_bank_sel_t;
        host_index          : in  ss_coeff_index_t;
        host_wdata          : in  ss_coeff_word_t;
        host_write_stb      : in  std_logic;
        host_read_stb       : in  std_logic;
        shadow_pending_bank : in  ss_bank_sel_t;
        commit_stb          : in  std_logic;
        host_rdata          : out ss_coeff_word_t;
        host_rvalid         : out std_logic;
        active_bank         : out ss_bank_sel_t;
        pending_bank        : out ss_bank_sel_t;
        busy                : out std_logic;
        u_c                 : out signed(WL-1 downto 0);
        u_c_valid           : out std_logic;
        feat_modal          : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
        feat_innov          : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
        feat_valid          : out std_logic
    );
end entity ss_ctrl_runtime;

architecture rtl of ss_ctrl_runtime is
    signal pending_bank_reg : ss_bank_sel_t := (others => '0');
    signal coeff_bank_s     : ss_bank_sel_t := (others => '0');
    signal coeff_index_s    : ss_coeff_index_t := (others => '0');
    signal coeff_data_s     : ss_coeff_word_t := (others => '0');
    signal host_rdata_s     : ss_coeff_word_t := (others => '0');
    signal host_read_dly1    : std_logic := '0';
    signal host_read_dly2    : std_logic := '0';
begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pending_bank_reg <= (others => '0');
                host_read_dly1   <= '0';
                host_read_dly2   <= '0';
            else
                host_read_dly1 <= host_read_stb;
                host_read_dly2 <= host_read_dly1;
                if commit_stb = '1' then
                    pending_bank_reg <= shadow_pending_bank;
                end if;
            end if;
        end if;
    end process;

    pending_bank <= pending_bank_reg;
    host_rdata   <= host_rdata_s;
    host_rvalid  <= host_read_dly2;

    u_coeff_store : entity work.ss_coeff_store
        generic map (
            CTRL_SLOT => CTRL_SLOT
        )
        port map (
            clk        => clk,
            live_bank  => coeff_bank_s,
            live_index => coeff_index_s,
            live_data  => coeff_data_s,
            host_bank  => host_bank,
            host_index => host_index,
            host_wdata => host_wdata,
            host_write => host_write_stb,
            host_rdata => host_rdata_s
        );

    u_ctrl : entity work.ss_obs_ctrl_fsm
        port map (
            clk          => clk,
            reset        => reset,
            u            => u,
            y            => y_mic,
            g_in         => g_in,
            alpha_in     => alpha_in,
            in_valid     => in_valid,
            pending_bank => pending_bank_reg,
            coeff_bank   => coeff_bank_s,
            coeff_index  => coeff_index_s,
            coeff_data   => coeff_data_s,
            active_bank  => active_bank,
            busy         => busy,
            u_c          => u_c,
            u_c_valid    => u_c_valid,
            feat_modal   => feat_modal,
            feat_innov   => feat_innov,
            feat_valid   => feat_valid
        );

end rtl;