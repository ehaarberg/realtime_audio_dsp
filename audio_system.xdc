# audio_system.xdc
# Pin constraints for the new standalone audiodsp project.
# Pins from ZedBoard schematic — same as existing zedboard_audio.xdc.

# ----------------------------------------------------------------------------
# Audio Codec (ADAU1761) – Bank 13, 3.3V
# ----------------------------------------------------------------------------

# Master clock  (12.288 MHz from clk_wiz clk_out2)
set_property PACKAGE_PIN AB2 [get_ports AC_MCLK]
set_property IOSTANDARD LVCMOS33 [get_ports AC_MCLK]

# Bit clock — driven by I2S TX (master), also received by I2S RX
set_property PACKAGE_PIN AA6 [get_ports AC_BCLK]
set_property IOSTANDARD LVCMOS33 [get_ports AC_BCLK]

# L/R clock — driven by I2S TX (master), also received by I2S RX
set_property PACKAGE_PIN Y6 [get_ports AC_LRCLK]
set_property IOSTANDARD LVCMOS33 [get_ports AC_LRCLK]

# ADC serial data (codec → FPGA, input to I2S RX)
set_property PACKAGE_PIN AA7 [get_ports AC_SDATA_I]
set_property IOSTANDARD LVCMOS33 [get_ports AC_SDATA_I]

# DAC serial data (FPGA → codec, output from I2S TX)
set_property PACKAGE_PIN Y8 [get_ports AC_SDATA_O]
set_property IOSTANDARD LVCMOS33 [get_ports AC_SDATA_O]

# ----------------------------------------------------------------------------
# I2C to ADAU1761 (open-drain, pulled up on board)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN AB4 [get_ports IIC_CODEC_scl_io]
set_property PACKAGE_PIN AB5 [get_ports IIC_CODEC_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports IIC_CODEC_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports IIC_CODEC_sda_io]
set_property PULLTYPE PULLUP [get_ports IIC_CODEC_scl_io]
set_property PULLTYPE PULLUP [get_ports IIC_CODEC_sda_io]
set_property SLEW SLOW [get_ports IIC_CODEC_scl_io]
set_property SLEW SLOW [get_ports IIC_CODEC_sda_io]
set_property DRIVE 8 [get_ports IIC_CODEC_scl_io]
set_property DRIVE 8 [get_ports IIC_CODEC_sda_io]



