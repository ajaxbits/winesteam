#!/bin/bash
# launch-steam.sh — Open-source Wine launcher for Windows Steam on Apple Silicon
# Uses Wine Staging (LGPL), running under Rosetta 2 on macOS.
# The launcher scripts are MIT-licensed. Steam is proprietary software by Valve.

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect if running from inside a .app bundle (Resources/) vs git-clone root
if [[ "${SCRIPT_DIR}" == *".app/Contents/Resources"* ]]; then
    WINE_DIR="${HOME}/Library/Application Support/WineSteam/wine"
else
    WINE_DIR="${SCRIPT_DIR}/wine"
fi

WINE_BIN="${WINE_DIR}/bin"
WINE_LIB="${WINE_DIR}/lib"

DEFAULT_PREFIX="$HOME/Library/Application Support/WineSteam"
WINEPREFIX="${WINEPREFIX:-${DEFAULT_PREFIX}}"

STEAM_EXE="C:/Program Files (x86)/Steam/steam.exe"

# ── Sanity checks ─────────────────────────────────────────────────────
if [[ ! -x "${WINE_BIN}/wine" ]]; then
    echo "ERROR: wine not found at ${WINE_BIN}/wine" >&2
    echo "       Run the setup script first." >&2
    exit 1
fi

# ── First-run: create prefix and install Steam ────────────────────────
if [[ ! -d "${WINEPREFIX}/drive_c" ]]; then
    echo "First run — creating Wine prefix at ${WINEPREFIX}..."
    echo "This may take a minute."
    export WINEPREFIX
    export WINEDEBUG="-all"
    export WINEDATADIR="${WINE_DIR}/share/wine"
    export DYLD_LIBRARY_PATH="${WINE_LIB}"
    export PATH="${WINE_BIN}:${PATH}"

    # Initialize the 64-bit prefix
    WINEARCH=win64 "${WINE_BIN}/wineboot" --init 2>/dev/null

    # Download and run Steam installer if no Steam.exe exists
    STEAM_PATH="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
    if [[ ! -f "${STEAM_PATH}" ]]; then
        echo "Downloading Steam installer..."
        if [[ -f "$HOME/Downloads/SteamSetup.exe" ]]; then
            INSTALLER="$HOME/Downloads/SteamSetup.exe"
        else
            INSTALLER="$(mktemp /tmp/SteamSetup.XXXXXX.exe)"
            curl -L -o "${INSTALLER}" "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe" 2>/dev/null
        fi
        echo "Installing Steam (this takes a few minutes)..."
        "${WINE_BIN}/wine" "${INSTALLER}" /S 2>/dev/null
        echo "Steam installed."
    fi

    # Install the webhelper wrapper (injects --no-sandbox --in-process-gpu for Wine compat)
    CEF_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
    if [[ -f "${SCRIPT_DIR}/steamwebhelper_wrapper.exe" ]] && [[ -f "${CEF_DIR}/steamwebhelper.exe" ]]; then
        if [[ ! -f "${CEF_DIR}/steamwebhelper_real.exe" ]]; then
            cp "${CEF_DIR}/steamwebhelper.exe" "${CEF_DIR}/steamwebhelper_real.exe"
        fi
        cp "${SCRIPT_DIR}/steamwebhelper_wrapper.exe" "${CEF_DIR}/steamwebhelper.exe"
        echo "Webhelper wrapper installed."
    fi

    echo "Setup complete."
    echo ""
fi

# ── Re-install webhelper wrapper if Steam overwrote it during update ──
WRAPPER_SRC="${SCRIPT_DIR}/steamwebhelper_wrapper.exe"
CEF_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
WRAPPER_DST="${CEF_DIR}/steamwebhelper.exe"
REAL_DST="${CEF_DIR}/steamwebhelper_real.exe"
if [[ -f "${WRAPPER_SRC}" ]] && [[ -f "${WRAPPER_DST}" ]]; then
    INSTALLED_SIZE=$(stat -f%z "${WRAPPER_DST}")
    # Real Steam binary is always >1MB; our wrapper is <1MB.
    # If the installed file is large, Steam updated and overwrote our wrapper.
    if [[ "${INSTALLED_SIZE}" -gt 1048576 ]]; then
        echo "Steam update overwrote webhelper wrapper — re-installing..."
        cp "${WRAPPER_DST}" "${REAL_DST}"
        cp "${WRAPPER_SRC}" "${WRAPPER_DST}"
    fi
fi

# ── Wine environment ──────────────────────────────────────────────────
export WINEPREFIX
export WINESERVER="${WINE_BIN}/wineserver"
export WINEARCH=win64
export WINEDATADIR="${WINE_DIR}/share/wine"
export DYLD_LIBRARY_PATH="${WINE_LIB}"
export PATH="${WINE_BIN}:${PATH}"

# ── Performance ────────────────────────────────────────────────────────
export DOTNET_EnableWriteXorExecute=0

