from rfsoc_lib.clocks import clock_plan, program_clocks
from rfsoc_lib.overlay_task import OverlayTask
from rfsoc_lib.rfdc import MyRFdc
import os
import time
import logging
from rfsoc_lib.rfdc_config import RFDC_CONFIG


class RfdcTask(OverlayTask):
    """Bring the RF data converters up as RFDC_CONFIG describes: program
    the board's clock chips, power the tiles up, configure every block, set
    the NCOs. Run on its own thread (start() / join()); MTS is the caller's
    (rfsoc_lib.mts.MyMTS, run by the daemon after this task)."""

    def __init__(self, overlay, debug_mode=False, board="ZCU216", masked_tiles=(), clock_source="internal"):
        """board: the xrfclk/<board>/ register files; masked_tiles: the DAC
        and ADC tiles left unpowered (tiles the board does not wire: init()
        skips them instead of timing out on their PLLs)."""
        super().__init__(overlay, name="RfdcTask")
        self.debug_mode = debug_mode
        rfdc_ip = overlay.rfdc.usp_rf_data_converter
        self.my_rfdc = MyRFdc(rfdc_ip, debug_mode=debug_mode)
        self.board = board
        self.clock_source = clock_source      # LMK04828 reference: internal | external
        for t in masked_tiles:
            self.my_rfdc.rfdc_status.dac_tile_mask_out[t] = True
            self.my_rfdc.rfdc_status.adc_tile_mask_out[t] = True

    def set_external_clocks(self):
        # Every board has the LMK04828 + LMX2594 chain; only the xrfclk TICS
        # register files differ per board.

        # The clock plan is the build's: the LMX2594 makes the tiles'
        # reference (RefClockForPLL = the .hwh Refclk_Freq, fs with the tile
        # PLLs bypassed) and the LMK04828 the MTS PL clock the build's
        # MTS_clk_wiz expects (MTSPLClockFreq, its PRIM_IN_FREQ; 300 MHz
        # unless the caller says otherwise). That picks the 250 MHz family
        # (PL_CLK 300, SYSREF 10) or the 245.76 MHz one (122.88, 7.68).
        # The register files are found relative to the CWD (the library root).
        config_dir = os.getcwd()
        for sub_dir in ["rfsoc_lib", "xrfclk", self.board]:
            config_dir = os.path.join(config_dir, sub_dir)
        if not os.path.isdir(config_dir):
            raise RuntimeError(f"RFSoC board {self.board}: no clock register files in {config_dir}")
        lmk_config, lmx_config = clock_plan(
            config_dir, lmx_out=RFDC_CONFIG['RefClockForPLL'],
            pl_clk=RFDC_CONFIG.get('MTSPLClockFreq', 300.0), source=self.clock_source)
        self.clock_files = (lmk_config.file, lmx_config.file)
        logging.info(f"clock plan ({self.clock_source} reference): {lmk_config.file} + {lmx_config.file}")

        _lmk_prop, _lmx_prop = program_clocks(lmk_config, lmx_config)
        if self.debug_mode:
            for prop in [_lmk_prop, _lmx_prop]:
                logging.info(
                    f"{prop['chip']} freq_in {prop['freq_in']} MHz freq_out {prop['freq_out']} MHz ")
                if 'mts_pl_clk_freq' in prop:
                    logging.info(
                        f"{prop['chip']} mts_pl_clk_freq {prop['mts_pl_clk_freq']} MHz mts_pl_sysref_freq {prop['mts_pl_sysref_freq']} MHz ")

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
                    dac_nco_mhz = RFDC_CONFIG[f'DACNCO{tile.tile_id}{block_id}']
                    self.my_rfdc.config_dac_nco(tile, block_id, dac_nco_mhz)
        # Set all ADCs to their respective ADCNCO
        for tile in self.my_rfdc.adc_tiles:
            if self.my_rfdc.rfdc_status.get_adc_tile_enb(tile.tile_id):
                for block_id, block in enumerate(tile.blocks):
                    adc_nco_mhz = RFDC_CONFIG[f'ADCNCO{tile.tile_id}{block_id}']
                    self.my_rfdc.config_adc_nco(tile, block_id, adc_nco_mhz)

    def run(self):
        # THE CLOCKS ARE PROGRAMMED EVERY TIME, NOT ONLY WHEN THE TILES LOOK DOWN.
        #
        # With the in-tile PLL bypassed the tiles reach state 15 on their own as
        # soon as any clock is present, so a "ready" check is already true on a
        # fresh boot and the converters would run at whatever the LMX2594 was
        # left at by an earlier session -- correct or not, with nothing
        # reporting the difference. Programming the LMX unconditionally makes a
        # run depend on its own configuration instead of on what happened to
        # run before it. init() follows unconditionally for the same reason:
        # reprogramming the LMX disturbs the reference under whatever is
        # already running, so the tiles have to be brought back up against the
        # clock this run just set.
        self.set_external_clocks()
        self.relock_pl_mmcm()
        self.my_rfdc.init()
        # Config DAC/ADC to target sampling rate and interp/decim factor
        self.my_rfdc.setup()
        self.set_nco()
