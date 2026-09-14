# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Materialize a pinned Git checkout plus the maintained patch for uv."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCH = "patches/hindsight-api-slim.patch"
STATE = ".git/hindsight-state.json"


def run(*args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def checkout_state(checkout):
    return {
        "revision": run("git", "rev-parse", "HEAD", cwd=checkout),
        "diff": digest(run("git", "diff", "--binary", "HEAD", cwd=checkout).encode()),
    }


def verify_checkout(checkout):
    saved = json.loads((checkout / STATE).read_text())
    current = checkout_state(checkout)
    if any(current[key] != saved[key] for key in current):
        raise RuntimeError("Upstream checkout was edited. Export edits to the patch before updating.")
    untracked = run("git", "ls-files", "--others", "--exclude-standard", cwd=checkout)
    if untracked:
        raise RuntimeError(f"Upstream checkout contains untracked files; preserve them first:\n{untracked}")
    return saved


def resolve(stage, *, locked, version=None):
    if version is not None and not locked:
        subprocess.run(
            ["uv", "add", "--project", str(stage), "--no-sync", f"hindsight-api-slim=={version}"], check=True
        )
        return
    command = ["uv", "lock", "--project", str(stage)]
    if locked:
        command.append("--check")
    subprocess.run(command, check=True)


def sync(root, *, version=None, source=None, check=False):
    manifest_path = root / "UPSTREAM.json"
    original_manifest = manifest_path.read_bytes()
    original_lock = (root / "uv.lock").read_bytes()
    original_project = (root / "pyproject.toml").read_bytes()
    manifest = json.loads(original_manifest)
    if version is not None:
        version = version.removeprefix("v")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", version):
            raise ValueError("Specify a release version such as 0.9.2.")
    revision = manifest["revision"] if version is None or version == manifest.get("version") else None
    if revision is not None and not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("The source lock must contain a full upstream commit SHA.")
    patch = root / PATCH
    patch_hash = digest(patch.read_bytes())
    checkout = root / ".upstream"
    if checkout.exists():
        saved = verify_checkout(checkout)
        if saved["revision"] == revision and saved["patch"] == patch_hash:
            print(f"Verified upstream {revision} and Lakebase patch")
            return
    if check:
        raise RuntimeError("Checkout is missing or differs from the pin/patch. Run sync_upstream.py first.")

    # Prepare and resolve in isolation. A fetch, patch or uv failure leaves the
    # current checkout, pin and lockfile untouched.
    with tempfile.TemporaryDirectory(prefix=".upstream-prepare-", dir=root) as temporary:
        stage = Path(temporary)
        candidate = stage / ".upstream"
        candidate.mkdir()
        run("git", "init", "--quiet", cwd=candidate)
        run("git", "remote", "add", "origin", manifest["repository"], cwd=candidate)
        run(
            "git",
            "fetch",
            "--quiet",
            "--depth=1",
            source or "origin",
            revision or f"refs/tags/v{version}",
            cwd=candidate,
        )
        run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=candidate)
        actual = run("git", "rev-parse", "HEAD", cwd=candidate)
        if revision is not None and actual != revision:
            raise RuntimeError("Fetched commit differs from the requested pin.")
        revision = actual
        if version is not None:
            metadata = tomllib.loads((candidate / "hindsight-api-slim/pyproject.toml").read_text())
            if metadata["project"]["version"] != version:
                raise RuntimeError("The release tag and package version differ.")
        run("git", "apply", "--check", "--directory=hindsight-api-slim", str(patch), cwd=candidate)
        run("git", "apply", "--directory=hindsight-api-slim", str(patch), cwd=candidate)
        saved = checkout_state(candidate) | {"patch": patch_hash}
        (candidate / STATE).write_text(json.dumps(saved, indent=2) + "\n")
        shutil.copy2(root / "pyproject.toml", stage / "pyproject.toml")
        shutil.copy2(root / "uv.lock", stage / "uv.lock")
        shutil.copytree(root / "src", stage / "src")
        shutil.copy2(root / "README.md", stage / "README.md")
        resolve(stage, locked=revision == manifest["revision"], version=version)
        backup = None
        if checkout.exists():
            backup = Path(tempfile.mkdtemp(prefix=".upstream-backup-", dir=root)) / ".upstream"
            checkout.rename(backup)
        try:
            candidate.rename(checkout)
            manifest["revision"] = revision
            if version is not None:
                manifest["version"] = version
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            shutil.copy2(stage / "uv.lock", root / "uv.lock")
            shutil.copy2(stage / "pyproject.toml", root / "pyproject.toml")
        except BaseException:
            # Restore the runtime first: read-only metadata must not block it.
            if checkout.exists():
                shutil.rmtree(checkout)
            if backup:
                backup.rename(checkout)
            manifest_path.write_bytes(original_manifest)
            (root / "uv.lock").write_bytes(original_lock)
            (root / "pyproject.toml").write_bytes(original_project)
            raise
        print(f"Prepared upstream {revision}. Run uv sync --locked, then the regression tests.")
        if backup:
            print(f"Previous checkout retained at {backup}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Update to a release version, e.g. 0.9.2; also resolve uv.lock")
    parser.add_argument("--source", help="Fetch from an existing local Git repository (offline preparation)")
    parser.add_argument("--check", action="store_true", help="Verify the prepared source without network or writes")
    args = parser.parse_args()
    sync(ROOT, version=args.version, source=args.source, check=args.check)


if __name__ == "__main__":
    main()
