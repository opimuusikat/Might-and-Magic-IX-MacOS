#!/bin/bash
# MM9 Native Builder: builds "MM9 Native.app", a native Apple Silicon version of Might and Magic IX,
# from YOUR OWN copy of the game, on THIS Mac. Nothing from the game comes with the builder: the
# game's code is analysed with Ghidra, translated to C and compiled here, and the result stays here.
# Do not share the app it makes (it contains code translated from the game).
#
#   bash build.sh            (or double-click "Build MM9 Native.command")
#
# Needs: an Apple Silicon Mac with macOS 13 or later, Apple's Command Line Tools, about 4 GB free
# disk, and the GOG release 1.3 of the game (the folder the "Might and Magic IX" Wine app unpacks,
# or another folder holding lithtech.exe). Downloads Ghidra 12.1.4, a Java 21 runtime and the
# Unicorn library once (0.8 GB) into the cache folder below; checks every download's SHA-256.
#
# Settings (environment variables, all optional):
#   MM9N_GAME      game folder to build from (default: the Wine app's folder, or ask)
#   MM9N_INSTALLER the GOG installer (setup_might_and_magic_9_...exe) to unpack and build from
#   MM9N_INNOEXTRACT  path of the innoextract tool (default: the one next to the builder, or on PATH)
#   MM9N_SUPPORT   where the game copy, saves and logs live
#                  (default: ~/Library/Application Support/MM9 Native)
#   MM9N_CACHE     tool cache (default: ~/Library/Application Support/MM9 Native Builder; delete it
#                  any time). Not under ~/Library/Caches: Ghidra skips every jar whose path contains
#                  "caches", finds none of its own classes and stops with "Unable to locate extension points".
#   MM9N_APPDIR    where the app goes (default: ~/Applications)
#   MM9N_DIALOGS=0 no dialog windows (errors only in Terminal)
#   MM9N_KEEP_WORK=1  keep the 1 GB of intermediate files after a successful build
#   MM9N_JOBS, MM9N_GHIDRA_JOBS, MM9N_GHIDRA_MAXMEM   parallelism and Ghidra's Java heap
#   MM9N_SKIP_SMOKETEST=1  do not start the game once at the end
#   MM9N_FFMPEG_DOWNLOAD=1  also download ffmpeg (28 MB, SHA-256 checked) so the intro movies play
#
# MIT licence (see LICENSES/). Parts are derived from Fallout-NV-MacOS (MIT, (c) 2026 thetheoryofR).

set -u -o pipefail
export LC_ALL=C

SRC="$(cd "$(dirname "$0")" && pwd)"
. "$SRC/manifest.sh"

SUPPORT="${MM9N_SUPPORT:-$HOME/Library/Application Support/MM9 Native}"
CACHE="${MM9N_CACHE:-$HOME/Library/Application Support/MM9 Native Builder}"
OLD_CACHE="$HOME/Library/Caches/MM9 Native Builder"   # builder 1.0's default, where Ghidra cannot start
APPDIR="${MM9N_APPDIR:-$HOME/Applications}"
WINE_GAME="$HOME/Library/Application Support/Might and Magic IX/game"
GAME="$SUPPORT/game"                   # the working copy the native game runs in (saves live here)
WORK="$SUPPORT/build-work"             # intermediate files, deleted after a successful build
LOGDIR="$SUPPORT/logs"
LOG="$LOGDIR/build.log"
PY="${MM9N_PYTHON:-/usr/bin/python3}"
DIALOGS="${MM9N_DIALOGS:-1}"
APPNAME="MM9 Native.app"
MARKER="Contents/Resources/mm9native-builder.txt"

# ---------------------------------------------------------------------------------------------
# Ghidra worker (run by xargs, one module per call, in parallel): import + auto-analysis, the
# FNV repair passes, then the P-code dump. Environment comes from the main run.
if [ "${1:-}" = "--ghidra-one" ]; then
  M="$2"; P="${M//./_}"; H="$GH/support/analyzeHeadless"; O="$WORK/out/$P"; L="$LOGDIR/ghidra-$P"
  # Each worker gets its own Ghidra settings and cache folders: parallel first runs race to create shared ones.
  export XDG_CONFIG_HOME="$GHIDRA_USER/$P/config" XDG_CACHE_HOME="$GHIDRA_USER/$P/cache"
  rm -rf "$WORK/ghidra/$P" "$O"; mkdir -p "$WORK/ghidra/$P" "$O"
  t0=$(date +%s)
  "$H" "$WORK/ghidra/$P" "$P" -import "$WORK/inputs/$M" -overwrite -analysisTimeoutPerFile 3600 \
     > "$L-import.log" 2>&1 < /dev/null || { echo "import failed" > "$O/.failed"; exit 1; }
  t1=$(date +%s)
  "$H" "$WORK/ghidra/$P" "$P" -process "$M" -noanalysis -scriptPath "$SRC/ghidra_scripts" \
     -postScript FixNoReturn.java -postScript ResolveJumpTables.java -postScript FixEntries.java "$O" \
     > "$L-fix.log" 2>&1 < /dev/null || { echo "repair passes failed" > "$O/.failed"; exit 1; }
  [ -s "$O/extra_entries.json" ] || { echo "repair passes wrote no extra_entries.json" > "$O/.failed"; exit 1; }
  t2=$(date +%s)
  "$H" "$WORK/ghidra/$P" "$P" -process "$M" -noanalysis -readOnly -scriptPath "$SRC/ghidra_scripts" \
     -postScript DumpPcode.java "$O/all.jsonl" all > "$L-dump.log" 2>&1 < /dev/null \
     || { echo "P-code dump failed" > "$O/.failed"; exit 1; }
  [ -s "$O/all.jsonl" ] || { echo "P-code dump is empty" > "$O/.failed"; exit 1; }
  t3=$(date +%s)
  printf '%-13s import+analysis %3ds, repair %2ds, dump %2ds\n' "$M" $((t1 - t0)) $((t2 - t1)) $((t3 - t2)) > "$O/.done"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
