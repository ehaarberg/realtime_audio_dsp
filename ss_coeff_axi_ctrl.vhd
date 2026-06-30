library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity ss_coeff_axi_ctrl is
    port (
        S_AXI_ACLK               : in  std_logic;
        S_AXI_ARESETN            : in  std_logic;
        S_AXI_AWADDR             : in  std_logic_vector(7 downto 0);
        S_AXI_AWPROT             : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID            : in  std_logic;
        S_AXI_AWREADY            : out std_logic;
        S_AXI_WDATA              : in  std_logic_vector(31 downto 0);
        S_AXI_WSTRB              : in  std_logic_vector(3 downto 0);
        S_AXI_WVALID             : in  std_logic;
        S_AXI_WREADY             : out std_logic;
        S_AXI_BRESP              : out std_logic_vector(1 downto 0);
        S_AXI_BVALID             : out std_logic;
        S_AXI_BREADY             : in  std_logic;
        S_AXI_ARADDR             : in  std_logic_vector(7 downto 0);
        S_AXI_ARPROT             : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID            : in  std_logic;
        S_AXI_ARREADY            : out std_logic;
        S_AXI_RDATA              : out std_logic_vector(31 downto 0);
        S_AXI_RRESP              : out std_logic_vector(1 downto 0);
        S_AXI_RVALID             : out std_logic;
        S_AXI_RREADY             : in  std_logic;
        coeff_target_ctrl        : out std_logic_vector(SS_CTRL_SEL_W-1 downto 0);
        coeff_target_bank        : out std_logic_vector(SS_BANK_SEL_W-1 downto 0);
        coeff_index              : out std_logic_vector(SS_COEFF_INDEX_W-1 downto 0);
        coeff_wdata              : out std_logic_vector(WL-1 downto 0);
        coeff_write_stb          : out std_logic;
        coeff_read_stb           : out std_logic;
        coeff_shadow_pending_bank : out std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
        coeff_commit_mask        : out std_logic_vector(SS_CTRL_COUNT - 1 downto 0);
        coeff_commit_stb         : out std_logic;
        coeff_rdata              : in  std_logic_vector(WL-1 downto 0);
        coeff_rvalid             : in  std_logic;
        coeff_active_bank_status : in  std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
        coeff_pending_bank_status : in  std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
        coeff_busy_status        : in  std_logic_vector(SS_CTRL_COUNT - 1 downto 0);
        coeff_g_out              : out std_logic_vector(SS_CTRL_COUNT * WL - 1 downto 0);
        coeff_alpha_out          : out std_logic_vector(SS_CTRL_COUNT * WL - 1 downto 0);
        -- Width = SS_FEAT_BUS_W; expanded to leaf constants so the Vivado IP
        -- packager can resolve the port width (it cannot evaluate derived
        -- package constants in port expressions).
        coeff_feat_in            : in  std_logic_vector(SS_CTRL_COUNT * SS_FEAT_PER_CTRL * SS_FEAT_WORD_W - 1 downto 0)
    );
end entity ss_coeff_axi_ctrl;

