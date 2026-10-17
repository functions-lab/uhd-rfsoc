from rfsoc_lib.clocks import clock_plan, program_clocks
from rfsoc_lib.overlay_task import OverlayTask
from rfsoc_lib.rfdc import MyRFdc
from rfsoc_lib.mts import MyMTS
import os
import time
import logging
from rfsoc_lib.rfdc_config import ZCU216_CONFIG


class RfdcTask(OverlayTask):
    """Task for configuring RF data converters."""

    def __init__(self, overlay, mts_enable=False, debug_mode=False, board="ZCU216"):
        """Initialize the task with the given overlay."""
        super().__init__(overlay, name="RfdcTask")
        self.debug_mode = debug_mode
        rfdc_ip = overlay.rfdc.usp_rf_data_converter
        self.my_rfdc = MyRFdc(rfdc_ip, debug_mode=debug_mode)
        self.board = board
        self.mts_enable = mts_enable
        if self.mts_enable:
            self.my_mts = MyMTS(
                rfdc_ip, overlay, board=self.board, debug=debug_mode)
        self.set_board_rules()

    def set_board_rules(self):
        if self.board == "RFSoC4x2":
            # The board wires only 2 DAC tiles (228, 230) and 2 ADC tiles
            # (224, 226) to SMA; mask out the unused middle tiles (#1, #3)
            # so init() skips powering them and avoids PLL timeout.
            self.my_rfdc.rfdc_status.dac_tile_mask_out[1] = True
            self.my_rfdc.rfdc_status.dac_tile_mask_out[3] = True
            self.my_rfdc.rfdc_status.adc_tile_mask_out[1] = True
            self.my_rfdc.rfdc_status.adc_tile_mask_out[3] = True

    def set_external_clocks(self):
        # ZCU216 and RFSoC4x2 share the LMK04828 + LMX2594 chain; only the
        # xrfclk TICS data subdirectory differs per board.
        if self.board not in ("ZCU216", "RFSoC4x2"):
            raise RuntimeError(f"RFSoC board {self.board} unsupported.")

        # The clock plan is the build's: the LMX2594 makes the tiles'
        # reference (RefClockForPLL = the .hwh Refclk_Freq, fs with the tile
        # PLLs bypassed) and the LMK04828 the MTS PL clock the build's
        # MTS_clk_wiz expects (MTSPLClockFreq, its PRIM_IN_FREQ; 300 MHz
        # unless the caller says otherwise). That picks the 250 MHz family
        # (PL_CLK 300, SYSREF 10) or the 245.76 MHz one (122.88, 7.68).
        config_dir = os.getcwd()
        for sub_dir in ["rfsoc_lib", "xrfclk", self.board]:
            config_dir = os.path.join(config_dir, sub_dir)
        lmk_config, lmx_config = clock_plan(
            config_dir, lmx_out=ZCU216_CONFIG['RefClockForPLL'],
            pl_clk=ZCU216_CONFIG.get('MTSPLClockFreq', 300.0))
        self.clock_files = (lmk_config.file, lmx_config.file)
        logging.info(f"clock plan: {lmk_config.file} + {lmx_config.file}")

        # Program clocks
        _lmk_prop, _lmx_prop = program_clocks(lmk_config, lmx_config)
        # Debug clock properties
        if self.debug_mode:
            for prop in [_lmk_prop, _lmx_prop]:
                logging.info(
                    f"{prop['chip']} freq_in {prop['freq_in']} MHz freq_out {prop['freq_out']} MHz ")
                try:
                    logging.info(
                        f"{prop['chip']} mts_pl_clk_freq {prop['mts_pl_clk_freq']} MHz mts_pl_sysref_freq {prop['mts_pl_sysref_freq']} MHz ")
                except:
                    pass

    def relock_pl_mmcm(self, timeout=1.0):
        """Reset the MTS clocking wizard if its MMCM is not locked after the
        clocks were programmed: a build of the other clock family (PL_CLK
        300 vs 122.88 MHz) leaves it unlocked until the LMK04828 runs at
        its frequency, and an MMCM does not recover from a changed input by
        itself. The reset restores the build's setting, which is the one
        wanted here."""
        # a plain MMIO from ip_dict: the overlay's driver attribute would
        # need an asyncio loop in this (task) thread
        from pynq import MMIO
        key = next((k for k in self.ol.ip_dict if k.endswith("MTS_clk_wiz")), None)
        if key is None:
            return
        ip = self.ol.ip_dict[key]
        cw = MMIO(ip["phys_addr"], ip["addr_range"])
        if cw.read(0x4) & 1:
            return
        cw.write(0x0, 0xA)
        t0 = time.monotonic()
        while not cw.read(0x4) & 1:
            if time.monotonic() - t0 > timeout:
                raise RuntimeError("MTS clocking wizard did not lock after "
                                   "the clock plan was programmed")
            time.sleep(0.005)
        logging.info(f"MTS clocking wizard relocked after reset "
                     f"({1e3 * (time.monotonic() - t0):.0f} ms)")

    def set_nco(self):
        # Set all DACs to their respective DACNCO
        for tile in self.my_rfdc.dac_tiles:
            if self.my_rfdc.rfdc_status.get_dac_tile_enb(tile.tile_id):
                for block_id, block in enumerate(tile.blocks):
                    dac_nco_mhz = ZCU216_CONFIG[f'DACNCO{tile.tile_id}{block_id}']
                    self.my_rfdc.config_dac_nco(tile, block_id, dac_nco_mhz)
        # Set all ADCs to their respective ADCNCO
        for tile in self.my_rfdc.adc_tiles:
            if self.my_rfdc.rfdc_status.get_adc_tile_enb(tile.tile_id):
                for block_id, block in enumerate(tile.blocks):
                    adc_nco_mhz = ZCU216_CONFIG[f'ADCNCO{tile.tile_id}{block_id}']
                    self.my_rfdc.config_adc_nco(tile, block_id, adc_nco_mhz)

    # TODO: Find a better way to handle this
    def settiqc_demo_freq(self):
        # Set DAC NCOs to TIQC spec
        t0 = self.my_rfdc.dac_tiles[0]
        self.my_rfdc.config_dac_nco(t0, 0, 184)
        self.my_rfdc.config_dac_nco(t0, 1, 197)
        self.my_rfdc.config_dac_nco(t0, 2, 197)
        self.my_rfdc.config_dac_nco(t0, 3, 197)

    def set_tiqc_demo_freq(self):
        logging.info(f"Overwrite NCO frequency for TIQC application.")
        # Set DAC NCOs to TIQC spec
        t0 = self.my_rfdc.dac_tiles[0]
        self.my_rfdc.config_dac_nco(t0, 0, 153)
        self.my_rfdc.config_dac_nco(t0, 1, 153)
        self.my_rfdc.config_dac_nco(t0, 2, 153)
        self.my_rfdc.config_dac_nco(t0, 3, 153)

    def run(self):
        """Run the task."""
        # THE CLOCKS ARE PROGRAMMED EVERY TIME, NOT ONLY WHEN THE TILES LOOK DOWN.
        #
        # With the in-tile PLL bypassed the tiles reach state 15 on their own as
        # soon as any clock is present, so is_ready() is already True on a fresh
        # boot and this whole block used to be skipped. The converters then ran
        # at whatever the LMX2594 was left at by an earlier session -- correct or
        # not, with nothing reporting the difference. Programming the LMX
        # unconditionally makes a run depend on its own configuration instead of
        # on what happened to run before it.
        # init() follows unconditionally for the same reason: reprogramming the
        # LMX disturbs the reference under whatever is already running, so the
        # tiles have to be brought back up against the clock this run just set.
        self.set_external_clocks()
        self.relock_pl_mmcm()
        self.my_rfdc.init()
        # Config DAC/ADC to target samping rate and interp/decim factor
        self.my_rfdc.setup()
        # Initialize MTS if enabled
        if self.mts_enable:
            self.my_mts.init()
        # Set DAC/ADC NCOs
        self.set_nco()


