import logging
import xrfdc
import numpy as np
import time
import contextlib

from xrfdc import RFdcDacTile, RFdcAdcTile

from rfsoc_lib.rfdc_config import ZCU216_CONFIG
# defined PYNQ-free in their own modules; re-exported for existing importers
from rfsoc_lib.rfdc_type import MyRFdcType  # noqa: F401
from rfsoc_lib.dsp.unit_convt import dB2Amp, amp2dB  # noqa: F401


def nco_on_sysref():
    """True when mixer/NCO/QMC updates are applied on a SYSREF edge.

    ZCU216_CONFIG['NCOEventSource']: "TILE" (default) applies them per tile
    as they are written; "SYSREF" holds them until setup() pulses SYSREF into
    the converters, so every tile takes its NCO frequency and phase reset on
    the same edge (cross-tile phase alignment). SYSREF must be running for it --
    with no SYSREF an update never lands.
    """
    src = str(ZCU216_CONFIG.get('NCOEventSource', 'TILE')).upper()
    if src not in ('TILE', 'SYSREF'):
        raise ValueError(f"NCOEventSource {src!r}: expected TILE or SYSREF")
    return src == 'SYSREF'


class MyRFdcStatus:
    """Status of RF Data Converter"""

    def __init__(self, rfdc):
        # Keep the rfdc handle: IPStatus must be RE-READ for anything dynamic.
        # This used to snapshot IPStatus once at construction, so TileState was
        # frozen at whatever it was when the task object was built -- measured
        # on a ZCU216: state read 15 on every tile immediately after
        # tile.ShutDown(), and is_ready() therefore returned True on any warm
        # board, silently skipping set_external_clocks() + init() (the only
        # path to DynamicPLLConfig). Enable masks are static configuration and
        # stay snapshotted; the STATES are properties of the running hardware.
        self._rfdc = rfdc
        self.dac_tile_status = rfdc.IPStatus['DACTileStatus']
        self.adc_tile_status = rfdc.IPStatus['ADCTileStatus']
        self.dac_tile_mask_out = [False, False, False, False]
        self.adc_tile_mask_out = [False, False, False, False]
        # DAC IQ-to-IQ or IQ-to-Real mask
        dac_iq2iq_mask_out = [False, True, False, True]
        dac_iq2r_mask_out = [False, False, False, False]
        dac_r2r_mask_out = [False, False, False, False]
        # ADC IQ-to-IQ or Real-to-IQ mask
        adc_iq2iq_mask_out = [False, True, False, True]
        adc_r2iq_mask_out = [False, False, False, False]
        adc_r2r_mask_out = [False, False, False, False]
        # DAC and ADC mask mode
        self.adc_block_mask_out = adc_r2iq_mask_out
        self.dac_block_mask_out = dac_iq2r_mask_out

        self.dac_clk_dist_status = rfdc.ClkDistribution['DAC']
        self.adc_clk_dist_status = rfdc.ClkDistribution['ADC']

    def get_dac_tile_enb(self, tile_id):
        return self.dac_tile_status[tile_id]['IsEnabled'] and not self.dac_tile_mask_out[tile_id]

    def get_dac_tile_state(self, tile_id):
        return self._rfdc.IPStatus['DACTileStatus'][tile_id]['TileState']

    def get_dac_powerup_state(self, tile_id):
        return self.dac_tile_status[tile_id]['PowerUpState']

    def get_dac_pll_state(self, tile_id):
        return self.dac_tile_status[tile_id]['PLLState']

    def get_dac_block_enb(self, tile_id, block_id):
        if self.dac_block_mask_out[block_id]:
            return False
        else:
            return self.dac_tile_status[tile_id]['BlockStatusMask'] & (1 << block_id)

    def get_dac_clk_dist(self, tile_id):
        return self.dac_clk_dist_status[tile_id]

    def get_adc_tile_enb(self, tile_id):
        return self.adc_tile_status[tile_id]['IsEnabled'] and not self.adc_tile_mask_out[tile_id]

    def get_adc_tile_state(self, tile_id):
        return self._rfdc.IPStatus['ADCTileStatus'][tile_id]['TileState']

    def get_adc_powerup_state(self, tile_id):
        return self.adc_tile_status[tile_id]['PowerUpState']

    def get_adc_pll_state(self, tile_id):
        return self.adc_tile_status[tile_id]['PLLState']

    def get_adc_block_enb(self, tile_id, block_id):
        if self.adc_block_mask_out[block_id]:
            return False
        else:
            return self.adc_tile_status[tile_id]['BlockStatusMask'] & (1 << block_id)

    def get_adc_clk_dist(self, tile_id):
        return self.adc_clk_dist_status[tile_id]


