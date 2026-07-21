"""CoFleet host service.

The package deliberately depends only on Python's standard library so a host can
be bootstrapped on a clean macOS or Linux machine without granting a package
manager access to the user's Codex credentials.
"""

__version__ = "0.1.0"

from .config import HostConfig
from .service import CoFleetHostService

__all__ = ["CoFleetHostService", "HostConfig"]
