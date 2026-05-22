# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# common/base.dockerfile — dotnet-autopsy SHARED BASE image
#
# The reusable toolchain layer shared by every dotnet-autopsy sibling
# (sos = core-dump analysis, trace = dotnet-trace analysis, …). Build &
# tag ONCE; per-case images do `FROM dotnet-autopsy-base`.
#
#   docker build -f common/base.dockerfile -t dotnet-autopsy-base .
#
# Build context is the REPO ROOT (so COPY can reach common/ ; .dockerignore
# is the existing root one). Contains: apt diagnostics packages, the .NET
# global tools (incl. dotnet-trace) + pwsh + dotnet-monitor, the downloaded
# file server, the Fresh editor, the SHARED .NET 10 file-based report apps
# (analysis_md, json-get) published to /opt/report-bin, the shared
# /usr/local/bin/json-get shim + PATH hardening, the reusable-sources bake
# (/analysis/sources), and the always-on toolchain smoke. Per-image triage
# apps (triage_summary, trace_triage), the dump/trace, delve wrappers and
# the SMOKE_TEST=1 end-to-end live in the per-image Dockerfile.
#
# Key build args:
#   DUMP_ARCH          — image CPU arch: amd64 (default) or arm64
#   DOTNET_SDK_IMAGE   — override base (e.g. mcr.microsoft.com/dotnet/sdk:10.0-jammy)
#   FILESERVER_VERSION — pin file server release tag (default: latest)
# ─────────────────────────────────────────────────────────────────────────────

# ── Build-time args (before FROM so --platform can use them) ─────────────────
ARG DUMP_ARCH=amd64
ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0
ARG FILESERVER_REPO=JanusMael/Bennewitz.Ninja.FileServer
ARG FILESERVER_VERSION=latest
# dotnet-monitor is the ONE pinned tool (everything else floats "newest").
# Its release cadence is independent of the SDK and an unpinned
# `dotnet tool install dotnet-monitor` is unreliable, so we pin a version
# verified to install AND run on the base image. Override via --build-arg.
ARG DOTNET_MONITOR_VERSION=9.0.0
# Fresh terminal editor (github.com/sinelaw/fresh) — pinned, static musl
# binary fetched at build time (no apt deps; sha256-verified). For SDK devs
# editing/repro in interactive sessions; nano is kept as the minimal fallback.
ARG FRESH_VERSION=v0.3.6

FROM --platform=linux/${DUMP_ARCH} ${DOTNET_SDK_IMAGE} AS base

# Re-declare ARGs after FROM (Docker scope rule)
ARG DUMP_ARCH=amd64
ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0
ARG FILESERVER_REPO=JanusMael/Bennewitz.Ninja.FileServer
ARG FILESERVER_VERSION=latest
ARG DOTNET_MONITOR_VERSION=9.0.0
ARG FRESH_VERSION=v0.3.6

# Expose base image tag to scripts via env (for provenance)
ENV DOTNET_SDK_IMAGE=${DOTNET_SDK_IMAGE}

# ── Diagnostics env vars ───────────────────────────────────────────────────────
# Do NOT set DOTNET_DbgEnableMiniDump globally. If an analyzer itself
# (dotnet-dump/ClrMD) crashes on a low-fidelity input, a global setting makes
# the runtime write a multi-GB minidump INTO the image layer (observed: an
# 8 GB /tmp/core.dump → 11 GB image). The SMOKE_TEST step and the rot-check
# workflow set DOTNET_DbgEnableMiniDump inline, per-invocation, which is the
# only place a crash dump is actually wanted.
ENV DOTNET_PerfMapEnabled=1
ENV DOTNET_EnableEventLog=1

# ── Analysis environment ───────────────────────────────────────────────────────
ENV FILE_SERVER_DIR=/fileserver
ENV FILES_DIR=/analysis
ENV CASE_OUTPUT=${FILES_DIR}/analysis.txt
ENV SYMBOLS_CACHE=${FILES_DIR}/symbols

# ── Package install ────────────────────────────────────────────────────────────
# ONE block — the documented seam for base-image swaps (apt→apk for Chainguard).
# All packages tuned for post-mortem diagnosis; live-process-only tools
# (netcat, telnet, dnsutils, procdump) intentionally omitted.
#
# To swap to Chainguard/Wolfi: change FROM above and replace this block with:
#   RUN apk add --no-cache lldb gdb elfutils binutils file less nano \
#       procps btop curl ca-certificates tar gzip unzip
# (and add USER root before build steps if using nonroot base)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        # SOS host + interactive debugger
        lldb \
        gdb \
        # ELF inspection / runtime build-ID detection (no DAC needed)
        elfutils \
        binutils \
        # Utilities
        file \
        less \
        nano \
        procps \
        btop \
        # Network / download
        curl \
        ca-certificates \
        # Archive tools (file server extraction)
        tar \
        gzip \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ── .NET global diagnostic tools + PowerShell (newest, no version pin) ────────