class MyRFdcDACTile(RFdcDacTile):
    """New DAC tile class that inherits everything from Xilinx's RFdcDacTile class"""

    def __init__(self, tile_id, rfdc_dac_tile=None):
        if rfdc_dac_tile is not None:
            # The __dict__ of an instance holds all instance attributes, the above merely copies over all of those attributes to the new instance.
            self.__dict__.update(rfdc_dac_tile.__dict__)
        self._tile_id = tile_id
        self._tile_phy_id = tile_id + 228

    @property
    def tile_id(self):
        return self._tile_id

    @property
    def tile_phy_id(self):
        return self._tile_phy_id


class MyRFdcADCTile(RFdcAdcTile):
    """New ADC tile class that inherits everything from Xilinx's RFdcAdcTile class"""

    def __init__(self, tile_id, rfdc_adc_tile=None):
        if rfdc_adc_tile is not None:
            self.__dict__.update(rfdc_adc_tile.__dict__)
        self._tile_id = tile_id
        self._tile_phy_id = tile_id + 224

    @property
    def tile_id(self):
        return self._tile_id

    @property
    def tile_phy_id(self):
        return self._tile_phy_id


class MyRFdcFreqConfig:
    """RFDC clock and sampling rate configuration"""

    def __init__(self, ref_clk, dac_samp_rate, dac_nco, dac_interp_rate, adc_samp_rate, adc_nco, adc_interp_rate, clock_src=xrfdc.CLK_SRC_PLL):
        self.ref_clk = ref_clk
        self.clock_src = clock_src
        self.dac_samp_rate = dac_samp_rate
        self.dac_nco = dac_nco
        self.dac_interp_rate = dac_interp_rate
        self.adc_samp_rate = adc_samp_rate
        self.adc_nco = adc_nco
        self.adc_interp_rate = adc_interp_rate
        self.check_config()

    def mandatory_check(self):
        # Check reference clock
        if self.clock_src == xrfdc.CLK_SRC_PLL:
            ref_clk_min, ref_clk_max = ZCU216_CONFIG['RefClockForPLLMin'], ZCU216_CONFIG['RefClockForPLLMax']
            assert self.ref_clk >= ref_clk_min and self.ref_clk <= ref_clk_max, f"Reference clock frequency shall fall between {ref_clk_min}, {ref_clk_max} Hz if on-chip PLL is enabled."
        else:  # xrfdc.CLK_SRC_EXT
            ref_clk_min_for_dac = ZCU216_CONFIG['RefClockNoPLLDacMin']
            ref_clk_max_for_dac = ZCU216_CONFIG['RefClockNoPLLDacMax']
            ref_clk_min_for_adc = ZCU216_CONFIG['RefClockNoPLLAdcMin']
            ref_clk_max_for_adc = ZCU216_CONFIG['RefClockNoPLLAdcMax']
            err_msg = f"Reference clock frequency shall be above DAC:{ref_clk_min_for_dac} or ADC:{ref_clk_min_for_adc} Hz if on-chip PLL is bypassed."
            assert self.ref_clk >= ref_clk_min_for_dac and self.ref_clk >= ref_clk_min_for_adc, err_msg
            # The bypassed tile samples at its reference, so this bound is the
            # converter's own rate limit -- 2400 MHz sits inside both and must
            # not warn, which the old max/min mix-up made it do on every run.
            err_msg = f"Reference clock frequency shall fall below DAC:{ref_clk_max_for_dac} or ADC:{ref_clk_max_for_adc} Hz if on-chip PLL is bypassed."
            if self.ref_clk > ref_clk_max_for_dac or self.ref_clk > ref_clk_max_for_adc:
                logging.warning(err_msg)
        # Check NCO range
        err_msg = f"DAC NCO shall fall between -1/2*Fs and 1/2*Fs"
        if self.dac_samp_rate / 2 >= self.dac_nco >= -self.dac_samp_rate / 2:
            logging.warning(err_msg)
        err_msg = f"ADC NCO shall fall between 0 and 1/2*Fs"
        if self.adc_samp_rate / 2 >= self.adc_nco >= -self.adc_samp_rate / 2:
            logging.warning(err_msg)

    def comm_sys_check(self):
        # Check NCO diirection
        err_msg = f"DAC NCO is normally > 0 while ADC is normally < 0"
        assert self.dac_nco >= 0 and self.adc_nco <= 0, err_msg

    def filter_check(self):
        # Check whether interpolation/decimator factor is valid
        valid_factor_list = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 40]
        assert self.dac_interp_rate in valid_factor_list and self.adc_interp_rate in valid_factor_list, f"Interpolation or decimation factor does not fall in the valid range."

    def check_config(self):
        self.checker_list = [self.mandatory_check,
                             self.comm_sys_check, self.filter_check]
        for checker in self.checker_list:
            checker()


