#!/bin/bash
# build.sh — build a dotnet-autopsy image (sos | trace | gcdump).
# Canonical path: docker compose build  (works on all OSes identically).
# This script is a thin wrapper for users who prefer a direct docker build.
# It builds the shared base (dotnet-autopsy-base) first, then the per-image
# image FROM that base.
#
# Usage:
#   ./build.sh [sos|trace|gcdump] [--build-arg KEY=VALUE ...]
#
# Examples:
#   ./build.sh                                       # sos (default)
#   ./build.sh sos    --build-arg DUMP_FILE=myapp.dump
#   ./build.sh sos    --build-arg DUMP_ARCH=arm64
#   ./build.sh sos    --build-arg INNER_EXCEPTION_DEPTH=20
#   ./build.sh trace  --build-arg TRACE_FILE=mytrace.nettrace
#   ./build.sh gcdump --build-arg GCDUMP_FILE=myheap.gcdump
#   ./build.sh trace  --build-arg SMOKE_TEST=1
#
# Note: DUMP_ARCH defaults to amd64. Apple Silicon users building for an x64
#       dump should leave it as amd64 (runs emulated — correct, just slower).

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# First arg = image slug (sos|trace|gcdump), default sos. Shift only if present.
SLUG="${1:-sos}"
case "${SLUG}" in
    sos|trace|gcdump) shift || true ;;
    -*|"")            SLUG="sos" ;;                # first arg is a --flag; treat as sos
    *)                echo "ERROR: unknown image '${SLUG}' (expected sos|trace|gcdump)" >&2
                      exit 2 ;;
esac

DUMP_ARCH="${DUMP_ARCH:-amd64}"

case "${SLUG}" in
    sos)
        IMAGE_DOCKERFILE="sos/dotnet-sos.dockerfile"
        IMAGE_TAG="dotnet-autopsy-sos"
        ;;
    trace)
        IMAGE_DOCKERFILE="trace/dotnet-trace.dockerfile"
        IMAGE_TAG="dotnet-autopsy-trace"
        ;;
    gcdump)
        IMAGE_DOCKERFILE="gcdump/dotnet-gcdump.dockerfile"
        IMAGE_TAG="dotnet-autopsy-gcdump"
        ;;
esac

echo "Building dotnet-autopsy/${SLUG} (platform: linux/${DUMP_ARCH})"
echo "  Context    : ${DIR}"
echo "  Base       : ${DIR}/common/base.dockerfile      -> dotnet-autopsy-base"
echo "  Image      : ${DIR}/${IMAGE_DOCKERFILE} -> ${IMAGE_TAG}"
echo ""

docker build \
    --platform "linux/${DUMP_ARCH}" \
    -f "${DIR}/common/base.dockerfile" \
    -t dotnet-autopsy-base \
    --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
    "${DIR}"

exec docker build \
    --platform "linux/${DUMP_ARCH}" \
    -f "${DIR}/${IMAGE_DOCKERFILE}" \
    -t "${IMAGE_TAG}" \
    --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
    "$@" \
    "${DIR}"
