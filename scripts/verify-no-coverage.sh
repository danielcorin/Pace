#!/usr/bin/env bash
# Inspect native code without running the app or its helpers. Coverage in a
# statically linked core or bundled framework can write profiles too.
set -euo pipefail

fail() { echo "verify-no-coverage: $*" >&2; exit 1; }
[[ $# -eq 1 && -d "$1/Contents" ]] || fail "usage: $0 App.app"

for directory in MacOS Helpers Frameworks PlugIns; do
    root="$1/Contents/$directory"
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' binary; do
        case "$(/usr/bin/file -b "$binary")" in
            *Mach-O*) ;;
            *) continue ;;
        esac
        commands="$(xcrun otool -l "$binary")" || fail "cannot inspect $binary"
        if /usr/bin/grep -Eq 'sectname __llvm_(prf_|cov)' <<< "$commands"; then
            fail "coverage instrumentation found in $binary; rebuild with ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO"
        fi
    done < <(/usr/bin/find "$root" -type f -print0)
done