class MyRFdcConfig:

    @staticmethod
    def clock_src_for(ref_clk):
        """Pick the tile clock source the reference frequency implies.

        The MTS-enabled shells bypass the in-tile PLL and take the sample clock
        straight from the LMX2594 (Refclk_Freq 2400, PLL_Enable false), so their
        reference sits far above RefClockForPLLMax.  Hard-wiring CLK_SRC_PLL
        made those references fail the PLL range assertion, and the only way to
        get past it was to program the LMX to 300 MHz -- which a bypassed tile
        then samples at directly, running 8x slow with nothing reporting it.
        """
        if ref_clk > ZCU216_CONFIG['RefClockForPLLMax']:
            return xrfdc.CLK_SRC_EXT
        return xrfdc.CLK_SRC_PLL

    def __init__(self):
        self.freq_cfg = MyRFdcFreqConfig(
            ref_clk=ZCU216_CONFIG['RefClockForPLL'],
            dac_samp_rate=ZCU216_CONFIG['DACSampleRate'],
            dac_nco=ZCU216_CONFIG['DACNCO'],
            dac_interp_rate=ZCU216_CONFIG['DACInterpolationRate'],
            adc_samp_rate=ZCU216_CONFIG['ADCSampleRate'],
            adc_nco=ZCU216_CONFIG['ADCNCO'],
            adc_interp_rate=ZCU216_CONFIG['ADCInterpolationRate'],
            clock_src=self.clock_src_for(ZCU216_CONFIG['RefClockForPLL'])
        )

        self.dac_block_cfg = {
            'InterpolationFactor': self.freq_cfg.dac_interp_rate,
            'NyquistZone': ZCU216_CONFIG['DACNyquistZone'],
            'UpdateEvent': xrfdc.EVENT_MIXER,
            'InvSincFIR': ZCU216_CONFIG['InvSincFIR'],
        }
        self.dac_block_mixer_cfg = {
            'CoarseMixFreq': xrfdc.COARSE_MIX_BYPASS,
            'EventSource': xrfdc.EVNT_SRC_TILE,
            'FineMixerScale': xrfdc.MIXER_SCALE_1P0,
            'Freq': self.freq_cfg.dac_nco,
            'MixerMode': xrfdc.MIXER_MODE_C2R,
            'MixerType': xrfdc.MIXER_TYPE_FINE,
            'PhaseOffset': 0,
        }

        self.adc_block_cfg = {
            'DecimationFactor': self.freq_cfg.adc_interp_rate,
            'NyquistZone': ZCU216_CONFIG['ADCNyquistZone'],
            'UpdateEvent': xrfdc.EVENT_MIXER,
        }
        self.adc_block_mixer_cfg = {
            'CoarseMixFreq': xrfdc.COARSE_MIX_BYPASS,
            'EventSource': xrfdc.EVNT_SRC_TILE,
            'FineMixerScale': xrfdc.MIXER_SCALE_1P0,
            'Freq': self.freq_cfg.adc_nco,
            'MixerMode': xrfdc.MIXER_MODE_R2C,
            'MixerType': xrfdc.MIXER_TYPE_FINE,
            'PhaseOffset': 0
        }


