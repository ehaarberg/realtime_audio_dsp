-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2024.1 (win64) Build 5076996 Wed May 22 18:37:14 MDT 2024
-- Date        : Sun Jun 14 22:31:39 2026
-- Host        : eirik-hobby running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               c:/master/new/vivado_prj/audio_prj.gen/sources_1/bd/audio_system/ip/audio_system_aud_clkwiz_0/audio_system_aud_clkwiz_0_stub.vhdl
-- Design      : audio_system_aud_clkwiz_0
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7z020clg484-1
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity audio_system_aud_clkwiz_0 is
  Port ( 
    clk_out1 : out STD_LOGIC;
    aud_mclk : out STD_LOGIC;
    resetn : in STD_LOGIC;
    locked : out STD_LOGIC;
    clk_in1 : in STD_LOGIC
  );

end audio_system_aud_clkwiz_0;

architecture stub of audio_system_aud_clkwiz_0 is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk_out1,aud_mclk,resetn,locked,clk_in1";
begin
end;
