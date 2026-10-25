import threading
from abc import ABC, abstractmethod
from rfsoc_lib.rfsoc_overlay import RFSoCOverlay


class OverlayTask(ABC):
    """A piece of hardware bring-up run on its own thread against an
    RFSoCOverlay: subclasses implement run(); callers start() then join()."""

    def __init__(self, overlay, name="OverlayTask"):
        if not isinstance(overlay, RFSoCOverlay):
            raise TypeError("This task is not an RFSoCOverlay instance.")
        self.ol = overlay
        self.task_name = name
        self.thread = threading.Thread(target=self.run)

    @abstractmethod
    def run(self):
        pass

    def start(self):
        self.thread.start()

    def join(self):
        self.thread.join()