sha() { /usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
# SHA-256 that identifies this builder (every file under src/, sorted); the same for the copy inside an app bundle.
source_hash() {
  ( cd "$SRC" && /usr/bin/find . -type f ! -name .DS_Store ! -name '._*' ! -path '*/__pycache__/*' | sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) | /usr/bin/shasum -a 256 | cut -d' ' -f1
}
if [ "${1:-}" = "--source-hash" ]; then source_hash; exit 0; fi

# ---------------------------------------------------------------------------------------------
# --status: what is on this Mac, as key=value lines (read-only: no log, no dialogs, nothing created). The updater app reads it.
if [ "${1:-}" = "--status" ]; then
  kv() { printf '%s=%s\n' "$1" "$2"; }
  bsrc="$(source_hash)"; kv bundled_version "$BUILDER_VERSION"; kv bundled_source "$bsrc"
  arm=0; [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && arm=1
  clt=0; /usr/bin/xcode-select -p > /dev/null 2>&1 && /usr/bin/xcrun --find clang > /dev/null 2>&1 && clt=1
  kv mac_arm64 $arm; kv macos "$(/usr/bin/sw_vers -productVersion 2>/dev/null)"; kv clt $clt
  app=""; for d in "$APPDIR" /Applications; do [ -z "$app" ] && [ -d "$d/$APPNAME" ] && app="$d/$APPNAME"; done
  kv app_path "$app"
  appstate=missing; asrc=""; aver=""; aarm=0; asmoke=""; asup="$SUPPORT"
  if [ -n "$app" ]; then
    mk="$app/$MARKER"
    if [ ! -f "$mk" ]; then appstate=foreign; else
      appstate=ok
      aver="$(sed -n 's/^builder-version: *//p' "$mk" | head -1)"; [ -n "$aver" ] || aver="$(head -1 "$mk" | sed -n 's/^MM9 Native Builder *//p')"
      asrc="$(sed -n 's/^builder-source: *//p' "$mk" | head -1)"
      kv app_state ok; kv app_version "$aver"; kv app_source "$asrc"
      kv app_built "$(sed -n 's/^built //p' "$mk" | head -1)"
      asmoke="$(sed -n 's/^smoke test: //p' "$mk" | head -1)"; kv app_smoke "$asmoke"
      kv app_ghidra "$(sed -n 's/^Ghidra output: //p' "$mk" | head -1)"
      kv app_table "$(sed -n 's/^function table ([^)]*): //p' "$mk" | head -1)"
      /usr/bin/file "$app/Contents/MacOS/MM9NativeGame" 2>/dev/null | grep -q 'Mach-O 64-bit executable arm64' && aarm=1
      kv app_arm64 $aarm
      l="$(grep -m1 '^SUPPORT=' "$app/Contents/MacOS/MM9Native" 2>/dev/null)"   # written with printf %q
      case "$l" in *'`'*|*'$('*|*'${'*) l="" ;; esac   # a path never needs command substitution; refuse it
      case "$l" in SUPPORT=*) x=""; eval "x=${l#SUPPORT=}" 2>/dev/null; [ -n "$x" ] && asup="$x" ;; esac
    fi
  fi
  [ "$appstate" = ok ] || kv app_state $appstate
  kv app_support "$asup"
  g="$asup/game"; gs=missing
  if [ -f "$g/lithtech.exe" ]; then
    gs=ok; for f in $GAME_FILES; do [ "$(sha "$g/$f")" = "$(sha_game "$f")" ] || gs=wrong; done
  fi
  kv game_state $gs
  ns=0; mb=0
  if [ -d "$g/SaveGames" ]; then
    ns="$(find "$g/SaveGames" -type f 2>/dev/null | wc -l | tr -d ' ')"; mb=$(( ($(du -sk "$g/SaveGames" 2>/dev/null | cut -f1) + 512) / 1024 ))
  fi
  kv saves "$ns"; kv saves_mb "$mb"
  fd="$asup"; while [ ! -d "$fd" ] && [ "$fd" != / ]; do fd="$(dirname "$fd")"; done
  kv free_gb "$(df -k "$fd" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')"
  tstate() {   # <name> <manifest sha>
    if [ "$(cat "$CACHE/$1/.ok" 2>/dev/null)" = "$2" ]; then echo ok; elif [ -e "$CACHE/$1" ]; then echo update; else echo missing; fi
  }
  tg=$(tstate ghidra "$GHIDRA_SHA"); tj=$(tstate jdk "$JDK_SHA"); tu=$(tstate unicorn "$UNICORN_SHA")
  kv tools_ghidra "$tg"; kv tools_jdk "$tj"; kv tools_unicorn "$tu"
  FF="$asup/tools/ffmpeg"; ff=missing
  if [ -x "$FF" ]; then if [ "$(cat "$FF.zip.sha" 2>/dev/null)" = "$FFMPEG_SHA" ]; then ff=ok; else ff=update; fi; fi
  kv ffmpeg $ff
  wa=0; [ -d "/Applications/Might and Magic IX.app" ] && wa=1; wg=0; [ -f "$WINE_GAME/lithtech.exe" ] && wg=1
  kv wine_app $wa; kv wine_game $wg
  blocker=""
  if [ "$arm" != 1 ]; then blocker="This Mac does not have Apple Silicon (M1 or later). The native version runs only on Apple Silicon."
  elif [ "$appstate" = missing ]; then blocker="MM9 Native is not installed on this Mac. Use the MM9 Native Installer."
  elif [ "$appstate" = foreign ]; then blocker="The app at $app was not made by the MM9 Native Builder, so it is left alone. Use the MM9 Native Installer."
  elif [ "$gs" != ok ]; then blocker="The game copy in $g is $([ "$gs" = missing ] && echo missing || echo "not the expected GOG 1.3 version"). Use the MM9 Native Installer."
  fi
  if [ -n "$blocker" ]; then kv update_needed no; kv app_update no; kv blocker "$blocker"; exit 0; fi
  reasons=(); au=no
  if [ -z "$asrc" ]; then au=yes; reasons+=("Your MM9 Native was built by an older builder that did not record its version details.")
  elif [ "$asrc" != "$bsrc" ]; then au=yes; reasons+=("Your MM9 Native was built by a different builder than this updater's (version $aver, this one is $BUILDER_VERSION).")
  elif [ "$aver" != "$BUILDER_VERSION" ]; then au=yes; reasons+=("Your MM9 Native was built by builder $aver; this updater has $BUILDER_VERSION.")
  fi
  if [ "$aarm" != 1 ]; then au=yes; reasons+=("The game program inside MM9 Native is not an Apple Silicon program.")
  fi
  case "$asmoke" in passed*) ;; *) au=yes; reasons+=("The last start-up test of MM9 Native did not pass.") ;; esac
  need=no
  [ "$au" = yes ] && need=yes
  for t in "ghidra:$tg" "jdk:$tj" "unicorn:$tu"; do
    [ "${t#*:}" = update ] && { need=yes; reasons+=("The build tool ${t%%:*} in the tool folder is not the version this builder needs.") ; }
  done
  [ "$ff" = update ] && { need=yes; reasons+=("The movie tool ffmpeg is not the version this builder expects."); }
  kv update_needed $need; kv app_update $au
  for r in "${reasons[@]+"${reasons[@]}"}"; do kv reason "$r"; done
  exit 0