architecture rtl of ss_coeff_axi_ctrl is
    constant REG_CONTROL        : integer := 16#00# / 4;
    constant REG_TARGET         : integer := 16#04# / 4;
    constant REG_WDATA          : integer := 16#08# / 4;
    constant REG_RDATA          : integer := 16#0C# / 4;
    constant REG_SHADOW_PENDING : integer := 16#10# / 4;
    constant REG_LIVE_ACTIVE    : integer := 16#14# / 4;
    constant REG_LIVE_PENDING   : integer := 16#18# / 4;
    constant REG_STATUS         : integer := 16#1C# / 4;
    constant REG_VERSION        : integer := 16#20# / 4;
    constant REG_G_0            : integer := 16#24# / 4;
    constant REG_ALPHA_0        : integer := 16#28# / 4;
    constant REG_G_1            : integer := 16#2C# / 4;
    constant REG_ALPHA_1        : integer := 16#30# / 4;
    constant REG_G_2            : integer := 16#34# / 4;
    constant REG_ALPHA_2        : integer := 16#38# / 4;
    constant REG_G_3            : integer := 16#3C# / 4;
    constant REG_ALPHA_3        : integer := 16#40# / 4;

    -- Read-only feedback-risk feature registers (thesis 5.3 / 5.8.1).
    --   0x44 + 4*b : E_innov[b]   (innovation residual energy)
    --   0x54 + 4*b : E_band[b]    (band signal energy)
    --   0x64 + 4*b : E_modal[b]   (observer modal energy)
    constant REG_FEAT_INNOV_0   : integer := 16#44# / 4;
    constant REG_FEAT_BAND_0    : integer := 16#54# / 4;
    constant REG_FEAT_MODAL_0   : integer := 16#64# / 4;

    constant VERSION_WORD : std_logic_vector(31 downto 0) := x"53534332";

    -- Extract one 32-bit feature word for controller c, feature kind w.
    function feat_slice(bus_in : std_logic_vector; c : integer; w : integer)
        return std_logic_vector is
        constant lo : integer := (c * SS_FEAT_PER_CTRL + w) * SS_FEAT_WORD_W;
    begin
        return bus_in(lo + SS_FEAT_WORD_W - 1 downto lo);
    end function;

    signal awaddr_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal wdata_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb_reg  : std_logic_vector(3 downto 0) := (others => '0');
    signal araddr_reg : std_logic_vector(7 downto 0) := (others => '0');

    signal aw_pending : std_logic := '0';
    signal w_pending  : std_logic := '0';
    signal ar_pending : std_logic := '0';
    signal bvalid_reg : std_logic := '0';
    signal rvalid_reg : std_logic := '0';
    signal rdata_reg  : std_logic_vector(31 downto 0) := (others => '0');

    signal coeff_target_ctrl_reg : std_logic_vector(SS_CTRL_SEL_W-1 downto 0) := (others => '0');
    signal coeff_target_bank_reg : std_logic_vector(SS_BANK_SEL_W-1 downto 0) := (others => '0');
    signal coeff_index_reg       : std_logic_vector(SS_COEFF_INDEX_W-1 downto 0) := (others => '0');
    signal coeff_wdata_reg       : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal shadow_pending_reg    : std_logic_vector(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0) := (others => '0');
    signal g_reg_0     : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal alpha_reg_0 : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal g_reg_1     : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal alpha_reg_1 : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal g_reg_2     : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal alpha_reg_2 : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal g_reg_3     : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal alpha_reg_3 : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal commit_mask_reg       : std_logic_vector(SS_CTRL_COUNT - 1 downto 0) := (others => '0');

    signal coeff_write_stb_reg : std_logic := '0';
    signal coeff_read_stb_reg  : std_logic := '0';
    signal coeff_commit_stb_reg : std_logic := '0';

    signal readback_data_reg  : std_logic_vector(WL-1 downto 0) := (others => '0');
    signal readback_valid_reg : std_logic := '0';
    signal awready_i          : std_logic;
    signal wready_i           : std_logic;
    signal arready_i          : std_logic;
