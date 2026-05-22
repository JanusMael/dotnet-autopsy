#!/bin/bash
# smoke.sh — dotnet-autopsy smoke dispatcher.
#
#   ./smoke.sh [sos|trace|gcdump|all] [extra docker build args…]
#
# Default target: sos. Each per-image smoke (sos/smoke.sh, trace/smoke.sh,
# gcdump/smoke.sh) is a thin caller of common/lib/smoke-common.sh; this
# just routes. Extra args after the target are forwarded to the per-image
# smoke.

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TARGET="${1:-sos}"
[ $# -gt 0 ] && shift

run_one() {
    local slug="$1"; shift
    local script="${DIR}/${slug}/smoke.sh"
    if [ ! -x "${script}" ] && [ ! -f "${script}" ]; then
        echo "ERROR: ${slug}/smoke.sh not present yet (the ${slug} image may"
        echo "       not be implemented — see the plan / Phase B for trace)."
        return 2
    fi
    echo "▶ Running ${slug} smoke..."
    bash "${script}" "$@"
}

case "${TARGET}" in
    sos)    run_one sos    "$@" ;;
    trace)  run_one trace  "$@" ;;
    gcdump) run_one gcdump "$@" ;;
    all)
        run_one sos    "$@"
        run_one trace  "$@"
        run_one gcdump "$@"
        ;;
    *)
        echo "usage: smoke.sh [sos|trace|gcdump|all] [extra docker build args…]"
        exit 2
        ;;
esac
