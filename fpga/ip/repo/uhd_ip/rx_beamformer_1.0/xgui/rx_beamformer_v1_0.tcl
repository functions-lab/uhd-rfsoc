# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "BEAT_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "N_CH" -parent ${Page_0}


}

proc update_PARAM_VALUE.BEAT_W { PARAM_VALUE.BEAT_W } {
	# Procedure called to update BEAT_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BEAT_W { PARAM_VALUE.BEAT_W } {
	# Procedure called to validate BEAT_W
	return true
}

proc update_PARAM_VALUE.N_CH { PARAM_VALUE.N_CH } {
	# Procedure called to update N_CH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.N_CH { PARAM_VALUE.N_CH } {
	# Procedure called to validate N_CH
	return true
}


proc update_MODELPARAM_VALUE.N_CH { MODELPARAM_VALUE.N_CH PARAM_VALUE.N_CH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.N_CH}] ${MODELPARAM_VALUE.N_CH}
}

proc update_MODELPARAM_VALUE.BEAT_W { MODELPARAM_VALUE.BEAT_W PARAM_VALUE.BEAT_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BEAT_W}] ${MODELPARAM_VALUE.BEAT_W}
}