begin

    awready_i <= '1' when aw_pending = '0' and bvalid_reg = '0' else '0';
    wready_i  <= '1' when w_pending = '0' and bvalid_reg = '0' else '0';
    arready_i <= '1' when ar_pending = '0' and rvalid_reg = '0' else '0';

    S_AXI_AWREADY <= awready_i;
    S_AXI_WREADY  <= wready_i;
    S_AXI_BRESP   <= "00";
    S_AXI_BVALID  <= bvalid_reg;

    S_AXI_ARREADY <= arready_i;
    S_AXI_RDATA   <= rdata_reg;
    S_AXI_RRESP   <= "00";
    S_AXI_RVALID  <= rvalid_reg;

    coeff_target_ctrl         <= coeff_target_ctrl_reg;
    coeff_target_bank         <= coeff_target_bank_reg;
    coeff_index               <= coeff_index_reg;
    coeff_wdata               <= coeff_wdata_reg;
    coeff_write_stb           <= coeff_write_stb_reg;
    coeff_read_stb            <= coeff_read_stb_reg;
    coeff_shadow_pending_bank <= shadow_pending_reg;
    coeff_commit_mask         <= commit_mask_reg;
    coeff_commit_stb          <= coeff_commit_stb_reg;

    coeff_g_out(1 * WL - 1 downto 0 * WL) <= g_reg_0;
    coeff_g_out(2 * WL - 1 downto 1 * WL) <= g_reg_1;
    coeff_g_out(3 * WL - 1 downto 2 * WL) <= g_reg_2;
    coeff_g_out(4 * WL - 1 downto 3 * WL) <= g_reg_3;
    coeff_alpha_out(1 * WL - 1 downto 0 * WL) <= alpha_reg_0;
    coeff_alpha_out(2 * WL - 1 downto 1 * WL) <= alpha_reg_1;
    coeff_alpha_out(3 * WL - 1 downto 2 * WL) <= alpha_reg_2;
    coeff_alpha_out(4 * WL - 1 downto 3 * WL) <= alpha_reg_3;

    process(S_AXI_ACLK)
        variable write_word_addr : integer range 0 to 63;
        variable read_word_addr  : integer range 0 to 63;
        variable read_data_v     : std_logic_vector(31 downto 0);
    begin
        if rising_edge(S_AXI_ACLK) then
            coeff_write_stb_reg  <= '0';
            coeff_read_stb_reg   <= '0';
            coeff_commit_stb_reg <= '0';

            if S_AXI_ARESETN = '0' then
                awaddr_reg             <= (others => '0');
                wdata_reg              <= (others => '0');
                wstrb_reg              <= (others => '0');
                araddr_reg             <= (others => '0');
                aw_pending             <= '0';
                w_pending              <= '0';
                ar_pending             <= '0';
                bvalid_reg             <= '0';
                rvalid_reg             <= '0';
                rdata_reg              <= (others => '0');
                coeff_target_ctrl_reg  <= (others => '0');
                coeff_target_bank_reg  <= (others => '0');
                coeff_index_reg        <= (others => '0');
                coeff_wdata_reg        <= (others => '0');
                shadow_pending_reg     <= (others => '0');
                commit_mask_reg        <= (others => '0');
                readback_data_reg      <= (others => '0');
                readback_valid_reg     <= '0';
            else
                if coeff_rvalid = '1' then
                    readback_data_reg  <= coeff_rdata;
                    readback_valid_reg <= '1';
                end if;

                if awready_i = '1' and S_AXI_AWVALID = '1' then
                    awaddr_reg <= S_AXI_AWADDR;
                    aw_pending <= '1';
                end if;

                if wready_i = '1' and S_AXI_WVALID = '1' then
                    wdata_reg <= S_AXI_WDATA;
                    wstrb_reg <= S_AXI_WSTRB;
                    w_pending <= '1';
                end if;

                if aw_pending = '1' and w_pending = '1' and bvalid_reg = '0' then
                    write_word_addr := to_integer(unsigned(awaddr_reg(7 downto 2)));
                    if wstrb_reg /= "0000" then
                        case write_word_addr is
                            when REG_CONTROL =>
                                if wdata_reg(0) = '1' then
                                    coeff_write_stb_reg <= '1';
                                end if;
                                if wdata_reg(1) = '1' then
                                    coeff_read_stb_reg  <= '1';
                                    readback_valid_reg  <= '0';
                                end if;
                                if wdata_reg(2) = '1' then
                                    coeff_commit_stb_reg <= '1';
                                    commit_mask_reg      <= wdata_reg(8 + SS_CTRL_COUNT - 1 downto 8);
                                end if;

                            when REG_TARGET =>
                                coeff_target_ctrl_reg <= wdata_reg(SS_CTRL_SEL_W-1 downto 0);
                                coeff_target_bank_reg <= wdata_reg(4 + SS_BANK_SEL_W - 1 downto 4);
                                coeff_index_reg       <= wdata_reg(12 + SS_COEFF_INDEX_W - 1 downto 12);

                            when REG_WDATA =>
                                coeff_wdata_reg <= wdata_reg(WL-1 downto 0);

                            when REG_SHADOW_PENDING =>
                                shadow_pending_reg <= wdata_reg(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0);
                            when REG_G_0 => g_reg_0 <= wdata_reg(WL-1 downto 0);
                            when REG_ALPHA_0 => alpha_reg_0 <= wdata_reg(WL-1 downto 0);
                            when REG_G_1 => g_reg_1 <= wdata_reg(WL-1 downto 0);
                            when REG_ALPHA_1 => alpha_reg_1 <= wdata_reg(WL-1 downto 0);
                            when REG_G_2 => g_reg_2 <= wdata_reg(WL-1 downto 0);
                            when REG_ALPHA_2 => alpha_reg_2 <= wdata_reg(WL-1 downto 0);
                            when REG_G_3 => g_reg_3 <= wdata_reg(WL-1 downto 0);
                            when REG_ALPHA_3 => alpha_reg_3 <= wdata_reg(WL-1 downto 0);

                            when others =>
                                null;
                        end case;
                    end if;

                    aw_pending <= '0';
                    w_pending  <= '0';
                    bvalid_reg <= '1';
                elsif bvalid_reg = '1' and S_AXI_BREADY = '1' then
                    bvalid_reg <= '0';
                end if;

                if arready_i = '1' and S_AXI_ARVALID = '1' then
                    araddr_reg <= S_AXI_ARADDR;
                    ar_pending <= '1';
                end if;

                if ar_pending = '1' and rvalid_reg = '0' then
                    read_word_addr := to_integer(unsigned(araddr_reg(7 downto 2)));
                    read_data_v := (others => '0');

                    case read_word_addr is
                        when REG_CONTROL =>
                            read_data_v(0)            := readback_valid_reg;
                            read_data_v(8 + SS_CTRL_COUNT - 1 downto 8)  := commit_mask_reg;

                        when REG_TARGET =>
                            read_data_v(SS_CTRL_SEL_W-1 downto 0)  := coeff_target_ctrl_reg;
                            read_data_v(4 + SS_BANK_SEL_W - 1 downto 4)  := coeff_target_bank_reg;
                            read_data_v(12 + SS_COEFF_INDEX_W - 1 downto 12) := coeff_index_reg;

                        when REG_WDATA =>
                            read_data_v := std_logic_vector(resize(signed(coeff_wdata_reg), 32));

                        when REG_RDATA =>
                            read_data_v := std_logic_vector(resize(signed(readback_data_reg), 32));

                        when REG_SHADOW_PENDING =>
                            read_data_v(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0) := shadow_pending_reg;

                        when REG_LIVE_ACTIVE =>
                            read_data_v(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0) := coeff_active_bank_status;

                        when REG_LIVE_PENDING =>
                            read_data_v(SS_CTRL_COUNT * SS_BANK_SEL_W - 1 downto 0) := coeff_pending_bank_status;

                        when REG_STATUS =>
                            read_data_v(SS_CTRL_COUNT - 1 downto 0) := coeff_busy_status;
                            read_data_v(8)                          := readback_valid_reg;

                        when REG_VERSION =>
                            read_data_v := VERSION_WORD;
                    when REG_G_0 => read_data_v(WL-1 downto 0) := g_reg_0;
                    when REG_ALPHA_0 => read_data_v(WL-1 downto 0) := alpha_reg_0;
                    when REG_G_1 => read_data_v(WL-1 downto 0) := g_reg_1;
                    when REG_ALPHA_1 => read_data_v(WL-1 downto 0) := alpha_reg_1;
                    when REG_G_2 => read_data_v(WL-1 downto 0) := g_reg_2;
                    when REG_ALPHA_2 => read_data_v(WL-1 downto 0) := alpha_reg_2;
                    when REG_G_3 => read_data_v(WL-1 downto 0) := g_reg_3;
                    when REG_ALPHA_3 => read_data_v(WL-1 downto 0) := alpha_reg_3;
                    when REG_FEAT_INNOV_0 + 0 => read_data_v := feat_slice(coeff_feat_in, 0, SS_FEAT_INNOV);
                    when REG_FEAT_INNOV_0 + 1 => read_data_v := feat_slice(coeff_feat_in, 1, SS_FEAT_INNOV);
                    when REG_FEAT_INNOV_0 + 2 => read_data_v := feat_slice(coeff_feat_in, 2, SS_FEAT_INNOV);
                    when REG_FEAT_INNOV_0 + 3 => read_data_v := feat_slice(coeff_feat_in, 3, SS_FEAT_INNOV);
                    when REG_FEAT_BAND_0 + 0 => read_data_v := feat_slice(coeff_feat_in, 0, SS_FEAT_BAND);
                    when REG_FEAT_BAND_0 + 1 => read_data_v := feat_slice(coeff_feat_in, 1, SS_FEAT_BAND);
                    when REG_FEAT_BAND_0 + 2 => read_data_v := feat_slice(coeff_feat_in, 2, SS_FEAT_BAND);
                    when REG_FEAT_BAND_0 + 3 => read_data_v := feat_slice(coeff_feat_in, 3, SS_FEAT_BAND);
                    when REG_FEAT_MODAL_0 + 0 => read_data_v := feat_slice(coeff_feat_in, 0, SS_FEAT_MODAL);
                    when REG_FEAT_MODAL_0 + 1 => read_data_v := feat_slice(coeff_feat_in, 1, SS_FEAT_MODAL);
                    when REG_FEAT_MODAL_0 + 2 => read_data_v := feat_slice(coeff_feat_in, 2, SS_FEAT_MODAL);
                    when REG_FEAT_MODAL_0 + 3 => read_data_v := feat_slice(coeff_feat_in, 3, SS_FEAT_MODAL);
                    when others =>
                        null;
                    end case;

                    rdata_reg  <= read_data_v;
                    rvalid_reg <= '1';
                    ar_pending <= '0';
                elsif rvalid_reg = '1' and S_AXI_RREADY = '1' then
                    rvalid_reg <= '0';
                end if;
            end if;
        end if;
    end process;

end rtl;