# The DAC version is irrelevant here — it's downloaded per-dump by build-ID.
# PowerShell is installed as a .NET global tool (`pwsh`) rather than via the
# packages.microsoft.com apt feed: it floats to latest with the rest, needs no
# apt repo/GPG key, and stays base-image-independent (survives the Chainguard
# swap). Useful for scripting triage in this .NET-oriented container.
#
# dotnet-monitor is installed (NOT run as a service — this is a post-mortem
# container with no live target app) for ad-hoc interactive use. It is the
# one PINNED tool: its release cadence is independent of the SDK and an
# unpinned install is unreliable. ${DOTNET_MONITOR_VERSION} is verified to
# install and run on the base image; override via --build-arg.
RUN dotnet tool install --tool-path /opt/bin dotnet-counters \
    && dotnet tool install --tool-path /opt/bin dotnet-dump \
    && dotnet tool install --tool-path /opt/bin dotnet-gcdump \
    && dotnet tool install --tool-path /opt/bin dotnet-sos \
    && dotnet tool install --tool-path /opt/bin dotnet-stack \
    && dotnet tool install --tool-path /opt/bin dotnet-trace \
    && dotnet tool install --tool-path /opt/bin dotnet-symbol \
    && dotnet tool install --tool-path /opt/bin PowerShell \
    && dotnet tool install --tool-path /opt/bin dotnet-monitor --version "${DOTNET_MONITOR_VERSION}"

ENV PATH=/opt/bin:$PATH

# Register SOS plugin with lldb (~/.dotnet/sos/libsosplugin.so → ~/.lldbinit)
RUN dotnet-sos install

# ── File server — downloaded per-platform at build time ───────────────────────
# Asset names: Bennewitz.Ninja.FileServer-linux-x64.tar.gz
#              Bennewitz.Ninja.FileServer-linux-arm64.tar.gz
RUN case "${DUMP_ARCH}" in \
        amd64) RID="linux-x64" ;; \
        arm64) RID="linux-arm64" ;; \
        *)     echo "ERROR: unsupported DUMP_ARCH=${DUMP_ARCH}" && exit 1 ;; \
    esac \
    && if [ "${FILESERVER_VERSION}" = "latest" ]; then \
        URL="https://github.com/${FILESERVER_REPO}/releases/latest/download/Bennewitz.Ninja.FileServer-${RID}.tar.gz"; \
    else \
        URL="https://github.com/${FILESERVER_REPO}/releases/download/${FILESERVER_VERSION}/Bennewitz.Ninja.FileServer-${RID}.tar.gz"; \
    fi \
    && echo "Downloading file server: ${URL}" \
    && mkdir -p /tmp/fserver-extract "${FILE_SERVER_DIR}" \
    && for attempt in 1 2 3; do \
        curl -fSL "${URL}" -o /tmp/fileserver.tar.gz && break; \
        [ "${attempt}" -lt 3 ] && echo "Retry ${attempt}/3..." && sleep $((attempt * 5)); \
    done \
    && tar -xzf /tmp/fileserver.tar.gz -C /tmp/fserver-extract \
    && FS_BIN=$(find /tmp/fserver-extract -name "Bennewitz.Ninja.FileServer" -not -name "*.pdb" | head -1) \
    && [ -n "${FS_BIN}" ] || (echo "ERROR: binary not found in archive" && exit 1) \
    && cp "${FS_BIN}" "${FILE_SERVER_DIR}/Bennewitz.Ninja.FileServer" \
    && chmod +x "${FILE_SERVER_DIR}/Bennewitz.Ninja.FileServer" \
    && { echo "repo            : ${FILESERVER_REPO}"; \
         echo "version         : ${FILESERVER_VERSION}"; \
         echo "asset           : Bennewitz.Ninja.FileServer-${RID}.tar.gz"; \
         echo "source_url      : ${URL}"; \
         echo "downloaded_at   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
       } > "${FILE_SERVER_DIR}/RELEASE.txt" \
    && rm -rf /tmp/fserver-extract /tmp/fileserver.tar.gz \
    && echo "File server installed: ${FILE_SERVER_DIR}/Bennewitz.Ninja.FileServer"

