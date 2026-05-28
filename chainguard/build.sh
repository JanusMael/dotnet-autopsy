#!/bin/bash
# chainguard/build.sh — build the Chainguard variant of dotnet-autopsy-base.
#
# Tags the result as `dotnet-autopsy-base` (the same tag the canonical
# common/base.dockerfile produces), so all three per-image dockerfiles
# (sos/, trace/, gcdump/) work against this base unchanged — they just
# `FROM dotnet-autopsy-base`.
#
# Usage:
#   ./chainguard/build.sh                     # base only
#   ./chainguard/build.sh sos                 # base + sos per-case image
#   ./chainguard/build.sh trace --build-arg TRACE_FILE=mytrace.nettrace
#
# The first positional arg, if present, is forwarded to ./build.sh as the
# sibling slug (sos|trace|gcdump). Everything after that is forwarded too.

set -euo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT="$( cd "${DIR}/.." >/dev/null 2>&1 && pwd )"
DUMP_ARCH="${DUMP_ARCH:-amd64}"

echo "▶ Building Chainguard dotnet-autopsy-base (linux/${DUMP_ARCH})..."
docker build \
    --platform "linux/${DUMP_ARCH}" \
    -f "${DIR}/base.dockerfile" \
    -t dotnet-autopsy-base \
    --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
    "${ROOT}"

if [ $# -gt 0 ]; then
    echo ""
    echo "▶ Building per-image sibling on top of Chainguard base..."
    "${ROOT}/build.sh" "$@"
fi

echo ""
echo "Chainguard base ready: dotnet-autopsy-base"
