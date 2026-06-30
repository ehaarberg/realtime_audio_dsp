-- ss_feature_accum.vhd
-- Per-band feedback-risk feature smoothing (thesis 5.3 / 5.8.1).
--
-- A first-order leaky integrator (single-pole low-pass, unity DC gain) smooths
-- the per-sample energy proxies produced by the observer/controller FSM so the
-- PS supervisor reads stable indicators:
--
--   acc[k] = acc[k-1] + (x[k] - acc[k-1]) >> SHIFT_K
--
-- Inputs:
--   * in_modal : per-sample sum|x_hat| modal-energy magnitude (32-bit, >= 0)
--   * in_innov : per-sample |y - y_hat| innovation magnitude   (32-bit, >= 0)
--   * in_band  : crossover band sample; magnitude is taken internally
-- The smoothed outputs are unsigned 32-bit energy words exposed over AXI.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity ss_feature_accum is
    generic (
        SHIFT_K : integer range 1 to 20 := 8   -- leak rate (larger = slower)
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        sample_valid : in  std_logic;  -- one pulse per processed audio sample
        in_modal     : in  std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
        in_innov     : in  std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
        in_band      : in  signed(WL-1 downto 0);
        e_modal      : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
        e_innov      : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
        e_band       : out std_logic_vector(SS_FEAT_WORD_W-1 downto 0)
    );
end entity ss_feature_accum;

architecture rtl of ss_feature_accum is

    -- One guard bit above the 32-bit word keeps the signed (x - acc)
    -- difference exact while the inputs stay non-negative.
    constant ACC_W : integer := SS_FEAT_WORD_W + 2;

    signal acc_modal : signed(ACC_W-1 downto 0) := (others => '0');
    signal acc_innov : signed(ACC_W-1 downto 0) := (others => '0');
    signal acc_band  : signed(ACC_W-1 downto 0) := (others => '0');

    function band_mag(s : signed(WL-1 downto 0)) return signed is
        variable t : signed(WL downto 0);
    begin
        t := resize(s, WL+1);
        if t < 0 then
            t := -t;
        end if;
        return resize(t, ACC_W);
    end function;

    function as_acc(v : std_logic_vector(SS_FEAT_WORD_W-1 downto 0)) return signed is
    begin
        return signed(resize(unsigned(v), ACC_W));
    end function;

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                acc_modal <= (others => '0');
                acc_innov <= (others => '0');
                acc_band  <= (others => '0');
            elsif sample_valid = '1' then
                acc_modal <= acc_modal + shift_right(as_acc(in_modal) - acc_modal, SHIFT_K);
                acc_innov <= acc_innov + shift_right(as_acc(in_innov) - acc_innov, SHIFT_K);
                acc_band  <= acc_band  + shift_right(band_mag(in_band) - acc_band, SHIFT_K);
            end if;
        end if;
    end process;

    e_modal <= std_logic_vector(acc_modal(SS_FEAT_WORD_W-1 downto 0));
    e_innov <= std_logic_vector(acc_innov(SS_FEAT_WORD_W-1 downto 0));
    e_band  <= std_logic_vector(acc_band(SS_FEAT_WORD_W-1 downto 0));

end rtl;