# ── Fresh terminal editor — pinned static musl binary, sha256-verified ────────
# A real editor for SDK devs working interactively in the container (nano is
# kept as the minimal fallback). One self-contained static binary + its
# plugins/themes tree → no apt deps, runs on any libc (base-swap resilient).
# Tree installed to /opt/fresh; `fresh` symlinked into /opt/bin, which is on
# PATH for ALL shell types (login + non-login, verified) just like pwsh and
# the dotnet-* tools. Asset: fresh-editor-<rust-arch>-unknown-linux-musl.tar.gz
RUN case "${DUMP_ARCH}" in \
        amd64) RUST_ARCH="x86_64" ;; \
        arm64) RUST_ARCH="aarch64" ;; \
        *)     echo "ERROR: unsupported DUMP_ARCH=${DUMP_ARCH}" && exit 1 ;; \
    esac \
    && ASSET="fresh-editor-${RUST_ARCH}-unknown-linux-musl.tar.gz" \
    && URL="https://github.com/sinelaw/fresh/releases/download/${FRESH_VERSION}/${ASSET}" \
    && echo "Downloading Fresh editor: ${URL}" \
    && mkdir -p /tmp/fresh-dl /opt/fresh \
    && for attempt in 1 2 3; do \
        curl -fSL "${URL}" -o /tmp/fresh-dl/f.tgz \
            && curl -fSL "${URL}.sha256" -o /tmp/fresh-dl/f.sha256 && break; \
        [ "${attempt}" -lt 3 ] && echo "Retry ${attempt}/3..." && sleep $((attempt * 5)); \
    done \
    && PUB=$(awk '{print $1}' /tmp/fresh-dl/f.sha256) \
    && GOT=$(sha256sum /tmp/fresh-dl/f.tgz | awk '{print $1}') \
    && [ -n "${PUB}" ] && [ "${PUB}" = "${GOT}" ] \
        || (echo "ERROR: Fresh checksum mismatch (pub=${PUB} got=${GOT})" && exit 1) \
    && tar -xzf /tmp/fresh-dl/f.tgz -C /opt/fresh --strip-components=1 \
    && [ -x /opt/fresh/fresh ] || (echo "ERROR: fresh binary missing in archive" && exit 1) \
    && ln -sf /opt/fresh/fresh /opt/bin/fresh \
    && rm -rf /tmp/fresh-dl \
    && echo "Fresh editor installed: /opt/fresh/fresh -> /opt/bin/fresh"

# ── Shared report apps + entrypoint (from common/) ────────────────────────────
# Only the GENERIC apps live here: analysis_md (the renderer — profile-driven,
# SOS profile is its built-in default) and json-get (the status.json reader).
# Per-image triage apps (triage_summary, trace_triage) are COPY'd + published
# in the per-image Dockerfile.
COPY common/entrypoint.sh common/analysis_md.cs common/json-get.cs /opt/
# Shared sourced library for the per-image analyze scripts (sos/analyze.sh,
# trace/analyze-trace.sh do `source /opt/lib/analyze-common.sh`). Lives in
# the base since it is shared; smoke-common.sh is host-side (NOT shipped).
COPY common/lib/analyze-common.sh /opt/lib/analyze-common.sh
RUN chmod +x /opt/entrypoint.sh

# ── Publish the SHARED .NET report tools (cached layer; pristine stdout) ───────
# .NET 10 file-based apps compiled ONCE here so the per-case analyze script
# invokes FIXED binaries: no per-case compile, no MSBuild text leaking into
# the authoritative analysis.txt. BCL-only → offline-capable (no NuGet).
# Spike-verified: `dotnet publish file.cs` defaults to NativeAOT in .NET 10
# (needs a C linker), hence explicit AOT/single-file=off + framework-dependent
# (the runtime is present at run time since per-image is FROM this base).
# Apphost path is /opt/report-bin/<app>/<app>.
RUN export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    && for app in analysis_md json-get; do \
           dotnet publish "/opt/${app}.cs" -c Release -o "/opt/report-bin/${app}" \
               -p:PublishAot=false -p:PublishSingleFile=false --self-contained false \
               > "/tmp/pub-${app}.log" 2>&1 \
           || { echo "ERROR: publish ${app} failed"; cat "/tmp/pub-${app}.log"; exit 1; }; \
       done \
    && /opt/report-bin/json-get/json-get --selftest \
    && rm -f /tmp/pub-*.log \
    && echo "Shared report tools published to /opt/report-bin/{analysis_md,json-get}"

