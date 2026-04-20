# shellcheck shell=sh
# colors.sh — shared color-name → ANSI escape table.
#
# POSIX sh. Sourced by statusline.sh (runtime, hot path) and install.sh
# (wizard preview). Must stay POSIX so statusline.sh can source it — do
# NOT use bashisms (arrays, [[ ]], $'…').
#
# set_ansi VAR NAME
#   Assigns the ANSI escape for NAME into VAR (via eval, not command
#   substitution — avoids a subshell fork on the statusline hot path).

ESC=$(printf '\033')

# Detect color depth once at source time. The hot path (set_ansi on every
# refresh) reads $COLOR_DEPTH, so detection mustn't fork or call external
# commands repeatedly.
#
# Standards:
#   NO_COLOR       — https://no-color.org. If set (any value), suppress all
#                    ANSI color escapes, including RESET. Takes precedence.
#   FORCE_COLOR    — https://force-color.org. 0/false = suppress (same as
#                    NO_COLOR). 1/2/3 = force 16/256/truecolor. Higher than
#                    NO_COLOR in the spec? No — NO_COLOR wins.
#
# COLOR_DEPTH values: 0 = no color at all, 4 = ANSI-16, 8 = 256, 24 = truecolor.
if [ -n "${NO_COLOR:-}" ]; then
  COLOR_DEPTH=0
else
  case "${FORCE_COLOR:-}" in
    0|false|no) COLOR_DEPTH=0 ;;
    3)          COLOR_DEPTH=24 ;;
    2)          COLOR_DEPTH=8 ;;
    1|true|yes) COLOR_DEPTH=4 ;;
    *)
      case "${COLORTERM:-}" in
        truecolor|24bit) COLOR_DEPTH=24 ;;
        *)
          case "${TERM:-}" in
            dumb)          COLOR_DEPTH=0 ;;
            '')            COLOR_DEPTH=4 ;;
            *-256color|screen-256*|tmux-256*|xterm-kitty|alacritty|wezterm)
                           COLOR_DEPTH=8 ;;
            *)             COLOR_DEPTH=8 ;;
          esac
          ;;
      esac
      ;;
  esac
fi

# Matching RESET — empty when color is suppressed so NO_COLOR=1 gets zero
# ANSI bytes of any kind. Consumers reference $RESET; they no longer need
# to compute it from $ESC themselves.
# shellcheck disable=SC2034  # RESET is consumed by statusline.sh (the sourcing script); shellcheck can't see across `.` boundaries.
if [ "$COLOR_DEPTH" -le 0 ]; then
  RESET=""
else
  RESET="${ESC}[0m"
fi

# _palette VAR R G B C256 C16_SGR
#   Emits the best-supported escape for the given truecolor RGB, 256-color
#   index, and 16-color SGR fallback, based on $COLOR_DEPTH.
_palette() {
  if [ "$COLOR_DEPTH" -ge 24 ]; then
    eval "$1=\"\${ESC}[38;2;$2;$3;$4m\""
  elif [ "$COLOR_DEPTH" -ge 8 ]; then
    eval "$1=\"\${ESC}[38;5;$5m\""
  else
    eval "$1=\"\${ESC}[$6m\""
  fi
}

set_ansi() {
  # NO_COLOR / FORCE_COLOR=0 short-circuit — return empty for any name so
  # palette colors, SGR names, and raw SGR ("31", "1;33") all suppress.
  if [ "$COLOR_DEPTH" -le 0 ]; then
    eval "$1=''"
    return
  fi
  case "$2" in
    none|off|'') _v='' ;;
    # Palette — keep in sync with PALETTE in claude-newsline.js.
    amber)    _palette _v 255 193   7 214 "1;33" ;;
    coral)    _palette _v 255 127  80 209 "1;31" ;;
    pink)     _palette _v 255 105 180 213 "1;35" ;;
    mint)     _palette _v   0 255 135  48 "92"   ;;
    sky)      _palette _v 135 206 235 117 "96"   ;;
    lavender) _palette _v 177 156 217 183 "95"   ;;
    lime)     _palette _v 198 255   0 154 "92"   ;;
    # SGR-code-named colors.
    black)   _v="${ESC}[30m" ;; red)     _v="${ESC}[31m" ;;
    green)   _v="${ESC}[32m" ;; yellow)  _v="${ESC}[33m" ;;
    blue)    _v="${ESC}[34m" ;; magenta) _v="${ESC}[35m" ;;
    cyan)    _v="${ESC}[36m" ;; white)   _v="${ESC}[37m" ;;
    bright_black)   _v="${ESC}[90m" ;; bright_red)     _v="${ESC}[91m" ;;
    bright_green)   _v="${ESC}[92m" ;; bright_yellow)  _v="${ESC}[93m" ;;
    bright_blue)    _v="${ESC}[94m" ;; bright_magenta) _v="${ESC}[95m" ;;
    bright_cyan)    _v="${ESC}[96m" ;; bright_white)   _v="${ESC}[97m" ;;
    bold)        _v="${ESC}[1m" ;;
    bold_red)    _v="${ESC}[1;31m" ;; bold_green)   _v="${ESC}[1;32m" ;;
    bold_yellow) _v="${ESC}[1;33m" ;; bold_blue)    _v="${ESC}[1;34m" ;;
    bold_magenta)_v="${ESC}[1;35m" ;; bold_cyan)    _v="${ESC}[1;36m" ;;
    bold_white)  _v="${ESC}[1;37m" ;;
    dim)         _v="${ESC}[2m" ;;
    dim_red)     _v="${ESC}[2;31m" ;; dim_green)    _v="${ESC}[2;32m" ;;
    dim_yellow)  _v="${ESC}[2;33m" ;; dim_blue)     _v="${ESC}[2;34m" ;;
    dim_magenta) _v="${ESC}[2;35m" ;; dim_cyan)     _v="${ESC}[2;36m" ;;
    dim_white)   _v="${ESC}[2;37m" ;;
    *) _v="${ESC}[$2m" ;;
  esac
  eval "$1=\$_v"
}
