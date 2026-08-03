#!/bin/bash
# chainguard/generate.sh — generate a Chainguard/Wolfi-flavored variant of
# common/base.dockerfile, with the few build-time tweaks the README's
# "Adapting the base image" section calls out (SDK image, apt→apk, USER root).
#
# This is intentionally a transformation of the canonical base.dockerfile
# rather than a forked copy, so changes upstream stay easy to re-apply —
# just re-run this script.
#
# Single output:
#   chainguard/base.dockerfile — the adapted Chainguard variant.
#
# The build wrappers (chainguard/build.sh, chainguard/build.ps1) and the
# documentation (chainguard/README.md) are NOT touched by this script —
# they are normal hand-edited repo files committed alongside this
# generator. Edit them freely; --force only affects base.dockerfile.
#
# Per-image dockerfiles (sos/, trace/, gcdump/) are also NOT touched:
# each does `FROM dotnet-autopsy-base`, an image tag, not a file path.
# The build wrapper tags this Chainguard base with that name so the
# existing per-case pipelines work unchanged.
#
# Usage:
#   ./chainguard/generate.sh                              # interactive
#   ./chainguard/generate.sh --non-interactive            # all defaults
#   ./chainguard/generate.sh --sdk-image <ref>            # override default
#   ./chainguard/generate.sh --sdk-image <ref> -y --force # CI / re-gen
#
# Cross-platform: a sibling PowerShell script (generate.ps1) does the same.

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT="$( cd "${DIR}/.." >/dev/null 2>&1 && pwd )"
SRC="${ROOT}/common/base.dockerfile"
OUT="${DIR}/base.dockerfile"

SDK_IMAGE_DEFAULT="cgr.dev/chainguard/dotnet-sdk:latest-dev"
SDK_IMAGE=""
NON_INTERACTIVE=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --non-interactive|-y) NON_INTERACTIVE=1 ;;
        --force|-f)           FORCE=1 ;;
        --sdk-image)          SDK_IMAGE="${2:-}"; shift ;;
        --sdk-image=*)        SDK_IMAGE="${1#*=}" ;;
        --help|-h)
            cat <<HELP
Generate a Chainguard/Wolfi variant of common/base.dockerfile.

Usage: ./chainguard/generate.sh [options]

Options:
  --sdk-image <ref>     Chainguard SDK image to use
                        (default: ${SDK_IMAGE_DEFAULT}).
                        Pin by digest with image@sha256:<hex>.
  --non-interactive, -y Use defaults (no prompts). Required for CI.
  --force, -f           Overwrite existing outputs without prompting.
  --help, -h            Show this help.
HELP
            exit 0
            ;;
        *) echo "ERROR: unknown arg '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ── Interactive prompts ───────────────────────────────────────────────────────
if [ "${NON_INTERACTIVE}" -eq 0 ] && [ -z "${SDK_IMAGE}" ]; then
    printf 'Chainguard .NET SDK image [%s]: ' "${SDK_IMAGE_DEFAULT}"
    read -r SDK_IMAGE
fi
SDK_IMAGE="${SDK_IMAGE:-${SDK_IMAGE_DEFAULT}}"

if [ -e "${OUT}" ] && [ "${FORCE}" -eq 0 ] && [ "${NON_INTERACTIVE}" -eq 0 ]; then
    printf '%s exists. Overwrite? [y/N]: ' "${OUT}"
    read -r ans
    case "${ans}" in
        y|Y|yes|YES) ;;
        *) echo "Aborted (no files written)."; exit 1 ;;
    esac
fi

echo ""
echo "Generating Chainguard adaptation..."
echo "  source : ${SRC}"
echo "  output : ${OUT}"
echo "  sdk    : ${SDK_IMAGE}"
echo ""

[ -f "${SRC}" ] || { echo "ERROR: source not found: ${SRC}" >&2; exit 1; }

# ── Transform base.dockerfile ─────────────────────────────────────────────────
# Three changes vs the canonical Microsoft-SDK base:
#   1. Both `ARG DOTNET_SDK_IMAGE=…` defaults  → Chainguard image
#   2. After the FROM line                     → insert `USER root`
#      (Chainguard images run as nonroot by default; apk + global dotnet
#      tool installs that follow need root)
#   3. The `RUN apt-get update … apt-get install … && rm -rf …` block
#      → an equivalent `RUN apk add --no-cache …` (Wolfi has the same
#      package names so this is a direct swap)
awk -v sdk="${SDK_IMAGE}" '
BEGIN { in_apt = 0 }

# (1) Replace the DOTNET_SDK_IMAGE default — both occurrences (pre-FROM
# ARG and the re-declaration after FROM).
/^ARG DOTNET_SDK_IMAGE=/ {
    print "ARG DOTNET_SDK_IMAGE=" sdk
    next
}

# (2) After FROM, insert USER root + a marker comment.
/^FROM --platform=linux\/\$\{DUMP_ARCH\} \$\{DOTNET_SDK_IMAGE\} AS base$/ {
    print
    print ""
    print "# ── Chainguard adaptation ────────────────────────────────────────────────────"
    print "# Chainguard images run as nonroot by default. apk + the global dotnet"
    print "# tool installs that follow need root, so switch explicitly. If you want"
    print "# the final image to drop to nonroot, add a USER nonroot near the end"
    print "# (after all installs) and write the PATH/MOTD snippet from the canonical"
    print "# base to /home/nonroot/.bashrc as well as /root/.bashrc."
    print "USER root"
    next
}

# NOTE: DOTNET_ROLL_FORWARD=Major is no longer inserted here — the canonical
# common/base.dockerfile now sets it directly (the dotnet-monitor pin needs
# it on the Microsoft SDK image too, once that image advances past the pinned
# major). The Chainguard variant inherits it verbatim via passthrough.

