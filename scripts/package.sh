#!/bin/zsh
set -eu
cd "${0:A:h}/.."
zsh scripts/build.sh
dist/Clipboard.app/Contents/MacOS/Clipboard --self-test
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCHIVE="$PWD/dist/Clipboard-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Clipboard.app "$ARCHIVE"
cp "$ARCHIVE" dist/Clipboard.zip
python3 - "$ARCHIVE" <<'PY'
from pathlib import Path
import hashlib, plistlib, subprocess, sys, tempfile, zipfile
archive = Path(sys.argv[1])
expected = plistlib.loads(Path("Resources/Info.plist").read_bytes())
identity = Path("Sources/AppIdentity.swift").read_text()
assert f'static let bundleIdentifier = "{expected["CFBundleIdentifier"]}"' in identity
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None
    info = plistlib.loads(bundle.read("Clipboard.app/Contents/Info.plist"))
    assert info["CFBundleExecutable"] == "Clipboard"
    assert info == expected
    assert info["CFBundleIdentifier"] == "local.clipboard.app"
    assert bundle.read("Clipboard.app/Contents/MacOS/Clipboard") == Path("dist/Clipboard.app/Contents/MacOS/Clipboard").read_bytes()
with tempfile.TemporaryDirectory(prefix="clipboard-package-check-") as folder:
    subprocess.run(["ditto", "-x", "-k", str(archive), folder], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(Path(folder) / "Clipboard.app")], check=True)
print(f"Verified installer: {archive}")
print(f"Bytes: {archive.stat().st_size}")
print(f"SHA-256: {hashlib.sha256(archive.read_bytes()).hexdigest()}")
PY
