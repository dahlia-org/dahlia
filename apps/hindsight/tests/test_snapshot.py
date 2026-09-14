import subprocess
import sys
from pathlib import Path


def test_pinned_upstream_and_patch():
    root = Path(__file__).resolve().parents[1]
    subprocess.run(
        [sys.executable, str(root / "scripts/sync_upstream.py"), "--check"], check=True, capture_output=True, text=True
    )