class MyRFdc:
    """My class for controlling the RF Data Converter."""

    def __init__(self, rfdc_ip, debug_mode=False):
        self.rfdc = rfdc_ip
        self.rfdc_status = MyRFdcStatus(self.rfdc)
        self.rfdc_cfg = MyRFdcConfig()
        self.dac_tiles = [MyRFdcDACTile(
            tile_id, tile) for tile_id, tile in enumerate(self.rfdc.dac_tiles)]
        self.adc_tiles = [MyRFdcADCTile(
            tile_id, tile) for tile_id, tile in enumerate(self.rfdc.adc_tiles)]
        self.clock_src = self.rfdc_cfg.freq_cfg.clock_src
        self.debug_mode = debug_mode

    def debug(self):
        # Attributes for both DAC and ADC blocks
        block_attr = ['BlockStatus', 'MixerSettings', 'QMCSettings',
                      'CoarseDelaySettings', 'NyquistZone', 'EnabledInterrupts', 'PwrMode']
        # Attributes for DAC block only
        dac_only_attr = ['InterpolationFactor', 'DecoderMode',  # 'OutputCurr',
                         'InvSincFIR', 'FabRdVldWords', 'FabWrVldWords', 'DataPathMode', 'IMRPassMode', 'DACCompMode']
        # Attributes for ADC block only
        adc_only_attr = ['DecimationFactor', 'CalibrationMode', 'FabRdVldWords',
                         'FabWrVldWords', 'DecimationFactorObs', 'FabRdVldWordsObs', 'FabWrVldWordsObs', 'Dither', 'CalFreeze', 'DSA']

        for tile in self.dac_tiles:
            if self.rfdc_status.get_dac_tile_enb(tile.tile_id):
                for block_id, block in enumerate(tile.blocks):
                    if self.rfdc_status.get_dac_block_enb(
                            tile.tile_id, block_id):
                        for attr in block_attr:
                            logging.info(attr+": "+str(getattr(block, attr)))
                        for attr in dac_only_attr:
                            logging.info(attr+": "+str(getattr(block, attr)))
        for tile in self.adc_tiles:
            if self.rfdc_status.get_adc_tile_enb(tile.tile_id):
                for block_id, block in enumerate(tile.blocks):
                    if self.rfdc_status.get_adc_block_enb(
                            tile.tile_id, block_id):
                        for attr in block_attr:
                            logging.info(attr+": "+str(getattr(block, attr)))
                        for attr in adc_only_attr:
                            logging.info(attr+": "+str(getattr(block, attr)))

    def init(self):
        """Power on DAC/ADC tiles"""
        # Power on DAC tiles
        for tile in self.dac_tiles:
            self.power_on_dac_tile(tile)
        # Power on ADC tiles
        for tile in self.adc_tiles:
            self.power_on_adc_tile(tile)

    def setup(self):
        """Configure DAC/ADC blocks"""
        # Configure DAC blocks within each tile
        with self._sysref_update(self.rfdc.mts_dac_config):
            for tile in self.dac_tiles:
                self.config_dac_blocks(tile)
        # Configure ADC blocks within each tile
        with self._sysref_update(self.rfdc.mts_adc_config):
            for tile in self.adc_tiles:
                self.config_adc_blocks(tile)

    @contextlib.contextmanager
    def _sysref_update(self, mts_config):
        """In SYSREF mode, gate SYSREF off while the blocks are written, then
        pulse it so every tile applies its mixer/QMC update on one edge."""
        if not nco_on_sysref():
            yield
            return
        mts_config.SysRef_Enable = 0
        yield
        mts_config.SysRef_Enable = 1
        time.sleep(1)  # wait for a SYSREF edge to be detected
        mts_config.SysRef_Enable = 0

    def is_ready(self):
        """Check if all tiles are powered up AND clocked as configured.

        Power alone is not readiness: the tiles self-start from whatever clock
        the boot left on the LMK, report state 15, and RfdcTask.run() then
        skipped init() -- so DynamicPLLConfig never ran, the tile PLL stayed
        disabled, and the converters sampled at the raw LMX frequency while
        every rate register read back correctly. When the configuration asks
        for the on-chip PLL (CLK_SRC_PLL), a tile whose PLL is not enabled is
        NOT ready, whatever its power state says.
        """
        for tile in self.dac_tiles:
            if not self.is_dac_tile_ready(tile):
                return False
        for tile in self.adc_tiles:
            if not self.is_adc_tile_ready(tile):
                return False
        if self.clock_src == xrfdc.CLK_SRC_PLL:
            for tile in self.dac_tiles:
                if self.rfdc_status.get_dac_tile_enb(tile.tile_id) and                         not int(tile.PLLConfig.get('Enabled', 0)):
                    return False
            for tile in self.adc_tiles:
                if self.rfdc_status.get_adc_tile_enb(tile.tile_id) and                         not int(tile.PLLConfig.get('Enabled', 0)):
                    return False
            # ENABLED IS A PROGRAMMED FLAG, NOT A LOCK. Measured on a ZCU216:
            # every ADC tile read PLLConfig Enabled=1 while PLLLockStatus was 1
            # (XRFDC_PLL_UNLOCKED) -- the tile free-ran at an arbitrary rate and
            # the fabric interface FIFO emitted 48-sample stale pages (both FIFO
            # flags asserted). A tile whose PLL is claimed enabled but not
            # actually locked (PLLLockStatus != 2) is NOT ready.
            for tiles, get_enb in ((self.dac_tiles,
                                    self.rfdc_status.get_dac_tile_enb),
                                   (self.adc_tiles,
                                    self.rfdc_status.get_adc_tile_enb)):
                for tile in tiles:
                    if not get_enb(tile.tile_id):
                        continue
                    if not int(tile.PLLConfig.get('Enabled', 0)):
                        continue
                    try:
                        locked = int(tile.PLLLockStatus)
                    except Exception:
                        continue
                    if locked != 2:
                        logging.warning(
                            f"tile {tile.tile_id}: PLL enabled but "
                            f"PLLLockStatus={locked} (2=locked) -- not ready")
                        return False
        return True

    def shutdown_tiles(self):
        """Safely shutdown all tiles."""
        for tile in self.dac_tiles:
            if self.rfdc_status.get_dac_tile_enb(tile.tile_id):
                tile.ShutDown()
        for tile in self.adc_tiles:
            if self.rfdc_status.get_adc_tile_enb(tile.tile_id):
                tile.ShutDown()
        logging.info(f"All tiles has been safely shutdown!")

    def is_dac_tile_ready(self, tile):
        tile_state = self.rfdc_status.get_dac_tile_state(tile.tile_id)
        if self.rfdc_status.get_dac_tile_enb(tile.tile_id):
            return False if tile_state < 15 else True
        else:
            return True

    def _dynamic_pll_config(self, kind, tile, samp_rate):
        """DynamicPLLConfig, tolerating a tile that receives a distributed clock.

        With the tile PLL bypassed (CLK_SRC_EXT) on a shell that distributes the
        sample clock from one tile to its neighbours (e.g. zcu216_v45_rt_1ch_mts:
        DAC1/ADC1 distribute to tiles 0,2,3), the driver refuses a source setting
        on the receiving tiles ("Invalid Source value (2) for DAC 0"): their clock
        is set by the distributing tile. That refusal is not an error. Whether
        the tile really has a clock is decided by the TileState == 15 check that
        follows, unchanged -- a tile without one still fails loudly.
        """
        try:
            tile.DynamicPLLConfig(
                self.clock_src, self.rfdc_cfg.freq_cfg.ref_clk, samp_rate)
        except RuntimeError as e:
            if self.clock_src == xrfdc.CLK_SRC_EXT and "Invalid Source value" in str(e):
                logging.info(f"{kind} tile {tile.tile_id}: clock comes from the "
                             f"distributing tile; source not set here")
            else:
                raise

    def power_on_dac_tile(self, tile):
        """Power on DAC tiles."""
        if self.rfdc_status.get_dac_tile_enb(tile.tile_id):
            # Configure a single tile
            self._dynamic_pll_config("DAC", tile, ZCU216_CONFIG[f'DACSampleRate{tile.tile_id}'])
            time.sleep(1)
            tile.SetupFIFO(True)
            # Check tile state
            tile_state = self.rfdc_status.get_dac_tile_state(tile.tile_id)
            if tile_state < 15:
                err_msg = f"DAC tile {tile.tile_id} ({tile.tile_phy_id}) is NOT fully powered up! Stuck at Step {tile_state}: {MyRFdcType.POWER_ON_SEQUENCE_STEPS[tile_state]['State']} Description: {MyRFdcType.POWER_ON_SEQUENCE_STEPS[tile_state]['Description']}"
                if 6 <= tile_state <= 10 and self.debug_mode:
                    logging.info(
                        self.rfdc_status.get_dac_clk_dist(tile.tile_id))
                raise Exception(err_msg)
            logging.info(
                f"DAC tile {tile.tile_id} ({tile.tile_phy_id}) is fully powered up!")

    def is_adc_tile_ready(self, tile):
        tile_state = self.rfdc_status.get_adc_tile_state(tile.tile_id)
        if self.rfdc_status.get_adc_tile_enb(tile.tile_id):
            return False if tile_state < 15 else True
        else:
            return True

    def power_on_adc_tile(self, tile):
        """Power on ADC tiles."""
        if self.rfdc_status.get_adc_tile_enb(tile.tile_id):
            # Configure a single tile
            self._dynamic_pll_config("ADC", tile, ZCU216_CONFIG[f'ADCSampleRate{tile.tile_id}'])
            time.sleep(1)
            tile.SetupFIFO(True)
            # Check tile state
            tile_state = self.rfdc_status.get_adc_tile_state(tile.tile_id)
            if tile_state < 15:
                err_msg = f"ADC tile {tile.tile_id} ({tile.tile_phy_id}) is NOT fully powered up! Stuck at Step {tile_state}: {MyRFdcType.POWER_ON_SEQUENCE_STEPS[tile_state]['State']} Description: {MyRFdcType.POWER_ON_SEQUENCE_STEPS[tile_state]['Description']}"
                if 6 <= tile_state <= 10 and self.debug_mode:
                    logging.info(
                        self.rfdc_status.get_adc_clk_dist(tile.tile_id))
                raise Exception(err_msg)
            logging.info(
                f"ADC tile {tile.tile_id} ({tile.tile_phy_id}) is fully powered up!")

    @staticmethod
    def _check_nco(kind, tile, nco_freq_mhz):
        fs = ZCU216_CONFIG[f'{kind}SampleRate{tile.tile_id}']
        if not (fs / 2 >= nco_freq_mhz >= -fs / 2):
            logging.warning(f"{kind} NCO ({nco_freq_mhz}) shall fall between "
                            f"-1/2*Fs ({-fs / 2}) and 1/2*Fs ({fs / 2})")

    @staticmethod
    def _apply_mixer(block):
        """Apply a written mixer setting: now (TILE), or on the next SYSREF
        edge with the NCO phase reset there too (SYSREF)."""
        if nco_on_sysref():
            block.ResetNCOPhase()
        else:
            block.UpdateEvent(xrfdc.EVENT_MIXER)

    @staticmethod
    def _block_mixer_cfg(base, kind, tile_id, block_id):
        """The mixer dict for one block: its own NCO (per-block key, falling
        back to the flat one) and the configured event source."""
        cfg = dict(base)
        cfg['Freq'] = ZCU216_CONFIG[f'{kind}NCO{tile_id}{block_id}']
        if nco_on_sysref():
            cfg['EventSource'] = xrfdc.EVNT_SRC_SYSREF
        return cfg

    def config_dac_nco(self, tile, block_id, nco_freq_mhz):
        """Configure the NCO freq of a DAC block"""
        self._check_nco("DAC", tile, nco_freq_mhz)
        assert nco_freq_mhz >= 0, f"DAC NCO frequency {nco_freq_mhz} shall be >= 0."
        block_enabled = self.rfdc_status.get_dac_block_enb(
            tile.tile_id, block_id)
        if block_enabled:
            block = tile.blocks[block_id]
            block.MixerSettings['Freq'] = nco_freq_mhz
            self._apply_mixer(block)
            logging.info(
                f"DAC tile {tile.tile_id} DAC block {block_id} NCO frequency is set to {nco_freq_mhz} MHz!")
        else:
            logging.info(
                f"DAC tile {tile.tile_id} DAC block {block_id} is NOT enabled!")

    def config_dac_block(self, tile, block_id):
        """Configure a single DAC block within a tile."""
        block_enabled = self.rfdc_status.get_dac_block_enb(
            tile.tile_id, block_id)
        if block_enabled:
            block = tile.blocks[block_id]
            block.NyquistZone = self.rfdc_cfg.dac_block_cfg['NyquistZone']
            block.MixerSettings = self._block_mixer_cfg(
                self.rfdc_cfg.dac_block_mixer_cfg, 'DAC', tile.tile_id, block_id)
            # Same guard as the ADC: rewriting an unchanged interpolation still
            # re-derives the DAC fabric width and breaks the compiled gearbox.
            interp = ZCU216_CONFIG[f'DACInterpFactor{tile.tile_id}{block_id}']
            if block.InterpolationFactor != interp:
                block.InterpolationFactor = interp
            self._apply_mixer(block)
            block.QMCSettings = {'EnablePhase': 0, 'EnableGain': 0, 'GainCorrectionFactor': 0.0,
                                 'PhaseCorrectionFactor': 0.0, 'OffsetCorrectionFactor': 0,
                                 'EventSource': xrfdc.EVNT_SRC_SYSREF if nco_on_sysref() else xrfdc.EVNT_SRC_IMMEDIATE}
            block.InvSincFIR = self.rfdc_cfg.dac_block_cfg['InvSincFIR']
            logging.info(
                f"DAC tile {tile.tile_id} DAC block {block_id} is enabled!")
        else:
            logging.info(
                f"DAC tile {tile.tile_id} DAC block {block_id} is NOT enabled!")

    def config_dac_blocks(self, tile):
        """Configure all DAC blocks within a tile."""
        for block_id in range(len(tile.blocks)):
            self.config_dac_block(tile, block_id)

    def config_adc_nco(self, tile, block_id, nco_freq_mhz):
        """Configure the NCO freq of an ADC block"""
        self._check_nco("ADC", tile, nco_freq_mhz)
        assert nco_freq_mhz <= 0, f"ADC NCO frequency {nco_freq_mhz} shall be <= 0 "
        block_enabled = self.rfdc_status.get_adc_block_enb(
            tile.tile_id, block_id)
        block = tile.blocks[block_id]
        if block_enabled:
            block.MixerSettings['Freq'] = nco_freq_mhz
            self._apply_mixer(block)
            logging.info(
                f"ADC tile {tile.tile_id} ADC block {block_id} NCO frequency is set to {nco_freq_mhz} MHz!")
        else:
            logging.info(
                f"ADC tile {tile.tile_id} ADC block {block_id} is NOT enabled!")

    def config_adc_block(self, tile, block_id):
        """Configure a single ADC block within a tile."""
        block_enabled = self.rfdc_status.get_adc_block_enb(
            tile.tile_id, block_id)
        if block_enabled:
            block = tile.blocks[block_id]
            block.NyquistZone = self.rfdc_cfg.adc_block_cfg['NyquistZone']
            block.MixerSettings = self._block_mixer_cfg(
                self.rfdc_cfg.adc_block_mixer_cfg, 'ADC', tile.tile_id, block_id)
            # WRITE THE DECIMATION ONLY IF IT DIFFERS FROM WHAT THE BITSTREAM
            # COMPILED. XRFdc_SetDecimationFactor is not an idempotent register
            # write: even when the value is unchanged (16 == 16) the driver
            # re-derives the fabric interface width from its own defaults,
            # which clobbers the compiled Data_Width gearbox. Measured on the
            # zcu216 4x4 overlay (Data_Width 8, four complex per 128-bit beat):
            # after this write the ADC handed the fabric TWO complex per clock
            # instead of four -- every frame captured 2x time-compressed (CP
            # correlation 0.92 at N=128 against 0.29 at the design's N=256)
            # with the missing half padded by stale FIFO re-reads.
            decim = ZCU216_CONFIG[f'ADCDecimFactor{tile.tile_id}{block_id}']
            if block.DecimationFactor != decim:
                block.DecimationFactor = decim
            self._apply_mixer(block)
            block.QMCSettings = {'EnablePhase': 0, 'EnableGain': 0, 'GainCorrectionFactor': 0.0,
                                 'PhaseCorrectionFactor': 0.0, 'OffsetCorrectionFactor': 0,
                                 'EventSource': xrfdc.EVNT_SRC_SYSREF if nco_on_sysref() else xrfdc.EVNT_SRC_TILE}
            logging.info(
                f"ADC tile {tile.tile_id} ADC block {block_id} is enabled!")
        else:
            logging.info(
                f"ADC tile {tile.tile_id} ADC block {block_id} is NOT enabled!")

    def config_adc_blocks(self, tile):
        """Configure all ADC blocks within a tile."""
        for block_id in range(len(tile.blocks)):
            self.config_adc_block(tile, block_id)
