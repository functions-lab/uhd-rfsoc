# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "DATA_FIFO_DEPTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "S_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TICK_STEP" -parent ${Page_0}


}

proc update_PARAM_VALUE.DATA_FIFO_DEPTH { PARAM_VALUE.DATA_FIFO_DEPTH } {
	# Procedure called to update DATA_FIFO_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.DATA_FIFO_DEPTH { PARAM_VALUE.DATA_FIFO_DEPTH } {
	# Procedure called to validate DATA_FIFO_DEPTH
	return true
}

proc update_PARAM_VALUE.S_WIDTH { PARAM_VALUE.S_WIDTH } {
	# Procedure called to update S_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.S_WIDTH { PARAM_VALUE.S_WIDTH } {
	# Procedure called to validate S_WIDTH
	return true
}

proc update_PARAM_VALUE.TICK_STEP { PARAM_VALUE.TICK_STEP } {
	# Procedure called to update TICK_STEP when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TICK_STEP { PARAM_VALUE.TICK_STEP } {
	# Procedure called to validate TICK_STEP
	return true
}


proc update_MODELPARAM_VALUE.DATA_FIFO_DEPTH { MODELPARAM_VALUE.DATA_FIFO_DEPTH PARAM_VALUE.DATA_FIFO_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.DATA_FIFO_DEPTH}] ${MODELPARAM_VALUE.DATA_FIFO_DEPTH}
}

proc update_MODELPARAM_VALUE.TICK_STEP { MODELPARAM_VALUE.TICK_STEP PARAM_VALUE.TICK_STEP } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TICK_STEP}] ${MODELPARAM_VALUE.TICK_STEP}
}

proc update_MODELPARAM_VALUE.S_WIDTH { MODELPARAM_VALUE.S_WIDTH PARAM_VALUE.S_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.S_WIDTH}] ${MODELPARAM_VALUE.S_WIDTH}
}

