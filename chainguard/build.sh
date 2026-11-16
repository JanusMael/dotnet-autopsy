#!/usr/bin/env bash
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
# The first positional arg, if present, is the sibling slug
# (sos|trace|gcdump); everything after it is passed to that image's
# `docker build`. The per-image image is built here, directly on the
# Chainguard base. It deliberately does NOT call the root ./build.sh, which
# rebuilds dotnet-autopsy-base from the canonical dockerfile and would
# silently replace the Chainguard base under the same tag.

set -euo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT="$( cd "${DIR}/.." >/dev/null 2>&1 && pwd )"
DUMP_ARCH="${DUMP_ARCH:-amd64}"

SLUG=""
if [ $# -gt 0 ]; then
    SLUG="$1"; shift
    case "${SLUG}" in
        sos)    IMAGE_DOCKERFILE="sos/dotnet-sos.dockerfile";       IMAGE_TAG="dotnet-autopsy-sos" ;;
        trace)  IMAGE_DOCKERFILE="trace/dotnet-trace.dockerfile";   IMAGE_TAG="dotnet-autopsy-trace" ;;
        gcdump) IMAGE_DOCKERFILE="gcdump/dotnet-gcdump.dockerfile"; IMAGE_TAG="dotnet-autopsy-gcdump" ;;
        *)      echo "ERROR: unknown image '${SLUG}' (expected sos|trace|gcdump)" >&2; exit 2 ;;
    esac
fi

echo "▶ Building Chainguard dotnet-autopsy-base (linux/${DUMP_ARCH})..."
docker build \
    --platform "linux/${DUMP_ARCH}" \
    -f "${DIR}/base.dockerfile" \
    -t dotnet-autopsy-base \
    --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
    "${ROOT}"

if [ -n "${SLUG}" ]; then
    echo ""
    echo "▶ Building ${IMAGE_TAG} on top of the Chainguard base..."
    docker build \
        --platform "linux/${DUMP_ARCH}" \
        -f "${ROOT}/${IMAGE_DOCKERFILE}" \
        -t "${IMAGE_TAG}" \
        --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
        "$@" \
        "${ROOT}"
    echo ""
    echo "Chainguard ${SLUG} image ready: ${IMAGE_TAG} (FROM the Chainguard dotnet-autopsy-base)"
else
    echo ""
    echo "Chainguard base ready: dotnet-autopsy-base"
fi
