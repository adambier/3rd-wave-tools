#!/bin/bash
# Run the tests of the package's libraries (PgdataFormats, WavetableFormats, PgdataPackerCore). Needs full Xcode on a Mac (XCTest is not part of the
# Command Line Tools). The app itself does not — see make-app.sh.
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    echo "Cannot run tests: XCTest needs a full Xcode installation (currently: $(xcode-select -p 2>/dev/null || echo unknown))." >&2
    echo "The app does not need Xcode. Run ./make-app.sh to build it." >&2
    exit 1
fi
PGDATA_TESTS=1 swift test "$@"
