# post_bit.tcl
# Runs automatically after write_bitstream (set as STEPS.WRITE_BITSTREAM.TCL.POST).
# Exports the hardware platform (XSA with embedded bitstream + ILA probes)
# so Vitis can be updated without a separate manual step.

write_hw_platform -fixed -include_bit -force -file C:/master/new/vivado_prj/audio_system_wrapper.xsa
puts "------------------------------------"
puts "XSA exported"
puts "Update Vitis: right-click platform -> Update Hardware Specification"
puts "------------------------------------"
