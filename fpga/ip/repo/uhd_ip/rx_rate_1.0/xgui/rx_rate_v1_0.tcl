# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "G" -parent ${Page_0}
  ipgui::add_param $IPINST -name "K" -parent ${Page_0}
  ipgui::add_param $IPINST -name "N_CH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "SPC" -parent ${Page_0}


}

proc update_PARAM_VALUE.G { PARAM_VALUE.G } {
	# Procedure called to update G when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G { PARAM_VALUE.G } {
	# Procedure called to validate G
	return true
}

proc update_PARAM_VALUE.K { PARAM_VALUE.K } {
	# Procedure called to update K when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.K { PARAM_VALUE.K } {
	# Procedure called to validate K
	return true
}

proc update_PARAM_VALUE.N_CH { PARAM_VALUE.N_CH } {
	# Procedure called to update N_CH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.N_CH { PARAM_VALUE.N_CH } {
	# Procedure called to validate N_CH
	return true
}

proc update_PARAM_VALUE.SPC { PARAM_VALUE.SPC } {
	# Procedure called to update SPC when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.SPC { PARAM_VALUE.SPC } {
	# Procedure called to validate SPC
	return true
}


proc update_MODELPARAM_VALUE.N_CH { MODELPARAM_VALUE.N_CH PARAM_VALUE.N_CH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.N_CH}] ${MODELPARAM_VALUE.N_CH}
}

proc update_MODELPARAM_VALUE.SPC { MODELPARAM_VALUE.SPC PARAM_VALUE.SPC } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.SPC}] ${MODELPARAM_VALUE.SPC}
}

proc update_MODELPARAM_VALUE.K { MODELPARAM_VALUE.K PARAM_VALUE.K } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.K}] ${MODELPARAM_VALUE.K}
}

proc update_MODELPARAM_VALUE.G { MODELPARAM_VALUE.G PARAM_VALUE.G } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G}] ${MODELPARAM_VALUE.G}
}

