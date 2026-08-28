#!/usr/bin/env bash
# coding-buddy status line — animated, right-aligned multi-line companion
#
# Art rendering: the server (writeStatusState in server/state.ts) pre-bakes
# every frame with eye, hat overlay, and blink resolved, and writes them into
# status.json along with the frame-index sequence. This script is a dumb
# cycler — one jq call per tick picks the current frame body.
#
# BUDDY_FAKE_NOW env var: override wall clock for snapshot tests.
#
# Uses Braille Blank (U+2800) for padding — survives JS .trim()
#
# When running inside buddy-shell (the PTY wrapper), skip status line rendering
# so the buddy doesn't show up twice (once in status line, once in wrapper panel).
# Bash treats COLUMNS as a special variable and may refresh it from a
# controlling PTY after startup. Snapshot the exported value before any
# sourced helper or external command can trigger that refresh.
_INHERITED_COLUMNS="${COLUMNS:-}"
_INHERITED_ROWS="${LINES:-}"
# Width math and substring slicing must agree on UTF-8 codepoints. Claude Code
# emits Unicode art even when a caller inherited the POSIX C locale.
_LOCALE_HINT="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case "$_LOCALE_HINT" in
    *UTF-8|*utf-8|*utf8|*UTF8) ;;
    *)
        _UTF8_LOCALE=""
        for _candidate in C.UTF-8 en_US.UTF-8; do
            if locale -a 2>/dev/null | grep -Fx "$_candidate" >/dev/null 2>&1; then
                _UTF8_LOCALE="$_candidate"
                break
            fi
        done
        [ -n "$_UTF8_LOCALE" ] && export LC_ALL="$_UTF8_LOCALE"
        ;;
esac

[ "$BUDDY_SHELL" = "1" ] && exit 0

# shellcheck source=../scripts/paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/paths.sh"
source "$(dirname "${BASH_SOURCE[0]}")/substatus.sh"

STATE="$BUDDY_STATE_DIR/status.json"
CONFIG_FILE="$BUDDY_STATE_DIR/config.json"
# Per-session ID resolved by paths.sh (CLAUDE_CODE_SESSION_ID > TMUX_PANE > default)
SID="$BUDDY_SID"

[ -f "$STATE" ] || exit 0

# Read one field per line into the named array. jq on Windows terminates lines
# with CRLF and mapfile -t strips only the newline, so trim the carriage return
# before any caller treats a field as a number.
_jq_fields() {
    local -n _fields="$1"
    local _i
    mapfile -t _fields
    for _i in "${!_fields[@]}"; do
        _fields[$_i]="${_fields[$_i]%$'\r'}"
    done
}

