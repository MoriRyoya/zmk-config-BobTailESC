#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/tools/macos/BobTailBar"
TESTS="$ROOT/tools/macos/tests"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bobtail-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for name in OverlayGeometry GlidePhysics PointerPhysics BatteryReadings; do
    test_file="$TESTS/${name}Tests.swift"
    if [[ ! -f "$test_file" ]]; then test_file="$APP/tests/${name}Tests.swift"; fi
    swiftc -module-cache-path "${BOBTAIL_SWIFT_CACHE:-$WORK/cache}" "$APP/$name.swift" "$test_file" -o "$WORK/$name"
    "$WORK/$name"
done

python3 - "$APP/main.swift" "$TESTS/AppRegressionChecks.swift" "$WORK/main.swift" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
launch = '\nlet app = NSApplication.shared\n'
assert source.count(launch) == 1
Path(sys.argv[3]).write_text(source.split(launch)[0] + '\n' + Path(sys.argv[2]).read_text())
PY
sources=("$WORK/main.swift")
for source in "$APP"/*.swift; do
    if [[ "$source" != "$APP/main.swift" ]]; then sources+=("$source"); fi
done
swiftc -module-cache-path "${BOBTAIL_SWIFT_CACHE:-$WORK/cache}" "${sources[@]}" -o "$WORK/app-checks"
"$WORK/app-checks" "$ROOT"
