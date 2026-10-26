# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  set page [ipgui::add_page $IPINST -name "Configuration"]
  set width [ipgui::add_param $IPINST -name "C_S_AXIS_TDATA_WIDTH" -parent $page -widget comboBox]
  set_property tooltip {Input width of each I/Q AXI stream. The output width is double this value.} $width
}

proc update_PARAM_VALUE.C_S_AXIS_TDATA_WIDTH { PARAM_VALUE.C_S_AXIS_TDATA_WIDTH } {
}

proc validate_PARAM_VALUE.C_S_AXIS_TDATA_WIDTH { PARAM_VALUE.C_S_AXIS_TDATA_WIDTH } {
  set value [get_property value ${PARAM_VALUE.C_S_AXIS_TDATA_WIDTH}]
  return [expr {$value in {32 64 128 256 512 1024}}]
}

proc update_MODELPARAM_VALUE.C_S_AXIS_TDATA_WIDTH { MODELPARAM_VALUE.C_S_AXIS_TDATA_WIDTH PARAM_VALUE.C_S_AXIS_TDATA_WIDTH } {
  set_property value [get_property value ${PARAM_VALUE.C_S_AXIS_TDATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXIS_TDATA_WIDTH}
}
