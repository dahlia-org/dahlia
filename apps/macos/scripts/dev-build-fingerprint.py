#!/usr/bin/env python3
"""Hash development bundle inputs by content, including names, modes, and links."""

import hashlib
import os
from pathlib import Path
import stat
import sys


def fingerprint(paths):
    digest = hashlib.sha256()

    def add(value):
        data = os.fsencode(value)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)

    def visit(path):
        add(str(path))
        if not path.exists() and not path.is_symlink():
            add("missing")
            return
        mode = path.lstat().st_mode
        add(str(mode))
        if stat.S_ISLNK(mode):
            add(os.readlink(path))
        elif stat.S_ISDIR(mode):
            for child in sorted(path.iterdir()):
                visit(child)
        elif stat.S_ISREG(mode):
            content = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    content.update(block)
            add(content.hexdigest())
        else:
            raise ValueError(f"Unsupported bundle input: {path}")

    for path in paths:
        visit(Path(path))
    return digest.hexdigest()


if __name__ == "__main__":
    print(fingerprint(sys.argv[1:]))
