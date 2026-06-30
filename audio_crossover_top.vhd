-- audio_crossover_top.vhd

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audiodsp_pkg.all;
use work.ss_coeff_pkg.all;

entity audio_crossover_top is
    generic (
        BYPASS    : boolean := false;
        BYPASS_SS : boolean := false
    );
    port (
        clk                       : in  std_logic;
        reset                     : in  std_logic;
        Audio_In                  : in  signed(WL-1 downto 0);  -- vocal mic
        Mic_Near                  : in  signed(WL-1 downto 0);  -- near mic
        In_Valid                  : in  std_logic;
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
        coeff_feat_out            : out std_logic_vector(SS_FEAT_BUS_W - 1 downto 0);
        Audio_Out                 : out signed(WL-1 downto 0);
        Out_Valid                 : out std_logic
    );
end entity audio_crossover_top;

architecture rtl of audio_crossover_top is

    -- Band-limited vocal-microphone outputs (measurement path y_b)
    signal xo_band0, xo_band1, xo_band2, xo_band3 : signed(WL-1 downto 0);
    signal xo_valid : std_logic;

    -- Band-limited monitor-send outputs (model input path u)
    signal us_band0, us_band1, us_band2, us_band3 : signed(WL-1 downto 0);
    signal us_valid : std_logic;
    signal ss_in_valid : std_logic;

    -- SS controller contributions (4 controllers)
    signal uc1, uc2, uc3, uc4 : signed(WL-1 downto 0);
    signal ucv1, ucv2, ucv3, ucv4 : std_logic;

    -- Per-controller feature extraction (modal energy + innovation)
    signal fmod1, fmod2, fmod3, fmod4 : std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
    signal finn1, finn2, finn3, finn4 : std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
    signal fval1, fval2, fval3, fval4 : std_logic;
    -- Smoothed feature outputs per controller
    signal em1, em2, em3, em4 : std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
    signal ei1, ei2, ei3, ei4 : std_logic_vector(SS_FEAT_WORD_W-1 downto 0);
    signal eb1, eb2, eb3, eb4 : std_logic_vector(SS_FEAT_WORD_W-1 downto 0);

    signal ctrl_rdata1, ctrl_rdata2, ctrl_rdata3, ctrl_rdata4 : signed(WL-1 downto 0);
    signal ctrl_rvalid1, ctrl_rvalid2, ctrl_rvalid3, ctrl_rvalid4 : std_logic;
    signal ss1_host_write_stb, ss2_host_write_stb, ss3_host_write_stb, ss4_host_write_stb : std_logic;
    signal ss1_host_read_stb, ss2_host_read_stb, ss3_host_read_stb, ss4_host_read_stb : std_logic;
    signal ss1_commit_stb, ss2_commit_stb, ss3_commit_stb, ss4_commit_stb : std_logic;
    signal active_bank1, active_bank2, active_bank3, active_bank4 : ss_bank_sel_t;
    signal pending_bank1, pending_bank2, pending_bank3, pending_bank4 : ss_bank_sel_t;
    signal busy1, busy2, busy3, busy4 : std_logic;

    constant SUM_WL : integer := 27;
    signal sum_pair0, sum_pair1, program_sum : signed(SUM_WL-1 downto 0);
    signal sum_pair0_vld, sum_pair1_vld, program_sum_vld : std_logic;
    
    signal uc_sum_pair0, uc_sum_pair1, uc_total_sum : signed(SUM_WL-1 downto 0);
    signal uc_sum_pair0_vld, uc_sum_pair1_vld, uc_total_sum_vld : std_logic;
    
    signal total_out : signed(SUM_WL-1 downto 0);
    signal total_out_vld : std_logic;

    constant MAX_VAL : signed(SUM_WL-1 downto 0) := to_signed( 2**(WL-1) - 1, SUM_WL);
    constant MIN_VAL : signed(SUM_WL-1 downto 0) := to_signed(-2**(WL-1),     SUM_WL);

    function saturate(s : signed(SUM_WL-1 downto 0)) return signed is
    begin
        if s > MAX_VAL then
            return MAX_VAL(WL-1 downto 0);
        elsif s < MIN_VAL then
            return MIN_VAL(WL-1 downto 0);
        else
            return s(WL-1 downto 0);
        end if;
    end function;

