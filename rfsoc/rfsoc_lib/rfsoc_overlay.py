import logging
from pynq import Overlay


class RFSoCOverlay(Overlay):
    """A pynq Overlay of one of this repository's bitstreams (the .hwh next
    to the .bit). ignore_version: PYNQ's xrfdc binds the RFDC IP by version
    (2.3 / 2.4 on PYNQ 2.7, 2.6 / 2.4 / 2.3 on 3.x); the 2021.1 builds'
    2.5 gets its driver only this way (fpga/AGENTS.md, "PYNQ versions")."""

    def __init__(self, path_to_bitstream, **kwargs):
        super().__init__(path_to_bitstream, ignore_version=True, **kwargs)
        logging.debug("overlay %s: IPs %s", path_to_bitstream, ", ".join(self.ip_dict))