class RfdcMultiBandTask(RfdcTask):

    def set_nco(self):
        tile_id_to_configure = 2  # Based on original code's comment "Use 2nd tile only"

        # Additional configuration for DAC NCO
        tile = self.my_rfdc.dac_tiles[tile_id_to_configure]

        # Determine current block 0 NCO and offset calculation
        dac_nco_0_mhz = ZCU216_CONFIG[f'DACNCO{tile_id_to_configure}0']
        dac_samp_rate_tile = ZCU216_CONFIG[f'DACSampleRate{tile_id_to_configure}']
        dac_interp_factor_0 = ZCU216_CONFIG[f'DACInterpFactor{tile_id_to_configure}0']
        dac_nco_offset = (dac_samp_rate_tile / dac_interp_factor_0) + 50

        # Set 1st DAC NCO (Block 0)
        self.my_rfdc.config_dac_nco(tile, 0, dac_nco_0_mhz)

        for block_id in [1, 2, 3]:
            # Get the NCO value for the current block from JSON
            dac_nco_current_block = ZCU216_CONFIG[f'DACNCO{tile_id_to_configure}{block_id}']
            # Apply the offset to this block's NCO value (as per original logic intent)
            dac_nco_mhz_with_offset = dac_nco_current_block + dac_nco_offset
            self.my_rfdc.config_dac_nco(tile, block_id, dac_nco_mhz_with_offset)

        # Additional configuration for ADC NCO
        tile = self.my_rfdc.adc_tiles[tile_id_to_configure]

        # Determine current block 0 NCO and offset calculation
        adc_nco_0_mhz = ZCU216_CONFIG[f'ADCNCO{tile_id_to_configure}0']
        adc_samp_rate_tile = ZCU216_CONFIG[f'ADCSampleRate{tile_id_to_configure}']
        adc_decim_factor_0 = ZCU216_CONFIG[f'ADCDecimFactor{tile_id_to_configure}0']
        adc_nco_offset = (adc_samp_rate_tile / adc_decim_factor_0) - 50

        # Set 1st ADC NCO (Block 0)
        self.my_rfdc.config_adc_nco(tile, 0, adc_nco_0_mhz)

        for block_id in [1, 2, 3]:
            # Get the NCO value for the current block from JSON
            adc_nco_current_block = ZCU216_CONFIG[f'ADCNCO{tile_id_to_configure}{block_id}']
            # Apply the offset to this block's NCO value (as per original logic intent)
            adc_nco_mhz_with_offset = adc_nco_current_block - adc_nco_offset
            self.my_rfdc.config_adc_nco(tile, block_id, adc_nco_mhz_with_offset)

    def run(self):
        super().run()
        # Customly set DAC/ADC NCO
        self.set_nco()
