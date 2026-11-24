#!/usr/bin/env bash
#
# Puts RecompLauncher in the desktop's application menu, with Exec pointing at the sandbox runner
# instead of the bare binary: clicking the icon starts the launcher inside the boundary described
# in README.md, not outside it.
#
#   sandbox/desktop-entry.sh install [--binary PATH | --appimage PATH] [--config PATH]
#   sandbox/desktop-entry.sh check      # is it valid, does the menu see it, does it launch in the sandbox
#   sandbox/desktop-entry.sh uninstall
#
# Everything it writes is per-user (~/.local/share, ~/.config), so nothing here needs root and
# nothing touches a .deb installed system-wide: a user entry with the same desktop id simply
# shadows it.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/rl-sandbox"
REPO="$(cd "$HERE/.." && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
ICONS_DIR="$DATA_HOME/icons/hicolor"
# The same id the .deb uses, so the menu shows one RecompLauncher and it is this one.
DESKTOP_FILE="$APPS_DIR/recomplauncher.desktop"
ICON_NAME="recomplauncher"
DEFAULT_CONFIG="$HOME/.config/recomplauncher/sandbox.json"
ARTIFACTS="$HERE/out/artifacts"

action="${1:-check}"
shift || true
BINARY=""
APPIMAGE=""
CONFIG="${RL_SANDBOX_CONFIG:-$DEFAULT_CONFIG}"

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) BINARY="${2:?}"; shift 2 ;;
        --appimage) APPIMAGE="${2:?}"; shift 2 ;;
        --config) CONFIG="${2:?}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; status=1; }
status=0

# --- helpers ---------------------------------------------------------------------------------

# What the menu itself would list. Gio.AppInfo is where GNOME Shell's app grid gets its entries,
# and should_show() is the same filter it applies, so this is not a guess about GNOME's behaviour.
gio_lookup() {
    python3 - "$DESKTOP_FILE" <<'PY'
import sys
from gi.repository import Gio

path = sys.argv[1]
info = Gio.DesktopAppInfo.new_from_filename(path) if path.endswith(".desktop") else None
if info is None:
    print("NOT-FOUND")
    raise SystemExit(1)
print("id:        ", info.get_id())
print("name:      ", info.get_name())
print("command:   ", info.get_commandline())
print("executable:", info.get_executable())
print("icon:      ", info.get_icon().to_string() if info.get_icon() else "none")
print("should_show:", info.should_show())
PY
}

# The chain of parents of a pid, to see whether a process really is inside a sandbox.
ancestry() {
    local pid="$1" line
    while [ "$pid" != "0" ] && [ -n "$pid" ]; do
        line="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        [ -n "$line" ] && printf '%s(%s) ' "$line" "$pid"
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    done
    echo
}

icon_sources() {
    # Best source first: the checkout's own icons, then whatever the .deb installed.
    for size in 32x32:32x32.png 128x128:128x128.png 256x256@2:128x128@2x.png; do
        local dir="${size%%:*}" png="${size##*:}"
        if [ -f "$REPO/src-tauri/icons/$png" ]; then
            printf '%s %s\n' "$dir" "$REPO/src-tauri/icons/$png"
        elif [ -f "/usr/share/icons/hicolor/$dir/apps/$ICON_NAME.png" ]; then
            printf '%s %s\n' "$dir" "/usr/share/icons/hicolor/$dir/apps/$ICON_NAME.png"
        fi
    done
}

# --- install ---------------------------------------------------------------------------------

do_install() {
    if [ -n "$APPIMAGE" ]; then
        APPIMAGE="$(readlink -f "$APPIMAGE")"
    fi
    if [ ! -x "$RUNNER" ]; then
        echo "$RUNNER is not executable" >&2; exit 1
    fi

    # The entry runs the runner, so the runner's own configuration has to exist and resolve to a
    # launcher. Without a config there is nothing for the menu item to start.
    if [ ! -f "$CONFIG" ]; then
        mkdir -p "$(dirname "$CONFIG")"
        cp "$HERE/sandbox.json.example" "$CONFIG"
        say "created $CONFIG from sandbox.json.example — edit the folder lists before relying on it"
    fi
    # A binary nobody can find is the one thing worth fixing here rather than at click time.
    if "$RUNNER" --config "$CONFIG" --list 2>&1 | grep -q 'no launcher binary found'; then
        local target="$BINARY"
        [ -z "$target" ] && target="$(ls -1 "$ARTIFACTS"/recomplauncher "$ARTIFACTS"/*.AppImage /usr/bin/recomplauncher 2>/dev/null | head -n1 || true)"
        if [ -z "$target" ]; then
            echo "no launcher binary found; pass --binary PATH or --appimage PATH" >&2
            exit 1
        fi
        python3 - "$CONFIG" "$(readlink -f "$target")" <<'PY'
import json, sys
path, binary = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["binary"] = binary
json.dump(cfg, open(path, "w"), indent=2)
print(f"set binary = {binary} in {path}")
PY
    fi

    mkdir -p "$APPS_DIR"
    # %u so a recomplauncher:// link reaches the launcher; the runner appends whatever it is given.
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=RecompLauncher
GenericName=Game launcher
Comment=Recompiled and decompiled PC games, in a sandbox
Exec=$RUNNER --config $CONFIG %u
Icon=$ICON_NAME
Terminal=false
Categories=Game;
Keywords=games;recomp;
StartupWMClass=recomplauncher
MimeType=x-scheme-handler/recomplauncher;
EOF
    say "wrote $DESKTOP_FILE"

    local count=0
    while read -r dir src; do
        [ -n "$dir" ] || continue
        mkdir -p "$ICONS_DIR/$dir/apps"
        cp -f "$src" "$ICONS_DIR/$dir/apps/$ICON_NAME.png"
        count=$((count + 1))
    done < <(icon_sources)
    if [ "$count" -gt 0 ]; then
        gtk-update-icon-cache -f -t "$ICONS_DIR" >/dev/null 2>&1 || true
        say "installed $count icon size(s) under $ICONS_DIR"
    else
        say "warning: no icon found to install; the menu entry will show a generic icon"
    fi

    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    say "refreshed the desktop database"
    say
    do_check
}

