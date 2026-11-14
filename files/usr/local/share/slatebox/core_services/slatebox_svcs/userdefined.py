"""CORE 9 stand-in for legacy CORE's per-node UserDefined service.

Legacy maps configure it per node with Python tuples (dirs, files, cmdup,
cmddown). The map carries those verbatim as service configs and the files'
content as templates, so map content stays unchanged.
"""

import ast
from typing import ClassVar

from core.config import ConfigString
from core.services.base import CoreService

KEYS = ("dirs", "files", "cmdup", "cmddown")


class UserDefined(CoreService):
    name = "UserDefined"
    group = "Utility"
    default_configs: ClassVar[list[ConfigString]] = [ConfigString(id=key, default="()") for key in KEYS]

    def set_config(self, data: dict[str, str]) -> None:
        super().set_config(data)
        cfg = {k: list(ast.literal_eval(self.custom_config.get(k, "()"))) for k in KEYS}
        self.directories, self.files = cfg["dirs"], cfg["files"]
        self.startup, self.shutdown = cfg["cmdup"], cfg["cmddown"]
