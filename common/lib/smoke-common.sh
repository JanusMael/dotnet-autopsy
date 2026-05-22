#!/bin/bash
# common/lib/smoke-common.sh — shared, SOURCED host-side e2e smoke skeleton
# for the dotnet-autopsy sibling images. NOT shipped into any image (host
# test orchestration only). NO top-level execution — defines functions.
#
# A per-image smoke.sh sources this, defines two hooks, and calls the steps:
#   make_synthetic_input   — produce the per-case input at $SMOKE_INPUT_PATH
#                            and set SMOKE_INPUT_NAME / SMOKE_INPUT_BUILDARG
#   content_asserts        — image-specific in-container assertions
#
#   . "$(dirname "$0")/../common/lib/smoke-common.sh"
#   sc_init sos
#   make_synthetic_input
#   sc_build sos/dotnet-sos.dockerfile
#   sc_run_and_wait
#   sc_http_checks
#   content_asserts
#   sc_pwsh_check
#   sc_status_check
#   sc_done
#
# Build context is the REPO ROOT; the shared base is built first (cached),
# then the per-image Dockerfile with SMOKE_TEST=1.

# Resolve repo root from this lib's location (common/lib/ -> repo root).
SC_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$( cd "${SC_LIB_DIR}/../.." >/dev/null 2>&1 && pwd )"

# sc_init <image-slug>  — naming, env, banner, cleanup trap.
sc_init() {
    SLUG="$1"
    DUMP_ARCH="${DUMP_ARCH:-amd64}"
    DOTNET_SDK_IMAGE="${DOTNET_SDK_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"
    BASE_TAG="dotnet-autopsy-base"
    TAG="dotnet-autopsy-${SLUG}-smoke-$$"
    CONTAINER_NAME="dotnet-autopsy-${SLUG}-smoke-$$"
    GEN_NAME="dotnet-autopsy-${SLUG}-smoke-gen-$$"
    HOST_PORT="${HOST_PORT:-55509}"
    SMOKE_INPUT_PATH=""          # set by make_synthetic_input
    SMOKE_INPUT_NAME=""          # baked filename (build context = repo root)
    SMOKE_INPUT_BUILDARG=""      # e.g. DUMP_FILE / TRACE_FILE

    sc_cleanup() {
        echo ""
        echo "Cleaning up smoke artifacts..."
        docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm -f "${GEN_NAME}"       2>/dev/null || true
        docker rmi -f "${TAG}"           2>/dev/null || true
        [ -n "${SMOKE_INPUT_PATH}" ] && rm -f "${SMOKE_INPUT_PATH}" 2>/dev/null || true
        echo "Done."
    }
    trap sc_cleanup EXIT

    echo "══════════════════════════════════════════════════════"
    echo "  dotnet-autopsy · ${SLUG}  smoke test"
    echo "  Platform : linux/${DUMP_ARCH}"
    echo "  Base     : ${DOTNET_SDK_IMAGE}"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# sc_build <per-image-dockerfile-relpath> [extra docker build args…]
# Builds the shared base first (cached), then the per-image image with
# SMOKE_TEST=1 + the per-case input build-arg. Context = repo root.
sc_build() {
    local image_df="$1"; shift
    echo "Step — Building shared base (${BASE_TAG})..."
    docker build \
        --platform "linux/${DUMP_ARCH}" \
        -f "${ROOT_DIR}/common/base.dockerfile" \
        -t "${BASE_TAG}" \
        --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
        --build-arg "DOTNET_SDK_IMAGE=${DOTNET_SDK_IMAGE}" \
        "${ROOT_DIR}"
    echo ""
    echo "Step — Building ${SLUG} image with SMOKE_TEST=1..."
    docker build \
        --platform "linux/${DUMP_ARCH}" \
        -f "${ROOT_DIR}/${image_df}" \
        -t "${TAG}" \
        --build-arg "DUMP_ARCH=${DUMP_ARCH}" \
        --build-arg "${SMOKE_INPUT_BUILDARG}=${SMOKE_INPUT_NAME}" \
        --build-arg "SMOKE_TEST=1" \
        "$@" \
        "${ROOT_DIR}"
    echo ""
    echo "Step — Build PASSED"
}

sc_run_and_wait() {
    echo ""
    echo "Step — Starting container..."
    docker run -d \
        --platform "linux/${DUMP_ARCH}" \
        --name "${CONTAINER_NAME}" \
        -p "127.0.0.1:${HOST_PORT}:5550" \
        "${TAG}"
    echo "Waiting for file server to become healthy..."
    for i in $(seq 1 30); do
        if docker exec "${CONTAINER_NAME}" curl -sf http://localhost:5550/ >/dev/null 2>&1; then
            echo "File server is up."
            break
        fi
        [ "${i}" -eq 30 ] && echo "ERROR: File server did not start within 60 s" && exit 1
        sleep 2
    done
    echo ""
    echo "Step — Container started PASSED"
}

sc_http_checks() {
    echo ""
    echo "Step — HTTP serving check..."
    local code
    code=$(curl -sL -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || echo "000")
    echo "HTTP status: ${code}"
    echo "${code}" | grep -qE "^[23]" || { echo "ERROR: expected 2xx/3xx, got ${code}"; exit 1; }
    docker exec "${CONTAINER_NAME}" \
        bash -c 'test -s /analysis/analysis.txt || (echo "ERROR: analysis.txt empty/missing"; exit 1)'
    docker exec "${CONTAINER_NAME}" \
        bash -c 'test -s /analysis/analysis.md || (echo "ERROR: analysis.md empty/missing"; exit 1)'
    local md
    md=$(curl -sL -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${HOST_PORT}/analysis/analysis.md" 2>/dev/null || echo "000")
    echo "analysis.md HTTP: ${md}"
    echo "${md}" | grep -qE "^[23]" || { echo "ERROR: analysis.md not served"; exit 1; }
    echo ""
    echo "Step — HTTP check PASSED"
}

sc_pwsh_check() {
    echo ""
    echo "Step — PowerShell (pwsh) runtime check..."
    local out
    out=$(docker exec "${CONTAINER_NAME}" pwsh -NoProfile -NonInteractive \
        -Command '"pwsh " + $PSVersionTable.PSVersion.ToString() + " edition=" + $PSVersionTable.PSEdition' 2>&1) \
        || { echo "ERROR: pwsh failed: ${out}"; exit 1; }
    echo "${out}"
    echo "${out}" | grep -qE "^pwsh [0-9]+\." || { echo "ERROR: unexpected pwsh output"; exit 1; }
    echo ""
    echo "Step — PowerShell check PASSED"
}

sc_status_check() {
    local status
    status=$(docker exec "${CONTAINER_NAME}" \
        json-get /analysis/status.json status 2>/dev/null || echo "unknown")
    echo ""
    echo "Analysis status: ${status}"
    [ "${status}" = "failed" ] && { echo "ERROR: analysis status=failed"; exit 1; }
}

sc_done() {
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  SMOKE TEST PASSED — dotnet-autopsy · ${SLUG}"
    echo "══════════════════════════════════════════════════════"
}
