"""Exercise release selection and failure isolation using a tiny local Git repo."""

import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/sync_upstream.py"
spec = importlib.util.spec_from_file_location("sync_upstream", SCRIPT)
upstream = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upstream)


@pytest.fixture
def project(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.mkdir()
    upstream.run("git", "init", "--quiet", cwd=source)
    upstream.run("git", "config", "user.email", "test@example.invalid", cwd=source)
    upstream.run("git", "config", "user.name", "Test", cwd=source)
    package = source / "hindsight-api-slim"
    package.mkdir()
    (package / "module.py").write_text("value = 1\n")
    (package / "pyproject.toml").write_text('[project]\nname = "hindsight-api-slim"\nversion = "1.0.0"\n')
    upstream.run("git", "add", ".", cwd=source)
    upstream.run("git", "commit", "--quiet", "-m", "initial", cwd=source)
    first = upstream.run("git", "rev-parse", "HEAD", cwd=source)
    upstream.run("git", "tag", "v1.0.0", cwd=source)
    (package / "pyproject.toml").write_text('[project]\nname = "hindsight-api-slim"\nversion = "1.1.0"\n')
    upstream.run("git", "add", ".", cwd=source)
    upstream.run("git", "commit", "--quiet", "-m", "release", cwd=source)
    upstream.run("git", "tag", "-a", "v1.1.0", "-m", "release", cwd=source)
    root = tmp_path / "app"
    root.mkdir()
    (root / "UPSTREAM.json").write_text(json.dumps({"repository": str(source), "version": "1.0.0", "revision": first}))
    (root / "patches").mkdir()
    (root / upstream.PATCH).write_text("--- a/module.py\n+++ b/module.py\n@@ -1 +1 @@\n-value = 1\n+value = 2\n")
    (root / "pyproject.toml").write_text("[project]\n")
    (root / "uv.lock").write_text("initial lock")
    (root / "README.md").write_text("test")
    (root / "src").mkdir()
    monkeypatch.setattr(upstream, "resolve", lambda stage, **kwargs: None)
    upstream.sync(root)
    return root, source


def test_release_update_pins_annotated_tag_and_preserves_old_checkout(project, monkeypatch):
    root, source = project
    previous = json.loads((root / "UPSTREAM.json").read_text())["revision"]

    def resolve(stage, *, locked, version):
        assert version == "1.1.0"
        assert not locked
        (stage / "uv.lock").write_text("new lock")

    monkeypatch.setattr(upstream, "resolve", resolve)
    upstream.sync(root, version="1.1.0")
    manifest = json.loads((root / "UPSTREAM.json").read_text())
    assert manifest["version"] == "1.1.0"
    assert manifest["revision"] == upstream.run("git", "rev-parse", "v1.1.0^{commit}", cwd=source)
    assert (root / ".upstream/hindsight-api-slim/module.py").read_text() == "value = 2\n"
    assert (root / "uv.lock").read_text() == "new lock"
    backup = next(root.glob(".upstream-backup-*/.upstream"))
    assert upstream.run("git", "rev-parse", "HEAD", cwd=backup) == previous
    # A pinned release check needs neither a fetch nor dependency resolution.
    upstream.sync(root, check=True)


@pytest.mark.parametrize("failure", ["patch", "resolve", "dirty", "untracked"])
def test_update_failure_preserves_checkout_pin_and_lock(project, monkeypatch, failure):
    root, _ = project
    checkout = root / ".upstream"
    before = [(root / name).read_bytes() for name in ["UPSTREAM.json", "uv.lock", "pyproject.toml"]]
    commit = upstream.run("git", "rev-parse", "HEAD", cwd=checkout)
    if failure == "patch":
        patch = root / upstream.PATCH
        patch.write_text(patch.read_text().replace("-value = 1", "-not the source"))
    elif failure == "resolve":

        def fail(*args, **kwargs):
            raise RuntimeError("resolution failed")

        monkeypatch.setattr(upstream, "resolve", fail)
    elif failure == "dirty":
        (checkout / "hindsight-api-slim/module.py").write_text("uncommitted work\n")
    else:
        (checkout / "keep.txt").write_text("untracked work\n")
    with pytest.raises((RuntimeError, subprocess.CalledProcessError)):
        upstream.sync(root, version="1.1.0")
    assert [(root / name).read_bytes() for name in ["UPSTREAM.json", "uv.lock", "pyproject.toml"]] == before
    assert upstream.run("git", "rev-parse", "HEAD", cwd=checkout) == commit
    if failure == "dirty":
        assert (checkout / "hindsight-api-slim/module.py").read_text() == "uncommitted work\n"
    if failure == "untracked":
        assert (checkout / "keep.txt").read_text() == "untracked work\n"


@pytest.mark.parametrize("name", ["UPSTREAM.json", "uv.lock", "pyproject.toml"])
def test_publication_failure_restores_checkout_before_readonly_metadata(project, name):
    root, _ = project
    files = [root / filename for filename in ["UPSTREAM.json", "uv.lock", "pyproject.toml"]]
    before = [path.read_bytes() for path in files]
    checkout = root / ".upstream"
    revision = upstream.run("git", "rev-parse", "HEAD", cwd=checkout)
    readonly = root / name
    readonly.chmod(0o444)
    try:
        with pytest.raises(PermissionError):
            upstream.sync(root, version="1.1.0")
        assert upstream.run("git", "rev-parse", "HEAD", cwd=checkout) == revision
        assert [path.read_bytes() for path in files] == before
    finally:
        readonly.chmod(0o644)
    upstream.sync(root, check=True)
    upstream.sync(root, version="1.1.0")
    assert json.loads((root / "UPSTREAM.json").read_text())["version"] == "1.1.0"
