// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2024.1 (win64) Build 5076996 Wed May 22 18:37:14 MDT 2024
// Date        : Sun Jun 14 22:31:39 2026
// Host        : eirik-hobby running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               c:/master/new/vivado_prj/audio_prj.gen/sources_1/bd/audio_system/ip/audio_system_aud_clkwiz_0/audio_system_aud_clkwiz_0_stub.v
// Design      : audio_system_aud_clkwiz_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z020clg484-1
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module audio_system_aud_clkwiz_0(clk_out1, aud_mclk, resetn, locked, clk_in1)
/* synthesis syn_black_box black_box_pad_pin="resetn,locked,clk_in1" */
/* synthesis syn_force_seq_prim="clk_out1" */
/* synthesis syn_force_seq_prim="aud_mclk" */;
  output clk_out1 /* synthesis syn_isclock = 1 */;
  output aud_mclk /* synthesis syn_isclock = 1 */;
  input resetn;
  output locked;
  input clk_in1;
endmodule
