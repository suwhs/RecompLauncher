#!/usr/bin/env bash
#
# Puts a game in the application menu with its own icon and name, started through the sandbox:
# clicking it opens the game and not the launcher, and the game still only sees the folders the
# sandbox config allows.
#
#   sandbox/game-entry.sh list                     # installed games, and whether each has an entry
#   sandbox/game-entry.sh add <id> [--name NAME]   # write/refresh the entry for one game
#   sandbox/game-entry.sh add --all                # one entry per installed game
#   sandbox/game-entry.sh remove <id> | --all
#
# Where the games and their names come from: the launcher's own library.json (its `installed`
# map). `name` is the recomp's own name; the launcher shows the game's name from the catalog when
# it has one, and `--name` overrides either.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/rl-sandbox"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
LIBRARY="$DATA_HOME/com.recomplauncher.app/library.json"
DEFAULT_CONFIG="$HOME/.config/recomplauncher/sandbox.json"
PREFIX="com.recomplauncher.app."

status=0
say() { printf '%s\n' "$*"; }
ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; status=1; }

config="${RL_SANDBOX_CONFIG:-$DEFAULT_CONFIG}"
action="${1:-list}"
shift || true

game_id=""
name_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) name_override="${2:?}"; shift 2 ;;
        --config) config="${2:?}"; shift 2 ;;
        --all) game_id="--all"; shift ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) game_id="$1"; shift ;;
    esac
done

command -v python3 >/dev/null || { echo "python3 is needed to read the launcher's library" >&2; exit 1; }
[ -f "$LIBRARY" ] || { echo "no library at $LIBRARY: has the launcher installed anything yet?" >&2; exit 1; }

# One line per installed game: id, name, folder, program, and its arguments. The program and the
# arguments come from the recomp's own recomplauncher.json — the same file the launcher reads. A
# game started with only its executable is a game started wrong: Longshot's AppRun, for one, is a
# builder that prints a message and exits unless it is given --play.
read_games() {
    python3 - "$LIBRARY" <<'PY'
import json, os, sys

lib = json.load(open(sys.argv[1]))
for gid, g in (lib.get("installed") or {}).items():
    folder = g.get("path") or ""
    name = g.get("name") or gid
    program, args = "", ""
    try:
        with open(os.path.join(folder, "recomplauncher.json")) as f:
            m = json.load(f)
        start = m.get("start") or {}
        label = ((m.get("game") or {}).get("label") or "").strip()
        # "Your copy of The Legend of Zelda: Ocarina of Time for Nintendo Switch 2, version …"
        # is a sentence, not a name: keep the title.
        if label.startswith("Your copy of "):
            label = label[len("Your copy of "):].split(" for ")[0].strip().rstrip(",")
        if label:
            name = label
        for p in start.get("program") or []:
            candidate = os.path.join(folder, p)
            if os.path.exists(candidate):
                program = candidate
                break
        if not program:
            program = os.path.join(folder, g.get("exe") or "")
        args = " ".join(str(a).replace("{install}", folder) for a in (start.get("args") or []))
    except (OSError, ValueError):
        program = os.path.join(folder, g.get("exe") or "")
    print("\t".join([gid, name.replace("\t", " "), folder, program, args]))
PY
}

installed_ids() { read_games | cut -f1; }

entry_file() { echo "$APPS_DIR/$PREFIX$1.desktop"; }

# What the game's own directory offers: an AppImage, or whatever the launcher recorded as its
# program. The launcher writes one of these for each game it installs.
find_program() {
    local dir="$1" exe="$2"
    local candidate
    for candidate in "$dir/$exe" "$dir"/*.AppImage "$dir"/AppRun; do
        if [ -n "$candidate" ] && [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

write_entry() {
    local id="$1" name="$2" dir="$3" program="$4" args="$5"
    if [ -z "$program" ] || [ ! -x "$program" ]; then
        if ! program="$(find_program "$dir" "$exe")"; then
            bad "$id: no program found under $dir"
            return
        fi
    fi
    local icon="$dir/.DirIcon"
    [ -e "$icon" ] || icon="$dir/$exe"
    [ -e "$icon" ] || icon="applications-games"

    mkdir -p "$APPS_DIR"
    local file
    file="$(entry_file "$id")"
    # Exec runs the runner, so the game is inside the same boundary the launcher gets. %U keeps a
    # file argument working; nothing here needs it, but a shortcut that ignores one is a surprise.
    local exec_line="$RUNNER --config $config --exec $program"
    [ -n "$args" ] && exec_line="$exec_line $args"

    cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$name
Comment=$name, through RecompLauncher's sandbox
Exec=$exec_line
Icon=$icon
Terminal=false
Categories=Game;
StartupWMClass=$name
EOF
    chmod 0644 "$file"
    say "wrote $file"
    say "     Exec=$exec_line"
}

case "$action" in
    list)
        printf '%-28s %-38s %s\n' "ID" "NAME" "MENU ENTRY"
        while IFS=$'\t' read -r id name dir program args; do
            [ -n "$id" ] || continue
            if [ -f "$(entry_file "$id")" ]; then
                printf '%-28s %-38s %s\n' "$id" "$name" "yes"
            else
                printf '%-28s %-38s %s\n' "$id" "$name" "no"
            fi
        done < <(read_games)
        say
        say "add one with: $0 add <id>"
        ;;

    add)
        [ -n "$game_id" ] || { echo "which game? try: $0 list" >&2; exit 2; }
        while IFS=$'\t' read -r id name dir program args; do
            [ -n "$id" ] || continue
            if [ "$game_id" != "--all" ] && [ "$id" != "$game_id" ]; then
                continue
            fi
            [ -n "$name_override" ] && name="$name_override"
            write_entry "$id" "$name" "$dir" "$program" "$args"
        done < <(read_games)
        if [ "$game_id" != "--all" ] && ! installed_ids | grep -qx "$game_id"; then
            bad "no installed game with id '$game_id'"
            exit 1
        fi
        update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
        ;;

    remove)
        [ -n "$game_id" ] || { echo "which game? try: $0 list" >&2; exit 2; }
        if [ "$game_id" = "--all" ]; then
            set -- "$APPS_DIR/$PREFIX"*.desktop
            [ -e "$1" ] || { say "nothing to remove"; exit 0; }
            rm -f "$APPS_DIR/$PREFIX"*.desktop
            say "removed every RecompLauncher game entry"
        else
            rm -f "$(entry_file "$game_id")"
            say "removed $(entry_file "$game_id")"
        fi
        update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
        ;;

    *)
        echo "usage: $0 list | add <id>|--all [--name NAME] | remove <id>|--all" >&2
        exit 2
        ;;
esac

exit "$status"
