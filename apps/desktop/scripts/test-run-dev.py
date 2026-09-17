#!/usr/bin/env python3
"""Exercise development packaging with tiny payloads and fake signing/build tools."""

import importlib.util
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile


SCRIPTS = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("fingerprint", SCRIPTS / "dev-build-fingerprint.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


def check_fingerprints(root):
    folder = root / "input with spaces"
    file = folder / "resource"
    write(file, "first")
    original = MODULE.fingerprint([folder])
    timestamp = file.stat().st_mtime_ns
    write(file, "other")
    os.utime(file, ns=(timestamp, timestamp))
    assert MODULE.fingerprint([folder]) != original, "same-size edits with preserved dates must invalidate"
    original = MODULE.fingerprint([folder])
    file.chmod(0o755)
    assert MODULE.fingerprint([folder]) != original, "executable mode must invalidate"
    link = folder / "link"
    link.symlink_to("resource")
    original = MODULE.fingerprint([folder])
    link.unlink()
    link.symlink_to("missing")
    assert MODULE.fingerprint([folder]) != original, "link destinations must invalidate"
    original = MODULE.fingerprint([folder])
    file.unlink()
    assert MODULE.fingerprint([folder]) != original, "resource deletion must invalidate"


def check_packaging(root):
    scripts = root / "apps/desktop/scripts"
    scripts.mkdir(parents=True)
    for name in ("run-dev.sh", "common.sh", "dev-build-fingerprint.py"):
        shutil.copy2(SCRIPTS / name, scripts / name)
    write(scripts / "build-codex.sh", '''#!/bin/bash
case "${1:-}" in
    --print-version) echo 0.0.0 ;;
    --validate-only) echo helper-validate >> "$DEV_TEST_LOG" ;;
    *) echo helper-build >> "$DEV_TEST_LOG" ;;
esac
''')
    tools = root / "tools"
    write(tools / "swift", '#!/bin/bash\n[[ "$*" != *--show-bin-path* ]] || echo "$PWD/.build/debug"\n', True)
    write(tools / "lipo", '#!/bin/bash\necho "${DEV_TEST_ARCH:-arm64}"\n', True)
    write(tools / "codesign", '''#!/bin/bash
echo "codesign $*" >> "$DEV_TEST_LOG"
case "$*" in
    *--entitlements*--xml*) echo '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>' ;;
    *--verify*) [[ "${DEV_TEST_VERIFY_FAIL:-0}" != 1 ]] ;;
    *--force*)
        output="${@: -1}"
        if [[ -d "$output" ]]; then
            mkdir -p "$output/_CodeSignature"
            echo signature > "$output/_CodeSignature/CodeResources"
        else
            echo '# signature' >> "$output"
        fi ;;
esac
''', True)
    write(tools / "sips", '#!/bin/bash\necho sips >> "$DEV_TEST_LOG"\necho icon > "${@: -1}"\n', True)
    write(tools / "iconutil", '#!/bin/bash\necho icon > "${@: -1}"\n', True)
    write(tools / "xattr", '#!/bin/bash\nexit 0\n', True)
    write(tools / "sqlite3", '''#!/bin/bash
if [[ "${DEV_TEST_REQUIRE_LOCK:-0}" = 1 && ! -d "$PWD/.build/run-dev/lock" ]]; then
    echo "run-dev lock missing during SQLite preparation" >&2
    exit 1
fi
if [[ "${DEV_TEST_QUICK_CHECK_FAIL:-0}" = 1 && "$*" = *"PRAGMA quick_check"* ]]; then
    echo corrupt
    exit 0
fi
exec /usr/bin/sqlite3 "$@"
''', True)

    executable = root / ".build/debug/Dahlia"
    write(executable, "#!/bin/bash\nexit 0\n", True)
    write(root / ".build/debug/dahlia-mcp", "#!/bin/bash\nexit 0\n", True)
    write(root / ".build/debug/auth-helper", "#!/bin/bash\nexit 0\n", True)
    for name in ("Dahlia_Dahlia.bundle", "Dahlia_DahliaRuntimeSupport.bundle", "TelemetryDeck_TelemetryDeck.bundle"):
        write(root / ".build/debug" / name / "resource", "resource")
    for name in ("codex", "codex-code-mode-host"):
        write(root / ".build/codex-helper" / name, "#!/bin/bash\necho codex-cli 0.0.0\n", True)
    for name in ("LICENSE", "NOTICE.txt"):
        write(root / ".build/codex-helper" / name, "license")
    for name in ("argmax-oss-swift/LICENSE", "argmax-oss-swift/NOTICES", "SwiftSDK/LICENSE",
                 "libwebp-Xcode/LICENSE", "libwebp-Xcode/libwebp/COPYING",
                 "libwebp-Xcode/libwebp/PATENTS", "libwebp-Xcode/libwebp/AUTHORS"):
        write(root / ".build/checkouts" / name, "license")
    for name in ("DahliaLindera-LICENSE.txt", "DahliaLindera-THIRD-PARTY-NOTICES.txt"):
        write(root / "Vendor" / name, "license")
    write(root / ".build/artifacts/sparkle/Sparkle/LICENSE", "license")
    framework = root / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64/Sparkle.framework"
    write(framework / "Sparkle", "binary")
    for name in ("XPCServices/Installer.xpc/binary", "XPCServices/Downloader.xpc/binary", "Autoupdate", "Updater.app/binary"):
        write(framework / "Versions/Current" / name, "binary")
    write(root / "Resources/Info.plist", '<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
    for locale in ("en", "ja"):
        write(root / "Resources" / f"{locale}.lproj/Localizable.strings", '"key" = "value";')
    write(root / "apps/desktop/Sources/Dahlia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png", "icon")

    log = root / "calls.log"
    environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", CODESIGN_IDENTITY="-", DEV_TEST_LOG=str(log))

    def run(expected, success=True, arguments=("--build-only",), **overrides):
        log.write_text("")
        result = subprocess.run(["bash", str(scripts / "run-dev.sh"), *arguments],
                                env=environment | overrides, text=True, capture_output=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert expected in result.stdout + result.stderr, result.stdout + result.stderr
        assert not (root / ".build/run-dev/lock").exists(), "build lock leaked"
        return log.read_text()

    assert "sips" in run("Assembling"), "first build must assemble assets"
    calls = run("Reusing signed")
    assert "--force" not in calls and "sips" not in calls and "helper-build" not in calls
    assert "--verify --deep --strict" in calls, "cache hits must still verify the signed app"

    write(executable, "#!/bin/bash\n# changed UI\nexit 0\n", True)
    calls = run("Updating Dahlia executable")
    assert calls.count("--force") == 1 and "sips" not in calls, "UI edits must only re-sign the app"
    run("Reusing signed")

    for name, content in (
        ("CodexHelper.entitlements",
         '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>'),
        ("Resources/en.lproj/Localizable.strings", "changed"),
        ("apps/desktop/Sources/Dahlia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png", "changed"),
    ):
        write(root / name, content)
        run("Assembling")
        run("Reusing signed")

    resource = root / ".build/debug/Dahlia_Dahlia.bundle/resource"
    resource.unlink()
    run("Assembling")
    assert not (root / "Dahlia.app/Contents/Resources/Dahlia_Dahlia.bundle/resource").exists()
    run("Assembling", GOOGLE_CLIENT_ID="changed-client")
    run("Reusing signed", GOOGLE_CLIENT_ID="changed-client")
    run("Assembling", GOOGLE_CLIENT_ID="")
    assert "GOOGLE_CLIENT_ID" not in (root / "Dahlia.app/Contents/Info.plist").read_text()

    auth_helper = root / "Dahlia.app/Contents/Helpers/auth-helper"
    assert auth_helper.exists(), "auth-helper must be bundled"
    assert "# signature" in auth_helper.read_text(), "auth-helper must be signed"

    write(root / "Dahlia.app/Contents/Helpers/codex", "damaged")
    run("Assembling")
    run("Reusing signed", success=False, DEV_TEST_VERIFY_FAIL="1")
    run("Reusing signed")

    write(executable, "#!/bin/bash\n# another UI edit\nexit 0\n", True)
    with (root / "Dahlia.app/Contents/MacOS/Dahlia").open():
        run("development app is running", success=False)
    run("Updating Dahlia executable")
    run("must contain only arm64", success=False, DEV_TEST_ARCH="x86_64")

    application_support = root / "Application Support"
    production_db = application_support / "Dahlia/dahlia.sqlite"
    qa_dir = application_support / "Dahlia-Development"
    qa_db = qa_dir / "dahlia.sqlite"
    qa_database_files = (qa_db, Path(f"{qa_db}-wal"), Path(f"{qa_db}-shm"))
    qa_dir.mkdir(parents=True)
    production_db.parent.mkdir(parents=True)
    production = sqlite3.connect(production_db)
    production.execute("PRAGMA journal_mode = WAL")
    production.execute("PRAGMA wal_autocheckpoint = 0")
    production.execute("CREATE TABLE copied(value TEXT NOT NULL)")
    production.execute("INSERT INTO copied VALUES ('from production WAL')")
    production.commit()
    assert Path(f"{production_db}-wal").exists(), "production fixture must exercise WAL backup"
    snapshot_dir = root / "snapshots"
    snapshot_dir.mkdir()
    qa_environment = {
        "DAHLIA_APPLICATION_SUPPORT_DIR": str(application_support),
        "TMPDIR": str(snapshot_dir),
    }

    for database_file in qa_database_files:
        write(database_file, "old QA")
    write(qa_dir / "BatchAudio/recording.caf", "audio")
    write(qa_dir / "FileStore/file", "file")
    write(qa_dir / "settings", "settings")
    run("Running Dahlia", arguments=("--reset", "--settings"), **qa_environment)
    for database_file in qa_database_files:
        assert not database_file.exists(), f"reset left {database_file.name}"
    for relative in ("BatchAudio/recording.caf", "FileStore/file", "settings"):
        assert (qa_dir / relative).exists(), f"reset removed {relative}"

    run("Running Dahlia", arguments=("--copy-production",),
        DEV_TEST_REQUIRE_LOCK="1", **qa_environment)
    qa_connection = sqlite3.connect(qa_db)
    assert qa_connection.execute("SELECT value FROM copied").fetchone() == ("from production WAL",)
    qa_connection.close()
    production_hash = hashlib.sha256(qa_db.read_bytes()).digest()
    run("Running Dahlia", arguments=("--copy",), **qa_environment)
    assert hashlib.sha256(qa_db.read_bytes()).digest() == production_hash, "copy aliases differ"

    for database_file in qa_database_files:
        write(database_file, "preserve QA")
    before_failure = {path: path.read_bytes() for path in qa_database_files}
    run("failed quick_check", success=False, arguments=("--copy",),
        DEV_TEST_QUICK_CHECK_FAIL="1", **qa_environment)
    for path, contents in before_failure.items():
        assert path.read_bytes() == contents, "failed inspection changed QA"

    with qa_db.open():
        run("development database is in use", success=False, arguments=("--reset",), **qa_environment)
        run("development database is in use", success=False, arguments=("--copy",), **qa_environment)
    leaked_snapshots = list(snapshot_dir.glob("dahlia-production.*"))
    assert not leaked_snapshots, f"failed copy leaked a production snapshot: {leaked_snapshots}"

    for arguments in (("--build-only", "--reset"), ("--build-only", "--copy"), ("--reset", "--copy")):
        run("cannot be combined", success=False, arguments=arguments, **qa_environment)
    production.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="dahlia-dev-tests-") as directory:
        root = Path(directory)
        check_fingerprints(root)
        check_packaging(root / "repo with spaces")
    print("Development build tests passed (packaging, QA reset, production copy, validation, conflicts)")
