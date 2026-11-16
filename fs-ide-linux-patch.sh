#!/usr/bin/env bash
# Patches the GIANTS "Farming Simulator IDE Support" VS Code extension for Linux.
# - installs the official LuaLS Linux binary (same version as the bundled Windows one),
#   keeping GIANTS' patched server scripts
# - makes extension.js pick the Linux binary on non-Windows
# - replaces the PowerShell unzip of gameSource.zip with `unzip` on non-Windows
# - recommends VS Code settings for Linux (game/log/editor paths, preload limits)
#   and optionally writes them into settings.json (asks per setting, makes a backup)
#
# Usage: fs-ide-linux-patch.sh [path-to-extension-dir]
#        Without an argument, known VS Code extension folders are searched and you are asked.
#        Set NO_COLOR=1 to disable colors.
set -euo pipefail
shopt -s nullglob

EXT_GLOB="giantssoftware.farmingsimulator-ide-*"

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'
else
  B=""; D=""; R=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""
fi
P="  "          # left margin
STEPS=4

tilde()   { local p="$1"; [[ "$p" == "$HOME"* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }
boxline() { # boxline STYLE TEXT  (pads by characters, not bytes, so UTF-8 symbols line up)
  local pad=$((54 - ${#2})); [ $pad -lt 0 ] && pad=0
  printf '%s%s│%s  %s%s%s%*s  %s│%s\n' "$P" "$CYN" "$R" "$1" "$2" "$R" "$pad" "" "$CYN" "$R"
}
banner()  {
  local line="──────────────────────────────────────────────────────────"
  echo
  echo "$P${CYN}╭${line}╮${R}"
  boxline "$B" "Farming Simulator IDE Support · Linux patch"
  boxline "$D" "LuaLS Linux binary · extension.js · VS Code settings"
  echo "$P${CYN}╰${line}╯${R}"
}
step()    { echo; echo "$P${B}${BLU}[$1/$STEPS]${R} ${B}$2${R}"; echo "$P${D}──────────────────────────────────────────────────────────${R}"; }
info()    { echo "$P  ${D}•${R} $*"; }
ok()      { echo "$P  ${GRN}✓${R} $*"; }
warn()    { echo "$P  ${YEL}!${R} ${YEL}$*${R}"; }
err()     { echo "$P  ${RED}✗ $*${R}" >&2; }
kv()      { printf '%s  %s%-14s%s %s\n' "$P" "$D" "$1" "$R" "$2"; }
opt()     { printf '%s    %s[%s]%s %s%s\n' "$P" "$CYN" "$1" "$R" "$2" "${3:+  $D$3$R}"; }
blank()   { echo; }

ask() { # ask "prompt" -> answer on stdout (reads from the terminal even if stdin is piped)
  local a="" prompt="$P  ${MAG}?${R} $1 "
  if { : </dev/tty; } 2>/dev/null; then read -r -p "$prompt" a </dev/tty || true
  else read -r -p "$prompt" a || true; fi
  printf '%s' "$a"
}

banner

# --------------------------------------------------------------------------
# 1. Find extension directory
# --------------------------------------------------------------------------
step 1 "Locate the GIANTS extension"

EXT_PARENTS=(
  "${VSCODE_EXTENSIONS:-}"
  "$HOME/.vscode/extensions"
  "$HOME/.vscode-insiders/extensions"
  "$HOME/.vscode-oss/extensions"
  "$HOME/.var/app/com.visualstudio.code/data/vscode/extensions"
  "$HOME/.var/app/com.vscodium.codium/data/codium/extensions"
  "/mnt/DATA/VS-Profil-FS/ext"
)

is_ext_dir() { [ -f "$1/package.json" ] && [ -d "$1/server/lua-language-server" ] && [ -f "$1/out/extension.js" ]; }

if [ $# -ge 1 ]; then
  EXT="${1%/}"
  info "Using path from command line"
else
  FOUND=()
  for p in "${EXT_PARENTS[@]}"; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    for d in "$p"/$EXT_GLOB; do
      is_ext_dir "$d" && FOUND+=("$(readlink -f "$d")")
    done
  done
  mapfile -t FOUND < <(printf '%s\n' "${FOUND[@]}" | awk 'NF && !seen[$0]++')

  if [ ${#FOUND[@]} -eq 0 ]; then
    warn "No installation found in the default locations."
  else
    info "Found ${B}${#FOUND[@]}${R} installation(s):"
  fi
  blank
  for i in "${!FOUND[@]}"; do opt "$((i + 1))" "$(tilde "${FOUND[$i]}")"; done
  opt a "enter a different path"
  opt q "quit"
  blank
  DEF=""; [ ${#FOUND[@]} -ge 1 ] && DEF=1
  CHOICE="$(ask "Choice${DEF:+ ${D}[$DEF]${R}}:")"; CHOICE="${CHOICE:-$DEF}"

  case "$CHOICE" in
    q|Q|"") blank; info "Aborted."; blank; exit 0 ;;
    a|A)    EXT="$(ask "Path to the extension folder ${D}(${EXT_GLOB})${R}:")"
            EXT="${EXT/#\~/$HOME}"; EXT="${EXT%/}" ;;
    *)      if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#FOUND[@]} ]; then
              EXT="${FOUND[$((CHOICE - 1))]}"
            else
              err "Invalid choice: $CHOICE"; exit 1
            fi ;;
  esac
fi

if ! is_ext_dir "$EXT"; then
  err "Not a valid extension folder: $EXT"
  err "(expected: package.json, out/extension.js, server/lua-language-server/)"
  exit 1
fi

SRV="$EXT/server/lua-language-server"
JS="$EXT/out/extension.js"

# --------------------------------------------------------------------------
# 2. Install LuaLS Linux binary + patch extension.js
# --------------------------------------------------------------------------
step 2 "Patch the extension"

# LuaLS version bundled by GIANTS (from their changelog marker)
VER="$(grep -m1 -oP '^## \K[0-9.]+' "$SRV/changelog.md")"
kv "Extension"  "$(tilde "$EXT")"
kv "LuaLS"      "$VER ${D}(bundled version)${R}"
blank

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading LuaLS $VER for linux-x64 …"
if ! curl -sSLf -o "$TMP/luals.tar.gz" \
     "https://github.com/LuaLS/lua-language-server/releases/download/$VER/lua-language-server-$VER-linux-x64.tar.gz"; then
  err "Download failed (no internet, or release $VER not available for Linux)."; exit 1
fi
tar xzf "$TMP/luals.tar.gz" -C "$TMP" bin/lua-language-server
install -m 755 "$TMP/bin/lua-language-server" "$SRV/bin/lua-language-server"
ok "Linux binary installed ${D}→ server/lua-language-server/bin/lua-language-server${R}"

if [ -f "$JS.orig" ]; then
  info "Backup of extension.js already exists ${D}(extension.js.orig)${R}"
else
  cp "$JS" "$JS.orig"; ok "Backup created ${D}→ out/extension.js.orig${R}"
fi

PATCH_OUT="$(python3 - "$JS" <<'EOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
reps = [
    ("LuaLS path: use binary without .exe on Linux",
     '"bin","lua-language-server.exe")',
     '"bin",process.platform==="win32"?"lua-language-server.exe":"lua-language-server")'),
    ("gameSource.zip: unzip instead of PowerShell on Linux",
     'try{(0,D1.execFileSync)("powershell.exe",',
     'try{process.platform!=="win32"?(0,D1.execFileSync)("unzip",["-o","-q",t,"-d",n],{timeout:3e4}):(0,D1.execFileSync)("powershell.exe",'),
]
for name, old, new in reps:
    if new in s:
        print(f"skip\t{name}"); continue
    if s.count(old) != 1:
        sys.exit(f"pattern not found exactly once (extension version changed?): {name}")
    s = s.replace(old, new)
    print(f"ok\t{name}")
open(p, "w", encoding="utf-8").write(s)
EOF
)" || { err "Patching extension.js failed - see message above."; exit 1; }
while IFS=$'\t' read -r st name; do
  if [ "$st" = ok ]; then ok "Patched: $name"; else info "Already patched: $name"; fi
done <<< "$PATCH_OUT"

if command -v node >/dev/null && node --check "$JS" 2>/dev/null; then
  ok "extension.js syntax check passed"
else
  warn "node not found or syntax check failed - please check extension.js manually"
fi
if LUALS_VER="$("$SRV/bin/lua-language-server" --version 2>/dev/null)"; then
  ok "Language server runs ${D}(version ${LUALS_VER})${R}"
else
  warn "Language server did not start - check $(tilde "$SRV/bin/lua-language-server")"
fi

# --------------------------------------------------------------------------
# 3. Detect paths and recommend VS Code settings
# --------------------------------------------------------------------------
step 3 "Detect game, log and editor paths"

FS25_APPID=2300320
uniq_lines() { awk 'NF && !seen[$0]++'; }
newest_first() { # sort existing files by mtime, newest first
  local f; for f in "$@"; do [ -e "$f" ] && printf '%s\t%s\n' "$(stat -c %Y "$f")" "$f"; done | sort -rn | cut -f2-
}

GAME_CANDS=(); LOG_CANDS=(); EDITOR_CANDS=()

# Steam (native + Flatpak), all library folders from libraryfolders.vdf
STEAM_ROOTS=(
  "$HOME/.local/share/Steam"
  "$HOME/.steam/steam"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
)
LIBS=()
for r in "${STEAM_ROOTS[@]}"; do
  [ -d "$r/steamapps" ] || continue
  LIBS+=("$r")
  if [ -f "$r/steamapps/libraryfolders.vdf" ]; then
    while IFS= read -r l; do LIBS+=("$l"); done \
      < <(grep -oP '"path"\s+"\K[^"]+' "$r/steamapps/libraryfolders.vdf")
  fi
done
mapfile -t LIBS < <(printf '%s\n' "${LIBS[@]}" | xargs -r -d '\n' -n1 readlink -f 2>/dev/null | uniq_lines)
for l in "${LIBS[@]}"; do
  g="$l/steamapps/common/Farming Simulator 25"
  [ -d "$g/data" ] && GAME_CANDS+=("$g/")
  LOG_CANDS+=("$l/steamapps/compatdata/$FS25_APPID/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/log.txt")
done

# Bottles (Flatpak + native) and plain Wine prefixes
WINE_PREFIXES=(
  "$HOME"/.var/app/com.usebottles.bottles/data/bottles/bottles/*
  "$HOME"/.local/share/bottles/bottles/*
  "$HOME/.wine"
)
for pfx in "${WINE_PREFIXES[@]}"; do
  [ -d "$pfx/drive_c" ] || continue
  for g in "$pfx"/drive_c/Program\ Files*/Farming\ Simulator\ 2025 \
           "$pfx"/drive_c/Program\ Files*/Farming\ Simulator\ 25; do
    [ -d "$g/data" ] && GAME_CANDS+=("$g/")
  done
  LOG_CANDS+=("$pfx"/drive_c/users/*/Documents/My\ Games/FarmingSimulator2025/log.txt)
  for e in "$pfx"/drive_c/Program\ Files*/GIANTS\ Software/GIANTS_Editor_*; do
    [ -d "$e" ] && EDITOR_CANDS+=("$e/")
  done
done

mapfile -t GAME_CANDS   < <(printf '%s\n' "${GAME_CANDS[@]}" | uniq_lines)
mapfile -t LOG_CANDS    < <(newest_first "${LOG_CANDS[@]}" | uniq_lines)            # most recently written first
mapfile -t EDITOR_CANDS < <(printf '%s\n' "${EDITOR_CANDS[@]}" | sort -rV | uniq_lines) # newest version first

U="$USER"
EX_EDITOR="/home/$U/.var/app/com.usebottles.bottles/data/bottles/bottles/<BOTTLENAME>/drive_c/Program Files/GIANTS Software/GIANTS_Editor_10.0.XX/"
EX_LOG="/home/$U/.local/share/Steam/steamapps/compatdata/$FS25_APPID/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/log.txt"
EX_GAME="/home/$U/.local/share/Steam/steamapps/common/Farming Simulator 25/"

first_or() { if [ $# -gt 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; } # first_or EXAMPLE CANDS...
show() { # show "setting" "example" cands...
  local key="$1" ex="$2"; shift 2
  echo "$P  ${B}$key${R}"
  if [ $# -gt 0 ]; then
    local more=""; [ $# -gt 1 ] && more=" ${D}(+$(($# - 1)) more)${R}"
    echo "$P    ${GRN}✓${R} $(tilde "$1")$more"
  else
    echo "$P    ${YEL}?${R} ${D}$(tilde "$ex")  (example - not detected)${R}"
  fi
}
show_num() { printf '%s  %s%-26s%s %s%-6s%s %s\n' "$P" "$B" "$1" "$R" "$GRN" "$2" "$R" "${D}$3${R}"; }

HAS_SUMNEKO=""
for d in "$(dirname "$EXT")"/sumneko.lua-*; do HAS_SUMNEKO=1; done

info "Recommended VS Code settings:"
blank
show "fsLua.editorPath"  "$EX_EDITOR" "${EDITOR_CANDS[@]}"
show "fsLua.gameLogPath" "$EX_LOG"    "${LOG_CANDS[@]}"
show "fsLua.gamePath"    "$EX_GAME"   "${GAME_CANDS[@]}"
blank
show_num "fsLua.maxPreload"      10000 "(default 2500)"
show_num "fsLua.preloadFileSize" 2048  "(default 500)"
if [ -n "$HAS_SUMNEKO" ]; then
  show_num "Lua.workspace.maxPreload" 10000 "(sumneko Lua extension is installed)"
fi

blank
echo "$P  ${B}Notes${R}"
echo "$P  ${D}• editorPath / gamePath can also be set via 'FS Lua: Set Editor Path' / 'FS Lua: Set Game Path'.${R}"
echo "$P  ${D}• gameLogPath must point to the log.txt file itself (a folder does not work);${R}"
echo "$P  ${D}  alternatively use 'FS Lua: Select Game Log'.${R}"

blank
echo "$P  ${B}settings.json snippet${R}"
{
  echo "\"fsLua.editorPath\": \"$(first_or "$EX_EDITOR" "${EDITOR_CANDS[@]}")\","
  echo "\"fsLua.gameLogPath\": \"$(first_or "$EX_LOG" "${LOG_CANDS[@]}")\","
  echo "\"fsLua.gamePath\": \"$(first_or "$EX_GAME" "${GAME_CANDS[@]}")\","
  echo "\"fsLua.maxPreload\": 10000,"
  echo "\"fsLua.preloadFileSize\": 2048,"
  if [ -n "$HAS_SUMNEKO" ]; then echo '"Lua.workspace.maxPreload": 10000,'; fi
} | while IFS= read -r line; do echo "$P  ${D}│${R} ${CYN}$line${R}"; done

# --------------------------------------------------------------------------
# 4. Optionally write the settings into settings.json
# --------------------------------------------------------------------------
step 4 "Update settings.json ${D}(optional)${R}"

A="$(ask "Apply these settings to your VS Code settings.json now? ${D}[y/N]${R}")"
if [[ ! "$A" =~ ^[yY] ]]; then
  info "Settings not changed."
  blank; ok "${B}Done.${R} Restart VS Code (or run 'FS Lua: Restart Language Server')."; blank
  exit 0
fi

# VS Code user-data dir belonging to the chosen extensions dir
EXT_PARENT="$(dirname "$EXT")"
case "$EXT_PARENT" in
  "$HOME/.vscode/extensions")          UD="$HOME/.config/Code" ;;
  "$HOME/.vscode-insiders/extensions") UD="$HOME/.config/Code - Insiders" ;;
  "$HOME/.vscode-oss/extensions")      UD="$HOME/.config/VSCodium" ;;
  */com.visualstudio.code/data/vscode/extensions) UD="$HOME/.var/app/com.visualstudio.code/config/Code" ;;
  */com.vscodium.codium/data/codium/extensions)   UD="$HOME/.var/app/com.vscodium.codium/config/VSCodium" ;;
  */data/extensions)                   UD="$(dirname "$EXT_PARENT")/user-data" ;;   # portable mode
  *)                                   UD="$(dirname "$EXT_PARENT")" ;;             # --user-data-dir with ext/ inside
esac

SET_CANDS=()
[ -d "$UD/User" ] && SET_CANDS+=("$UD/User/settings.json")
for f in "$UD"/User/profiles/*/settings.json; do SET_CANDS+=("$f"); done

blank
info "Which settings.json should be updated?"
blank
for i in "${!SET_CANDS[@]}"; do
  note=""; [[ "${SET_CANDS[$i]}" == */profiles/* ]] && note="VS Code profile"
  [ -f "${SET_CANDS[$i]}" ] || note="will be created"
  opt "$((i + 1))" "$(tilde "${SET_CANDS[$i]}")" "$note"
done
opt c "enter a different path"
opt q "skip"
blank
DEF=""; [ ${#SET_CANDS[@]} -ge 1 ] && DEF=1
CHOICE="$(ask "Choice${DEF:+ ${D}[$DEF]${R}}:")"; CHOICE="${CHOICE:-$DEF}"
case "$CHOICE" in
  q|Q|"") info "Settings not changed."; blank; exit 0 ;;
  c|C)    SETTINGS="$(ask "Path to settings.json:")"; SETTINGS="${SETTINGS/#\~/$HOME}" ;;
  *)      if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#SET_CANDS[@]} ]; then
            SETTINGS="${SET_CANDS[$((CHOICE - 1))]}"
          else
            err "Invalid choice: $CHOICE"; exit 1
          fi ;;
esac
[ -n "$SETTINGS" ] && [ -d "$(dirname "$SETTINGS")" ] || { err "Folder does not exist: $(dirname "$SETTINGS")"; exit 1; }

# Small JSONC (JSON with comments / trailing commas) editor: changes only the
# affected values, keeps comments and formatting of everything else.
PY="$TMP/jsonc_settings.py"
cat > "$PY" <<'EOF'
import json, os, re, sys

LIT = re.compile(r'[^\s{}\[\]:,"/]+')

def tokenize(s):
    toks, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in ' \t\r\n﻿':
            i += 1
        elif s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            toks.append(('s', i, j + 1)); i = j + 1
        elif c in '{}[]:,':
            toks.append((c, i, i + 1)); i += 1
        else:
            m = LIT.match(s, i)
            if not m:
                sys.exit(f"cannot parse settings file near offset {i}")
            toks.append(('l', i, m.end())); i = m.end()
    return toks

def analyze(s):
    toks = tokenize(s)
    if not toks or toks[0][0] != '{':
        sys.exit("settings file is not a JSON object")
    scalars, keys, depth, close = {}, set(), 0, None
    for k, (typ, a, b) in enumerate(toks):
        if typ in ('{', '['):
            depth += 1
        elif typ in ('}', ']'):
            depth -= 1
            if depth == 0:
                close = k; break
        elif (typ == 's' and depth == 1 and toks[k - 1][0] in ('{', ',')
              and k + 2 < len(toks) and toks[k + 1][0] == ':'):
            key = json.loads(s[a:b]); keys.add(key)
            v = toks[k + 2]
            if v[0] in ('s', 'l'):
                scalars[key] = (v[1], v[2])
    if close is None:
        sys.exit("settings file: missing closing brace")
    return toks, scalars, keys, close

def load(path):
    if not os.path.exists(path):
        return '{\n}\n'
    with open(path, encoding='utf-8') as f:
        return f.read()

mode, path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
s = load(path)
toks, scalars, keys, close = analyze(s)

if mode == 'get':
    for key in args:
        if key in scalars:
            a, b = scalars[key]
            v = json.loads(s[a:b])
            print(f"{key}\t{v if isinstance(v, str) else s[a:b]}")
    sys.exit(0)

# mode == 'set': args = key type value key type value ...
edits, new = [], []
for i in range(0, len(args), 3):
    key, typ, val = args[i:i + 3]
    lit = json.dumps(val, ensure_ascii=False) if typ == 'str' else str(int(val))
    if key in scalars:
        edits.append((*scalars[key], lit))
    elif key in keys:
        print(f"skipped {key}: existing value is not a plain value", file=sys.stderr)
    else:
        new.append((key, lit))

if new:
    indent = '    '
    first_key = next((t for t in toks[1:close] if t[0] == 's'), None)
    if first_key:
        ls = s.rfind('\n', 0, first_key[1]) + 1
        if s[ls:first_key[1]].strip() == '':
            indent = s[ls:first_key[1]]
    prev = toks[close - 1]
    # insert new keys at the end of that line (after a trailing // comment, if any)
    pos = prev[2]
    eol = s.find('\n', pos)
    if eol != -1 and eol < toks[close][1]:
        pos = eol
    text = ','.join(f'\n{indent}{json.dumps(k, ensure_ascii=False)}: {v}' for k, v in new)
    if prev[0] not in ('{', ','):                    # comma right after the last value
        if pos == prev[2]:
            text = ',' + text
        else:
            edits.append((prev[2], prev[2], ','))
    if '\n' not in s[pos:toks[close][1]]:
        text += '\n'
    edits.append((pos, pos, text))

for a, b, t in sorted(edits, key=lambda e: e[0], reverse=True):
    s = s[:a] + t + s[b:]
analyze(s)  # sanity check before writing
with open(path, 'w', encoding='utf-8') as f:
    f.write(s)
EOF

CUR_OUT="$(python3 "$PY" get "$SETTINGS" fsLua.editorPath fsLua.gameLogPath fsLua.gamePath \
           fsLua.maxPreload fsLua.preloadFileSize Lua.workspace.maxPreload)" \
  || { err "Could not read $SETTINGS - please edit it manually."; exit 1; }
declare -A CUR=()
while IFS=$'\t' read -r k v; do [ -n "$k" ] && CUR["$k"]="$v"; done <<< "$CUR_OUT"

CHANGES=()   # key type value ...
PICKED=""

# pick_path KEY CANDIDATES... -> PICKED (empty = no change)
pick_path() {
  local key="$1"; shift
  local cur="${CUR[$key]:-}" cands=("$@") i a def mark
  PICKED=""
  blank
  echo "$P  ${B}$key${R}"
  printf '%s    %scurrent%s  %s\n' "$P" "$D" "$R" "$( [ -n "$cur" ] && tilde "$cur" || echo "${D}(not set)${R}")"
  if [ "$key" = "fsLua.gameLogPath" ] && [ -n "$cur" ] && [ -d "$cur" ]; then
    warn "  current value is a folder - the extension needs the log.txt file"
    cands=("${cur%/}/log.txt" "${cands[@]}")
  fi
  mapfile -t cands < <(printf '%s\n' "${cands[@]}" | uniq_lines)
  for i in "${!cands[@]}"; do
    mark=""; [ "${cands[$i]%/}" = "${cur%/}" ] && mark="current"
    opt "$((i + 1))" "$(tilde "${cands[$i]}")" "$mark"
  done
  opt c "enter a custom path"
  opt k "keep current / skip"
  def=k; [ -z "$cur" ] && [ ${#cands[@]} -gt 0 ] && def=1
  a="$(ask "Choice ${D}[$def]${R}:")"; a="${a:-$def}"
  case "$a" in
    k|K) return 0 ;;
    c|C) a="$(ask "Path:")"; PICKED="${a/#\~/$HOME}" ;;
    *)   if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le ${#cands[@]} ]; then
           PICKED="${cands[$((a - 1))]}"
         else
           warn "Invalid choice, keeping current."; return 0
         fi ;;
  esac
  if [ "$key" = "fsLua.gameLogPath" ] && [ -d "$PICKED" ]; then
    PICKED="${PICKED%/}/log.txt"; info "using $(tilde "$PICKED")"
  fi
  if [ -n "$PICKED" ] && [ ! -e "$PICKED" ]; then warn "$(tilde "$PICKED") does not exist (yet)"; fi
  [ "${PICKED%/}" = "${cur%/}" ] && PICKED=""
  if [ -n "$PICKED" ]; then CHANGES+=("$key" str "$PICKED"); fi
  return 0
}

# pick_num KEY VALUE
pick_num() {
  local key="$1" new="$2" cur="${CUR[$1]:-}" a
  if [ "$cur" = "$new" ]; then
    printf '%s  %s%-26s%s %-6s %s✓ already set%s\n' "$P" "$B" "$key" "$R" "$new" "$GRN" "$R"; return 0
  fi
  printf '%s  %s%-26s%s %s → %s%s%s\n' "$P" "$B" "$key" "$R" "${cur:-${D}(not set)${R}}" "$GRN" "$new" "$R"
  a="$(ask "Set ${B}$key${R} to $new? ${D}[Y/n]${R}")"
  if [[ ! "$a" =~ ^[nN] ]]; then CHANGES+=("$key" num "$new"); fi
  return 0
}

pick_path fsLua.editorPath  "${EDITOR_CANDS[@]}"
pick_path fsLua.gameLogPath "${LOG_CANDS[@]}"
pick_path fsLua.gamePath    "${GAME_CANDS[@]}"
blank
pick_num  fsLua.maxPreload      10000
pick_num  fsLua.preloadFileSize 2048
if [ -n "$HAS_SUMNEKO" ] || [ -n "${CUR[Lua.workspace.maxPreload]:-}" ]; then
  pick_num Lua.workspace.maxPreload 10000
fi

blank
if [ ${#CHANGES[@]} -eq 0 ]; then
  ok "Nothing to change in $(tilde "$SETTINGS")"
  blank; ok "${B}Done.${R} Restart VS Code (or run 'FS Lua: Restart Language Server')."; blank
  exit 0
fi
info "Changes for ${B}$(tilde "$SETTINGS")${R}:"
blank
for ((i = 0; i < ${#CHANGES[@]}; i += 3)); do
  v="${CHANGES[$((i + 2))]}"; [ "${CHANGES[$((i + 1))]}" = str ] && v="$(tilde "$v")"
  printf '%s    %s%-26s%s %s\n' "$P" "$CYN" "${CHANGES[$i]}" "$R" "$v"
done
blank
A="$(ask "Write these changes? ${D}[Y/n]${R}")"
if [[ "$A" =~ ^[nN] ]]; then info "Settings not changed."; blank; exit 0; fi

blank
if [ -f "$SETTINGS" ]; then
  BAK="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$BAK"
  ok "Backup created ${D}→ $(tilde "$BAK")${R}"
fi
python3 "$PY" set "$SETTINGS" "${CHANGES[@]}"
ok "Settings written ${D}(VS Code picks them up automatically)${R}"
blank
ok "${B}Done.${R} Restart VS Code (or run 'FS Lua: Restart Language Server')."
blank