# ── Steam CEF rendering fix ───────────────────────────────────────────
# Wine's DXGI/ANGLE doesn't report properly, causing CEF to black-screen.
# Force CEF to use software rendering (SwiftShader) via these overrides.
# This only affects Steam's UI — games use their own rendering path.
export STEAM_DISABLE_GPU_PROCESS=1


# Force CEF to use software rendering with no sandbox.
# These are passed to steamwebhelper child processes via environment.
export STEAM_CEF_COMMAND_LINE="--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing --use-gl=swiftshader --disable-software-rasterizer"

# ── Debug ──────────────────────────────────────────────────────────────
export WINEDEBUG="${WINEDEBUG:--all}"

# msync is the macOS-native sync primitive (Mach semaphores); keep it enabled.
# esync (eventfd) is Linux-only and should be disabled on macOS.
export WINEMSYNC=1
export WINEESYNC=0


# ── Kill stale wineserver (prevents "won't start" after unclean shutdown) ─
"${WINESERVER}" -k 2>/dev/null && sleep 2 || true

# ── Launch ─────────────────────────────────────────────────────────────
echo "=== WineSteam (Open Source) ==="
echo "  Wine     : $(${WINE_BIN}/wine --version 2>/dev/null || echo 'unknown')"
echo "  Prefix   : ${WINEPREFIX}"
echo "  WINEMSYNC: ${WINEMSYNC}"
echo "  WINEDEBUG: ${WINEDEBUG}"
echo ""

# Auto-dismiss error dialogs if the script exists
DISMISS_PID=""
pkill -f "dismiss-dialogs\\.sh" 2>/dev/null
if [[ -x "${SCRIPT_DIR}/dismiss-dialogs.sh" ]]; then
    "${SCRIPT_DIR}/dismiss-dialogs.sh" &
    DISMISS_PID=$!
fi

# Clean up on signals (user quit / system shutdown)
CLEANUP_DONE=0
cleanup() {
    [[ $CLEANUP_DONE -eq 1 ]] && return
    CLEANUP_DONE=1
    # Restore original display mode FIRST, before killing anything
    if [[ -n "$ORIGINAL_DISPLAY_MODE" ]] && [[ -x "$DISPLAYPLACER" ]]; then
        "$DISPLAYPLACER" "$ORIGINAL_DISPLAY_MODE"
    fi
    # Now force-kill everything — graceful shutdown is unreliable under Wine
    # Exclude our own PID to avoid self-kill before cleanup completes
    pkill -9 -f "winedevice|steamwebhelper|steamservice|steam\\.exe|explorer\\.exe" 2>/dev/null
    killall -9 wine 2>/dev/null
    "${WINESERVER}" -k9 2>/dev/null
    [[ -n "$DISMISS_PID" ]] && kill -9 $DISMISS_PID 2>/dev/null
    pkill -9 -f "dismiss-dialogs" 2>/dev/null
    exit 0
}
trap cleanup INT TERM HUP EXIT

# Launch Steam and wait for it to exit
# CEF flags: force software rendering (fixes black screen on non-CrossOver Wine)

export STEAM_NO_GPU=1
export STEAM_SKIP_GPU_DRIVER_CHECK=1

# Switch display to non-scaled native resolution so Wine sees higher modes.
# Wine's virtual desktop caps available resolutions at the macOS reported size.
ORIGINAL_DISPLAY_MODE=""
DISPLAYPLACER=$(command -v displayplacer 2>/dev/null || echo "/opt/homebrew/bin/displayplacer")
if [[ -x "$DISPLAYPLACER" ]]; then
    # Capture the current mode command (strip 'displayplacer ' prefix and surrounding quotes)
    ORIGINAL_DISPLAY_MODE=$("$DISPLAYPLACER" list 2>/dev/null | grep "^displayplacer " | head -1 | sed 's/^displayplacer "//;s/"$//')
    DISPLAY_ID=$(echo "$ORIGINAL_DISPLAY_MODE" | sed 's/.*id:\([^ ]*\).*/\1/')
    # Switch to 2560x1600 non-scaled — avoids the notch (64px shorter than full panel)
    # while still providing near-native resolution for games
    "$DISPLAYPLACER" "id:${DISPLAY_ID} res:2560x1600 hz:60 color_depth:8 scaling:off" 2>/dev/null
    sleep 1
fi

# Launch Steam directly (no virtual desktop) — the mac driver exposes the native
# display modes to games when the macOS display is set to non-scaled resolution.
# Using explorer /desktop= at the screen's exact size causes Wine to hang.
"${WINE_BIN}/wine" "${STEAM_EXE}" \
    -noverifyfiles -norepairfiles \
    -cef-disable-gpu -cef-disable-gpu-compositing \
    -cef-in-process-gpu -cef-disable-sandbox \
    "$@" &
WINE_PID=$!

# Wait in a loop so bash can process signals (SIGINT) between iterations
while kill -0 $WINE_PID 2>/dev/null; do
    wait $WINE_PID 2>/dev/null || break
done
