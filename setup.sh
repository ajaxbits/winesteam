#!/bin/bash
# WineSteam Setup — Downloads and configures Wine Staging for running Windows Steam on macOS
# Supports Apple Silicon (M1/M2/M3/M4) via Rosetta 2
#
# Usage: ./setup.sh [--target-dir DIR] [--quiet]
#   --target-dir DIR  Install Wine to DIR instead of ./wine/
#   --quiet           Only output PROGRESS: lines (for GUI parsing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_VERSION="11.9"
WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/wine-staging-${WINE_VERSION}/wine-staging-${WINE_VERSION}-osx64.tar.xz"
WINE_SHA256="0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"

# Parse arguments
TARGET_DIR=""
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir) TARGET_DIR="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        *) shift ;;
    esac
done

WINE_DIR="${TARGET_DIR:-${SCRIPT_DIR}/wine}"
CREATE_SYMLINKS=1
[[ -n "${TARGET_DIR}" ]] && CREATE_SYMLINKS=0

log() { [[ $QUIET -eq 0 ]] && echo "$@" || true; }
progress() { echo "PROGRESS:$1"; }

log "=== WineSteam Setup ==="
log ""

# Check architecture
# if [[ "$(uname -m)" == "arm64" ]]; then
#     if ! /usr/bin/pgrep -q oahd; then
#         progress "Installing Rosetta 2..."
#         log "Installing Rosetta 2 (required for x86_64 Wine)..."
#         softwareupdate --install-rosetta --agree-to-license
#     fi
#     log "  Platform: Apple Silicon ($(sysctl -n machdep.cpu.brand_string))"
#     log "  Rosetta 2: installed"
# else
#     log "  Platform: Intel Mac"
# fi
# log ""

# Download Wine if not present
if [[ -d "${WINE_DIR}/bin" ]]; then
    log "  Wine: already installed at ${WINE_DIR}"
    progress "done"
else
    progress "downloading"
    log "Downloading Wine Staging ${WINE_VERSION}..."

    if [[ -f "$HOME/Downloads/wine-staging-${WINE_VERSION}-osx64.tar.xz" ]]; then
        TARBALL="$HOME/Downloads/wine-staging-${WINE_VERSION}-osx64.tar.xz"
        log "  (Using existing download from ~/Downloads)"
    else
        TARBALL="$(mktemp /tmp/wine-staging-XXXXXX.tar.xz)"
        curl -L -o "${TARBALL}" "${WINE_URL}"
    fi

    # progress "verifying"
    # log "Verifying checksum..."
    # ACTUAL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
    # if [[ "${ACTUAL_SHA256}" != "${WINE_SHA256}" ]]; then
    #     echo "ERROR: Checksum mismatch!" >&2
    #     echo "  Expected: ${WINE_SHA256}" >&2
    #     echo "  Got:      ${ACTUAL_SHA256}" >&2
    #     echo "  The download may be corrupted or tampered with." >&2
    #     exit 1
    # fi

    progress "extracting"
    log "Extracting..."
    EXTRACT_DIR=$(mktemp -d)
    tar xf "${TARBALL}" -C "${EXTRACT_DIR}"

    # Find the Wine app bundle inside the extracted archive
    WINE_APP=$(find "${EXTRACT_DIR}" -name "Wine Staging.app" -o -name "Wine Devel.app" | head -1)
    if [[ -z "${WINE_APP}" ]]; then
        echo "ERROR: Could not find Wine app in archive" >&2
        exit 1
    fi

    WINE_RESOURCES="${WINE_APP}/Contents/Resources/wine"

    mkdir -p "${WINE_DIR}"
    cp -R "${WINE_RESOURCES}/bin" "${WINE_DIR}/bin"
    cp -R "${WINE_RESOURCES}/lib" "${WINE_DIR}/lib"
    cp -R "${WINE_RESOURCES}/share" "${WINE_DIR}/share"

    rm -rf "${EXTRACT_DIR}"

    # Create convenience symlinks (only for git-clone layout)
    if [[ $CREATE_SYMLINKS -eq 1 ]]; then
        ln -sf wine/bin "${SCRIPT_DIR}/bin"
        ln -sf wine/lib "${SCRIPT_DIR}/lib"
        ln -sf wine/share "${SCRIPT_DIR}/share"
    fi

    log "  Wine Staging ${WINE_VERSION} installed."
    progress "done"
fi

log ""
log "Setup complete! Launch Steam with:"
log "  ./launch-steam.sh"
log ""
log "Or double-click WineSteam.app"
log ""