fi

# ---------------------------------------------------------------------------------------------
NSTEPS=13; STEPNO=0; STEP=""; STEP_T0=0; T_START=$(date +%s)
mkdir -p "$LOGDIR" || { echo "Cannot create $LOGDIR"; exit 1; }
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
: > "$LOG"

dialog() {
  [ "$DIALOGS" = 1 ] || return 0
  /usr/bin/osascript - "$1" <<'EOF' >/dev/null 2>&1
on run argv
  display dialog (item 1 of argv) with title "MM9 Native Builder" buttons {"OK"} default button 1 with icon caution
end run
EOF
}
step() {
  STEPNO=$((STEPNO + 1)); STEP="$1"; STEP_T0=$(date +%s)
  printf '\n[%d/%d] %s\n' "$STEPNO" "$NSTEPS" "$1"
  printf '\n=== [%d/%d] %s (%s)\n' "$STEPNO" "$NSTEPS" "$1" "$(date)" >> "$LOG"
}
say() { printf '      %s\n' "$*"; printf '%s\n' "$*" >> "$LOG"; }
done_step() { say "done in $(( $(date +%s) - STEP_T0 )) s${1:+: $1}"; }
# fail <message> [log file to show]
fail() {
  local d="${2:-$LOG}"
  printf '\nThe build stopped at step %d (%s):\n  %s\n' "$STEPNO" "$STEP" "$1"
  printf '\nFAILED at step %d (%s): %s\n' "$STEPNO" "$STEP" "$1" >> "$LOG"
  if [ -s "$d" ] && { [ -n "${2:-}" ] || [ "$STEPNO" -ge 5 ]; }; then   # checks before step 5 explain themselves
    printf '\n  Last lines of %s:\n' "$d"
    tail -n 30 "$d" | sed 's/^/    /'
  fi
  [ "$d" != "$LOG" ] && [ -f "$d" ] && { printf '\n--- %s (last 200 lines)\n' "$d"; tail -n 200 "$d"; } >> "$LOG"
  printf '\n  Full log: %s\n  If you ask for help, send that file. It holds tool output and file names only.\n' "$LOG"
  dialog "The build stopped at step \"$STEP\": $1

Details are in $LOG"
  exit 1
}
logrun() { "$@" >> "$LOG" 2>&1; }
trap 'printf "\nStopped.\n"; exit 130' INT TERM

echo "MM9 Native Builder $BUILDER_VERSION"
echo "Log: $LOG"
{ echo "MM9 Native Builder $BUILDER_VERSION, $(date)"; echo "SUPPORT=$SUPPORT"; echo "CACHE=$CACHE"; echo "APPDIR=$APPDIR"; } >> "$LOG"

# ---------------------------------------------------------------------------------------------
step "Checking this Mac"
[ "$(id -u)" != 0 ] || fail "Do not run the builder as root (no sudo)."
[ "$(uname -s)" = Darwin ] || fail "This builder runs on macOS only."
[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
  || fail "This Mac does not have Apple Silicon (M1 or later). The native build runs only on Apple Silicon for now; the Wine app works on Intel Macs."
osv="$(/usr/bin/sw_vers -productVersion)"
[ "${osv%%.*}" -ge 13 ] 2>/dev/null || fail "macOS 13 (Ventura) or later is needed; this Mac has $osv."
if ! /usr/bin/xcode-select -p > /dev/null 2>&1 || ! /usr/bin/xcrun --find clang > /dev/null 2>&1; then
  /usr/bin/xcode-select --install > /dev/null 2>&1
  fail "Apple's Command Line Tools are not installed. A window to install them should have opened (if not, run: xcode-select --install). Install them (about 10 minutes, no Apple ID needed), then run the builder again."
fi
# Ghidra ignores jars whose path contains these words (ClassJar.ignoreJar) and then cannot start.
case "$(printf '%s' "$CACHE" | tr '[:upper:]' '[:lower:]')" in
  *caches*|*externallibraries*|*flatrepo*)
    fail "The tool folder $CACHE has \"Caches\", \"ExternalLibraries\" or \"flatrepo\" in its path, and Ghidra cannot start from there. Unset MM9N_CACHE or point it somewhere else." ;;
esac
if [ -z "${MM9N_CACHE:-}" ] && [ -d "$OLD_CACHE" ]; then
  rm -rf "$OLD_CACHE" && say "removed the old tool folder $OLD_CACHE (Ghidra cannot start from there)"
fi
mkdir -p "$WORK" || fail "Cannot create $WORK"
SRC_HASH="$(source_hash)"
if [ -f "$WORK/.source" ] && [ "$(cat "$WORK/.source")" != "$SRC_HASH" ]; then   # leftovers of an unfinished run by another builder
  rm -rf "$WORK"; mkdir -p "$WORK" || fail "Cannot create $WORK"
  say "removed the unfinished files of an earlier build: they came from a different builder version"
fi
echo "$SRC_HASH" > "$WORK/.source"
printf 'int main(void) { return 0; }\n' > "$WORK/cc-test.c"
logrun /usr/bin/xcrun clang -arch arm64 "$WORK/cc-test.c" -o "$WORK/cc-test" \
  || fail "The C compiler does not work. If the log mentions a licence, run: sudo xcodebuild -license accept"
logrun "$PY" -I -c 'import sys; sys.exit(sys.version_info < (3, 8))' \
  || fail "Python 3.8 or later is needed (the Command Line Tools include it as /usr/bin/python3)."
