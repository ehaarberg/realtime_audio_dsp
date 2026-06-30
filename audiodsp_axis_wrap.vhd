-- audiodsp_axis_wrap.vhd
-- Serial I2S wrapper around audio_crossover_top.
--
-- The ADAU1761 clocks the I2S bus. adau1761_i2s synchronizes BCLK/LRCLK/SDATA
-- into the 100 MHz system clock and emits one clean sample-valid pulse per full
-- stereo frame. For this bring-up slice the DSP top runs the full crossover
-- controller path so the custom serial receive/transmit path stays unchanged
-- while the SS stages are exercised behind the verified crossover bank.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity audiodsp_axis_wrap is
    port (
        clk                       : in  std_logic;
        resetn                    : in  std_logic;
        bclk                      : in  std_logic;
        lrclk                     : in  std_logic;
        sdata_in                  : in  std_logic;
        coeff_target_ctrl         : in  std_logic_vector(SS_CTRL_SEL_W-1 downto 0);
        coeff_target_bank         : in  std_logic_vector(SS_BANK_SEL_W-1 downto 0);
        coeff_index               : in  std_logic_vector(SS_COEFF_INDEX_W-1 downto 0);
        coeff_wdata               : in  std_logic_vector(WL-1 downto 0);
        coeff_write_stb           : in  std_logic;
        coeff_read_stb            : in  std_logic;
        coeff_shadow_pending_bank : in  std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
        coeff_commit_mask         : in  std_logic_vector(SS_CTRL_COUNT - 1 downto 0);
        coeff_commit_stb          : in  std_logic;
        coeff_rdata               : out std_logic_vector(WL-1 downto 0);
        coeff_rvalid              : out std_logic;
        coeff_active_bank_status  : out std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
        coeff_pending_bank_status : out std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
        coeff_busy_status         : out std_logic_vector(SS_CTRL_COUNT - 1 downto 0);
        coeff_g_in                : in  std_logic_vector(SS_CTRL_COUNT * WL - 1 downto 0);
        coeff_alpha_in            : in  std_logic_vector(SS_CTRL_COUNT * WL - 1 downto 0);
        -- Width = SS_FEAT_BUS_W; expanded to leaf constants so the Vivado IP
        -- packager can resolve the port width (it cannot evaluate derived
        -- package constants in port expressions).
        coeff_feat_out            : out std_logic_vector(SS_CTRL_COUNT * SS_FEAT_PER_CTRL * SS_FEAT_WORD_W - 1 downto 0);
        sdata_out                 : out std_logic
    );
end entity audiodsp_axis_wrap;

architecture rtl of audiodsp_axis_wrap is
    signal reset_i      : std_logic;
    signal i2s_in_valid : std_logic;
    signal i2s_in_l     : std_logic_vector(WL-1 downto 0);
    signal i2s_in_r     : std_logic_vector(WL-1 downto 0);
    signal tx_sample    : std_logic_vector(WL-1 downto 0);
    signal tx_valid_r   : std_logic;

    signal audio_in     : signed(WL-1 downto 0);
    signal mic_near     : signed(WL-1 downto 0);
    signal audio_out    : signed(WL-1 downto 0);
    signal out_valid    : std_logic;
    signal in_valid_r   : std_logic;
    signal s_axis_tid   : std_logic_vector(2 downto 0);

begin

    reset_i      <= not resetn;
    s_axis_tid   <= bclk & lrclk & in_valid_r;

    u_i2s : entity work.adau1761_i2s
        generic map (
            word_bits => WL
        )
        port map (
            clk             => clk,
            rst             => reset_i,
            audio_in_valid  => i2s_in_valid,
            audio_in_l      => i2s_in_l,
            audio_in_r      => i2s_in_r,
            audio_out_valid => tx_valid_r,
            audio_out_l     => tx_sample,
            audio_out_r     => tx_sample,
            bclk            => bclk,
            lrclk           => lrclk,
            sdata_in        => sdata_in,
            sdata_out       => sdata_out
        );

    process(clk)
    begin
        if rising_edge(clk) then
            if reset_i = '1' then
                audio_in   <= (others => '0');
                mic_near   <= (others => '0');
                in_valid_r <= '0';
            else
                if i2s_in_valid = '1' then
                    audio_in <= signed(i2s_in_l);
                    mic_near <= signed(i2s_in_r);
                end if;
                in_valid_r <= i2s_in_valid;
            end if;
        end if;
    end process;

    u_top : entity work.audio_crossover_top
        generic map (
            BYPASS    => false,
            BYPASS_SS => false
        )
        port map (
            clk                       => clk,
            reset                     => reset_i,
            Audio_In                  => audio_in,
            Mic_Near                  => mic_near,
            In_Valid                  => in_valid_r,
            coeff_target_ctrl         => coeff_target_ctrl,
            coeff_target_bank         => coeff_target_bank,
            coeff_index               => coeff_index,
            coeff_wdata               => coeff_wdata,
            coeff_write_stb           => coeff_write_stb,
            coeff_read_stb            => coeff_read_stb,
            coeff_shadow_pending_bank => coeff_shadow_pending_bank,
            coeff_commit_mask         => coeff_commit_mask,
            coeff_commit_stb          => coeff_commit_stb,
            coeff_rdata               => coeff_rdata,
            coeff_rvalid              => coeff_rvalid,
            coeff_active_bank_status  => coeff_active_bank_status,
            coeff_pending_bank_status => coeff_pending_bank_status,
            coeff_busy_status         => coeff_busy_status,
            coeff_g_in                => coeff_g_in,
            coeff_alpha_in            => coeff_alpha_in,
            coeff_feat_out            => coeff_feat_out,
            Audio_Out                 => audio_out,
            Out_Valid                 => out_valid
        );

    process(clk)
    begin
        if rising_edge(clk) then
            if reset_i = '1' then
                tx_sample  <= (others => '0');
                tx_valid_r <= '0';
            else
                tx_valid_r <= out_valid;
                if out_valid = '1' then
                    tx_sample <= std_logic_vector(audio_out);
                end if;
            end if;
        end if;
    end process;

end rtl;