begin

    ss1_host_write_stb <= coeff_write_stb when coeff_target_ctrl = "00" else '0';
    ss2_host_write_stb <= coeff_write_stb when coeff_target_ctrl = "01" else '0';
    ss3_host_write_stb <= coeff_write_stb when coeff_target_ctrl = "10" else '0';
    ss4_host_write_stb <= coeff_write_stb when coeff_target_ctrl = "11" else '0';

    ss1_host_read_stb <= coeff_read_stb when coeff_target_ctrl = "00" else '0';
    ss2_host_read_stb <= coeff_read_stb when coeff_target_ctrl = "01" else '0';
    ss3_host_read_stb <= coeff_read_stb when coeff_target_ctrl = "10" else '0';
    ss4_host_read_stb <= coeff_read_stb when coeff_target_ctrl = "11" else '0';

    ss1_commit_stb <= coeff_commit_stb and coeff_commit_mask(0);
    ss2_commit_stb <= coeff_commit_stb and coeff_commit_mask(1);
    ss3_commit_stb <= coeff_commit_stb and coeff_commit_mask(2);
    ss4_commit_stb <= coeff_commit_stb and coeff_commit_mask(3);

    -- ---------------------------------------------------------------
    -- BYPASS mode
    -- ---------------------------------------------------------------
    gen_bypass : if BYPASS generate
        process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    Audio_Out <= (others => '0');
                    Out_Valid <= '0';
                else
                    Audio_Out <= Audio_In;
                    Out_Valid <= In_Valid;
                end if;
            end if;
        end process;

        coeff_rdata               <= (others => '0');
        coeff_rvalid              <= '0';
        coeff_active_bank_status  <= (others => '0');
        coeff_pending_bank_status <= (others => '0');
        coeff_busy_status         <= (others => '0');
        coeff_feat_out            <= (others => '0');
    end generate;

    -- ---------------------------------------------------------------
    -- Normal DSP path
    -- ---------------------------------------------------------------
    gen_dsp : if not BYPASS generate

    -- Vocal-mic crossover (measurement path y_b)
    u_xover : entity work.crossover_filters port map (
        clk   => clk,
        reset => reset,
        en    => In_Valid,
        x     => Audio_In,
        band0 => xo_band0,
        band1 => xo_band1,
        band2 => xo_band2,
        band3 => xo_band3,
        band4 => open,
        band5 => open,
        band6 => open,
        band7 => open,
        valid => xo_valid
    );

    -- Monitor-send crossover (model input path u)
    u_send_xover : entity work.crossover_filters port map (
        clk   => clk,
        reset => reset,
        en    => In_Valid,
        x     => Mic_Near,
        band0 => us_band0,
        band1 => us_band1,
        band2 => us_band2,
        band3 => us_band3,
        band4 => open,
        band5 => open,
        band6 => open,
        band7 => open,
        valid => us_valid
    );

    -- Only launch observer/controller when both input paths are aligned valid.
    ss_in_valid <= xo_valid and us_valid;

    gen_bypass_ss : if BYPASS_SS generate
        process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    sum_pair0 <= (others => '0');
                    sum_pair1 <= (others => '0');
                    program_sum <= (others => '0');
                    sum_pair0_vld <= '0';
                    sum_pair1_vld <= '0';
                    program_sum_vld <= '0';
                    Audio_Out <= (others => '0');
                    Out_Valid <= '0';
                else
                    sum_pair0_vld <= '0';
                    sum_pair1_vld <= '0';
                    program_sum_vld <= '0';
                    Out_Valid <= '0';

                    if xo_valid = '1' then
                        sum_pair0 <= resize(xo_band0, SUM_WL) + resize(xo_band1, SUM_WL);
                        sum_pair1 <= resize(xo_band2, SUM_WL) + resize(xo_band3, SUM_WL);
                        sum_pair0_vld <= '1';
                        sum_pair1_vld <= '1';
                    end if;

                    if sum_pair0_vld = '1' then
                        program_sum <= sum_pair0 + sum_pair1;
                        program_sum_vld <= '1';
                    end if;

                    if program_sum_vld = '1' then
                        Audio_Out <= saturate(program_sum);
                        Out_Valid <= '1';
                    end if;
                end if;
            end if;
        end process;

        coeff_rdata               <= (others => '0');
        coeff_rvalid              <= '0';
        coeff_active_bank_status  <= (others => '0');
        coeff_pending_bank_status <= (others => '0');
        coeff_busy_status         <= (others => '0');
        coeff_feat_out            <= (others => '0');
    end generate;

    gen_full : if not BYPASS_SS generate
        u_ss1 : entity work.ss_ctrl_runtime
            generic map (CTRL_SLOT => 0)
            port map (
                clk                 => clk,
                reset               => reset,
                u                   => us_band0,
                y_mic               => xo_band0,
                g_in                => signed(coeff_g_in(1*WL-1 downto 0*WL)),
                alpha_in            => signed(coeff_alpha_in(1*WL-1 downto 0*WL)),
                in_valid            => ss_in_valid,
                host_bank           => unsigned(coeff_target_bank),
                host_index          => unsigned(coeff_index),
                host_wdata          => signed(coeff_wdata),
                host_write_stb      => ss1_host_write_stb,
                host_read_stb       => ss1_host_read_stb,
                shadow_pending_bank => unsigned(coeff_shadow_pending_bank(1*SS_BANK_SEL_W-1 downto 0*SS_BANK_SEL_W)),
                commit_stb          => ss1_commit_stb,
                host_rdata          => ctrl_rdata1,
                host_rvalid         => ctrl_rvalid1,
                active_bank         => active_bank1,
                pending_bank        => pending_bank1,
                busy                => busy1,
                u_c                 => uc1,
                u_c_valid           => ucv1,
                feat_modal          => fmod1,
                feat_innov          => finn1,
                feat_valid          => fval1
            );

        u_ss2 : entity work.ss_ctrl_runtime
            generic map (CTRL_SLOT => 1)
            port map (
                clk                 => clk,
                reset               => reset,
                u                   => us_band1,
                y_mic               => xo_band1,
                g_in                => signed(coeff_g_in(2*WL-1 downto 1*WL)),
                alpha_in            => signed(coeff_alpha_in(2*WL-1 downto 1*WL)),
                in_valid            => ss_in_valid,
                host_bank           => unsigned(coeff_target_bank),
                host_index          => unsigned(coeff_index),
                host_wdata          => signed(coeff_wdata),
                host_write_stb      => ss2_host_write_stb,
                host_read_stb       => ss2_host_read_stb,
                shadow_pending_bank => unsigned(coeff_shadow_pending_bank(2*SS_BANK_SEL_W-1 downto 1*SS_BANK_SEL_W)),
                commit_stb          => ss2_commit_stb,
                host_rdata          => ctrl_rdata2,
                host_rvalid         => ctrl_rvalid2,
                active_bank         => active_bank2,
                pending_bank        => pending_bank2,
                busy                => busy2,
                u_c                 => uc2,
                u_c_valid           => ucv2,
                feat_modal          => fmod2,
                feat_innov          => finn2,
                feat_valid          => fval2
            );

        u_ss3 : entity work.ss_ctrl_runtime
            generic map (CTRL_SLOT => 2)
            port map (
                clk                 => clk,
                reset               => reset,
                u                   => us_band2,
                y_mic               => xo_band2,
                g_in                => signed(coeff_g_in(3*WL-1 downto 2*WL)),
                alpha_in            => signed(coeff_alpha_in(3*WL-1 downto 2*WL)),
                in_valid            => ss_in_valid,
                host_bank           => unsigned(coeff_target_bank),
                host_index          => unsigned(coeff_index),
                host_wdata          => signed(coeff_wdata),
                host_write_stb      => ss3_host_write_stb,
                host_read_stb       => ss3_host_read_stb,
                shadow_pending_bank => unsigned(coeff_shadow_pending_bank(3*SS_BANK_SEL_W-1 downto 2*SS_BANK_SEL_W)),
                commit_stb          => ss3_commit_stb,
                host_rdata          => ctrl_rdata3,
                host_rvalid         => ctrl_rvalid3,
                active_bank         => active_bank3,
                pending_bank        => pending_bank3,
                busy                => busy3,
                u_c                 => uc3,
                u_c_valid           => ucv3,
                feat_modal          => fmod3,
                feat_innov          => finn3,
                feat_valid          => fval3
            );

        u_ss4 : entity work.ss_ctrl_runtime
            generic map (CTRL_SLOT => 3)
            port map (
                clk                 => clk,
                reset               => reset,
                u                   => us_band3,
                y_mic               => xo_band3,
                g_in                => signed(coeff_g_in(4*WL-1 downto 3*WL)),
                alpha_in            => signed(coeff_alpha_in(4*WL-1 downto 3*WL)),
                in_valid            => ss_in_valid,
                host_bank           => unsigned(coeff_target_bank),
                host_index          => unsigned(coeff_index),
                host_wdata          => signed(coeff_wdata),
                host_write_stb      => ss4_host_write_stb,
                host_read_stb       => ss4_host_read_stb,
                shadow_pending_bank => unsigned(coeff_shadow_pending_bank(4*SS_BANK_SEL_W-1 downto 3*SS_BANK_SEL_W)),
                commit_stb          => ss4_commit_stb,
                host_rdata          => ctrl_rdata4,
                host_rvalid         => ctrl_rvalid4,
                active_bank         => active_bank4,
                pending_bank        => pending_bank4,
                busy                => busy4,
                u_c                 => uc4,
                u_c_valid           => ucv4,
                feat_modal          => fmod4,
                feat_innov          => finn4,
                feat_valid          => fval4
            );

        -- Memory read mux
        process(clk)
            variable sel : unsigned(1 downto 0);
        begin
            if rising_edge(clk) then
                sel := unsigned(coeff_target_ctrl);
                if sel = "00" then
                    coeff_rdata <= std_logic_vector(ctrl_rdata1);
                    coeff_rvalid <= ctrl_rvalid1;
                elsif sel = "01" then
                    coeff_rdata <= std_logic_vector(ctrl_rdata2);
                    coeff_rvalid <= ctrl_rvalid2;
                elsif sel = "10" then
                    coeff_rdata <= std_logic_vector(ctrl_rdata3);
                    coeff_rvalid <= ctrl_rvalid3;
                else
                    coeff_rdata <= std_logic_vector(ctrl_rdata4);
                    coeff_rvalid <= ctrl_rvalid4;
                end if;
            end if;
        end process;

        coeff_active_bank_status <= std_logic_vector(active_bank4) & std_logic_vector(active_bank3) & std_logic_vector(active_bank2) & std_logic_vector(active_bank1);
        coeff_pending_bank_status <= std_logic_vector(pending_bank4) & std_logic_vector(pending_bank3) & std_logic_vector(pending_bank2) & std_logic_vector(pending_bank1);
        coeff_busy_status <= busy4 & busy3 & busy2 & busy1;

        -- Feature extraction: leaky-integrator smoothing per controller/band.
        u_feat1 : entity work.ss_feature_accum
            port map (clk => clk, reset => reset, sample_valid => fval1,
                      in_modal => fmod1, in_innov => finn1, in_band => xo_band0,
                      e_modal => em1, e_innov => ei1, e_band => eb1);
        u_feat2 : entity work.ss_feature_accum
            port map (clk => clk, reset => reset, sample_valid => fval2,
                      in_modal => fmod2, in_innov => finn2, in_band => xo_band1,
                      e_modal => em2, e_innov => ei2, e_band => eb2);
        u_feat3 : entity work.ss_feature_accum
            port map (clk => clk, reset => reset, sample_valid => fval3,
                      in_modal => fmod3, in_innov => finn3, in_band => xo_band2,
                      e_modal => em3, e_innov => ei3, e_band => eb3);
        u_feat4 : entity work.ss_feature_accum
            port map (clk => clk, reset => reset, sample_valid => fval4,
                      in_modal => fmod4, in_innov => finn4, in_band => xo_band3,
                      e_modal => em4, e_innov => ei4, e_band => eb4);

        -- Pack {modal, innov, band} per controller into the feature bus.
        coeff_feat_out((0*SS_FEAT_PER_CTRL+SS_FEAT_MODAL+1)*SS_FEAT_WORD_W-1 downto (0*SS_FEAT_PER_CTRL+SS_FEAT_MODAL)*SS_FEAT_WORD_W) <= em1;
        coeff_feat_out((0*SS_FEAT_PER_CTRL+SS_FEAT_INNOV+1)*SS_FEAT_WORD_W-1 downto (0*SS_FEAT_PER_CTRL+SS_FEAT_INNOV)*SS_FEAT_WORD_W) <= ei1;
        coeff_feat_out((0*SS_FEAT_PER_CTRL+SS_FEAT_BAND +1)*SS_FEAT_WORD_W-1 downto (0*SS_FEAT_PER_CTRL+SS_FEAT_BAND )*SS_FEAT_WORD_W) <= eb1;
        coeff_feat_out((1*SS_FEAT_PER_CTRL+SS_FEAT_MODAL+1)*SS_FEAT_WORD_W-1 downto (1*SS_FEAT_PER_CTRL+SS_FEAT_MODAL)*SS_FEAT_WORD_W) <= em2;
        coeff_feat_out((1*SS_FEAT_PER_CTRL+SS_FEAT_INNOV+1)*SS_FEAT_WORD_W-1 downto (1*SS_FEAT_PER_CTRL+SS_FEAT_INNOV)*SS_FEAT_WORD_W) <= ei2;
        coeff_feat_out((1*SS_FEAT_PER_CTRL+SS_FEAT_BAND +1)*SS_FEAT_WORD_W-1 downto (1*SS_FEAT_PER_CTRL+SS_FEAT_BAND )*SS_FEAT_WORD_W) <= eb2;
        coeff_feat_out((2*SS_FEAT_PER_CTRL+SS_FEAT_MODAL+1)*SS_FEAT_WORD_W-1 downto (2*SS_FEAT_PER_CTRL+SS_FEAT_MODAL)*SS_FEAT_WORD_W) <= em3;
        coeff_feat_out((2*SS_FEAT_PER_CTRL+SS_FEAT_INNOV+1)*SS_FEAT_WORD_W-1 downto (2*SS_FEAT_PER_CTRL+SS_FEAT_INNOV)*SS_FEAT_WORD_W) <= ei3;
        coeff_feat_out((2*SS_FEAT_PER_CTRL+SS_FEAT_BAND +1)*SS_FEAT_WORD_W-1 downto (2*SS_FEAT_PER_CTRL+SS_FEAT_BAND )*SS_FEAT_WORD_W) <= eb3;
        coeff_feat_out((3*SS_FEAT_PER_CTRL+SS_FEAT_MODAL+1)*SS_FEAT_WORD_W-1 downto (3*SS_FEAT_PER_CTRL+SS_FEAT_MODAL)*SS_FEAT_WORD_W) <= em4;
        coeff_feat_out((3*SS_FEAT_PER_CTRL+SS_FEAT_INNOV+1)*SS_FEAT_WORD_W-1 downto (3*SS_FEAT_PER_CTRL+SS_FEAT_INNOV)*SS_FEAT_WORD_W) <= ei4;
        coeff_feat_out((3*SS_FEAT_PER_CTRL+SS_FEAT_BAND +1)*SS_FEAT_WORD_W-1 downto (3*SS_FEAT_PER_CTRL+SS_FEAT_BAND )*SS_FEAT_WORD_W) <= eb4;

        -- Sum and saturate logic
        process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    sum_pair0 <= (others => '0');
                    sum_pair1 <= (others => '0');
                    program_sum <= (others => '0');
                    
                    uc_sum_pair0 <= (others => '0');
                    uc_sum_pair1 <= (others => '0');
                    uc_total_sum <= (others => '0');
                    
                    total_out <= (others => '0');
                    
                    sum_pair0_vld <= '0';
                    program_sum_vld <= '0';
                    uc_sum_pair0_vld <= '0';
                    uc_total_sum_vld <= '0';
                    total_out_vld <= '0';
                    
                    Audio_Out <= (others => '0');
                    Out_Valid <= '0';
                else
                    sum_pair0_vld <= '0';
                    program_sum_vld <= '0';
                    uc_sum_pair0_vld <= '0';
                    uc_total_sum_vld <= '0';
                    total_out_vld <= '0';
                    Out_Valid <= '0';

                    -- 1. Combine program elements
                    if xo_valid = '1' then
                        sum_pair0 <= resize(xo_band0, SUM_WL) + resize(xo_band1, SUM_WL);
                        sum_pair1 <= resize(xo_band2, SUM_WL) + resize(xo_band3, SUM_WL);
                        sum_pair0_vld <= '1';
                    end if;
                    if sum_pair0_vld = '1' then
                        program_sum <= sum_pair0 + sum_pair1;
                        program_sum_vld <= '1';
                    end if;

                    -- 2. Combine u_c elements
                    if ucv1 = '1' then
                        uc_sum_pair0 <= resize(uc1, SUM_WL) + resize(uc2, SUM_WL);
                        uc_sum_pair1 <= resize(uc3, SUM_WL) + resize(uc4, SUM_WL);
                        uc_sum_pair0_vld <= '1';
                    end if;
                    if uc_sum_pair0_vld = '1' then
                        uc_total_sum <= uc_sum_pair0 + uc_sum_pair1;
                        uc_total_sum_vld <= '1';
                    end if;

                    -- Wait for both to be ready (uc is much slower, approx 1100 cycles)
                    if uc_total_sum_vld = '1' then
                        -- Since program_sum is calculated well in advance, it is stable here
                        total_out <= program_sum + uc_total_sum;
                        total_out_vld <= '1';
                    end if;
                    
                    -- Saturate and emit
                    if total_out_vld = '1' then
                        Audio_Out <= saturate(total_out);
                        Out_Valid <= '1';
                    end if;
                end if;
            end if;
        end process;

    end generate; -- end gen_full
    end generate; -- end gen_dsp
    
end rtl;