#!/bin/sh
# claude-newsline — appends a rotating headline to your Claude Code status line.
# https://github.com/sitapix/claude-newsline
#
# Designed to be chained after your existing statusLine command:
#   "command": "your-statusline.sh ; bash ~/.claude/claude-newsline.sh"
#
# Prints one line — a label + headline from one of the enabled feeds, wrapped
# in an OSC 8 hyperlink. Stdin is ignored (the chained command upstream reads
# the JSON payload from Claude Code; we don't need it).
#
# Opt out of feeds via NEWSLINE_FEEDS_DISABLED (comma-separated names). Add
# one by writing a feed_<name>() function and appending the name to ALL_FEEDS.
#
# User-facing env vars are namespaced with a NEWSLINE_* prefix so they can't
# collide with host-shell vars (PREFIX, CACHE_FILE, and SCROLL are generic
# enough that a user's autoconf/make workflow would otherwise override them).
# Internal variable names below (SCROLL, PREFIX, …) are kept short because
# the external surface is already disambiguated by the prefix at read time.

# ============= BUILT-IN FEEDS =============
# JQ emits three tab-separated fields: label<TAB>title<TAB>url. The default
# label is passed in via --arg default, so feeds can still swap in a more
# specific label when the title starts with a known convention (e.g. HN's
# "Show HN:" / "Ask HN:" / "Tell HN:" prefixes get promoted into the label
# position so the rendered line doesn't read "HN: Show HN: ...").
feed_hn() {
  LABEL='HN'
  URL='https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30'
  # shellcheck disable=SC2016  # $default / $m are jq variables, not shell expansions — single quotes are required so jq sees them verbatim.
  JQ='.hits[] |
    select(.title != null) |
    (if (.title | test("^(Show|Ask|Tell) HN: "))
     then (.title | capture("^(?<kind>Show HN|Ask HN|Tell HN): (?<rest>.*)"))
     else {kind: $default, rest: .title}
     end) as $m |
    [$m.kind, $m.rest, "https://news.ycombinator.com/item?id=\(.objectID)"] | @tsv'
}
# Parameterized feed: called once per entry in $REDDIT_SUBS (resolved from
# $NEWSLINE_REDDIT_SUBS at config time). The dispatch loop in
# refresh_all_feeds splits the CSV and invokes this function with each entry
# as $1. Return non-zero to reject a bad entry (belt-and-braces over
# installer validation — a hand-edited .env shouldn't inject into URLs).
# Entry shapes are mirrored in bin/claude-newsline.js (SUBREDDIT_REGEX,
# USER_MULTI_REGEX, normalizeRedditEntry); the fuzz parity test keeps them
# in sync.
feed_reddit() {
  _entry=$1
  _entry=$(printf '%s' "$_entry" | tr -d '[:space:]')
  # Tolerate URL-bar copy-paste: strip a leading slash ONLY when followed
  # by "r/" or "m/" ("/m/rust+go" → "m/rust+go"), then strip the r/ or m/
  # prefix when the rest has no further slash ("m/user/multi" is ambiguous,
  # leave it for validation to reject). A bare "/foo" is NOT a Reddit URL
  # shape and won't be silently accepted. Reddit serves anonymous combined
  # feeds at both /r/a+b/ and /m/a+b/, so either prefix collapses to bare.
  case "$_entry" in
    /r/*|/m/*) _entry=${_entry#/} ;;
  esac
  case "$_entry" in
    r/*|m/*)
      _rest=${_entry#[rm]/}
      case "$_rest" in
        */*) : ;;
        *) _entry=$_rest ;;
      esac
      ;;
  esac
  case "$_entry" in
    */*)
      # Named multi: exactly one slash separates <user> and <multi>.
      # Users can contain dashes; multi names can't.
      _user=${_entry%%/*}
      _multi=${_entry#*/}
      case "$_user" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
      case "$_multi" in ''|*[!A-Za-z0-9_]*|*/*) return 1 ;; esac
      LABEL="m/$_multi"
      URL="https://www.reddit.com/user/$_user/m/$_multi/top.json?t=day&limit=30"
      ;;
    *)
      # Single sub or anonymous multi. '+' is allowed between names but
      # never at the edges or doubled.
      case "$_entry" in
        ''|*[!A-Za-z0-9_+]*|+*|*+|*++*) return 1 ;;
      esac
      LABEL="r/$_entry"
      URL="https://www.reddit.com/r/$_entry/top.json?t=day&limit=30"
      ;;
  esac
  # shellcheck disable=SC2016  # $default is a jq variable, must not expand in shell.
  JQ='.data.children[].data | [$default, .title, "https://reddit.com\(.permalink)"] | @tsv'
}
# Declare `reddit` as a parameterized feed. The dispatch loop splits the
# named *internal* variable (comma-separated, already resolved from
# $NEWSLINE_REDDIT_SUBS + default) and calls feed_reddit once per entry, so
# N subs produce N fetches from one feed. To add another parameterized
# feed: write feed_<name>() taking $1, add a config line reading
# `INTERNAL="${NEWSLINE_INTERNAL:-default}"`, and set
# FEED_PARAMS_<name>='INTERNAL'. No dispatch-loop changes needed.
FEED_PARAMS_reddit='REDDIT_SUBS'
feed_lobsters() {
  LABEL='Lobsters'
  URL='https://lobste.rs/hottest.json'
  # shellcheck disable=SC2016  # $default is a jq variable, must not expand in shell.
  JQ='.[] | select(.title != null) | [$default, .title, .short_id_url] | @tsv'
}
ALL_FEEDS='hn reddit lobsters'

# Knobs the debug report inspects — stored with the user-facing NEWSLINE_*
# names so the attribution probe below and the display loop further down
# share one vocabulary. Listed once so the env-snapshot probe and the report
# can't drift.
_DBG_VARS='NEWSLINE_FEEDS_DISABLED NEWSLINE_REDDIT_SUBS NEWSLINE_ROTATION_SEC
  NEWSLINE_REFRESH_SEC NEWSLINE_MAX_TITLE NEWSLINE_COLOR_FEED
  NEWSLINE_COLOR_PREFIX NEWSLINE_PREFIX NEWSLINE_SHOW_LABELS
  NEWSLINE_LABEL_SEP NEWSLINE_HYPERLINKS NEWSLINE_SCROLL NEWSLINE_SCROLL_SEC
  NEWSLINE_SCROLL_WIDTH NEWSLINE_SCROLL_SEPARATOR NEWSLINE_CACHE_FILE
  NEWSLINE_CACHE_CHUNK'

# Before defaults apply, record which knobs were already set in the environment
# (shell export, `env -v`, or Claude Code's settings.json → "env"). Used by the
# debug report to attribute "env" vs "default". `${VAR+set}` distinguishes
# "user explicitly cleared it" (set to empty) from "never touched".
if [ "${NEWSLINE_DEBUG:-0}" = "1" ]; then
  _DBG_ENV=" "
  for _dbg_v in $_DBG_VARS; do
    eval "_dbg_set=\${$_dbg_v+set}"
    [ "${_dbg_set:-}" = "set" ] && _DBG_ENV="$_DBG_ENV$_dbg_v "
  done
fi

# ============= CONFIG =============
# Every user-facing knob is read from its NEWSLINE_*-prefixed env var into a
# short internal name. The prefix keeps us out of the way of host-shell vars
# (PREFIX / CACHE_FILE / SCROLL all have common third-party meanings);
# internal names stay unprefixed because all downstream code is scoped to
# this script.
FEEDS_DISABLED="${NEWSLINE_FEEDS_DISABLED:-}"
# Comma-separated subreddits to pull. Each becomes its own rotation entry
# with label "r/<sub>". Names are validated to [A-Za-z0-9_]+; anything else
# is silently skipped to keep malformed env from injecting into URLs.
REDDIT_SUBS="${NEWSLINE_REDDIT_SUBS:-programming}"
ROTATION_SEC="${NEWSLINE_ROTATION_SEC:-20}"
REFRESH_SEC="${NEWSLINE_REFRESH_SEC:-600}"
MAX_TITLE="${NEWSLINE_MAX_TITLE:-60}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE_FILE="${NEWSLINE_CACHE_FILE:-$CONFIG_DIR/cache/feed-titles.txt}"

COLOR_FEED="${NEWSLINE_COLOR_FEED:-dim_yellow}"

# Brand prefix — a short glyph rendered to the left of every headline.
# Lives outside the scrolling window so it reads as a fixed mark even
# mid-transition. Takes its own color (default dim) so it doesn't compete
# with the headline. NEWSLINE_PREFIX="" disables both the glyph and its
# space — `${NEWSLINE_PREFIX-Ξ }` (no colon) distinguishes "unset" from
# "explicitly empty".
PREFIX="${NEWSLINE_PREFIX-Ξ }"
COLOR_PREFIX="${NEWSLINE_COLOR_PREFIX:-dim}"

# Source label rendering. NEWSLINE_SHOW_LABELS=0 hides the feed name entirely
# and renders just the bare headline — drop the "HN • " prefix if you
# already know where you get your news from. NEWSLINE_LABEL_SEP is the
# separator between label and title; default is " • " (U+2022) because
# ": " visually stacks with colons that appear in titles themselves
# ("HN: PopOS Linux: …" reads like a triple-layer label). Override with
# " | ", " · ", or " › " to taste; any literal string works.
SHOW_LABELS="${NEWSLINE_SHOW_LABELS:-1}"
LABEL_SEP="${NEWSLINE_LABEL_SEP:- • }"

# OSC 8 hyperlinks. auto (default) disables for Apple_Terminal, which prints
# the escape as literal text. Values: auto, always, never.
HYPERLINKS="${NEWSLINE_HYPERLINKS:-auto}"

# Scroll transition between headlines. Each rotation shows the current
# headline statically for (ROTATION_SEC - SCROLL_SEC) seconds, then scrolls
# horizontally to the next for SCROLL_SEC seconds. Claude Code refreshes at
# 1 FPS, so the "scroll" is always a stepped slide — SCROLL_SEC discrete
# frames, not a smooth glide. NEWSLINE_SCROLL=0 disables the transition
# (static rotation). NEWSLINE_SCROLL_WIDTH tracks NEWSLINE_MAX_TITLE by
# default — widen MAX_TITLE and the window follows so long titles don't
# get clipped mid-slide.
SCROLL="${NEWSLINE_SCROLL:-1}"
SCROLL_SEC="${NEWSLINE_SCROLL_SEC:-5}"
SCROLL_WIDTH="${NEWSLINE_SCROLL_WIDTH:-$MAX_TITLE}"
# ==================================

# Coerce a numeric env var to the given default if empty, non-numeric, or
# (unless "allow_zero" is passed) zero. Silent fallback is the least-surprising
# behavior on the hot path — a pasted typo must not produce "awk: division
# by zero" or "integer expression expected" on every status-line refresh,
# because Claude Code surfaces stderr so any noise becomes user-visible.
# Uses eval for indirection to avoid a subshell fork per call (5 per tick).
guard_num() {
  eval "_gn_v=\$$1"
  # shellcheck disable=SC2154  # _gn_v is assigned by the preceding `eval`.
  case "$_gn_v" in
    ''|*[!0-9]*) eval "$1=$2"; return ;;
  esac
  if [ "${3:-}" != "allow_zero" ] && [ "$_gn_v" = "0" ]; then
    eval "$1=$2"
  fi
}
guard_num ROTATION_SEC 20
guard_num REFRESH_SEC  600
guard_num MAX_TITLE    60
guard_num SCROLL_SEC   5 allow_zero
# Track MAX_TITLE for the same reason the default in the config block does —
# a user widening MAX_TITLE shouldn't have their scroll window clip long
# titles just because they pasted a garbage SCROLL_WIDTH.
guard_num SCROLL_WIDTH "$MAX_TITLE"
# Separator rendered between consecutive headlines during the scroll
# transition — gives the eye a clear boundary when one article leaves and
# the next enters. Default "  |  " (pipe, padded with two spaces each side).
# The whitespace does most of the "break" work; the pipe is just a hairline
# landmark. Swap for " ❯ ", " » ", " ◆ ", " > " etc. Unicode glyphs are OK
# — awk substr is byte-based but iconv downstream drops orphan bytes, so
# the worst case is a 1-col drift at window edges, not a broken render.
SCROLL_SEPARATOR="${NEWSLINE_SCROLL_SEPARATOR:-  |  }"
# SCROLL_SEC must not exceed ROTATION_SEC — keep at least 1s of dwell.
if [ "$SCROLL_SEC" -ge "$ROTATION_SEC" ]; then
  SCROLL_SEC=$(( ROTATION_SEC - 1 ))
  [ "$SCROLL_SEC" -lt 0 ] && SCROLL_SEC=0
fi

# FORCE_HYPERLINK is Claude Code's standard knob for OSC 8 on/off (it
# honors it before launching). We respect it as a higher-priority override
# than our own HYPERLINKS var so a user who sets FORCE_HYPERLINK=0 globally
# doesn't have to also set HYPERLINKS=never here. Unset → fall through.
case "${FORCE_HYPERLINK:-}" in
  0|false|no)  HYPERLINKS_ON=0 ;;
  1|true|yes)  HYPERLINKS_ON=1 ;;
  *)
    case "$HYPERLINKS" in
      never|off|0|false|no) HYPERLINKS_ON=0 ;;
      always|on|1|true|yes) HYPERLINKS_ON=1 ;;
      *)
        case "${TERM_PROGRAM:-}" in
          Apple_Terminal) HYPERLINKS_ON=0 ;;
          *) HYPERLINKS_ON=1 ;;
        esac
        ;;
    esac
    ;;
esac

# Follow any script symlinks so sourcing colors.sh from the same dir still
# works when $0 points through a symlink (dotfiles layouts that link
# ~/.claude/claude-newsline.sh → a repo checkout). The loop is usually 0
# iterations on a canonical install — one `[ -L ]` is a builtin test, not
# a fork, so the hot-path cost is a single stat.
_script=$0
while [ -L "$_script" ]; do
  _link=$(readlink "$_script")
  case "$_link" in
    /*) _script=$_link ;;
    # Inside the subshell, `CDPATH=;` clears CDPATH as a pure assignment
    # (not a command prefix), which avoids SC1007's false alarm while
    # still scoping the clear to this subshell only.
    *)  _script=$(CDPATH=; cd -- "$(dirname -- "$_script")" && pwd)/$_link ;;
  esac
done
_SCRIPT_DIR=$(CDPATH=; cd -- "$(dirname -- "$_script")" && pwd)
# shellcheck source=bin/colors.sh
. "$_SCRIPT_DIR/colors.sh"

TAB=$(printf '\t')

# BSD (stat -f %m) and GNU (stat -c %Y) disagree on the flag for %epoch-modified;
# try the BSD form first, fall through to GNU, degrade to 0 so the caller
# still has a number to do arithmetic with. A missing file also returns 0,
# which is exactly what the staleness check wants.
mtime_of() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

is_disabled() {
  case ",$FEEDS_DISABLED," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Byte-truncate a string to ≤$2 bytes and repair any trailing partial UTF-8
# sequence using iconv -c. Prevents the mid-codepoint mojibake (U+FFFD) that
# a naïve `printf '%.*s'` produces on non-ASCII titles. Appends "..." so the
# total byte budget matches the pre-fix behavior the tests assert on.
#
# Byte-accurate length without forking: LC_ALL=C makes bash ${#var} count
# bytes instead of codepoints (MAX_TITLE is a byte budget). The temporary
# locale only scopes the length check — head -c and iconv are byte/encoding
# operations that don't depend on LC_ALL.
truncate_title() {
  _tt_s=$1; _tt_max=$2
  # POSIX: LC_ALL='' means "use LANG" which differs from fully-unset, so
  # restore the original state rather than collapsing both to empty.
  if [ "${LC_ALL+set}" = "set" ]; then _tt_lc_was_set=1; _tt_prev_lc=$LC_ALL; else _tt_lc_was_set=0; _tt_prev_lc=; fi
  LC_ALL=C
  _tt_bytes=${#_tt_s}
  if [ "$_tt_lc_was_set" = "1" ]; then LC_ALL=$_tt_prev_lc; else unset LC_ALL; fi
  if [ "$_tt_bytes" -le "$_tt_max" ]; then
    printf '%s' "$_tt_s"
    return
  fi
  _tt_room=$(( _tt_max - 3 ))
  [ "$_tt_room" -lt 1 ] && _tt_room=1
  _tt_head=$(printf '%s' "$_tt_s" | head -c "$_tt_room" 2>/dev/null)
  # iconv -c drops invalid sequences, including a trailing incomplete
  # codepoint. Absent/old iconv → fall back to the raw byte-trimmed head.
  _tt_fixed=$(printf '%s' "$_tt_head" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)
  [ -n "$_tt_fixed" ] && _tt_head=$_tt_fixed
  printf '%s...' "$_tt_head"
}

# Parse a label<TAB>title<TAB>url cache line into globals:
#   _PL_TITLE   — title, truncated to MAX_TITLE
#   _PL_URL     — raw URL
#   _PL_PREFIX  — "label${LABEL_SEP}" or empty when SHOW_LABELS=0 / no label
# Callers copy these into local scope before invoking parse_line again.
parse_line() {
  _pl_raw=$1
  _pl_label="${_pl_raw%%"${TAB}"*}"
  _pl_rest="${_pl_raw#*"${TAB}"}"
  _PL_TITLE="${_pl_rest%%"${TAB}"*}"
  _PL_URL="${_pl_rest#*"${TAB}"}"
  _PL_TITLE=$(truncate_title "$_PL_TITLE" "$MAX_TITLE")
  if [ "$SHOW_LABELS" != "0" ] && [ -n "$_pl_label" ]; then
    _PL_PREFIX="${_pl_label}${LABEL_SEP}"
  else
    _PL_PREFIX=""
  fi
}

# Shared fetch pipeline — reads LABEL, URL, JQ from the caller's scope.
# Extracted so the reddit multi-sub loop and the single-feed path share one
# curl|jq|tr|awk stage. Pipeline: fetch → jq emits <label>\t<title>\t<url>
# (feed may promote a more specific label; $default is the fallback) →
# strip C0 control bytes (defense in depth: a compromised feed must not
# smuggle ESC sequences that would escape from inside our OSC 8 wrapper
# and hijack the terminal — keep \t=0x09 and \n=0x0A, our separators) →
# drop empties. Caller redirects stdout to the refresh tempfile.
_fetch_one() {
  curl -fsS --connect-timeout 2 --max-time 5 \
      -A "${NEWSLINE_USER_AGENT:-claude-newsline/1.0 (+https://github.com/sitapix/claude-newsline)}" \
      "$URL" 2>/dev/null \
    | jq -r --arg default "$LABEL" "$JQ" 2>/dev/null \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | awk 'NF'
}

# Fetch every enabled feed in parallel. Writes to a per-process tempfile and
# only mv's on success, so a transient fetch failure never blanks the cache.
# Caller holds the lock so concurrent invocations don't share a tempfile or
# thundering-herd the network. Feeds that declare FEED_PARAMS_<name> are
# parameterized: their env var (e.g. REDDIT_SUBS) is split on ',' and the
# feed function is called once per entry, so N values become N fetches from
# one feed definition. Plain feeds are called once.
#
# Each _fetch_one call writes to its own per-source bucket; after all fetches
# complete, the buckets are interleaved round-robin CACHE_CHUNK lines at a
# time into the real cache. Naive append would play all of HN's 30 titles
# before showing a single Reddit or Lobsters entry — with ROTATION_SEC=20
# that's 10 minutes of HN before the rotation ever visits another source.
# Chunked interleave caps the "stuck on one feed" window at CACHE_CHUNK ticks.
#
# Forks are safe because LABEL/URL/JQ are copied into each child at fork time
# — the parent loop can reassign them for the next iteration without racing
# the already-running children. Parallelism keeps worst-case refresh far under
# the 120s stale-lock reaper even as MAX_REDDIT_SUBS grows.
refresh_all_feeds() {
  tmp="$CACHE_FILE.new.$$"
  buckets="$CACHE_FILE.buckets.$$"
  mkdir -p "$buckets" 2>/dev/null
  _bucket_idx=0
  _capture_bucket() {
    _bucket_idx=$((_bucket_idx + 1))
    # Zero-padded filename so lexicographic glob expansion == fetch order.
    _idx=$(printf '%03d' $_bucket_idx)
    ( _fetch_one > "$buckets/$_idx" 2>/dev/null ) &
  }
  for f in $ALL_FEEDS; do
    is_disabled "$f" && continue
    eval "_params_var=\${FEED_PARAMS_$f:-}"
    if [ -n "$_params_var" ]; then
      # Parameterized feed: split the declared env var on ',' and call
      # feed_<name> once per entry. Bad entries return non-zero and get
      # skipped — defense in depth over installer validation.
      eval "_params_val=\${$_params_var:-}"
      _old_ifs=$IFS
      IFS=','
      # shellcheck disable=SC2086
      set -- $_params_val
      IFS=$_old_ifs
      for _p in "$@"; do
        if "feed_$f" "$_p"; then
          _capture_bucket
        fi
      done
    else
      "feed_$f"
      _capture_bucket
    fi
  done
  wait

  # Round-robin merge: CACHE_CHUNK lines per bucket per pass. Buckets exhaust
  # at different rates (HN returns 30, Lobsters 25, Reddit varies) — the
  # inner bounds check drops exhausted buckets so remaining buckets aren't
  # clumped at the tail.
  if [ "$_bucket_idx" -gt 0 ]; then
    awk -v chunk="${NEWSLINE_CACHE_CHUNK:-3}" '
      FNR == 1 { fi++ }
      { lines[fi, lc[fi]++] = $0 }
      END {
        max = 0
        for (f = 1; f <= fi; f++) if (lc[f] > max) max = lc[f]
        for (pos = 0; pos < max; pos += chunk)
          for (f = 1; f <= fi; f++)
            for (c = 0; c < chunk; c++)
              if (pos + c < lc[f]) print lines[f, pos + c]
      }
    ' "$buckets"/* > "$tmp" 2>/dev/null
  fi
  rm -rf "$buckets"
  if [ -s "$tmp" ]; then
    mv "$tmp" "$CACHE_FILE"
  else
    rm -f "$tmp"
  fi
}

# Render the horizontal-scroll transition between two composed headlines.
# The tape is `a + SCROLL_SEPARATOR + b` — offset sweeps 0..(len(a)+len(sep))
# over SCROLL_SEC frames, so offset=0 shows the start of the window (a
# leading) and the end-offset shows b starting at window column 0. The
# visible separator between consecutive headlines is fixed-width regardless
# of title length (prior impl padded each side to SCROLL_WIDTH, which
# produced a huge dead zone for short titles). No OSC 8 is emitted during
# scroll: the window rarely corresponds to a single URL.
# Reads pos_in_cycle, dwell, SCROLL_SEC, SCROLL_WIDTH, SCROLL_SEPARATOR,
# c_feed, RESET from the enclosing scope.
render_scroll_window() {
  _rs_cur=$1
  _rs_nxt=$2
  _rs_frame=$(( pos_in_cycle - dwell ))
  _rs_slide=$(( ${#_rs_cur} + ${#SCROLL_SEPARATOR} ))
  if [ "$SCROLL_SEC" -le 1 ]; then
    _rs_offset=$_rs_slide
  else
    _rs_offset=$(( _rs_frame * _rs_slide / (SCROLL_SEC - 1) ))
  fi
  # BSD awk substr() is byte-based, so a slice can bisect a multi-byte
  # codepoint and render as U+FFFD. Pipe through `iconv -c` in the same
  # subshell to drop the orphan bytes — fork-free vs the prior capture-
  # then-re-pipe pattern.
  _rs_window=$(awk -v a="$_rs_cur" -v b="$_rs_nxt" \
                   -v sep="$SCROLL_SEPARATOR" -v w="$SCROLL_WIDTH" -v o="$_rs_offset" '
    BEGIN {
      combined = a sep b
      if (length(combined) < w) combined = sprintf("%-*s", w, combined)
      print substr(combined, o + 1, w)
    }
  ' | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)
  # PREFIX sits outside the scroll window so it reads as a fixed brand
  # mark while text slides past it. Color it independently of c_feed.
  # shellcheck disable=SC2154  # c_prefix and c_feed are set by set_ansi below the function definition; render_scroll_window is only called after that.
  printf '%s%s%s%s%s%s\n' "$c_prefix" "$PREFIX" "$RESET" "$c_feed" "$_rs_window" "$RESET"
}

set_ansi c_feed "$COLOR_FEED"
set_ansi c_prefix "$COLOR_PREFIX"

now=$(date +%s)

# NEWSLINE_DEBUG=1 → print the resolved config to stdout and exit before any
# render or network work. For the "why isn't my knob applying?" question.
# Shows which knobs came from the environment vs defaults; can't disambiguate
# shell env from settings.json "env" because bash sees them merged. Output
# goes to stdout (not stderr) so users can `>>` it into a bug report.
if [ "${NEWSLINE_DEBUG:-0}" = "1" ]; then
  _dbg_src() {
    case "$_DBG_ENV" in
      *" $1 "*) printf 'env' ;;
      *)        printf 'default' ;;
    esac
  }
  _dbg_show() {
    _val=$2
    case "$_val" in '') _val='(empty)' ;; esac
    printf '  %-26s = %-25s %s\n' "$1" "$_val" "$(_dbg_src "$1")"
  }
  _dbg_std() {
    # $1=name, $2=actual value, $3=description of effect
    case "${2:-__unset__}" in
      __unset__|'') printf '  %-15s = %-12s %s\n' "$1" "(unset)" "$3" ;;
      *)            printf '  %-15s = %-12s %s\n' "$1" "$2"       "$3" ;;
    esac
  }

  echo 'claude-newsline debug'
  echo
  echo "CLAUDE_CONFIG_DIR = $CONFIG_DIR"
  echo "CACHE_FILE        = $CACHE_FILE"
  if [ -s "$CACHE_FILE" ]; then
    _dbg_lines=$(awk 'END { print NR }' "$CACHE_FILE")
    _dbg_age=$(( now - $(mtime_of "$CACHE_FILE") ))
    _dbg_fresh="fresh"
    [ "$_dbg_age" -gt "$REFRESH_SEC" ] && _dbg_fresh="stale (refresh queued)"
    echo "  status: $_dbg_lines entries, ${_dbg_age}s old ($_dbg_fresh)"
  else
    echo "  status: empty (refresh queued)"
  fi
  echo
  echo 'standards:'
  _dbg_std NO_COLOR        "${NO_COLOR:-}"        "→ COLOR_DEPTH=$COLOR_DEPTH"
  _dbg_std FORCE_COLOR     "${FORCE_COLOR:-}"     ''
  _dbg_std FORCE_HYPERLINK "${FORCE_HYPERLINK:-}" "→ HYPERLINKS_ON=$HYPERLINKS_ON"
  echo
  echo 'config (env > .env > default):'
  _dbg_show NEWSLINE_ROTATION_SEC     "$ROTATION_SEC"
  _dbg_show NEWSLINE_CACHE_CHUNK      "${NEWSLINE_CACHE_CHUNK:-3}"
  _dbg_show NEWSLINE_REFRESH_SEC      "$REFRESH_SEC"
  _dbg_show NEWSLINE_MAX_TITLE        "$MAX_TITLE"
  _dbg_show NEWSLINE_SCROLL           "$SCROLL"
  _dbg_show NEWSLINE_SCROLL_SEC       "$SCROLL_SEC"
  _dbg_show NEWSLINE_SCROLL_WIDTH     "$SCROLL_WIDTH"
  _dbg_show NEWSLINE_SCROLL_SEPARATOR "\"$SCROLL_SEPARATOR\""
  _dbg_show NEWSLINE_PREFIX           "\"$PREFIX\""
  _dbg_show NEWSLINE_COLOR_PREFIX     "$COLOR_PREFIX"
  _dbg_show NEWSLINE_COLOR_FEED       "$COLOR_FEED"
  _dbg_show NEWSLINE_SHOW_LABELS      "$SHOW_LABELS"
  _dbg_show NEWSLINE_LABEL_SEP        "\"$LABEL_SEP\""
  _dbg_show NEWSLINE_FEEDS_DISABLED   "$FEEDS_DISABLED"
  _dbg_show NEWSLINE_REDDIT_SUBS      "$REDDIT_SUBS"
  _dbg_show NEWSLINE_HYPERLINKS       "$HYPERLINKS"
  echo
  _dbg_enabled=
  for f in $ALL_FEEDS; do
    is_disabled "$f" || _dbg_enabled="$_dbg_enabled $f"
  done
  echo "feeds enabled:$_dbg_enabled"
  exit 0
fi

# Atomic-mkdir lock serializes concurrent refreshes so a fresh install
# (empty cache → every tick wants a refresh) doesn't fork a thundering
# herd of curl|jq pipelines. Foreground never blocks on network.
mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null
mtime=$(mtime_of "$CACHE_FILE")
if [ ! -s "$CACHE_FILE" ] || [ "$((now - mtime))" -gt "$REFRESH_SEC" ]; then
  lock="$CACHE_FILE.lock"
  # Reap stale locks: if a previous refresh was SIGKILLed mid-flight, the
  # lock dir sticks around forever. Bound: (MAX_REDDIT_SUBS + builtin feeds)
  # × curl --max-time 5 + slack. With the 15-sub cap plus HN+Lobsters that's
  # ~85s worst-case; 120s gives headroom. Keep this ≥ worst-case refresh or
  # concurrent refreshes can race themselves (finding M2).
  if [ -d "$lock" ]; then
    lock_mtime=$(mtime_of "$lock")
    if [ "$((now - lock_mtime))" -gt 120 ]; then
      rmdir "$lock" 2>/dev/null
    fi
  fi
  # Mirror of the lock reaper: SIGKILL mid-refresh leaves a per-pid buckets
  # dir ($CACHE_FILE.buckets.$$) that refresh_all_feeds normally removes on
  # success. Without this, killed refreshes accumulate forever.
  for _stale_buckets in "$CACHE_FILE".buckets.*; do
    [ -d "$_stale_buckets" ] || continue
    _stale_mtime=$(mtime_of "$_stale_buckets")
    [ "$((now - _stale_mtime))" -gt 120 ] && rm -rf "$_stale_buckets" 2>/dev/null
  done
  if mkdir "$lock" 2>/dev/null; then
    ( refresh_all_feeds; rmdir "$lock" 2>/dev/null ) &
  fi
fi

# Nothing cached yet → exit silently. Upstream status line still renders.
[ ! -s "$CACHE_FILE" ] && exit 0

# ASCII RS (\036) separates current from next so either field can contain
# tabs without collision. Single-line caches emit only current — scroll
# mode falls back to static automatically.
both=$(awk -F'\t' -v rs="$ROTATION_SEC" -v now="$now" '
  { a[NR] = $0 }
  END {
    if (NR > 0) {
      i = (int(now / rs) % NR) + 1
      printf "%s", a[i]
      if (NR > 1) {
        j = (i % NR) + 1
        printf "\036%s", a[j]
      }
      printf "\n"
    }
  }
' "$CACHE_FILE")
[ -z "$both" ] && exit 0

SEP=$(printf '\036')
case "$both" in
  *"${SEP}"*)
    line="${both%%"${SEP}"*}"
    next_line="${both#*"${SEP}"}"
    ;;
  *)
    line="$both"
    next_line=""
    ;;
esac

parse_line "$line"
cur_title=$_PL_TITLE
cur_url=$_PL_URL
cur_prefix=$_PL_PREFIX
[ -z "$cur_title" ] && exit 0

# Decide scroll vs static. Dwell = ROTATION_SEC - SCROLL_SEC; once past it
# within the cycle we're in the scroll transition. Requires a next line and
# a positive SCROLL_SEC, else fall back to static rendering.
pos_in_cycle=$(( now % ROTATION_SEC ))
dwell=$(( ROTATION_SEC - SCROLL_SEC ))
[ "$dwell" -lt 0 ] && dwell=0

if [ "$SCROLL" != "0" ] && [ "$SCROLL_SEC" -gt 0 ] && [ -n "$next_line" ] && [ "$pos_in_cycle" -ge "$dwell" ]; then
  parse_line "$next_line"
  render_scroll_window "${cur_prefix}${cur_title}" "${_PL_PREFIX}${_PL_TITLE}"
  exit 0
fi

if [ -n "$cur_url" ] && [ "$HYPERLINKS_ON" = "1" ]; then
  # PREFIX lives inside the OSC 8 wrapper so clicking the glyph also opens
  # the story. Color reset between prefix and feed keeps their palettes
  # independent; trailing reset closes the feed color.
  printf '\033]8;;%s\033\\%s%s%s%s%s%s%s\033]8;;\033\\\n' \
    "$cur_url" "$c_prefix" "$PREFIX" "$RESET" "$c_feed" "$cur_prefix" "$cur_title" "$RESET"
else
  printf '%s%s%s%s%s%s%s\n' \
    "$c_prefix" "$PREFIX" "$RESET" "$c_feed" "$cur_prefix" "$cur_title" "$RESET"
fi
