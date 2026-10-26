# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "CHAIN_DEPTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "CHAIN_STAGES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "META_DEPTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "M_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TICK_STEP" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TX_BUF_RESERVE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TX_BUF_WORDS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "URAM_RD_LATENCY" -parent ${Page_0}
  ipgui::add_param $IPINST -name "XFER_DEPTH" -parent ${Page_0}


}

proc update_PARAM_VALUE.CHAIN_DEPTH { PARAM_VALUE.CHAIN_DEPTH } {
	# Procedure called to update CHAIN_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CHAIN_DEPTH { PARAM_VALUE.CHAIN_DEPTH } {
	# Procedure called to validate CHAIN_DEPTH
	return true
}

proc update_PARAM_VALUE.CHAIN_STAGES { PARAM_VALUE.CHAIN_STAGES } {
	# Procedure called to update CHAIN_STAGES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CHAIN_STAGES { PARAM_VALUE.CHAIN_STAGES } {
	# Procedure called to validate CHAIN_STAGES
	return true
}

proc update_PARAM_VALUE.META_DEPTH { PARAM_VALUE.META_DEPTH } {
	# Procedure called to update META_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.META_DEPTH { PARAM_VALUE.META_DEPTH } {
	# Procedure called to validate META_DEPTH
	return true
}

proc update_PARAM_VALUE.M_WIDTH { PARAM_VALUE.M_WIDTH } {
	# Procedure called to update M_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.M_WIDTH { PARAM_VALUE.M_WIDTH } {
	# Procedure called to validate M_WIDTH
	return true
}

proc update_PARAM_VALUE.TICK_STEP { PARAM_VALUE.TICK_STEP } {
	# Procedure called to update TICK_STEP when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TICK_STEP { PARAM_VALUE.TICK_STEP } {
	# Procedure called to validate TICK_STEP
	return true
}

proc update_PARAM_VALUE.TX_BUF_RESERVE { PARAM_VALUE.TX_BUF_RESERVE } {
	# Procedure called to update TX_BUF_RESERVE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TX_BUF_RESERVE { PARAM_VALUE.TX_BUF_RESERVE } {
	# Procedure called to validate TX_BUF_RESERVE
	return true
}

proc update_PARAM_VALUE.TX_BUF_WORDS { PARAM_VALUE.TX_BUF_WORDS } {
	# Procedure called to update TX_BUF_WORDS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TX_BUF_WORDS { PARAM_VALUE.TX_BUF_WORDS } {
	# Procedure called to validate TX_BUF_WORDS
	return true
}

proc update_PARAM_VALUE.URAM_RD_LATENCY { PARAM_VALUE.URAM_RD_LATENCY } {
	# Procedure called to update URAM_RD_LATENCY when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.URAM_RD_LATENCY { PARAM_VALUE.URAM_RD_LATENCY } {
	# Procedure called to validate URAM_RD_LATENCY
	return true
}

proc update_PARAM_VALUE.XFER_DEPTH { PARAM_VALUE.XFER_DEPTH } {
	# Procedure called to update XFER_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.XFER_DEPTH { PARAM_VALUE.XFER_DEPTH } {
	# Procedure called to validate XFER_DEPTH
	return true
}


proc update_MODELPARAM_VALUE.TX_BUF_WORDS { MODELPARAM_VALUE.TX_BUF_WORDS PARAM_VALUE.TX_BUF_WORDS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TX_BUF_WORDS}] ${MODELPARAM_VALUE.TX_BUF_WORDS}
}

proc update_MODELPARAM_VALUE.TX_BUF_RESERVE { MODELPARAM_VALUE.TX_BUF_RESERVE PARAM_VALUE.TX_BUF_RESERVE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TX_BUF_RESERVE}] ${MODELPARAM_VALUE.TX_BUF_RESERVE}
}

proc update_MODELPARAM_VALUE.META_DEPTH { MODELPARAM_VALUE.META_DEPTH PARAM_VALUE.META_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.META_DEPTH}] ${MODELPARAM_VALUE.META_DEPTH}
}

proc update_MODELPARAM_VALUE.XFER_DEPTH { MODELPARAM_VALUE.XFER_DEPTH PARAM_VALUE.XFER_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.XFER_DEPTH}] ${MODELPARAM_VALUE.XFER_DEPTH}
}

proc update_MODELPARAM_VALUE.CHAIN_STAGES { MODELPARAM_VALUE.CHAIN_STAGES PARAM_VALUE.CHAIN_STAGES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CHAIN_STAGES}] ${MODELPARAM_VALUE.CHAIN_STAGES}
}

proc update_MODELPARAM_VALUE.CHAIN_DEPTH { MODELPARAM_VALUE.CHAIN_DEPTH PARAM_VALUE.CHAIN_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CHAIN_DEPTH}] ${MODELPARAM_VALUE.CHAIN_DEPTH}
}

proc update_MODELPARAM_VALUE.URAM_RD_LATENCY { MODELPARAM_VALUE.URAM_RD_LATENCY PARAM_VALUE.URAM_RD_LATENCY } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.URAM_RD_LATENCY}] ${MODELPARAM_VALUE.URAM_RD_LATENCY}
}

proc update_MODELPARAM_VALUE.TICK_STEP { MODELPARAM_VALUE.TICK_STEP PARAM_VALUE.TICK_STEP } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TICK_STEP}] ${MODELPARAM_VALUE.TICK_STEP}
}

proc update_MODELPARAM_VALUE.M_WIDTH { MODELPARAM_VALUE.M_WIDTH PARAM_VALUE.M_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.M_WIDTH}] ${MODELPARAM_VALUE.M_WIDTH}
}

