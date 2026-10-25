import logging
from pynq import Overlay


class RFSoCOverlay(Overlay):
    """A pynq Overlay of one of this repository's bitstreams (the .hwh next
    to the .bit). ignore_version: the .hwh was written by Vivado 2021.1,
    which may be newer or older than the board's PYNQ expects."""

    def __init__(self, path_to_bitstream, **kwargs):
        super().__init__(path_to_bitstream, ignore_version=True, **kwargs)
        logging.debug("overlay %s: IPs %s", path_to_bitstream, ", ".join(self.ip_dict))