# Every status field in one jq pass. A fork costs 100-400ms under Git Bash, so
# one read per field made the render cost more than the whole refresh interval.
_jq_fields _STATUS < <(jq -r '[
    (.muted // false), (.name // ""), (.rarity // "common"), (.stars // ""),
    (.shiny // false), (.achievement // ""),
    (if has("achievementAt") then (.achievementAt // 0) else "absent" end),
    (.level // 1), (.mood // "focused")
] | .[] | tostring' "$STATE" 2>/dev/null)

MUTED="${_STATUS[0]:-false}"
[ "$MUTED" = "true" ] && exit 0

NAME="${_STATUS[1]:-}"
[ -z "$NAME" ] && exit 0

RARITY="${_STATUS[2]:-common}"
STARS="${_STATUS[3]:-}"
SHINY="${_STATUS[4]:-false}"
ACHIEVEMENT="${_STATUS[5]:-}"
# "absent" distinguishes a legacy status.json (no field at all) from an explicit
# 0, which means "no achievement pending" and must not render.
ACHIEVEMENT_AT="${_STATUS[6]:-absent}"
LEVEL="${_STATUS[7]:-1}"
MOOD="${_STATUS[8]:-focused}"
REACTION_FILE="$BUDDY_STATE_DIR/reaction.$SID.json"

# Same single-pass treatment for config.json, read here once instead of in the
# three blocks further down that each used to fork their own jq.
CFG_THEME="auto"
CFG_RAINBOW=""
CFG_TTL=900
CFG_BUBBLE_W=44
CFG_MARGIN=8
CFG_WIDTH_ADJUST=0
CFG_DENSITY="auto"
if [ -f "$CONFIG_FILE" ]; then
    _jq_fields _CFG < <(jq -r '[
        (.theme // "auto"), ((.rainbowColors // []) | join(" ")),
        (.reactionTTL // 900), (.bubbleWidth // 44), (.bubbleMargin // 8),
        (.statuslineWidthAdjust // 0), (.statuslineDensity // "auto")
    ] | .[] | tostring' "$CONFIG_FILE" 2>/dev/null)
    if [ "${#_CFG[@]}" -eq 7 ]; then
        CFG_THEME="${_CFG[0]}"
        CFG_RAINBOW="${_CFG[1]}"
        CFG_TTL="${_CFG[2]}"
        CFG_BUBBLE_W="${_CFG[3]}"
        CFG_MARGIN="${_CFG[4]}"
        CFG_WIDTH_ADJUST="${_CFG[5]}"
        CFG_DENSITY="${_CFG[6]}"
    fi
fi

BUDDY_STATUSLINE_INPUT=$(cat)

# ─── Animation timing ───────────────────────────────────────────────────────
NOW=${BUDDY_FAKE_NOW:-$(date +%s)}
# The actual frame body is selected later once density/rows are known.

# ─── Rarity color (theme-aware) ─────────────────────────────────────────────
_THEME="dark"
[ "$CFG_THEME" = "light" ] && _THEME="light"

NC=$'\033[0m'
NEUTRAL=$'\033[39m'
case "$RARITY" in
  common)
    [ "$_THEME" = "light" ] && C=$'\033[38;2;90;90;90m' || C=$'\033[38;2;153;153;153m' ;;
  uncommon)
    [ "$_THEME" = "light" ] && C=$'\033[38;2;22;115;55m' || C=$'\033[38;2;78;186;101m' ;;
  rare)
    [ "$_THEME" = "light" ] && C=$'\033[38;2;55;85;210m' || C=$'\033[38;2;177;185;249m' ;;
  epic)
    [ "$_THEME" = "light" ] && C=$'\033[38;2;110;55;200m' || C=$'\033[38;2;175;135;255m' ;;
  legendary)
    [ "$_THEME" = "light" ] && C=$'\033[38;2;180;120;0m' || C=$'\033[38;2;255;193;7m' ;;
  *)         C=$'\033[0m' ;;
esac

B=$'\xe2\xa0\x80'  # Braille Blank U+2800

# ─── Rainbow colors for shiny buddies ────────────────────────────────────────
# Default ROYGBIV palette; overridden by rainbowColors in config.json
_hex_to_ansi() {
    local hex="${1#\#}"
    printf '\033[38;2;%d;%d;%dm' "$(( 16#${hex:0:2} ))" "$(( 16#${hex:2:2} ))" "$(( 16#${hex:4:2} ))"
}

RAINBOW=(
  $'\033[38;2;255;50;50m'
  $'\033[38;2;255;140;0m'
  $'\033[38;2;255;220;0m'
  $'\033[38;2;50;210;50m'
  $'\033[38;2;50;120;255m'
  $'\033[38;2;100;50;220m'
  $'\033[38;2;180;50;220m'
)

if [ -n "$CFG_RAINBOW" ]; then
    RAINBOW=()
    for _hex in $CFG_RAINBOW; do
        RAINBOW+=("$(_hex_to_ansi "$_hex")")
    done
fi

COLOR_ENABLED=1
[ -n "${NO_COLOR:-}" ] && COLOR_ENABLED=0

RAINBOW_LEN=${#RAINBOW[@]}
RAINBOW_OFFSET=$(( NOW % RAINBOW_LEN ))

_is_positive_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 0 ] 2>/dev/null && return 0
    return 1
}

# ─── Terminal size (rows + columns from the same stty size probe) ─────────────
COLS=0
ROWS=0

# Claude Code renders this command inside a content box, not across the full
# terminal. Reserve two columns for settings.json padding (1 per side) and
# twelve for Claude Code's internal left/right content margins. The 14-column
# reserve is calibrated against the reported ~74-column content box; the
# regression fixture is rendered at 60, 80, and 120 columns to assert the
# resulting budget before output.
CHROME_RESERVE=14
STATUSLINE_WIDTH_ADJUST=0

ROWS=0
COLS=0

# Rows/cols resolution precedence (real use):
#   1. BUDDY_STATUSLINE_ROWS / BUDDY_STATUSLINE_COLS (validated positive ints)
#   2. exported LINES / COLUMNS (validated positive ints)
#   3. Linux: /proc/$PID/fd/0 PTY via stty size (captures both values)
#   4. macOS: ps + stty on /dev/$TTY_NAME (captures both values)
#   5. Windows: PowerShell (Get-Host).UI.RawUI.WindowSize.Height/Width
#   6. final defaults: ROWS 999 (full), COLS 125
if _is_positive_int "${BUDDY_STATUSLINE_ROWS:-}"; then
    ROWS=$((10#${BUDDY_STATUSLINE_ROWS}))
elif _is_positive_int "$_INHERITED_ROWS"; then
    ROWS=$((10#$_INHERITED_ROWS))
fi

if _is_positive_int "${BUDDY_STATUSLINE_COLS:-}"; then
    COLS=$((10#${BUDDY_STATUSLINE_COLS}))
elif _is_positive_int "$_INHERITED_COLUMNS"; then
    COLS=$((10#$_INHERITED_COLUMNS))
fi

# If either dimension is still unknown, walk the process tree and read the
# PTY dimensions once. stty size returns "rows cols"; parse both from the same
# probe so rows and cols are consistent and no extra detection pass is needed.
if [ "$ROWS" -lt 1 ] 2>/dev/null || [ "$COLS" -lt 1 ] 2>/dev/null; then
    PID=$$
    for _ in 1 2 3 4 5; do
        PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -z "$PID" ] || [ "$PID" = "1" ] && break

        # Linux: read PTY device from /proc
        PTY=$(readlink "/proc/${PID}/fd/0" 2>/dev/null)
        if [ -c "$PTY" ] 2>/dev/null; then
            _stty=$(stty size < "$PTY" 2>/dev/null)
            if [ -n "$_stty" ]; then
                _rows=${_stty%% *}
                _cols=${_stty##* }
                [ "$ROWS" -lt 1 ] 2>/dev/null && _is_positive_int "$_rows" && ROWS=$((10#$_rows))
                [ "$COLS" -lt 1 ] 2>/dev/null && _is_positive_int "$_cols" && COLS=$((10#$_cols))
                [ "$ROWS" -gt 0 ] 2>/dev/null && [ "$COLS" -gt 0 ] 2>/dev/null && break
            fi
        fi

        # macOS: /proc doesn't exist — get TTY name from process table
        TTY_NAME=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
        if [ -n "$TTY_NAME" ] && [ "$TTY_NAME" != "??" ] && [ "$TTY_NAME" != "?" ]; then
            TTY_DEV="/dev/$TTY_NAME"
            if [ -c "$TTY_DEV" ] 2>/dev/null; then
                _stty=$(stty size < "$TTY_DEV" 2>/dev/null)
                if [ -n "$_stty" ]; then
                    _rows=${_stty%% *}
                    _cols=${_stty##* }
                    [ "$ROWS" -lt 1 ] 2>/dev/null && _is_positive_int "$_rows" && ROWS=$((10#$_rows))
                    [ "$COLS" -lt 1 ] 2>/dev/null && _is_positive_int "$_cols" && COLS=$((10#$_cols))
                    [ "$ROWS" -gt 0 ] 2>/dev/null && [ "$COLS" -gt 0 ] 2>/dev/null && break
                fi
            fi
        fi
    done
fi

[ "${COLS:-0}" -lt 1 ] 2>/dev/null && COLS=0
# Windows: /proc and TTY device detection don't exist; use PowerShell as fallback
if [ "${COLS:-0}" -lt 1 ] 2>/dev/null; then
    _ps_cols=$(powershell.exe -NoProfile -Command "(Get-Host).UI.RawUI.WindowSize.Width" 2>/dev/null | tr -d '\r\n')
    if _is_positive_int "$_ps_cols"; then
        [ "$_ps_cols" -gt 40 ] 2>/dev/null && COLS=$((10#$_ps_cols))
    fi
fi
if [ "${ROWS:-0}" -lt 1 ] 2>/dev/null; then
    _ps_rows=$(powershell.exe -NoProfile -Command "(Get-Host).UI.RawUI.WindowSize.Height" 2>/dev/null | tr -d '\r\n')
    _is_positive_int "$_ps_rows" && ROWS=$((10#$_ps_rows))
fi

[ "${COLS:-0}" -lt 1 ] 2>/dev/null && COLS=125
[ "${ROWS:-0}" -lt 1 ] 2>/dev/null && ROWS=999

COLS=$((10#$COLS))
DETECTED_COLS="$COLS"
DETECTED_ROWS="$ROWS"

# ─── Reaction bubble (with TTL check) ────────────────────────────────────────
# The achievement banner is resolved further down, once REACTION_TTL is known —
# it expires on the same clock as a reaction. Without that it latches into the
# shared status.json and pins every session's bubble to the last trophy.
BUBBLE=""
REACTION_TTL=900
INNER_W=44
MARGIN=8
DENSITY="auto"
case "$CFG_TTL" in ''|*[!0-9]*) ;; *) REACTION_TTL="$CFG_TTL" ;; esac
case "$CFG_BUBBLE_W" in ''|*[!0-9]*) ;; *) INNER_W="$CFG_BUBBLE_W" ;; esac
case "$CFG_MARGIN" in ''|*[!0-9]*) ;; *) MARGIN="$CFG_MARGIN" ;; esac
_wa="$CFG_WIDTH_ADJUST"
_wa_sign=1
case "$_wa" in
    -*) _wa_sign=-1; _wa="${_wa#-}" ;;
    +*) _wa="${_wa#+}" ;;
esac
case "$_wa" in
    ''|*[!0-9]*) ;;
    *) STATUSLINE_WIDTH_ADJUST=$(( _wa_sign * 10#$_wa )) ;;
esac
case "$CFG_DENSITY" in
    auto|full|compact|minimal) DENSITY="$CFG_DENSITY" ;;
    *) DENSITY="auto" ;;
esac
# ─── Statusline density tier ─────────────────────────────────────────────────
# Explicit config/env density overrides pin the tier; otherwise rows drive it:
#   full >= 40, compact 20-39, minimal < 20. Very narrow terminals also force minimal.
if [ -n "${BUDDY_STATUSLINE_DENSITY:-}" ]; then
    DENSITY="${BUDDY_STATUSLINE_DENSITY}"
fi
case "$DENSITY" in
    full|compact|minimal) TIER="$DENSITY" ;;
    *)
        TIER="full"
        if [ "$DETECTED_ROWS" -lt 40 ] 2>/dev/null; then
            TIER="compact"
        fi
        if [ "$DETECTED_ROWS" -lt 20 ] 2>/dev/null; then
            TIER="minimal"
        fi
        if [ "$DETECTED_COLS" -lt 40 ] 2>/dev/null; then
            TIER="minimal"
        fi
        ;;
esac

_sweep_expired_reactions() {
    [ "$REACTION_TTL" -gt 0 ] 2>/dev/null || return 0
    local now cutoff_ms cutoff_seconds file ts
    now=$(date +%s)
    cutoff_ms=$(( (now - REACTION_TTL) * 1000 ))
    cutoff_seconds=$(( now - REACTION_TTL ))

    for file in "$BUDDY_STATE_DIR"/reaction.*.json; do
        [ -f "$file" ] || continue
        ts=$(jq -r '.timestamp // 0' "$file" 2>/dev/null || echo 0)
        case "$ts" in
            ''|*[!0-9]*) rm -f "$file" 2>/dev/null ;;
            *) [ "$ts" -le "$cutoff_ms" ] 2>/dev/null && rm -f "$file" 2>/dev/null ;;
        esac
    done

    for file in "$BUDDY_STATE_DIR"/.last_comment.*; do
        [ -f "$file" ] || continue
        ts=$(cat "$file" 2>/dev/null)
        case "$ts" in
            ''|*[!0-9]*) rm -f "$file" 2>/dev/null ;;
            *) [ "$ts" -le "$cutoff_seconds" ] 2>/dev/null && rm -f "$file" 2>/dev/null ;;
        esac
    done
}

_sweep_expired_reactions

# Achievement banner: shown only while fresh. ACHIEVEMENT_AT is epoch ms, written
# alongside the name by writeStatusState. A legacy status.json without the field
# (pre-upgrade, or a snapshot fixture) is treated as fresh — the next write from
# the server backfills it.
#
# Validity and age are separate gates on purpose. A zeroed or malformed
# achievementAt means "nothing pending" and must never render, including under
# reactionTTL=0 — that opt-out disables *expiry*, not the field's meaning.
if [ -n "$ACHIEVEMENT" ] && [ "$ACHIEVEMENT" != "null" ]; then
    ACH_FRESH=1
    if [ "$ACHIEVEMENT_AT" != "absent" ]; then
        case "$ACHIEVEMENT_AT" in
            ''|0|*[!0-9]*) ACH_FRESH=0 ;;
            *)
                if [ "$REACTION_TTL" -gt 0 ] 2>/dev/null; then
                    ACH_AGE=$(( (NOW * 1000 - ACHIEVEMENT_AT) / 1000 ))
                    [ "$ACH_AGE" -ge "$REACTION_TTL" ] && ACH_FRESH=0
                fi
                ;;
        esac
    fi
    [ "$ACH_FRESH" -eq 1 ] && BUBBLE=$'\xf0\x9f\x8f\x86'" $ACHIEVEMENT"
fi

_jq_fields _REACT < <(jq -r '[(.reaction // ""), (.timestamp // 0)] | .[] | tostring' \
    "$REACTION_FILE" 2>/dev/null)
REACTION="${_REACT[0]:-}"
if [ -n "$REACTION" ] && [ "$REACTION" != "null" ]; then
    FRESH=0
    if [ "$REACTION_TTL" -eq 0 ]; then
        FRESH=1
    else
        TS="${_REACT[1]:-0}"
        if [ "$TS" != "0" ]; then
            AGE=$(( (NOW * 1000 - TS) / 1000 ))
            [ "$AGE" -lt "$REACTION_TTL" ] && FRESH=1
        fi
    fi
    if [ "$FRESH" -eq 1 ]; then
        if [ -n "$BUBBLE" ]; then
            BUBBLE="$BUBBLE | \"${REACTION}\""
        else
            BUBBLE="\"${REACTION}\""
        fi
    else
        rm -f "$REACTION_FILE" 2>/dev/null
    fi
fi

# ─── Animation: pick current density frame from server-rendered frames ───────
NOW=${BUDDY_FAKE_NOW:-$(date +%s)}
FRAME_BODY=$(jq -r --argjson now "$NOW" --arg tier "$TIER" '
    .frameSequence[$now % (.frameSequence | length)] as $idx
    | if $tier == "compact" then ((.compactFrames? // .frames) | .[$idx] // .frames[$idx])
      elif $tier == "minimal" then ((.minimalFrames? // .frames) | .[$idx] // .frames[$idx])
      else .frames[$idx]
      end // ""
' "$STATE" 2>/dev/null)

# Fallback when status.json lacks .frames — e.g. server/bash version skew
# during install or while the MCP server hasn't rewritten the file yet. Keep
# the buddy visible in a degraded form instead of emitting an empty block.
if [ -z "$FRAME_BODY" ]; then
    FRAME_BODY=$'            \n    (°°)    \n    (  )    \n            \n            '
fi

ART_LINES=()
while IFS= read -r line; do
    ART_LINES+=("$line")
done <<< "$FRAME_BODY"

# ─── Build all art lines ──────────────────────────────────────────────────────
# ART_LINES comes from the pre-rendered frame (already includes hat + blink).
# Center the name under the art. Frames are 12 cols wide (see server/art.ts),
# so the geometric center sits at col 6.
NAME_WITH_LEVEL="$NAME"
[ "$LEVEL" -gt 1 ] 2>/dev/null && NAME_WITH_LEVEL="${NAME} [L${LEVEL}]"
[ -n "$STARS" ] && NAME_WITH_LEVEL="${NAME_WITH_LEVEL} ${STARS}"
case "$MOOD" in
    happy)       MOOD_EMOJI="" ;;
    focused)     MOOD_EMOJI="" ;;
    excited)     MOOD_EMOJI="" ;;
    tired)       MOOD_EMOJI="" ;;
    melancholy)  MOOD_EMOJI="" ;;
    chaotic)     MOOD_EMOJI="" ;;
    *)           MOOD_EMOJI="" ;;
esac
NAME_WITH_LEVEL="${NAME_WITH_LEVEL}${MOOD_EMOJI}"
NAME_LEN=${#NAME_WITH_LEVEL}
ART_CENTER=6
NAME_PAD=$(( ART_CENTER - NAME_LEN / 2 ))
[ "$NAME_PAD" -lt 0 ] && NAME_PAD=0
NAME_LINE="$(printf '%*s%s' "$NAME_PAD" '' "$NAME_WITH_LEVEL")"

DIM=$'\033[2;3m'
if [ "$COLOR_ENABLED" -eq 0 ]; then
    C=""
    NC=""
    NEUTRAL=""
    DIM=""
    for _rainbow_index in "${!RAINBOW[@]}"; do
        RAINBOW[$_rainbow_index]=""
    done
fi

ALL_LINES=()
ALL_COLORS=()
_arc=0
for line in "${ART_LINES[@]}"; do
    ALL_LINES+=("$line")
    if [ "$SHINY" = "true" ]; then
        ALL_COLORS+=("${RAINBOW[$(( (_arc + RAINBOW_OFFSET) % RAINBOW_LEN ))]}")
    else
        ALL_COLORS+=("$C")
    fi
    _arc=$(( _arc + 1 ))
done
ALL_LINES+=("$NAME_LINE"); ALL_COLORS+=("$C")

ART_COUNT=${#ALL_LINES[@]}

# ─── Speech bubble (left of art, word-wrapped) ──────────────────────────────
# Strip the quotes we added earlier
BUBBLE_TEXT=""
if [ -n "$BUBBLE" ]; then
    BUBBLE_TEXT="${BUBBLE%\"}"
    BUBBLE_TEXT="${BUBBLE_TEXT#\"}"
fi

# ─── Display width (emojis count as 2 cols) ──────────────────────────────────
# iconv turns the string into a stream of UTF-32LE codepoints, then awk sums
# widths. Rules mirror server/art.ts:displayWidth; the generated data lists
# every Unicode Emoji_Presentation codepoint, while VS16 upgrades a previous
# narrow emoji to 2 cols (e.g. ❤ + VS16).
EMOJI_WIDTHS_DATA="$(dirname "${BASH_SOURCE[0]}")/emoji-widths.data"
EMOJI_PRES_2600="$(grep -v '^#' "$EMOJI_WIDTHS_DATA" 2>/dev/null | tr -d '\n')"
EMOJI_TEXT_DATA="$(dirname "${BASH_SOURCE[0]}")/emoji-text.data"
EMOJI_TEXT="$(grep -v '^#' "$EMOJI_TEXT_DATA" 2>/dev/null | tr -d '\n')"

# One awk program serves both entry points. Records are separated by newline
# codepoints inside the UTF-32 stream, so a whole batch of strings costs one
# iconv/od/awk pipeline instead of one per string — the difference between a
# 70-second render and a sub-second one on Git Bash.
_DW_AWK='
function load_ranges(value, target,    n, i, count, bounds, start, end, cp) {
    n = split(value, ranges, ",")
    for (i = 1; i <= n; i++) {
        count = split(ranges[i], bounds, "-")
        start = bounds[1] + 0
        end = (count == 2) ? bounds[2] + 0 : start
        for (cp = start; cp <= end; cp++) target[cp] = 1
    }
}
function char_width(cp) {
    if (cp in wide) return 2
    if (cp >= 9472 && cp <= 9631) return 1
    if (cp >= 12288 && cp <= 40959) return 2
    if (cp >= 65281 && cp <= 65376) return 2
    return 1
}
# profile=0 prints one total per record; profile=1 prints one width per
# codepoint and a blank line to close the record.
function flush_record() {
    if (profile) {
        for (j = 1; j <= idx; j++) print widths[j] + 0
        print ""
    } else {
        print w + 0
    }
    delete widths
    idx = 0
    w = 0
    upgradable = 0
}
BEGIN {
    load_ranges(pres, wide)
    load_ranges(text, text_default)
}
{
    for (i = 1; i <= NF; i++) {
        cp = $i + 0
        if (cp == 10) { flush_record(); continue }
        idx++
        # VS16 upgrades the preceding narrow emoji to 2 cols (e.g. ❤ + VS16)
        # and occupies no column of its own; ZWJ and the other variation
        # selectors are likewise zero-width.
        if (cp == 65039) {
            if (upgradable) { w += 1; if (idx > 1) widths[idx - 1] += 1 }
            widths[idx] = 0
            upgradable = 0
            continue
        }
        if ((cp >= 65024 && cp <= 65038) || cp == 8205) {
            widths[idx] = 0
            upgradable = 0
            continue
        }
        cw = char_width(cp)
        w += cw
        widths[idx] = cw
        upgradable = 0
        if (cw == 1 && (cp in text_default)) upgradable = 1
    }
}
'

# Display width of every string on stdin, one per line, in order. Callers must
# terminate each string with a newline; the awk records depend on it.
dwidth_many() {
    iconv -f UTF-8 -t UTF-32LE 2>/dev/null | od -An -tu4 \
        | awk -v pres="$EMOJI_PRES_2600" -v text="$EMOJI_TEXT" -v profile=0 "$_DW_AWK"
}

dwidth() {
    printf '%s\n' "$1" | dwidth_many
}

# Per-codepoint widths for every string on stdin: one width per line, a blank
# line closing each string. ANSI-aware truncation walks these to find its cut.
dwidth_profile_many() {
    iconv -f UTF-8 -t UTF-32LE 2>/dev/null | od -An -tu4 \
        | awk -v pres="$EMOJI_PRES_2600" -v text="$EMOJI_TEXT" -v profile=1 "$_DW_AWK"
}
# Art rows, label and name line measured together. Keep the label inside the
# same sprite column as the art; the exact Unicode width rules live in the
# shared awk program, so the shell and TS renderers agree on bounds.
mapfile -t _ART_WIDTHS < <(printf '%s\n' "${ART_LINES[@]}" "$NAME_WITH_LEVEL" "$NAME_LINE" \
    | dwidth_many)
ART_W=0
for _i in "${!ART_LINES[@]}"; do
    [ "${_ART_WIDTHS[$_i]:-0}" -gt "$ART_W" ] && ART_W="${_ART_WIDTHS[$_i]}"
done
LABEL_W="${_ART_WIDTHS[${#ART_LINES[@]}]:-0}"
NAME_LINE_W="${_ART_WIDTHS[$(( ${#ART_LINES[@]} + 1 ))]:-0}"
if [ "$LABEL_W" -gt "$ART_W" ] 2>/dev/null; then
    ART_W="$LABEL_W"
    NAME_PAD=$(( (ART_W - LABEL_W) / 2 ))
    NAME_LINE="$(printf '%*s%s' "$NAME_PAD" '' "$NAME_WITH_LEVEL")"
    ALL_LINES[$(( ART_COUNT - 1 ))]="$NAME_LINE"
    NAME_LINE_W=$(dwidth "$NAME_LINE")
fi
# Centering the name against a short fixture frame can make the label wider
# than every art row; include that width before sizing the card.
[ "$NAME_LINE_W" -gt "$ART_W" ] && ART_W="$NAME_LINE_W"

STATUSLINE_BUDGET=$(( DETECTED_COLS - CHROME_RESERVE + STATUSLINE_WIDTH_ADJUST ))
# Preserve the existing compact-card behavior at the smallest supported
# terminal size; the reserve applies once there is enough room for chrome.
if [ "$DETECTED_COLS" -ge 40 ] 2>/dev/null && [ "$STATUSLINE_BUDGET" -lt 40 ]; then
    STATUSLINE_BUDGET=40
fi
[ "$STATUSLINE_BUDGET" -gt "$DETECTED_COLS" ] && STATUSLINE_BUDGET="$DETECTED_COLS"

# The sprite and its identifying name are the irreducible minimum of the card.
# Never let the chrome reserve push the usable budget below the sprite's own
# width; if it does, fall back to the raw terminal width. If the terminal
# itself is narrower than the sprite, use the historical default rather than
# slicing art or name.
if [ "$STATUSLINE_BUDGET" -lt "$ART_W" ]; then
    STATUSLINE_BUDGET="$DETECTED_COLS"
fi
if [ "$STATUSLINE_BUDGET" -lt "$ART_W" ]; then
    STATUSLINE_BUDGET=125
fi
COLS="$STATUSLINE_BUDGET"

# ─── Density branch: compact drops the bubble; minimal is a single line. ─────
if [ "$TIER" = "minimal" ]; then
    _face_plain="${ART_LINES[0]:-}"
    if [ -z "$_face_plain" ]; then
        for _fline in "${ART_LINES[@]}"; do
            [ -n "$_fline" ] && _face_plain="$_fline" && break
        done
    fi
    [ -z "$_face_plain" ] && _face_plain=$'    (°°)    '
    _min_plain="${_face_plain} ${NAME_WITH_LEVEL}"
    _min_w=$(dwidth "$_min_plain")
    if [ -n "$REACTION" ]; then
        _react_plain=" │ \"${REACTION}\""
        _react_w=$(dwidth "$_react_plain")
        if [ $((_min_w + _react_w)) -le "$STATUSLINE_BUDGET" ]; then
            _min_plain="${_min_plain}${_react_plain}"
            _min_w=$(dwidth "$_min_plain")
        fi
    fi
    if [ "$STATUSLINE_BUDGET" -lt "$_min_w" ]; then
        STATUSLINE_BUDGET="$DETECTED_COLS"
    fi
    # Never widen past the real terminal: a hard-coded fallback here would
    # defeat ansi_truncate below and emit rows wider than the pane, wrapping
    # and clobbering the prompt on genuinely narrow terminals.
    if [ "$STATUSLINE_BUDGET" -lt "$_min_w" ]; then
        STATUSLINE_BUDGET="$DETECTED_COLS"
    fi
    COLS="$STATUSLINE_BUDGET"
    ART_LINES=("$_min_plain")
    ALL_COLORS=("$C")
    ALL_LINES=("$_min_plain")
    ART_COUNT=1
    ART_W="$_min_w"
    BUBBLE=""
    BUBBLE_TEXT=""
elif [ "$TIER" = "compact" ]; then
    BUBBLE=""
    BUBBLE_TEXT=""
fi

# The bubble, tail, and sprite are one unit. At narrow widths, drop the
# bubble rather than allowing a partial border or tail to escape the panel.
MIN_BUBBLE_INNER=12
TAIL_W=3
MAX_INNER=$(( COLS - ART_W - TAIL_W - 4 - MARGIN ))
if [ -n "$BUBBLE" ] && [ "$MAX_INNER" -ge "$MIN_BUBBLE_INNER" ] 2>/dev/null; then
    [ "$INNER_W" -gt "$MAX_INNER" ] && INNER_W="$MAX_INNER"
else
    BUBBLE=""
    BUBBLE_TEXT=""
fi

# ─── Word-wrap bubble text ────────────────────────────────────────────────────
TEXT_LINES=()
# Width of each wrapped line, carried out of the loop so the padding pass below
# never re-measures a string this loop already added up.
TEXT_WIDTHS=()
if [ -n "$BUBBLE_TEXT" ]; then
    read -r -a WORDS <<< "$BUBBLE_TEXT"
    mapfile -t WORD_WIDTHS < <(printf '%s\n' "${WORDS[@]}" | dwidth_many)
    CUR_LINE=""
    CUR_W=0
    for _wi in "${!WORDS[@]}"; do
        word="${WORDS[$_wi]}"
        word_w="${WORD_WIDTHS[$_wi]:-0}"
        if [ -z "$CUR_LINE" ]; then
            CUR_LINE="$word"; CUR_W=$word_w
        elif [ $(( CUR_W + 1 + word_w )) -le $INNER_W ]; then
            CUR_LINE="$CUR_LINE $word"; CUR_W=$(( CUR_W + 1 + word_w ))
        else
            TEXT_LINES+=("$CUR_LINE"); TEXT_WIDTHS+=("$CUR_W")
            CUR_LINE="$word"; CUR_W=$word_w
        fi
    done
    [ -n "$CUR_LINE" ] && { TEXT_LINES+=("$CUR_LINE"); TEXT_WIDTHS+=("$CUR_W"); }
fi

TEXT_COUNT=${#TEXT_LINES[@]}

# Build box as plain strings (no ANSI). Color applied at output time.
# Box display width = INNER_W + 4:  "| " + text(INNER_W) + " |"
BOX_W=$(( INNER_W + 4 ))
BUBBLE_LINES=()
BUBBLE_TYPES=()  # "border" or "text" — determines coloring
if [ $TEXT_COUNT -gt 0 ]; then
    # Top border
    BORDER=$(printf '%*s' "$(( BOX_W - 2 ))" '' | tr ' ' '-')
    BUBBLE_LINES+=(".${BORDER}.")
    BUBBLE_TYPES+=("border")
    # Text rows: "| text padded |"
    for _ti in "${!TEXT_LINES[@]}"; do
        tl="${TEXT_LINES[$_ti]}"
        tpad=$(( INNER_W - ${TEXT_WIDTHS[$_ti]:-0} ))
        [ "$tpad" -lt 0 ] && tpad=0
        padding=$(printf '%*s' "$tpad" '')
        BUBBLE_LINES+=("| ${tl}${padding} |")
        BUBBLE_TYPES+=("text")
    done
    # Bottom border
    BUBBLE_LINES+=("\`${BORDER}'")
    BUBBLE_TYPES+=("border")
fi

BUBBLE_COUNT=${#BUBBLE_LINES[@]}

# ─── Right-align with bubble box to the left ─────────────────────────────────
GAP=3
if [ $BUBBLE_COUNT -gt 0 ]; then
    TOTAL_W=$(( BOX_W + GAP + ART_W ))
else
    TOTAL_W=$ART_W
fi
# COLS already includes the Claude Code chrome reserve. The spacer starts with
# one Braille Blank cell, so account for that cell but don't subtract MARGIN
# again; doing so leaves the card visibly short of the pane's right edge.
PAD=$(( COLS - TOTAL_W - 1 ))
[ "$PAD" -lt 0 ] && PAD=0

# On Windows (Git Bash / MSYS2), Braille Blank (U+2800) renders as double-width,
# which doubles the spacer and pushes content off-screen. Use regular spaces instead.
case "$(uname -s)" in
    MINGW*|CYGWIN*|MSYS*) SPACER=$(printf '%*s' "$PAD" '') ;;
    *)                     SPACER=$(printf "${B}%${PAD}s" "") ;;
esac

# Minimal tier uses plain spaces so the one-line sprite + name fits without
# sacrificing a Braille Blank column on narrow terminals.
if [ "$TIER" = "minimal" ]; then
    PAD=$(( COLS - ART_W ))
    [ "$PAD" -lt 0 ] && PAD=0
    SPACER=$(printf '%*s' "$PAD" '')
fi

# Vertically center bubble box on the art
BUBBLE_START=0
if [ $BUBBLE_COUNT -gt 0 ] && [ $BUBBLE_COUNT -lt $ART_COUNT ]; then
    BUBBLE_START=$(( (ART_COUNT - BUBBLE_COUNT) / 2 ))
fi

# ─── Find the connector line (middle text line → points to buddy's mouth) ─────
# The connector goes on the middle text row of the bubble
CONNECTOR_BI=-1
if [ $BUBBLE_COUNT -gt 2 ]; then
    # text rows are indices 1..(BUBBLE_COUNT-2), pick the middle one
    FIRST_TEXT=1
    LAST_TEXT=$(( BUBBLE_COUNT - 2 ))
    CONNECTOR_BI=$(( (FIRST_TEXT + LAST_TEXT) / 2 ))
fi

# ─── Output: merged bubble box + art per line ──────────────────────────────────
TOTAL_BUBBLE=$(( BUBBLE_START + BUBBLE_COUNT ))
MAX_LINES=$(( ART_COUNT > TOTAL_BUBBLE ? ART_COUNT : TOTAL_BUBBLE ))
OUTPUT_LINES=()
for (( i=0; i<MAX_LINES; i++ )); do
    # Art part: actual art line or blank filler
    if [ $i -lt $ART_COUNT ]; then
        art_part="${ALL_COLORS[$i]}${ALL_LINES[$i]}${NC}"
    else
        art_part=$(printf '%*s' "$ART_W" '')
    fi

    if [ $BUBBLE_COUNT -gt 0 ]; then
        bi=$(( i - BUBBLE_START ))
        if [ $bi -ge 0 ] && [ $bi -lt $BUBBLE_COUNT ]; then
            bline="${BUBBLE_LINES[$bi]}"
            btype="${BUBBLE_TYPES[$bi]}"

            # Connector: "-- " on the middle text line, spaces otherwise.
            if [ $bi -eq $CONNECTOR_BI ]; then
                gap="${C}--${NC} "
            else
                gap="   "
            fi

            if [ "$btype" = "border" ]; then
                OUTPUT_LINES+=("${SPACER}${C}${bline}${NC}${gap}${art_part}")
            else
                pipe_l="${bline:0:1}"
                pipe_r="${bline: -1}"
                inner="${bline:1:$(( ${#bline} - 2 ))}"
                OUTPUT_LINES+=("${SPACER}${C}${pipe_l}${NC}${DIM}${inner}${NC}${C}${pipe_r}${NC}${gap}${art_part}")
            fi
        else
            empty=$(printf '%*s' "$BOX_W" '')
            OUTPUT_LINES+=("${SPACER}${empty}   ${art_part}")
        fi
    else
        OUTPUT_LINES+=("${SPACER}${art_part}")
    fi
done

# Strip SGR from a row, into globals so callers avoid a command substitution.
# _SGR_PLAIN carries the visible text, _SGR_SEEN whether any escape was found.
_strip_sgr() {
    local text="$1"
    local text_len=${#1}
    local i=0
    local char
    _SGR_PLAIN=""
    _SGR_SEEN=0
    while [ "$i" -lt "$text_len" ]; do
        char="${text:$i:1}"
        if [ "$char" = $'\033' ]; then
            _SGR_SEEN=1
            i=$(( i + 1 ))
            while [ "$i" -lt "$text_len" ]; do
                char="${text:$i:1}"
                i=$(( i + 1 ))
                [ "$char" = "m" ] && break
            done
            continue
        fi
        _SGR_PLAIN="${_SGR_PLAIN}${char}"
        i=$(( i + 1 ))
    done
}

# Codepoint widths for every output row in one iconv/od/awk pipeline. Measuring
# per row cost a fork per row; the flat array plus per-row offsets keeps that at
# one pipeline for the whole panel.
ROW_PLAIN=()
ROW_SGR_SEEN=()
for line in "${OUTPUT_LINES[@]}"; do
    _strip_sgr "$line"
    ROW_PLAIN+=("$_SGR_PLAIN")
    ROW_SGR_SEEN+=("$_SGR_SEEN")
done

ROW_WIDTHS=()
ROW_WIDTH_OFFSET=(0)
if [ "${#ROW_PLAIN[@]}" -gt 0 ]; then
    _row=0
    while IFS= read -r _w; do
        if [ -z "$_w" ]; then
            _row=$(( _row + 1 ))
            ROW_WIDTH_OFFSET[$_row]=${#ROW_WIDTHS[@]}
        else
            ROW_WIDTHS+=("$_w")
        fi
    done < <(printf '%s\n' "${ROW_PLAIN[@]}" | dwidth_profile_many)
fi

# Truncate row $1 to $2 columns, reading its widths out of the batch above.
ansi_truncate_row() {
    local row="$1"
    local max_width="$2"
    local text="${OUTPUT_LINES[$row]}"
    local out=""
    local i=0
    local text_len=${#text}
    local char seq char_width truncated=0
    local saw_sgr="${ROW_SGR_SEEN[$row]:-0}"
    local base="${ROW_WIDTH_OFFSET[$row]:-0}"
    local visible_width=0
    local visible_index=0

    [ "$max_width" -lt 0 ] && max_width=0

    while [ "$i" -lt "$text_len" ]; do
        char="${text:$i:1}"
        if [ "$char" = $'\033' ]; then
            seq="$char"
            i=$(( i + 1 ))
            while [ "$i" -lt "$text_len" ]; do
                char="${text:$i:1}"
                seq="${seq}${char}"
                i=$(( i + 1 ))
                [ "$char" = "m" ] && break
            done
            out="${out}${seq}"
            continue
        fi

        char_width="${ROW_WIDTHS[$(( base + visible_index ))]:-1}"
        if [ $(( visible_width + char_width )) -gt "$max_width" ]; then
            truncated=1
            break
        fi
        out="${out}${char}"
        visible_width=$(( visible_width + char_width ))
        visible_index=$(( visible_index + 1 ))
        i=$(( i + 1 ))
    done

    [ "$truncated" -eq 1 ] && [ "$saw_sgr" -eq 1 ] && out="${out}${NC}"
    printf '%s\n' "$out"
}

for _row in "${!OUTPUT_LINES[@]}"; do
    ansi_truncate_row "$_row" "$STATUSLINE_BUDGET"
done

# Append the last cached sub-status result below the buddy panel and refresh
# it asynchronously when stale. The statusline itself never waits on it.
append_substatus

exit 0
