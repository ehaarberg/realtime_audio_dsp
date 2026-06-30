library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adau1761_i2s is
    generic (
        word_bits : integer := 24
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        audio_in_valid  : out std_logic;
        audio_in_l      : out std_logic_vector(word_bits - 1 downto 0);
        audio_in_r      : out std_logic_vector(word_bits - 1 downto 0);
        audio_out_valid : in  std_logic;
        audio_out_l     : in  std_logic_vector(word_bits - 1 downto 0);
        audio_out_r     : in  std_logic_vector(word_bits - 1 downto 0);

        bclk            : in  std_logic;
        lrclk           : in  std_logic;
        sdata_in        : in  std_logic;
        sdata_out       : out std_logic
    );
end entity adau1761_i2s;

architecture rtl of adau1761_i2s is

    function rising(vec : std_logic_vector(4 downto 0)) return boolean is
    begin
        return vec(1 downto 0) = "10";
    end function;

    function falling(vec : std_logic_vector(4 downto 0)) return boolean is
    begin
        return vec(1 downto 0) = "01";
    end function;

    type state_type is (S0, S1, S2, S3, S4, S5, S6, S7);

    signal state      : state_type;
    signal bit_cnt    : integer range 0 to word_bits - 1;

    signal in_l_reg   : std_logic_vector(word_bits - 1 downto 0);
    signal in_r_reg   : std_logic_vector(word_bits - 1 downto 0);
    signal out_l_reg1 : std_logic_vector(word_bits - 1 downto 0);
    signal out_r_reg1 : std_logic_vector(word_bits - 1 downto 0);
    signal out_l_reg2 : std_logic_vector(word_bits - 1 downto 0);
    signal out_r_reg2 : std_logic_vector(word_bits - 1 downto 0);

    signal blck_p     : std_logic_vector(4 downto 0);
    signal lrclk_p    : std_logic_vector(4 downto 0);
    signal sdata_in_p : std_logic_vector(4 downto 0);

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                blck_p     <= (others => '0');
                lrclk_p    <= (others => '0');
                sdata_in_p <= (others => '0');
            else
                blck_p     <= bclk & blck_p(blck_p'high downto blck_p'low + 1);
                lrclk_p    <= lrclk & lrclk_p(lrclk_p'high downto lrclk_p'low + 1);
                sdata_in_p <= sdata_in & sdata_in_p(sdata_in_p'high downto sdata_in_p'low + 1);
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_l_reg1 <= (others => '0');
                out_r_reg1 <= (others => '0');
            elsif audio_out_valid = '1' then
                out_l_reg1 <= audio_out_l;
                out_r_reg1 <= audio_out_r;
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state          <= S0;
                sdata_out      <= '0';
                audio_in_valid <= '0';
                audio_in_l     <= (others => '0');
                audio_in_r     <= (others => '0');
                in_l_reg       <= (others => '0');
                in_r_reg       <= (others => '0');
                out_l_reg2     <= (others => '0');
                out_r_reg2     <= (others => '0');
                bit_cnt        <= 0;
            else
                audio_in_valid <= '0';

                case state is
                    when S0 =>
                        if falling(lrclk_p) then
                            state      <= S1;
                            out_l_reg2 <= out_l_reg1;
                            out_r_reg2 <= out_r_reg1;
                        end if;

                    when S1 =>
                        if rising(blck_p) then
                            state   <= S2;
                            bit_cnt <= word_bits - 1;
                        end if;

                    when S2 =>
                        if falling(blck_p) then
                            sdata_out <= out_l_reg2(bit_cnt);
                        end if;

                        if rising(blck_p) then
                            in_l_reg(bit_cnt) <= sdata_in_p(0);
                            if bit_cnt = 0 then
                                state <= S3;
                            else
                                bit_cnt <= bit_cnt - 1;
                            end if;
                        end if;

                    when S3 =>
                        if falling(blck_p) then
                            state     <= S4;
                            sdata_out <= '0';
                        end if;

                    when S4 =>
                        if rising(lrclk_p) then
                            state <= S5;
                        end if;

                    when S5 =>
                        if rising(blck_p) then
                            state   <= S6;
                            bit_cnt <= word_bits - 1;
                        end if;

                    when S6 =>
                        if falling(blck_p) then
                            sdata_out <= out_r_reg2(bit_cnt);
                        end if;

                        if rising(blck_p) then
                            in_r_reg(bit_cnt) <= sdata_in_p(0);
                            if bit_cnt = 0 then
                                state <= S7;
                            else
                                bit_cnt <= bit_cnt - 1;
                            end if;
                        end if;

                    when S7 =>
                        if falling(blck_p) then
                            state          <= S0;
                            sdata_out      <= '0';
                            audio_in_valid <= '1';
                            audio_in_l     <= in_l_reg;
                            audio_in_r     <= in_r_reg;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;