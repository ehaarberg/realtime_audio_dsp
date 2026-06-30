-- (c) Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- (c) Copyright 2022-2026 Advanced Micro Devices, Inc. All rights reserved.
-- 
-- This file contains confidential and proprietary information
-- of AMD and is protected under U.S. and international copyright
-- and other intellectual property laws.
-- 
-- DISCLAIMER
-- This disclaimer is not a license and does not grant any
-- rights to the materials distributed herewith. Except as
-- otherwise provided in a valid license issued to you by
-- AMD, and to the maximum extent permitted by applicable
-- law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
-- WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
-- AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
-- BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
-- INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
-- (2) AMD shall not be liable (whether in contract or tort,
-- including negligence, or under any other theory of
-- liability) for any loss or damage of any kind or nature
-- related to, arising under or in connection with these
-- materials, including for any direct, or any indirect,
-- special, incidental, or consequential loss or damage
-- (including loss of data, profits, goodwill, or any type of
-- loss or damage suffered as a result of any action brought
-- by a third party) even if such damage or loss was
-- reasonably foreseeable or AMD had been advised of the
-- possibility of the same.
-- 
-- CRITICAL APPLICATIONS
-- AMD products are not designed or intended to be fail-
-- safe, or for use in any application requiring fail-safe
-- performance, such as life-support or safety devices or
-- systems, Class III medical devices, nuclear facilities,
-- applications related to the deployment of airbags, or any
-- other applications that could lead to death, personal
-- injury, or severe property or environmental damage
-- (individually and collectively, "Critical
-- Applications"). Customer assumes the sole risk and
-- liability of any use of AMD products in Critical
-- Applications, subject only to applicable laws and
-- regulations governing limitations on product liability.
-- 
-- THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
-- PART OF THIS FILE AT ALL TIMES.
-- 
-- DO NOT MODIFY THIS FILE.

-- IP VLNV: xilinx.com:module_ref:audiodsp_axis_wrap:1.0
-- IP Revision: 1

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY audio_system_u_dsp_0 IS
  PORT (
    clk : IN STD_LOGIC;
    resetn : IN STD_LOGIC;
    bclk : IN STD_LOGIC;
    lrclk : IN STD_LOGIC;
    sdata_in : IN STD_LOGIC;
    coeff_target_ctrl : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    coeff_target_bank : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    coeff_index : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    coeff_wdata : IN STD_LOGIC_VECTOR(23 DOWNTO 0);
    coeff_write_stb : IN STD_LOGIC;
    coeff_read_stb : IN STD_LOGIC;
    coeff_shadow_pending_bank : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    coeff_commit_mask : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    coeff_commit_stb : IN STD_LOGIC;
    coeff_rdata : OUT STD_LOGIC_VECTOR(23 DOWNTO 0);
    coeff_rvalid : OUT STD_LOGIC;
    coeff_active_bank_status : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
    coeff_pending_bank_status : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
    coeff_busy_status : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    coeff_g_in : IN STD_LOGIC_VECTOR(95 DOWNTO 0);
    coeff_alpha_in : IN STD_LOGIC_VECTOR(95 DOWNTO 0);
    coeff_feat_out : OUT STD_LOGIC_VECTOR(383 DOWNTO 0);
    sdata_out : OUT STD_LOGIC
  );
END audio_system_u_dsp_0;

ARCHITECTURE audio_system_u_dsp_0_arch OF audio_system_u_dsp_0 IS
  ATTRIBUTE DowngradeIPIdentifiedWarnings : STRING;
  ATTRIBUTE DowngradeIPIdentifiedWarnings OF audio_system_u_dsp_0_arch: ARCHITECTURE IS "yes";
  COMPONENT audiodsp_axis_wrap IS
    PORT (
      clk : IN STD_LOGIC;
      resetn : IN STD_LOGIC;
      bclk : IN STD_LOGIC;
      lrclk : IN STD_LOGIC;
      sdata_in : IN STD_LOGIC;
      coeff_target_ctrl : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
      coeff_target_bank : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
      coeff_index : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
      coeff_wdata : IN STD_LOGIC_VECTOR(23 DOWNTO 0);
      coeff_write_stb : IN STD_LOGIC;
      coeff_read_stb : IN STD_LOGIC;
      coeff_shadow_pending_bank : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      coeff_commit_mask : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
      coeff_commit_stb : IN STD_LOGIC;
      coeff_rdata : OUT STD_LOGIC_VECTOR(23 DOWNTO 0);
      coeff_rvalid : OUT STD_LOGIC;
      coeff_active_bank_status : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
      coeff_pending_bank_status : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
      coeff_busy_status : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
      coeff_g_in : IN STD_LOGIC_VECTOR(95 DOWNTO 0);
      coeff_alpha_in : IN STD_LOGIC_VECTOR(95 DOWNTO 0);
      coeff_feat_out : OUT STD_LOGIC_VECTOR(383 DOWNTO 0);
      sdata_out : OUT STD_LOGIC
    );
  END COMPONENT audiodsp_axis_wrap;
  ATTRIBUTE X_INTERFACE_INFO : STRING;
  ATTRIBUTE X_INTERFACE_PARAMETER : STRING;
  ATTRIBUTE X_INTERFACE_PARAMETER OF clk: SIGNAL IS "XIL_INTERFACENAME clk, ASSOCIATED_RESET resetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN /aud_clkwiz_clk_out1, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF clk: SIGNAL IS "xilinx.com:signal:clock:1.0 clk CLK";
  ATTRIBUTE X_INTERFACE_PARAMETER OF resetn: SIGNAL IS "XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF resetn: SIGNAL IS "xilinx.com:signal:reset:1.0 resetn RST";
BEGIN
  U0 : audiodsp_axis_wrap
    PORT MAP (
      clk => clk,
      resetn => resetn,
      bclk => bclk,
      lrclk => lrclk,
      sdata_in => sdata_in,
      coeff_target_ctrl => coeff_target_ctrl,
      coeff_target_bank => coeff_target_bank,
      coeff_index => coeff_index,
      coeff_wdata => coeff_wdata,
      coeff_write_stb => coeff_write_stb,
      coeff_read_stb => coeff_read_stb,
      coeff_shadow_pending_bank => coeff_shadow_pending_bank,
      coeff_commit_mask => coeff_commit_mask,
      coeff_commit_stb => coeff_commit_stb,
      coeff_rdata => coeff_rdata,
      coeff_rvalid => coeff_rvalid,
      coeff_active_bank_status => coeff_active_bank_status,
      coeff_pending_bank_status => coeff_pending_bank_status,
      coeff_busy_status => coeff_busy_status,
      coeff_g_in => coeff_g_in,
      coeff_alpha_in => coeff_alpha_in,
      coeff_feat_out => coeff_feat_out,
      sdata_out => sdata_out
    );
END audio_system_u_dsp_0_arch;