# --- uninstall -------------------------------------------------------------------------------

do_uninstall() {
    rm -f "$DESKTOP_FILE"
    local removed=0
    for dir in 32x32 128x128 256x256@2; do
        if [ -f "$ICONS_DIR/$dir/apps/$ICON_NAME.png" ]; then
            rm -f "$ICONS_DIR/$dir/apps/$ICON_NAME.png"
            removed=$((removed + 1))
        fi
    done
    gtk-update-icon-cache -f -t "$ICONS_DIR" >/dev/null 2>&1 || true
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    say "removed $DESKTOP_FILE and $removed icon file(s); the .deb's own menu entry, if any, is back in charge"
}

# --- check -----------------------------------------------------------------------------------

do_check() {
    if [ -f "$DESKTOP_FILE" ]; then
        ok "user entry exists: $DESKTOP_FILE"
    else
        bad "no user entry at $DESKTOP_FILE (run: $0 install)"
        return
    fi

    if command -v desktop-file-validate >/dev/null; then
        local complaints
        if complaints="$(desktop-file-validate "$DESKTOP_FILE" 2>&1)"; then
            ok "desktop-file-validate: no complaints"
        else
            bad "desktop-file-validate said: $complaints"
        fi
    else
        say "INFO desktop-file-validate is not installed"
    fi

    local exec_line
    exec_line="$(grep -m1 '^Exec=' "$DESKTOP_FILE")"
    if printf '%s' "$exec_line" | grep -q "$RUNNER"; then
        ok "Exec goes through the sandbox runner: ${exec_line#Exec=}"
    else
        bad "Exec does not go through $RUNNER: $exec_line"
    fi

    if [ -f "$ICONS_DIR/128x128/apps/$ICON_NAME.png" ] || [ -f "/usr/share/icons/hicolor/128x128/apps/$ICON_NAME.png" ]; then
        ok "icon $ICON_NAME resolves to a 128x128 PNG"
    else
        bad "no 128x128 icon named $ICON_NAME found"
    fi

    say
    say "--- what the menu sees (Gio, the same list GNOME Shell builds its grid from) ---"
    if gio_lookup | sed 's/^/     /'; then
        if gio_lookup | grep -q 'should_show: True'; then
            ok "the entry is not hidden: it will appear in the app grid"
        else
            bad "should_show is False: the grid would hide it"
        fi
    else
        bad "Gio could not read the entry"
    fi

    say
    say "--- default handler for recomplauncher:// links ---"
    say "     $(xdg-mime query default x-scheme-handler/recomplauncher 2>/dev/null || echo '(none)')"

    say
    say "--- launch it the way the icon does ---"
    local before after new_pid
    before="$(pgrep -x recomplauncher 2>/dev/null | sort | tr '\n' ' ' || true)"
    gio launch "$DESKTOP_FILE" >/dev/null 2>&1 &
    for _ in $(seq 1 25); do
        after="$(pgrep -x recomplauncher 2>/dev/null | sort | tr '\n' ' ' || true)"
        [ "$after" != "$before" ] && break
        sleep 1
    done
    new_pid=""
    for pid in $after; do
        case " $before " in *" $pid "*) ;; *) new_pid="$pid" ;; esac
    done
    if [ -z "$new_pid" ]; then
        bad "nothing started from the desktop entry"
        return
    fi
    ok "started, pid $new_pid"
    local chain sandbox_env sandbox_config
    chain="$(ancestry "$new_pid")"
    sandbox_env="$(tr '\0' '\n' < "/proc/$new_pid/environ" 2>/dev/null || true)"
    sandbox_config="$(printf '%s\n' "$sandbox_env" | sed -n 's/^RL_SANDBOX_CONFIG=//p')"
    say "     process chain: $chain"
    # The marker is set by rl-sandbox itself, so this says "inside this sandbox" rather than
    # "somewhere behind some bubblewrap": a nested bwrap from a container or an agent's shell
    # would pass the weaker test.
    if printf '%s\n' "$sandbox_env" | grep -qx 'RL_SANDBOX=1'; then
        ok "it runs inside this sandbox (RL_SANDBOX=1, config $sandbox_config)"
    elif printf '%s' "$chain" | grep -q 'bwrap'; then
        bad "it is behind bwrap but without the RL_SANDBOX marker: not this runner's sandbox"
    else
        bad "it did NOT start inside bwrap"
    fi
    kill "$new_pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$new_pid" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$new_pid" 2>/dev/null || true
    ok "stopped it again"
    return 0
}

case "$action" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    check) do_check ;;
    *) echo "usage: $0 install|check|uninstall [--binary PATH] [--appimage PATH] [--config PATH]" >&2; exit 2 ;;
esac

exit "$status"
