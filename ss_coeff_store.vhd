library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity ss_coeff_store is
    generic (
        CTRL_SLOT : integer range 0 to SS_CTRL_COUNT - 1 := 0
    );
    port (
        clk         : in  std_logic;
        live_bank   : in  ss_bank_sel_t;
        live_index  : in  ss_coeff_index_t;
        live_data   : out ss_coeff_word_t;
        host_bank   : in  ss_bank_sel_t;
        host_index  : in  ss_coeff_index_t;
        host_wdata  : in  ss_coeff_word_t;
        host_write  : in  std_logic;
        host_rdata  : out ss_coeff_word_t
    );
end entity ss_coeff_store;

architecture rtl of ss_coeff_store is
    signal mem : ss_coeff_mem_t := default_mem(CTRL_SLOT);
    attribute ram_style : string;
    attribute ram_style of mem : signal is "block";
    
    signal live_data_ram : ss_coeff_word_t;
    signal host_rdata_ram : ss_coeff_word_t;
    signal live_data_reg : ss_coeff_word_t;
    signal host_rdata_reg : ss_coeff_word_t;
begin

    process(clk)
        variable live_addr_i : natural range 0 to SS_COEFF_MEM_DEPTH - 1;
        variable host_addr_i : natural range 0 to SS_COEFF_MEM_DEPTH - 1;
    begin
        if rising_edge(clk) then
            live_addr_i := coeff_addr(to_integer(live_bank), to_integer(live_index));
            host_addr_i := coeff_addr(to_integer(host_bank), to_integer(host_index));

            if host_write = '1' then
                mem(host_addr_i) <= host_wdata;
            end if;

            live_data_ram <= mem(live_addr_i);
            host_rdata_ram <= mem(host_addr_i);
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            live_data_reg <= live_data_ram;
            host_rdata_reg <= host_rdata_ram;
        end if;
    end process;

    live_data <= live_data_reg;
    host_rdata <= host_rdata_reg;

end rtl;