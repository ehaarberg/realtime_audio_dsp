-- crossover_filters.vhd
-- 4-band LR4 crossover implemented as a 16-stage time-division-multiplexed
-- (TDM) biquad engine.
--
--  Stage  0: LP300_s1   input=x          -> lp300_a   (-> band0 path)
--  Stage  1: LP300_s2   input=lp300_a    -> lp300_b
--  Stage  2: HP300_s1   input=x          -> hp300_a   (shared; bands 1-3)
--  Stage  3: HP300_s2   input=hp300_a    -> hp300_b
--  Stage  4: LP1000_s1  input=hp300_b    -> lp1000_a  (-> band1 path)
--  Stage  5: LP1000_s2  input=lp1000_a   -> band1
--  Stage  6: HP1000_s1  input=hp300_b    -> hp1000_a  (shared; bands 2-3)
--  Stage  7: HP1000_s2  input=hp1000_a   -> hp1000_b
--  Stage  8: LP2500_s1  input=hp1000_b   -> lp2500_a  (-> band2 path)
--  Stage  9: LP2500_s2  input=lp2500_a   -> band2
--  Stage 10: HP2500_s1  input=hp1000_b   -> hp2500_a  (-> band3 path)
--  Stage 11: HP2500_s2  input=hp2500_a   -> hp2500_b
--  Stage 12: HP50_s1    input=lp300_b    -> hp50_a    (band0 lower skirt, 50 Hz)
--  Stage 13: HP50_s2    input=hp50_a     -> band0     (final 50-300 Hz)
--  Stage 14: LP4500_s1  input=hp2500_b   -> lp4500_a  (band3 upper skirt, 4500 Hz)
--  Stage 15: LP4500_s2  input=lp4500_a   -> band3     (final 2500-4500 Hz)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;

entity crossover_filters is
    port (
        clk   : in  std_logic;
        reset : in  std_logic;
        en    : in  std_logic;
        x     : in  signed(WL-1 downto 0);
        band0 : out signed(WL-1 downto 0);
        band1 : out signed(WL-1 downto 0);
        band2 : out signed(WL-1 downto 0);
        band3 : out signed(WL-1 downto 0);
        band4 : out signed(WL-1 downto 0);
        band5 : out signed(WL-1 downto 0);
        band6 : out signed(WL-1 downto 0);
        band7 : out signed(WL-1 downto 0);
        valid : out std_logic
    );
end crossover_filters;

architecture rtl of crossover_filters is
    constant N_STAGES : integer := 16;
    type biquad_rom_t is array (0 to N_STAGES-1) of biquad_coeff_t;

    constant COEFF_ROM : biquad_rom_t := (
        LP300_COEFFS(0),
        LP300_COEFFS(1),
        HP300_COEFFS(0),
        HP300_COEFFS(1),
        LP1000_COEFFS(0),
        LP1000_COEFFS(1),
        HP1000_COEFFS(0),
        HP1000_COEFFS(1),
        LP2500_COEFFS(0),
        LP2500_COEFFS(1),
        HP2500_COEFFS(0),
        HP2500_COEFFS(1),
        HP50_COEFFS(0),
        HP50_COEFFS(1),
        LP4500_COEFFS(0),
        LP4500_COEFFS(1)
    );
 
    type word_array_t is array (0 to N_STAGES-1) of signed(WL-1 downto 0);
    signal st_x1 : word_array_t := (others => (others => '0'));
    signal st_x2 : word_array_t := (others => (others => '0'));
    signal st_y1 : word_array_t := (others => (others => '0'));
    signal st_y2 : word_array_t := (others => (others => '0'));

    signal running : std_logic := '0';
    signal stage   : integer range 0 to N_STAGES-1 := 0;
    signal phase   : integer range 0 to 7 := 0;

    signal bq_in_r                          : signed(WL-1 downto 0) := (others => '0');
    signal b0_r, b1_r, b2_r, a1_r, a2_r    : signed(WL-1 downto 0) := (others => '0');
    signal x1_r, x2_r, y1_r, y2_r          : signed(WL-1 downto 0) := (others => '0');

    signal prod_p  : signed(WL*2-1 downto 0) := (others => '0');
    signal acc_p   : signed(WL*2+3 downto 0) := (others => '0');

    signal x_reg     : signed(WL-1 downto 0) := (others => '0');

    signal lp300_a   : signed(WL-1 downto 0) := (others => '0');
    signal lp300_b   : signed(WL-1 downto 0) := (others => '0');
    signal hp300_a   : signed(WL-1 downto 0) := (others => '0');
    signal lp1000_a  : signed(WL-1 downto 0) := (others => '0');
    signal hp1000_a  : signed(WL-1 downto 0) := (others => '0');
    signal lp2500_a  : signed(WL-1 downto 0) := (others => '0');
    signal hp2500_a  : signed(WL-1 downto 0) := (others => '0');
    signal hp2500_b  : signed(WL-1 downto 0) := (others => '0');
    signal hp50_a    : signed(WL-1 downto 0) := (others => '0');
    signal lp4500_a  : signed(WL-1 downto 0) := (others => '0');
    signal hp300_b   : signed(WL-1 downto 0) := (others => '0');
    signal hp1000_b  : signed(WL-1 downto 0) := (others => '0');

    constant ACC_WL : integer := WL * 2 + 4;
    constant SHIFT  : integer := FL;

    signal bq_in : signed(WL-1 downto 0);

    constant VALID_DELAY : integer := N_STAGES * 8 + 1;
    signal valid_sr : std_logic_vector(VALID_DELAY-1 downto 0) := (others => '0');