# (3a) Start of the apt-get block — emit the apk replacement, then swallow
# all lines up to and including the trailing `rm -rf /var/lib/apt/lists/*`.
# The Chainguard curated apk feed is a minimal-attack-surface subset that
# omits some diagnostic tools (lldb, tar, btop). Chainguard images are
# built on Wolfi, so we add the public Wolfi feed for those — packages
# are signed by the same Wolfi key chain.
/^RUN apt-get update \\$/ {
    in_apt = 1
    print "# Chainguard adaptation: apt-get replaced with apk add."
    print "# Chainguard'\''s curated feed omits some diagnostic tools (lldb, btop)."
    print "# Pull in the public Wolfi feed for those — Chainguard images are built"
    print "# on top of Wolfi and share the same package keychain."
    print "#"
    print "# lldb: empirically NOT in the free Chainguard or Wolfi feeds (as of"
    print "# the 2026 builds we verified — `apk search lldb` returns only rust"
    print "# packages that mention LLDB in their description). It is available"
    print "# in Chainguard'\''s paid Production tier; if you have that, append"
    print "# apk.cgr.dev/extra-packages to /etc/apk/repositories before this RUN."
    print "#"
    print "# The block below still attempts dynamic discovery — if Wolfi ever"
    print "# adds an lldb package, it gets picked up automatically. If not, we"
    print "# log a clear INFO and continue: delve-lldb is optional; delve"
    print "# (dotnet-dump) is the documented primary interactive path."
    print "#"
    print "# tar is typically pre-installed in the Chainguard SDK image and is not"
    print "# in either curated feed by that exact name; verify-then-install."
    print "RUN wget -qO /etc/apk/keys/wolfi-signing.rsa.pub \\"
    print "        https://packages.wolfi.dev/os/wolfi-signing.rsa.pub \\"
    print "    && echo '\''https://packages.wolfi.dev/os'\'' >> /etc/apk/repositories \\"
    print "    && apk update \\"
    print "    && apk add --no-cache \\"
    print "        gdb \\"
    print "        elfutils \\"
    print "        binutils \\"
    print "        file \\"
    print "        less \\"
    print "        nano \\"
    print "        procps \\"
    print "        btop \\"
    print "        curl \\"
    print "        ca-certificates \\"
    print "        gzip \\"
    print "        unzip \\"
    print "    && apk update \\"
    print "    && LLDB_PKG=$(apk search lldb 2>/dev/null \\"
    print "            | sed -E '\''s/-[^-]+-r[0-9]+$//'\'' \\"
    print "            | sort -uV \\"
    print "            | grep -E '\''^lldb(-[0-9]+|-default)?$'\'' \\"
    print "            | tail -1) \\"
    print "    && if [ -n \"${LLDB_PKG}\" ]; then \\"
    print "           echo \"Installing lldb package: ${LLDB_PKG}\"; \\"
    print "           apk add --no-cache \"${LLDB_PKG}\"; \\"
    print "       else \\"
    print "           echo '\''INFO: no lldb in the configured apk feeds (Chainguard public + Wolfi os).'\''; \\"
    print "           echo '\''      delve-lldb wrapper will be unavailable; delve (dotnet-dump) is unaffected.'\''; \\"
    print "           echo '\''      For lldb on Chainguard, append apk.cgr.dev/extra-packages (paid tier).'\''; \\"
    print "       fi \\"
    print "    && (   command -v tar >/dev/null 2>&1 \\"
    print "        || apk add --no-cache tar \\"
    print "        || { echo '\''ERROR: tar not available'\'' >&2; exit 1; })"
    next
}

# Toolchain-smoke adaptation: lldb may not have installed (see apk block
# above; Chainguard / Wolfi free feeds do not ship lldb). Guard the two
# `lldb` invocations so the build does not fail when it is absent.
# delve-lldb is optional; delve (dotnet-dump) is the primary path.
/^    && lldb --version \\$/ {
    print "    && (command -v lldb >/dev/null 2>&1 && lldb --version \\"
    print "         || echo \"INFO: lldb absent (Chainguard free feed); delve-lldb wrapper unavailable\") \\"
    next
}
/^        lldb --batch -o "plugin load \$\{SOS_PLUGIN\}" -o "help sos" -o "quit" 2>&1 \| head -10 \\$/ {
    print "        (command -v lldb >/dev/null 2>&1 \\"
    print "            && lldb --batch -o \"plugin load ${SOS_PLUGIN}\" -o \"help sos\" -o \"quit\" 2>&1 | head -10 \\"
    print "            || echo \"INFO: lldb absent — SOS plugin load check skipped\") \\"
    next
}

# (3b) Skip the rest of the apt block.
in_apt {
    if (/&& rm -rf \/var\/lib\/apt\/lists\/\*$/) in_apt = 0
    next
}

{ print }
' "${SRC}" > "${OUT}"

# Note on scope: this generator only produces base.dockerfile from the
# canonical source. The thin build wrappers (chainguard/build.sh,
# chainguard/build.ps1) and the documentation (chainguard/README.md) are
# hand-written, committed alongside this script, and never touched by the
# generator. That keeps the mental model simple: one input, one output;
# the wrappers and docs are normal repo files you can edit freely without
# worrying about a regen wiping them.
echo "Done."
echo ""
echo "Generated:"
echo "  ${OUT}"
echo ""
echo "Review the adaptation:"
echo "  diff -u common/base.dockerfile chainguard/base.dockerfile"
echo ""
echo "Build:"
echo "  ./chainguard/build.sh           # base only"
echo "  ./chainguard/build.sh sos       # base + sos per-case image"
exit 0