# ── Shared wrappers + PATH hardening ──────────────────────────────────────────
# json-get shim: the .NET status.json reader (replaces the former python3
# one-liners in entrypoint.sh / demo.sh / smoke.sh / rot-check.yml). On PATH
# for login, non-login, and `docker exec` shells.
RUN printf '#!/bin/bash\nexec /opt/report-bin/json-get/json-get "$@"\n' \
        > /usr/local/bin/json-get \
    && chmod +x /usr/local/bin/json-get \
    # /opt/bin holds pwsh + all dotnet-* tools. ENV PATH covers non-login
    # shells, but LOGIN shells (bash -l, sh -l, bash -lc) source /etc/profile
    # which RESETS PATH and drops /opt/bin. profile.d re-adds it for login
    # shells; the .bashrc line covers interactive non-login bash belt-and-braces.
    # NOTE: this profile.d + /root/.bashrc hardening is Debian/bash/root
    # specific. On a Chainguard/Wolfi swap (often nonroot, possibly busybox
    # sh / no profile.d), keep the ENV PATH line and re-point this snippet —
    # see README.md "Adapting the base image".
    && printf '# Keep dotnet-autopsy tooling (pwsh, dotnet-*) on PATH for login shells.\nexport PATH=/opt/bin:$PATH\n' \
        > /etc/profile.d/dotnet-autopsy.sh \
    && chmod 0644 /etc/profile.d/dotnet-autopsy.sh \
    && printf '\n# dotnet-autopsy interactive session\nexport PATH=/opt/bin:$PATH\ncat /analysis/.motd 2>/dev/null\n' \
        >> /root/.bashrc

# ── Reusable sources (advertise standalone-reuse) ─────────────────────────────
# DISTINCT from /analysis/docker/ (which is "how THIS image was built").
# /analysis/sources/ surfaces the standalone-reusable .NET 10 file-based apps
# so consumers see they work outside this project. The SHARED apps + a
# generated README go here in the base (byte-identical in every sibling); the
# per-image stage adds its own triage app.
RUN mkdir -p /analysis/sources
COPY common/analysis_md.cs common/json-get.cs /analysis/sources/
RUN cat > /analysis/sources/README.md << 'SRCREADME'
# dotnet-autopsy — reusable report apps

These are **standalone .NET 10 file-based apps** (no `.csproj`, no NuGet —
BCL only). They power the dotnet-autopsy report pipeline but are deliberately
self-contained so you can reuse them **outside this project**.

Run directly with the SDK:

    dotnet run analysis_md.cs -- <analysis.txt> [status.json] > analysis.md
    dotnet run json-get.cs    -- <file.json> <key>

Or publish a fixed binary (note: `dotnet publish file.cs` defaults to
NativeAOT in .NET 10 and needs a C linker — build framework-dependent):

    dotnet publish analysis_md.cs -c Release -o out \
        -p:PublishAot=false -p:PublishSingleFile=false --self-contained false

| App | Contract |
|---|---|
| `json-get.cs` | `json-get <file> <key>` → top-level string value (`unknown` if absent; nonzero on error). Mirrors `json.load(open(f)).get(k,'unknown')`. |
| `analysis_md.cs` | `analysis_md <analysis.txt> [status.json]` → a navigable, XSS-safe Markdown view on stdout. Always exits 0 (single-fenced fallback on any error). Renderer is profile-driven; the SOS profile is the built-in default. |

The per-image triage app (`triage_summary.cs` for the dump image,
`trace_triage.cs` for the trace image) is alongside this README in each
image. See the per-image `RUNBOOK.md` → "Extending the report tools" for the
parity-gate discipline and the NativeAOT publish note. Licence: see the
project `LICENSE`.
SRCREADME

# ── Toolchain smoke test (always — fail build if the shared layer is broken) ──
RUN echo "=== Toolchain smoke test ===" \
    && dotnet --info \
    && lldb --version \
    && dotnet-dump --version \
    && dotnet-symbol --help >/dev/null \
    && pwsh --version \
    && pwsh -NoProfile -NonInteractive -Command '"pwsh OK: " + $PSVersionTable.PSVersion' \
    && dotnet-monitor --version \
    && fresh --version \
    && btop --version \
    && eu-readelf --version \
    && gdb --version \
    && /opt/report-bin/json-get/json-get --selftest \
    && echo "=== All tools present ===" \
    && SOS_PLUGIN=$(find /root/.dotnet/sos -name "libsosplugin.so" 2>/dev/null | head -1) \
    && if [ -n "${SOS_PLUGIN}" ]; then \
        echo "SOS plugin: ${SOS_PLUGIN}"; \
        lldb --batch -o "plugin load ${SOS_PLUGIN}" -o "help sos" -o "quit" 2>&1 | head -10 \
            && echo "=== SOS loads in lldb ===" || echo "=== WARNING: SOS lldb load check failed ==="; \
    else \
        echo "WARNING: libsosplugin.so not found — dotnet-sos install may have failed"; \
    fi
