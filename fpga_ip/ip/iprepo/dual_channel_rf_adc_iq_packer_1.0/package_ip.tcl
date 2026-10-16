set ip_root [file normalize [file dirname [info script]]]
set rtl_file [file join $ip_root hdl dual_channel_rf_adc_iq_packer_v1_0.v]

create_project -in_memory -part xczu48dr-fsvg1517-2-e
add_files -norecurse $rtl_file
set_property top dual_channel_rf_adc_iq_packer_v1_0 [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_root -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true -force
set core [ipx::current_core]
set_property name dual_channel_rf_adc_iq_packer $core
set_property display_name {Dual-Channel RF-ADC I/Q AXI Stream Packer} $core
set_property description {Interleaves two simultaneous dual RF-ADC I/Q channel pairs into a single four-times-width lossy capture stream} $core
set_property vendor_display_name {rfsoc-uhd} $core
set_property version 1.0 $core

set clk_if [ipx::get_bus_interfaces axis_aclk -of_objects $core]
set_property value s_ch0_i_axis:s_ch0_q_axis:s_ch1_i_axis:s_ch1_q_axis:m_axis \
    [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clk_if]
set reset_if [ipx::get_bus_interfaces axis_aresetn -of_objects $core]
set_property value ACTIVE_LOW [ipx::get_bus_parameters POLARITY -of_objects $reset_if]
set_property value axis_aresetn [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $clk_if]
set clock_frequency [ipx::add_bus_parameter FREQ_HZ $clk_if]
set_property value 300000000 $clock_frequency

set width_parameter [ipx::get_user_parameters C_S_AXIS_TDATA_WIDTH -of_objects $core]
set_property display_name {Input AXIS TDATA Width} $width_parameter
set_property description {Width in bits of each I or Q input; output width is four times this value} $width_parameter
set_property value_validation_type list $width_parameter
set_property value_validation_list {32 64 128 256 512} $width_parameter

set xgui_name dual_channel_rf_adc_iq_packer_v1_0_v1_0.tcl
file copy -force [file join $ip_root xgui ${xgui_name}.in] \
    [file join $ip_root xgui $xgui_name]

ipx::update_checksums $core
ipx::check_integrity -quiet $core
ipx::save_core $core
close_project
