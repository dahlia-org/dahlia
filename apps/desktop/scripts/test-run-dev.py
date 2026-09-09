#!/usr/bin/env python3
"""Exercise development packaging with tiny payloads and fake signing/build tools."""

import importlib.util
import os
from pathlib import Path
import shutil
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

    executable = root / ".build/debug/Dahlia"
    write(executable, "#!/bin/bash\nexit 0\n", True)
    write(root / ".build/debug/dahlia-mcp", "#!/bin/bash\nexit 0\n", True)
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

    def run(expected, success=True, **overrides):
        log.write_text("")
        result = subprocess.run(["bash", str(scripts / "run-dev.sh"), "--build-only"],
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

    write(root / "Dahlia.app/Contents/Helpers/codex", "damaged")
    run("Assembling")
    run("Reusing signed", success=False, DEV_TEST_VERIFY_FAIL="1")
    run("Reusing signed")

    write(executable, "#!/bin/bash\n# another UI edit\nexit 0\n", True)
    with (root / "Dahlia.app/Contents/MacOS/Dahlia").open():
        run("development app is running", success=False)
    run("Updating Dahlia executable")
    run("must contain only arm64", success=False, DEV_TEST_ARCH="x86_64")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="dahlia-dev-tests-") as directory:
        root = Path(directory)
        check_fingerprints(root)
        check_packaging(root / "repo with spaces")
    print("Development build tests passed (fingerprints, reuse, UI edits, invalidation, signing failures, running app)")