NCPU=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
MEM_GB=$(( $(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))
JOBS="${MM9N_JOBS:-$NCPU}"
if [ "$MEM_GB" -ge 16 ]; then GH_HEAP=6G; else GH_HEAP=4G; fi
GH_HEAP="${MM9N_GHIDRA_MAXMEM:-$GH_HEAP}"
GJ=$(( MEM_GB / 12 )); [ "$GJ" -lt 1 ] && GJ=1; [ "$GJ" -gt 3 ] && GJ=3
GJ="${MM9N_GHIDRA_JOBS:-$GJ}"
free_gb() { df -k "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'; }
need=2; [ -f "$CACHE/.tools-$BUILDER_VERSION" ] || need=4
mkdir -p "$CACHE" || fail "Cannot create $CACHE"
[ "$(free_gb "$SUPPORT")" -ge "$need" ] || fail "Not enough free disk space: the build needs about $need GB free on the disk that holds $SUPPORT."
[ "$(free_gb "$CACHE")" -ge "$need" ] || fail "Not enough free disk space: the build needs about $need GB free on the disk that holds $CACHE."
clangv="$(/usr/bin/xcrun clang --version 2>/dev/null | head -1)"
{ echo "macOS $osv, $NCPU cores, $MEM_GB GB"; echo "$clangv"; "$PY" --version 2>&1; } >> "$LOG"
done_step "macOS $osv, $NCPU cores, $MEM_GB GB memory; $clangv"

# ---------------------------------------------------------------------------------------------
step "Finding your game"
INSTALLER=""
choose_game() {
  [ "$DIALOGS" = 1 ] || return 1
  local b
  b=$(/usr/bin/osascript -e 'button returned of (display dialog "The builder needs your copy of Might and Magic IX (GOG version 1.3).

Choose the game folder (the one that holds lithtech.exe), or the GOG installer file setup_might_and_magic_9_….exe." with title "MM9 Native Builder" buttons {"Cancel", "Choose Installer…", "Choose Folder…"} default button 3)' 2>/dev/null) || return 1
  case "$b" in
    "Choose Folder…") GAME_IN=$(/usr/bin/osascript -e 'POSIX path of (choose folder with prompt "Choose the Might and Magic IX game folder (it holds lithtech.exe)")' 2>/dev/null) || return 1
                      GAME_IN="${GAME_IN%/}" ;;
    "Choose Installer…") INSTALLER=$(/usr/bin/osascript -e 'POSIX path of (choose file with prompt "Choose your GOG installer for Might and Magic 9 (setup_might_and_magic_9_….exe)" default location (path to downloads folder))' 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
}
if [ -n "${MM9N_GAME:-}" ]; then
  GAME_IN="${MM9N_GAME%/}"
elif [ -n "${MM9N_INSTALLER:-}" ] && [ ! -f "$GAME/lithtech.exe" ]; then
  GAME_IN=""; INSTALLER="$MM9N_INSTALLER"
elif [ -f "$GAME/lithtech.exe" ]; then
  GAME_IN="$GAME"                      # rebuilding: the existing working copy is the input
elif [ -f "$WINE_GAME/lithtech.exe" ]; then
  GAME_IN="$WINE_GAME"
else
  GAME_IN=""
  choose_game || fail "No game folder was found or chosen. Run the Might and Magic IX app (Wine version) once so it unpacks the game, or set MM9N_GAME to your game folder, then run the builder again."
fi
if [ -n "$INSTALLER" ]; then
  [ -f "$INSTALLER" ] || fail "Installer not found: $INSTALLER"
  INNO=""
  for c in "${MM9N_INNOEXTRACT:-}" "$SRC/../bin/innoextract" "$(command -v innoextract 2>/dev/null)" /opt/homebrew/bin/innoextract /usr/local/bin/innoextract; do
    [ -n "$c" ] && [ -x "$c" ] && { INNO="$c"; break; }
  done
  [ -n "$INNO" ] || fail "Unpacking the installer needs the innoextract tool (brew install innoextract). Or run the Might and Magic IX app (Wine version) once so it unpacks the game, then run the builder again."
  [ ! -e "$GAME" ] || fail "$GAME already exists. Move it away first if you want to start over from the installer."
  say "unpacking $INSTALLER"
  rm -rf "$SUPPORT/extract"
  logrun "$INNO" -e -s -p0 -n -d "$SUPPORT/extract" "$INSTALLER"
  [ -f "$SUPPORT/extract/lithtech.exe" ] || [ -f "$SUPPORT/extract/app/lithtech.exe" ] \
    || { rm -rf "$SUPPORT/extract"; fail "That file does not look like the GOG Might and Magic 9 installer, or it is damaged."; }
  mkdir -p "$GAME.partial"
  [ -d "$SUPPORT/extract/app" ] && cp -R "$SUPPORT/extract/app/." "$GAME.partial/"
  for f in "$SUPPORT/extract"/*; do
    case "$(basename "$f")" in app|__redist|commonappdata|tmp) ;; *) mv "$f" "$GAME.partial/" ;; esac
  done
  rm -rf "$SUPPORT/extract"
  GAME_IN="$GAME.partial"
fi
[ -d "$GAME_IN" ] || fail "Game folder not found: $GAME_IN"
done_step "$GAME_IN"

# ---------------------------------------------------------------------------------------------
step "Checking the game files"
check_game() {   # <folder>: the five code modules must be exactly GOG 1.3's
  local f h
  for f in $GAME_FILES; do
    [ -f "$1/$f" ] || { echo "$f is missing from $1"; return 1; }
    h=$(sha "$1/$f")
    [ "$h" = "$(sha_game "$f")" ] || { echo "$f in $1 is not the expected version (SHA-256 $h)"; return 1; }
  done
}
msg=$(check_game "$GAME_IN") || fail "$msg. The builder needs the GOG release of Might and Magic 9 (Writ of Fate), version 1.3: installer setup_might_and_magic_9_writ_of_fate_1.3_(31712).exe."
done_step "all five code modules match GOG 1.3"

# ---------------------------------------------------------------------------------------------
step "Preparing the game copy"
cfg_edits() {   # the same settings the Wine app uses: 800x600 (the menus only line up there), no auto-deactivate
  /usr/bin/sed -i '' -E 's/^"ScreenWidth" "[0-9.]+"/"ScreenWidth" "800"/; s/^"ScreenHeight" "[0-9.]+"/"ScreenHeight" "600"/; s/^"(AutoDeactivate|AutoDeactivation)" "[0-9.]+"/"\1" "0"/' "$1/autoexec.cfg"
}
if [ "$GAME_IN" = "$GAME" ]; then
  done_step "using the existing copy in $GAME (your native saves stay)"
else
  if [ -e "$GAME" ]; then
    msg=$(check_game "$GAME") || fail "An older game copy is in the way: $msg. Move $GAME somewhere else (it holds your native saves in SaveGames), then run the builder again."
    rm -rf "$GAME.partial"
    done_step "keeping the existing copy in $GAME (your native saves stay)"
  else
    if [ "$GAME_IN" != "$GAME.partial" ]; then
      rm -rf "$GAME.partial"
      how="APFS clone, takes no extra space"
      if ! /bin/cp -c -R "$GAME_IN" "$GAME.partial" >> "$LOG" 2>&1; then
        rm -rf "$GAME.partial"
        [ "$(free_gb "$SUPPORT")" -ge 3 ] || fail "Not enough free disk space for a copy of the game (about 1.1 GB plus the build)."
        how="full copy"
        /bin/cp -R "$GAME_IN" "$GAME.partial" >> "$LOG" 2>&1 || { rm -rf "$GAME.partial"; fail "Copying the game folder failed."; }
      fi
    else
      how="unpacked from the installer"
    fi
    [ -f "$GAME.partial/autoexec.cfg" ] && {
      cp -n "$GAME.partial/autoexec.cfg" "$GAME.partial/autoexec.cfg.orig"
      /usr/bin/sed -i '' -E 's/^"MaxFPS" "[0-9.]+"/"MaxFPS" "60"/' "$GAME.partial/autoexec.cfg"
      cfg_edits "$GAME.partial"
    }
    mv "$GAME.partial" "$GAME" || fail "Cannot create $GAME"
    done_step "$GAME ($how; saves that were there came along)"
  fi
fi
[ -f "$GAME/autoexec.cfg" ] || say "note: the game copy has no autoexec.cfg yet; the game writes one on its first exit"

# ---------------------------------------------------------------------------------------------
step "Getting the tools (Ghidra 12.1.4, Java 21, Unicorn 2.1.4)"
# fetch <name> <url> <sha256> <zip|tgz|wheel> <top folder in the archive>: unpacks into $CACHE/<name>, marked by .ok
fetch() {
  local name="$1" url="$2" want="$3" kind="$4" top="$5" file got try
  if [ -f "$CACHE/$name/.ok" ] && [ "$(cat "$CACHE/$name/.ok")" = "$want" ]; then say "$name: already here"; return 0; fi
  file="$CACHE/downloads/$name.$kind"
  mkdir -p "$CACHE/downloads"
  if [ "$(sha "$file")" != "$want" ]; then
    say "$name: downloading $url"
    for try in 1 2; do
      rm -f "$file.part"
      /usr/bin/curl -fL --retry 2 --connect-timeout 30 -# -o "$file.part" "$url" && mv -f "$file.part" "$file"
      got=$(sha "$file")
      [ "$got" = "$want" ] && break
      rm -f "$file" "$file.part"
      [ "$try" = 2 ] && fail "The download of $url failed or did not match its SHA-256 (got ${got:-nothing}). Check the internet connection and run the builder again."
      say "$name: download failed, retrying"
    done
  fi
  say "$name: unpacking"
  rm -rf "$CACHE/$name" "$CACHE/unpack"; mkdir -p "$CACHE/unpack"
  case "$kind" in
    zip)   /usr/bin/unzip -q "$file" -d "$CACHE/unpack" ;;
    tgz)   /usr/bin/tar -xzf "$file" -C "$CACHE/unpack" ;;
    wheel) /usr/bin/unzip -q "$file" 'unicorn/lib/libunicorn.a' 'unicorn/include/*' -d "$CACHE/unpack" ;;
  esac >> "$LOG" 2>&1 && mv "$CACHE/unpack/$top" "$CACHE/$name" || fail "Unpacking the $name download failed."
  rm -rf "$CACHE/unpack" "$file"
  echo "$want" > "$CACHE/$name/.ok"
}
fetch ghidra "$GHIDRA_URL" "$GHIDRA_SHA" zip "$GHIDRA_TOP"
fetch jdk "$JDK_URL" "$JDK_SHA" tgz "$JDK_TOP"
fetch unicorn "$UNICORN_URL" "$UNICORN_SHA" wheel unicorn
rmdir "$CACHE/downloads" 2>/dev/null
GH="$CACHE/ghidra"
JAVA_HOME="$CACHE/jdk/Contents/Home"
UNICORN="$CACHE/unicorn"
[ -x "$GH/support/analyzeHeadless" ] || fail "Ghidra is incomplete in $GH. Delete $CACHE and run the builder again."
[ -x "$JAVA_HOME/bin/java" ] || fail "Java is incomplete in $CACHE/jdk. Delete $CACHE and run the builder again."
[ -f "$UNICORN/lib/libunicorn.a" ] || fail "Unicorn is incomplete in $UNICORN. Delete $CACHE and run the builder again."
# Ghidra's release zip has no Apple Silicon build of its native decompiler, and without it Ghidra
# silently skips switch-table recovery (a different, untested analysis). Build it from the C++
# sources in the zip (about 15 s), as Homebrew's Ghidra does.
DECOMP="$GH/Ghidra/Features/Decompiler/os/mac_arm_64/decompile"
if [ ! -x "$DECOMP" ]; then
  say "ghidra: building its decompiler for Apple Silicon"
  rm -rf "$CACHE/decompiler-build"
  cp -R "$GH/Ghidra/Features/Decompiler/src/decompile/cpp" "$CACHE/decompiler-build" || fail "Ghidra's decompiler sources are missing."
  ( cd "$CACHE/decompiler-build" && /usr/bin/make -j "$NCPU" ghidra_opt ARCH_TYPE="-arch arm64" ADDITIONAL_FLAGS="-w" \
      CXX="/usr/bin/xcrun clang++ -std=c++11" ) >> "$LOG" 2>&1 || fail "Building Ghidra's decompiler failed."
  mkdir -p "$(dirname "$DECOMP")" && cp "$CACHE/decompiler-build/ghidra_opt" "$DECOMP" || fail "Cannot install Ghidra's decompiler."
  rm -rf "$CACHE/decompiler-build"
fi
# Ghidra uses exactly this Java, and keeps its settings and caches inside the tool cache (per module, see --ghidra-one).
/usr/bin/sed -i '' -E "s|^JAVA_HOME_OVERRIDE=.*|JAVA_HOME_OVERRIDE=$JAVA_HOME|" "$GH/support/launch.properties"
touch "$CACHE/.tools-$BUILDER_VERSION"
GHIDRA_USER="$CACHE/ghidra-user"
export GH JAVA_HOME WORK LOGDIR SRC GHIDRA_USER
export PATH="$JAVA_HOME/bin:$PATH"
export GHIDRA_HEADLESS_MAXMEM="$GH_HEAP"
"$JAVA_HOME/bin/java" -version >> "$LOG" 2>&1 || fail "The Java runtime does not start."
if [ "${MM9N_FFMPEG_DOWNLOAD:-0}" = 1 ]; then   # optional: movie support
  FF="$SUPPORT/tools/ffmpeg"
  if [ -x "$FF" ] && [ "$(cat "$FF.zip.sha" 2>/dev/null)" = "$FFMPEG_SHA" ]; then say "ffmpeg: already here"
  else
    say "ffmpeg: downloading $FFMPEG_URL"
    mkdir -p "$SUPPORT/tools" "$CACHE/downloads"
    FFZ="$CACHE/downloads/ffmpeg.zip"
    if /usr/bin/curl -fL --retry 2 --connect-timeout 30 -s -o "$FFZ" "$FFMPEG_URL" && [ "$(sha "$FFZ")" = "$FFMPEG_SHA" ] \
       && rm -f "$FF" && /usr/bin/unzip -q -o "$FFZ" ffmpeg -d "$SUPPORT/tools" >> "$LOG" 2>&1 && chmod +x "$FF" \
       && "$FF" -version >> "$LOG" 2>&1; then
      echo "$FFMPEG_SHA" > "$FF.zip.sha"; say "ffmpeg: ready in $SUPPORT/tools"
    else
      rm -f "$FF"; say "note: ffmpeg could not be downloaded; the game works without it and skips the movies (brew install ffmpeg adds them later)"
    fi
    rm -f "$FFZ"
  fi
fi
done_step "in $CACHE ($(du -sh "$CACHE" 2>/dev/null | cut -f1))"

# ---------------------------------------------------------------------------------------------
step "Rebasing the game modules"
rm -rf "$WORK/inputs"
logrun "$PY" -I "$SRC/tools/rebase.py" "$GAME" "$WORK/inputs" || fail "Rebasing failed."
for m in $MODULES; do
  [ "$(sha "$WORK/inputs/$m")" = "$(sha_rebased "$m")" ] || fail "The rebased $m is not as expected."
done
done_step "cshell.dll, object.lto and clientfx.fxd moved to their own addresses"

# ---------------------------------------------------------------------------------------------
step "Analysing the code with Ghidra (5 modules, $GJ at a time; the longest step)"
say "Java heap $GH_HEAP per module; logs: $LOGDIR/ghidra-*.log"
todo=""
for m in $MODULES; do
  p="${m//./_}"
  [ -f "$WORK/out/$p/.done" ] && [ -s "$WORK/out/$p/all.jsonl" ] || todo="$todo $m"
done
if [ -n "$todo" ]; then
  # largest first, so the parallel runs finish together
  order=""; for m in object.lto cshell.dll lithtech.exe d3d.ren clientfx.fxd; do case " $todo " in *" $m "*) order="$order $m" ;; esac; done
  printf '%s\n' $order | /usr/bin/xargs -P "$GJ" -I{} /bin/bash "$SRC/build.sh" --ghidra-one {}
fi
ref_ok=0
for m in $MODULES; do
  p="${m//./_}"
  if [ ! -f "$WORK/out/$p/.done" ]; then
    why=$(cat "$WORK/out/$p/.failed" 2>/dev/null || echo "Ghidra stopped")
    lf=$(ls -t "$LOGDIR/ghidra-$p"-*.log 2>/dev/null | head -1)
    fail "Ghidra failed on $m: $why." "$lf"
  fi
  if grep -q 'decompile does not exist' "$LOGDIR/ghidra-$p"-*.log; then
    fail "Ghidra ran without its decompiler on $m. Delete $CACHE and run the builder again." "$LOGDIR/ghidra-$p-import.log"
  fi
  line=$(cat "$WORK/out/$p/.done")
  if [ "$(sha "$WORK/out/$p/all.jsonl")" = "$(sha_ref_dump "$m")" ] && [ "$(sha "$WORK/out/$p/extra_entries.json")" = "$(sha_ref_extra "$m")" ]; then
    ref_ok=$((ref_ok + 1)); say "$line  (identical to the reference build)"
  else
    say "$line  (DIFFERS from the reference build)"
  fi
done
GHIDRA_MATCH="$ref_ok of 5 modules identical to the reference build"
done_step "$GHIDRA_MATCH"

# ---------------------------------------------------------------------------------------------
step "Translating to C"
nfn=0
for m in $MODULES; do
  p="${m//./_}"; g="$WORK/gen/$p"
  if [ ! -f "$g/.done" ]; then
    rm -rf "$g"
    "$PY" -I "$SRC/recomp/emit_rc.py" "$WORK/out/$p/all.jsonl" "$g" --extra "$WORK/out/$p/extra_entries.json" > "$LOGDIR/emit-$p.log" 2>&1 \
      || fail "Translating $m to C failed." "$LOGDIR/emit-$p.log"
    grep '^emitted' "$LOGDIR/emit-$p.log" > "$g/.done"
  fi
  say "$m: $(cat "$g/.done")"
  n=$(sed -E 's/^emitted ([0-9]+).*/\1/' "$g/.done"); nfn=$((nfn + n))
done
done_step "$nfn functions"

# ---------------------------------------------------------------------------------------------
step "Compiling ($JOBS at a time)"
INC="$SRC/recomp"
export INC
for m in $MODULES; do
  p="${m//./_}"; O="$WORK/obj/$p"; mkdir -p "$O"; export O
  t0=$(date +%s)
  n=$(find "$WORK/gen/$p" -maxdepth 1 -name '*.c' ! -name 'table.c' | wc -l | tr -d ' ')
  find "$WORK/gen/$p" -maxdepth 1 -name '*.c' ! -name 'table.c' -print0 |
    /usr/bin/xargs -0 -P "$JOBS" -I{} /bin/sh -c \
      'o="$O/$(basename "$1" .c).o"; [ "$o" -nt "$1" ] || /usr/bin/xcrun clang -arch arm64 -O2 -DRT_FIXED_MEM -w -I"$INC" -c "$1" -o "$o" || { rm -f "$o"; exit 255; }' _ {} \
      >> "$LOGDIR/compile.log" 2>&1 || fail "Compiling the C for $m failed." "$LOGDIR/compile.log"
  say "$m: $n files in $(( $(date +%s) - t0 )) s"
done
done_step

# ---------------------------------------------------------------------------------------------
step "Linking"
B="$WORK/link"; rm -rf "$B"; mkdir -p "$B/host" "$WORK/bin"
gens=(); for m in $MODULES; do gens+=("$WORK/gen/${m//./_}"); done
logrun "$PY" -I "$SRC/tools/merge_tables.py" "$B/table.c" "${gens[@]}" || fail "Merging the function tables failed."
if [ "$(sha "$B/table.c")" = "$REF_TABLE_SHA" ]; then TABLE_MATCH="identical to the reference build"; else TABLE_MATCH="DIFFERS from the reference build"; fi
logrun /usr/bin/xcrun clang -arch arm64 -O1 -w -I"$INC" -DRT_FIXED_MEM -c "$B/table.c" -o "$B/table.o" || fail "Compiling the function table failed."
for f in "$SRC"/host/*.c; do
  logrun /usr/bin/xcrun clang -arch arm64 -O2 -g -Wall -Wno-unused-function -I"$SRC/host" -I"$INC" -I"$UNICORN/include" \
    -c "$f" -o "$B/host/$(basename "$f" .c).o" || fail "Compiling the runtime ($(basename "$f")) failed."
done
for f in "$SRC"/host/*.m; do
  logrun /usr/bin/xcrun clang -arch arm64 -O2 -g -fobjc-arc -Wall -I"$SRC/host" -I"$INC" \
    -c "$f" -o "$B/host/$(basename "$f" .m).o" || fail "Compiling the runtime ($(basename "$f")) failed."
done
find "$WORK/obj" -name '*.o' > "$B/objs.txt"
logrun /usr/bin/xcrun clang -arch arm64 -o "$WORK/bin/mm9native" -filelist "$B/objs.txt" "$B/table.o" "$B"/host/*.o \
  "$UNICORN/lib/libunicorn.a" -framework Metal -framework QuartzCore -framework AppKit -framework ImageIO \
  -framework UniformTypeIdentifiers -framework CoreGraphics -framework AudioToolbox -framework CoreAudio \
  -Wl,-stack_size,0x10000000 || fail "Linking failed."
done_step "$(wc -l < "$B/objs.txt" | tr -d ' ') module objects; function table $TABLE_MATCH"

# ---------------------------------------------------------------------------------------------
step "Making the app"
A="$WORK/app/$APPNAME"; rm -rf "$WORK/app"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources/modules"
cp "$WORK/bin/mm9native" "$A/Contents/MacOS/MM9NativeGame"
for m in $MODULES; do cp "$WORK/inputs/$m" "$A/Contents/Resources/modules/"; done
ico=$(ls "$GAME"/goggame-*.ico 2>/dev/null | head -1)
iconkey=""
if [ -n "$ico" ] && logrun /usr/bin/xcrun clang -arch arm64 -O1 -fobjc-arc -framework AppKit "$SRC/tools/badge_icon.m" -o "$WORK/badge_icon" \
   && logrun "$WORK/badge_icon" "$ico" "$WORK/AppIcon.iconset" \
   && logrun "$PY" -I "$SRC/tools/icns.py" "$WORK/AppIcon.iconset" "$A/Contents/Resources/AppIcon.icns"; then
  iconkey="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  say "note: no icon (the game's goggame-*.ico was not found or could not be read)"
fi
cat > "$A/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>MM9Native</string>
	$iconkey
	<key>CFBundleIdentifier</key><string>local.mm9-native</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>MM9 Native</string>
	<key>CFBundleDisplayName</key><string>MM9 Native</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$BUILDER_VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.role-playing-games</string>
	<key>LSArchitecturePriority</key><array><string>arm64</string></array>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# The launcher: runs the game in the working copy, with the settings guard. SUPPORT is fixed at build time.
{ echo '#!/bin/bash'; printf 'SUPPORT=%q\n' "$SUPPORT"; cat <<'EOF'
# MM9 Native: made on this Mac by the MM9 Native Builder from your own copy of Might and Magic IX.
# It contains code translated from the game: do not share this app.
#   Game copy and saves: $SUPPORT/game (saves in SaveGames). Log: $SUPPORT/logs/play.log
#   Cmd+Esc releases the mouse; Ctrl+Cmd+F or the green button toggles fullscreen (remembered;
#   M1_FULLSCREEN=1/0 overrides it); Cmd+Q or closing the window quits through the game's own shutdown.
#   Movies need ffmpeg (brew install ffmpeg); without it the game skips them. Esc skips a movie.
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GAME="$SUPPORT/game"
LOG="$SUPPORT/logs/play.log"
alert() {
  /usr/bin/osascript - "$1" <<'EOS' >/dev/null 2>&1
on run argv
  display dialog (item 1 of argv) with title "MM9 Native" buttons {"OK"} default button 1 with icon caution
end run
EOS
}
[ -f "$GAME/lithtech.exe" ] || { alert "The game copy is missing ($GAME). Run the MM9 Native Builder again."; exit 1; }
cd "$GAME" || exit 1
mkdir -p "$SUPPORT/logs"
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
# Settings guard: the engine rewrites autoexec.cfg when it quits. Keep the last good file, and put it
# back if the current one lost its key bindings (e.g. a crash while writing).
if grep -q '^rangebind' autoexec.cfg 2>/dev/null; then cp autoexec.cfg autoexec.cfg.last-good
elif [ -f autoexec.cfg.last-good ]; then cp autoexec.cfg.last-good autoexec.cfg; fi
# Same as the Wine app: 800x600 (the menus only line up there; the window scales it), no auto-deactivate.
[ -f autoexec.cfg ] && /usr/bin/sed -i '' -E 's/^"ScreenWidth" "[0-9.]+"/"ScreenWidth" "800"/; s/^"ScreenHeight" "[0-9.]+"/"ScreenHeight" "600"/; s/^"(AutoDeactivate|AutoDeactivation)" "[0-9.]+"/"\1" "0"/' autoexec.cfg
[ -z "${M1_FFMPEG:-}" ] && [ -x "$SUPPORT/tools/ffmpeg" ] && export M1_FFMPEG="$SUPPORT/tools/ffmpeg"
[ -z "${M1_FFMPEG:-}" ] && [ -x /opt/local/bin/ffmpeg ] && export M1_FFMPEG=/opt/local/bin/ffmpeg
export M1_ICON="$APP/Contents/Resources/AppIcon.icns" M1_QUIET=${M1_QUIET:-1} M1_QUIET_SEC=1 M1_SECS=${M1_SECS:-100000}
exec "$APP/Contents/MacOS/MM9NativeGame" "$APP/Contents/Resources/modules" "$@" > "$LOG" 2>&1
EOF
} > "$A/Contents/MacOS/MM9Native"
chmod +x "$A/Contents/MacOS/MM9Native"
# (macOS volumes are usually case-insensitive: the game binary's name must differ from MM9Native in more than case)
/usr/bin/file "$A/Contents/MacOS/MM9NativeGame" | grep -q 'Mach-O 64-bit executable arm64' || fail "The app bundle's game binary is not an arm64 program."
cat > "$A/Contents/Resources/DO-NOT-SHARE.txt" <<'EOF'
This app was built on this Mac from your own copy of Might and Magic IX. It contains the game's
code, translated to native code, so it is a copy of the game: do not share it or upload it.
Friends can build their own with the MM9 Native Builder and their own copy of the game.
EOF
logrun /usr/bin/codesign --force --sign - "$A/Contents/MacOS/MM9NativeGame" || fail "Signing the game binary failed."
done_step "$(du -sh "$A" | cut -f1) app bundle, in the work folder for now"

# ---------------------------------------------------------------------------------------------
step "Testing the app (starts the game once, without a window, until the main menu)"
if [ "${MM9N_SKIP_SMOKETEST:-0}" = 1 ]; then
  SMOKE="skipped"; done_step "skipped (MM9N_SKIP_SMOKETEST=1)"
else
  ST="$LOGDIR/smoketest.log"
  cp -p "$GAME/autoexec.cfg" "$WORK/autoexec.cfg.before-test" 2>/dev/null
  rm -f "$GAME/m1_frame_240.png" "$LOGDIR/smoketest-menu.png"
  ( cd "$GAME" && exec env M1_OFFSCREEN=1 M1_NOSOUND=1 M1_NOMOVIES=1 M1_QUIET=1 M1_MIN_DRAWS=100 M1_SECS=3 M1_DUMP=240 \
      "$A/Contents/MacOS/MM9NativeGame" "$A/Contents/Resources/modules" ) > "$ST" 2>&1 < /dev/null &
  pid=$!
  i=0; while [ $i -lt 360 ] && kill -0 $pid 2>/dev/null; do sleep 0.25; i=$((i + 1)); done
  if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; rc=timeout; else wait $pid; rc=$?; fi
  [ -f "$WORK/autoexec.cfg.before-test" ] && cp -p "$WORK/autoexec.cfg.before-test" "$GAME/autoexec.cfg"
  [ -f "$GAME/m1_frame_240.png" ] && mv -f "$GAME/m1_frame_240.png" "$LOGDIR/smoketest-menu.png"
  if [ "$rc" = 0 ] && grep -q 'measurement window complete' "$ST"; then
    SMOKE="passed: $(grep -m1 '^\[m1\] window' "$ST" | sed 's/^\[m1\] //')"
    done_step "the game reached its main menu (picture: $LOGDIR/smoketest-menu.png)"
  else
    fail "The game did not reach its main menu in the test (exit: $rc). The unfinished app is in $WORK/app." "$ST"
  fi
fi

# ---------------------------------------------------------------------------------------------
step "Installing the app and cleaning up"
{ echo "MM9 Native Builder $BUILDER_VERSION"; echo "built $(date)"; echo "macOS $osv; $clangv"
  echo "Ghidra 12.1.4, Temurin $JDK_TOP, Unicorn 2.1.4"; echo "Ghidra output: $GHIDRA_MATCH"
  echo "function table ($nfn functions): $TABLE_MATCH"; echo "smoke test: $SMOKE"; echo "game copy: $GAME"
  echo "builder-version: $BUILDER_VERSION"; echo "builder-source: $SRC_HASH"; echo "built-unix: $(date +%s)"
  if [ -x "$SUPPORT/tools/ffmpeg" ] && [ "$(cat "$SUPPORT/tools/ffmpeg.zip.sha" 2>/dev/null)" = "$FFMPEG_SHA" ]; then echo "ffmpeg: $FFMPEG_SHA"; else echo "ffmpeg: none"; fi; } > "$A/$MARKER"
logrun /usr/bin/codesign --force --sign - "$A" || fail "Signing the app failed."
logrun /usr/bin/codesign --verify --deep --strict "$A" || fail "The app's signature does not verify."
mkdir -p "$APPDIR" || fail "Cannot create $APPDIR"
DEST="$APPDIR/$APPNAME"
if [ -e "$DEST" ]; then
  [ -f "$DEST/$MARKER" ] || fail "$DEST exists and was not made by this builder. Move it away, or set MM9N_APPDIR to another folder."
  rm -rf "$DEST"
fi
mv "$A" "$DEST" || fail "Cannot move the app to $APPDIR."
cp "$DEST/$MARKER" "$LOGDIR/build-info.txt"
if [ "${MM9N_KEEP_WORK:-0}" = 1 ]; then
  done_step "$DEST (kept the intermediate files in $WORK)"
else
  rm -rf "$WORK"
  done_step "$DEST (intermediate files removed)"
fi

secs=$(( $(date +%s) - T_START ))
if [ "$secs" -lt 60 ]; then took="$secs s"; else took="about $(( (secs + 30) / 60 )) min"; fi
cat <<EOF

Done in $took. Your app: $DEST
  - Double-click it to play (drag it to the Dock if you like). The first start shows the
    game's logo movies if ffmpeg is installed (brew install ffmpeg); Esc skips them.
  - Game copy and saves: $GAME (saves in SaveGames). Log: $LOGDIR/play.log
  - Do not share the app: it contains the game's code. Friends can run this builder themselves.
  - The tools stay in $CACHE for rebuilds
    ($(du -sh "$CACHE" 2>/dev/null | cut -f1)). Delete that folder if you need the space.
EOF
echo "=== success, $secs s" >> "$LOG"
exit 0
