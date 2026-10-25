class MyRFdcType:
    """The RF data converter tile power-on sequence (PG269, "Power-on
    Sequence"): what each TileState 0..15 means, for the bring-up's error
    messages."""

    POWER_ON_STATES = [
        "[Device Power-up and Configuration]",
        "[Power Supply Adjustment]",
        "[Clock Configuration]",
        "[Converter Calibration (ADC only)]",
        "[Wait for deassertion of AXI4-Stream reset]",
        "[Done]"
    ]

    POWER_ON_DESC = [
        "[The configuration parameters set in the Vivado IDE are programmed into the converters. The state machine then waits for the external supplies to be powered up. In hardware this can take up to 25 ms.]",
        "[The configuration settings are propagated to the analog sections of the converters. In addition the regulators, bias settings in the RF-DAC, and the common-mode output buffer in the RF-ADC are enabled.]",
        "[The state machine first detects the presence of a good clock into the converter. Then, if the PLL is enabled, it checks for PLL lock. The clocks are then released to the digital section of the converters.]",
        "[Calibration is carried out in the RF-ADC. In hardware this can take approximately 10 ms.]",
        "[The AXI4-Stream reset for the tile should be asserted until the AXI4-Stream clocks are stable. For example, if the clock is provided by a MMCM, the reset should be held until it has achieved lock. The state machine waits in this state until the reset is deasserted.]",
        "[The state machine has completed the power-up sequence.]"
    ]

    # TileState -> index into POWER_ON_STATES / POWER_ON_DESC
    _STATE_OF = [0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 4, 5]

    POWER_ON_SEQUENCE_STEPS = [
        {"Sequence Number": n, "State": POWER_ON_STATES[i], "Description": POWER_ON_DESC[i]}
        for n, i in enumerate(_STATE_OF)
    ]