begin

    process(stage, x_reg, lp300_a, lp300_b, hp300_a, hp300_b, lp1000_a, hp1000_a, hp1000_b, lp2500_a, hp2500_a, hp2500_b, hp50_a, lp4500_a)
    begin
        case stage is
            when  0 => bq_in <= x_reg;
            when  1 => bq_in <= lp300_a;
            when  2 => bq_in <= x_reg;
            when  3 => bq_in <= hp300_a;
            when  4 => bq_in <= hp300_b;
            when  5 => bq_in <= lp1000_a;
            when  6 => bq_in <= hp300_b;
            when  7 => bq_in <= hp1000_a;
            when  8 => bq_in <= hp1000_b;
            when  9 => bq_in <= lp2500_a;
            when 10 => bq_in <= hp1000_b;
            when 11 => bq_in <= hp2500_a;
            when 12 => bq_in <= lp300_b;
            when 13 => bq_in <= hp50_a;
            when 14 => bq_in <= hp2500_b;
            when others => bq_in <= lp4500_a;
        end case;
    end process;

    process(clk)
        variable coeff : biquad_coeff_t;
        variable y_new : signed(WL-1 downto 0);
        variable acc_sat : signed(ACC_WL - SHIFT - 1 downto 0);
        constant MAX_VAL : signed(ACC_WL - SHIFT - 1 downto 0) := to_signed( 2**(WL-1) - 1, ACC_WL - SHIFT);
        constant MIN_VAL : signed(ACC_WL - SHIFT - 1 downto 0) := to_signed(-2**(WL-1),     ACC_WL - SHIFT);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                running   <= '0';
                stage     <= 0;
                phase     <= 0;
                valid_sr  <= (others => '0');
                bq_in_r   <= (others => '0');
                b0_r <= (others => '0'); b1_r <= (others => '0'); b2_r <= (others => '0');
                a1_r <= (others => '0'); a2_r <= (others => '0');
                x1_r <= (others => '0'); x2_r <= (others => '0');
                y1_r <= (others => '0'); y2_r <= (others => '0');
                prod_p    <= (others => '0');
                acc_p     <= (others => '0');
                x_reg     <= (others => '0');
                lp300_a   <= (others => '0'); hp300_a   <= (others => '0');
                hp300_b   <= (others => '0');
                lp300_b   <= (others => '0');
                hp50_a    <= (others => '0');
                hp2500_b  <= (others => '0'); lp4500_a  <= (others => '0');
                lp1000_a  <= (others => '0'); hp1000_a  <= (others => '0');
                hp1000_b  <= (others => '0');
                lp2500_a  <= (others => '0'); hp2500_a  <= (others => '0');
                for i in 0 to N_STAGES-1 loop
                    st_x1(i) <= (others => '0');
                    st_x2(i) <= (others => '0');
                    st_y1(i) <= (others => '0');
                    st_y2(i) <= (others => '0');
                end loop;
                band0 <= (others => '0');  band1 <= (others => '0');
                band2 <= (others => '0');  band3 <= (others => '0');
                band4 <= (others => '0');  band5 <= (others => '0');
                band6 <= (others => '0');  band7 <= (others => '0');
            else
                if en = '1' and running = '0' then
                    x_reg    <= x;
                    running  <= '1';
                    stage    <= 0;
                    phase    <= 0;
                    valid_sr <= valid_sr(VALID_DELAY-2 downto 0) & '1';
                else
                    valid_sr <= valid_sr(VALID_DELAY-2 downto 0) & '0';
                end if;

                if running = '1' then
                    phase <= phase + 1;
                    case phase is
                        when 0 =>
                            coeff := COEFF_ROM(stage);
                            b0_r <= coeff(0); b1_r <= coeff(1); b2_r <= coeff(2);
                            a1_r <= coeff(3); a2_r <= coeff(4);
                            bq_in_r <= bq_in;
                            x1_r <= st_x1(stage); x2_r <= st_x2(stage);
                            y1_r <= st_y1(stage); y2_r <= st_y2(stage);
                        when 1 =>
                            prod_p <= b0_r * bq_in_r;
                            acc_p  <= (others => '0');
                        when 2 =>
                            acc_p  <= resize(prod_p, ACC_WL);
                            prod_p <= b1_r * x1_r;
                        when 3 =>
                            acc_p  <= acc_p + resize(prod_p, ACC_WL);
                            prod_p <= b2_r * x2_r;
                        when 4 =>
                            acc_p  <= acc_p + resize(prod_p, ACC_WL);
                            prod_p <= a1_r * y1_r;
                        when 5 =>
                            acc_p  <= acc_p - resize(prod_p, ACC_WL);
                            prod_p <= a2_r * y2_r;
                        when 6 =>
                            acc_p <= acc_p - resize(prod_p, ACC_WL);
                        when 7 =>
                            acc_sat := acc_p(ACC_WL-1 downto SHIFT);
                            if acc_sat > MAX_VAL then
                                y_new := MAX_VAL(WL-1 downto 0);
                            elsif acc_sat < MIN_VAL then
                                y_new := MIN_VAL(WL-1 downto 0);
                            else
                                y_new := acc_sat(WL-1 downto 0);
                            end if;

                            st_x2(stage) <= x1_r;
                            st_x1(stage) <= bq_in_r;
                            st_y2(stage) <= y1_r;
                            st_y1(stage) <= y_new;

                            case stage is
                                when  0 => lp300_a   <= y_new;
                                when  1 => lp300_b   <= y_new;
                                when  2 => hp300_a   <= y_new;
                                when  3 => hp300_b   <= y_new;
                                when  4 => lp1000_a  <= y_new;
                                when  5 => band1     <= y_new;
                                when  6 => hp1000_a  <= y_new;
                                when  7 => hp1000_b  <= y_new;
                                when  8 => lp2500_a  <= y_new;
                                when  9 => band2     <= y_new;
                                when 10 => hp2500_a  <= y_new;
                                when 11 => hp2500_b  <= y_new;
                                when 12 => hp50_a    <= y_new;
                                when 13 => band0     <= y_new;
                                when 14 => lp4500_a  <= y_new;
                                when others => band3 <= y_new;
                            end case;

                            if stage = N_STAGES-1 then
                                running <= '0';
                            else
                                stage <= stage + 1;
                            end if;
                            phase <= 0;
                    end case;
                end if;
            end if;
        end if;
    end process;

    valid <= valid_sr(VALID_DELAY-1);
end rtl;
