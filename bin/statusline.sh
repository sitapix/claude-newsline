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
# Feed metadata. Free-form `key=value` lines, parsed only by the debug report
# (NEWSLINE_DEBUG=1) and the installer's --list-feeds. Not consulted on the
# hot render path, so adding more keys in the future is free.
# Recognized keys:
#   api         — plugin-contract version the file was written against.
#                 See FEED_API_VERSION below. Absent or non-numeric is
#                 treated as api=1 for backward compatibility.
#   category    — grouping label shown in `--list-feeds -v`. Free-form;
#                 no enforcement. Defaults to "Custom" in the installer
#                 when absent from a user plugin.
#   description, version, author, homepage — free-form; surfaced by
#                 --list-feeds -v. Everything here is informational.
#   source      — auto-attached at load time for user feeds; built-ins
#                 set it explicitly to "built-in" so the debug report
#                 never shows a blank provenance for them.
# A feed with no FEED_META is still valid — all keys are optional.
#
# Plugin-contract version. Bumped when `feed_<name>()` grows a new
# required global, when FEED_PARAMS semantics change, or when the JQ TSV
# shape changes. User plugins that declare `api=N` with N > this value
# are skipped at load time (load_user_feeds). Absent / non-numeric `api`
# is treated as 1. v2 gates FEED_PARSER support.
FEED_API_VERSION=2
# Default jq filter for FEED_PARSER=xml plugins with no JQ declared —
# keeps the "just give me title + link" case down to three lines of
# plugin. Leading underscore so a plugin can't accidentally shadow it.
# shellcheck disable=SC2016  # $default is a jq variable bound via --arg, not a shell expansion.
_FEED_XML_DEFAULT_JQ='.[] | [$default, .title, .link] | @tsv'

# shellcheck disable=SC2034  # Read via eval in describe_feed_meta().
FEED_META_hn='description=Hacker News front page (top 30)
api=1
category=News
source=built-in'
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
# shellcheck disable=SC2034  # Referenced indirectly via eval in refresh_all_feeds.
FEED_PARAMS_reddit='REDDIT_SUBS'
# shellcheck disable=SC2034  # Read via eval in describe_feed_meta().
FEED_META_reddit='description=Reddit top posts (parameterized via NEWSLINE_REDDIT_SUBS)
api=1
category=News
source=built-in'
feed_lobsters() {
  LABEL='Lobsters'
  URL='https://lobste.rs/hottest.json'
  # shellcheck disable=SC2016  # $default is a jq variable, must not expand in shell.
  JQ='.[] | select(.title != null) | [$default, .title, .short_id_url] | @tsv'
}
# shellcheck disable=SC2034  # Read via eval in describe_feed_meta().
FEED_META_lobsters='description=Lobsters hottest links
api=1
category=News
source=built-in'
ALL_FEEDS='hn reddit lobsters'

# Knobs the debug report inspects — stored with the user-facing NEWSLINE_*
# names so the attribution probe below and the display loop further down
# share one vocabulary. Listed once so the env-snapshot probe and the report
# can't drift.
_DBG_VARS='NEWSLINE_FEEDS_DISABLED NEWSLINE_REDDIT_SUBS NEWSLINE_ROTATION_SEC
  NEWSLINE_REFRESH_SEC NEWSLINE_MAX_TITLE NEWSLINE_COLOR_FEED
  NEWSLINE_COLOR_PREFIX NEWSLINE_PREFIX NEWSLINE_SHOW_LABELS
  NEWSLINE_LABEL_SEP NEWSLINE_HYPERLINKS NEWSLINE_SCROLL NEWSLINE_SCROLL_SEC
  NEWSLINE_SCROLL_SEPARATOR NEWSLINE_CACHE_FILE NEWSLINE_CACHE_CHUNK'

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
# MAX_TITLE is a BYTE budget, not a column budget — truncate_title uses
# `head -c` which is byte-based. For ASCII that's 1:1 with columns; for
# CJK (3 bytes/char, 2 cols/char) a 60-byte limit means ≈36 columns; for
# emoji-heavy titles it drops lower still. 80 bytes is a compromise: gives
# ASCII users 80 visible columns (plenty for any modern status line), and
# gives CJK users ≈48 columns (a readable chunk) without needing a full
# wcwidth table here. Users pushing longer titles can still crank this.
MAX_TITLE="${NEWSLINE_MAX_TITLE:-80}"
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
# (static rotation). The viewport width is derived per-frame from the
# two headlines being transitioned (see render_scroll_window) — there is
# no NEWSLINE_SCROLL_WIDTH knob, because a fixed width wide enough to hold
# the longest title let both titles fit simultaneously and broke the slide.
SCROLL="${NEWSLINE_SCROLL:-1}"
SCROLL_SEC="${NEWSLINE_SCROLL_SEC:-5}"
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
    # Empty / non-digits: pure typo, fall back.
    # Leading zero on a multi-digit value: POSIX `$(( ))` reads it as octal,
    # so `008` / `09` would crash arithmetic on every status-line tick (and
    # Claude Code surfaces stderr → user-visible noise). Reject those too.
    ''|*[!0-9]*|0[0-9]*) eval "$1=$2"; return ;;
  esac
  if [ "${3:-}" != "allow_zero" ] && [ "$_gn_v" = "0" ]; then
    eval "$1=$2"
  fi
}
guard_num ROTATION_SEC 20
guard_num REFRESH_SEC  600
guard_num MAX_TITLE    80
guard_num SCROLL_SEC   5 allow_zero
# CACHE_CHUNK feeds the awk interleave loop's `pos += chunk` step. Awk coerces
# strings to 0, so an empty / non-numeric / "0" value would make the loop never
# advance — awk pegs a CPU and holds the lock until STALE_REAP_SEC. guard_num
# (rejecting 0 in default mode) keeps the increment positive.
CACHE_CHUNK="${NEWSLINE_CACHE_CHUNK:-1}"
guard_num CACHE_CHUNK 1
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

# Feature-detect iconv once. We pipe titles/URLs through `iconv -f UTF-8
# -t UTF-8 -c` to drop bare C1 control bytes (0x80-0x9F) that aren't part
# of a valid UTF-8 sequence — defense-in-depth against legacy 8-bit-C1
# terminals (CSI=0x9B, OSC=0x9D). The C0 strip in _fetch_one's tr handles
# 0x00-0x1F+0x7F directly, but the C1 range can't be tr-stripped without
# corrupting every multi-byte UTF-8 codepoint, so we lean on iconv's
# encoding awareness. If iconv is missing (rare — POSIX standard utility,
# default on macOS/Linux), we degrade to "tr handled the C0 attack surface;
# C1 is theoretical on modern terminals." Same fall-through pattern as the
# truncate_title and render_scroll_window iconv uses elsewhere.
if iconv -f UTF-8 -t UTF-8 -c </dev/null >/dev/null 2>&1; then
  _HAVE_ICONV=1
else
  _HAVE_ICONV=0
fi
_pipe_strip_c1() {
  if [ "$_HAVE_ICONV" = "1" ]; then
    iconv -f UTF-8 -t UTF-8 -c 2>/dev/null
  else
    cat
  fi
}

# ============= USER FEEDS =============
# Drop a `<name>.sh` file in $NEWSLINE_FEEDS_DIR (default:
# $CLAUDE_CONFIG_DIR/claude-newsline/feeds) and it's picked up as a feed.
# The file must define feed_<name>() which sets LABEL/URL/JQ. Parameterized
# feeds work exactly like built-ins — declare FEED_PARAMS_<name>='VAR' and
# set VAR in .env (e.g. NEWSLINE_MYFEED_SRCS → dispatched via FEED_PARAMS).
#
# Failure is local: a file that fails to source, doesn't define the expected
# function, or has a bad name is skipped silently (listed in NEWSLINE_DEBUG=1).
# A user file `hn.sh` overrides the built-in `feed_hn` via sh's last-definition
# wins — intended, but not duplicated into ALL_FEEDS (no double rotation slots).
USER_FEEDS_DIR="${NEWSLINE_FEEDS_DIR:-$CONFIG_DIR/claude-newsline/feeds}"
# Populated by load_user_feeds(); name<TAB>path pairs used by the debug
# report. Lazy so the hot path (fresh-cache tick, no refresh queued) doesn't
# source N shell files per second — feed_<name> functions are only called
# from refresh_all_feeds, which calls load_user_feeds on entry. The debug
# branch calls it too so the report reflects what a live refresh would see.
_USER_FEEDS_MAP=
# name<TAB>path<TAB>reason per line. Rendered in the debug report so users
# writing broken plugins get a direct answer instead of wondering why their
# file isn't rotating. Same three skip paths as scanAllUserFeeds on the JS
# side: bad filename, source error (syntax / missing feed_<name>), api gate.
_USER_FEEDS_FAILED=
_USER_FEEDS_LOADED=0
load_user_feeds() {
  # Idempotent: callers may hit both the refresh path and (hypothetically)
  # debug in the same process — re-sourcing would just double-append to
  # _USER_FEEDS_MAP. Guard once.
  [ "$_USER_FEEDS_LOADED" = "1" ] && return 0
  _USER_FEEDS_LOADED=1
  [ -d "$USER_FEEDS_DIR" ] || return 0
  for _ufeed in "$USER_FEEDS_DIR"/*.sh; do
    # Unglobbed literal when the dir is empty — guard with `-f`.
    [ -f "$_ufeed" ] || continue
    _uname=${_ufeed##*/}; _uname=${_uname%.sh}
    # Filename must map to a legal sh function name. POSIX: [A-Za-z_][A-Za-z0-9_]*.
    # Rejects "2fa.sh" (leading digit) and "my-feed.sh" (hyphen) before
    # producing an uncallable `feed_my-feed` function name.
    case "$_uname" in
      ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
        _USER_FEEDS_FAILED="${_USER_FEEDS_FAILED}${_uname}${TAB}${_ufeed}${TAB}bad filename (must match [A-Za-z_][A-Za-z0-9_]*)
"
        continue ;;
    esac
    # Reset FEED_META_<name> before sourcing so a user file overriding a
    # built-in (e.g. hn.sh) doesn't silently inherit the built-in's
    # description / category / api line. The user's file either sets its
    # own metadata (in which case we use that) or doesn't (in which case
    # we attach just the auto source= line below). Without this clear, the
    # debug report would render mixed-provenance metadata: built-in's
    # description plus the user file's source=, which reads as a
    # contradiction.
    eval "unset FEED_META_$_uname"
    # Capture source errors to a per-plugin tempfile so the debug report can
    # surface WHY a file failed (syntax error, unset variable under -u, …)
    # without polluting the hot path's stderr. mktemp fallback: if /tmp
    # isn't writable, we degrade to "source failure, no details" — better
    # than aborting load for the other plugins.
    _src_err=$(mktemp "${TMPDIR:-/tmp}/newsline-plugin-err.XXXXXX" 2>/dev/null || echo '')
    # shellcheck source=/dev/null
    if [ -n "$_src_err" ]; then
      . "$_ufeed" 2>"$_src_err"; _src_rc=$?
    else
      . "$_ufeed" 2>/dev/null; _src_rc=$?
    fi
    if [ "$_src_rc" -ne 0 ] || ! command -v "feed_$_uname" >/dev/null 2>&1; then
      if [ "$_src_rc" -ne 0 ]; then
        _reason="source failed (exit $_src_rc)"
        if [ -n "$_src_err" ] && [ -s "$_src_err" ]; then
          # First line of stderr is usually the most specific diagnostic;
          # keeping it short avoids wrapping the debug report layout.
          _first_err=$(head -1 "$_src_err" 2>/dev/null)
          [ -n "$_first_err" ] && _reason="$_reason: $_first_err"
        fi
      else
        _reason="feed_$_uname function not defined"
      fi
      _USER_FEEDS_FAILED="${_USER_FEEDS_FAILED}${_uname}${TAB}${_ufeed}${TAB}${_reason}
"
      [ -n "$_src_err" ] && rm -f "$_src_err"
      continue
    fi
    [ -n "$_src_err" ] && rm -f "$_src_err"
    # Plugin-contract version gate. A plugin declaring `api=N` with N >
    # FEED_API_VERSION was written against a contract this runtime doesn't
    # know how to honor (e.g. a global we don't read, or a JQ TSV shape
    # we don't parse). Skip it rather than silently mis-calling. Missing
    # or non-numeric `api` is treated as 1 for backward compat so plugins
    # written before this gate existed still load. Sourcing has already
    # happened — benign because the plugin only sets globals and a
    # function; we just don't append to ALL_FEEDS, so nothing calls it.
    eval "_meta=\${FEED_META_$_uname:-}"
    # Pull `api=<N>` out of the metadata block. First match wins; newline-
    # oriented so it doesn't trip over `api` appearing in a description.
    # shellcheck disable=SC2154  # _meta assigned by the preceding `eval`.
    _plugin_api=$(printf '%s' "$_meta" | awk -F= '$1=="api" { print $2; exit }')
    case "$_plugin_api" in
      ''|*[!0-9]*) : ;; # absent / non-numeric → implicit v1
      *)
        if [ "$_plugin_api" -gt "$FEED_API_VERSION" ]; then
          _USER_FEEDS_FAILED="${_USER_FEEDS_FAILED}${_uname}${TAB}${_ufeed}${TAB}api=$_plugin_api > runtime $FEED_API_VERSION (upgrade claude-newsline)
"
          continue
        fi
        ;;
    esac
    # Dedupe: a user file named hn.sh overrides the built-in function
    # (source replaces it) but must not double-append to ALL_FEEDS or
    # the dispatch loop fetches it twice per refresh.
    case " $ALL_FEEDS " in
      *" $_uname "*) : ;;
      *) ALL_FEEDS="$ALL_FEEDS $_uname" ;;
    esac
    # Auto-attach source=<path> to a user-feed's FEED_META so the debug
    # report can show "where does this feed come from" without the author
    # having to restate the path. If the user set `source=` themselves,
    # we append ours as an extra line — last-wins in the line-oriented
    # parser, so the user's declaration still takes precedence.
    eval "_meta_cur=\${FEED_META_$_uname:-}"
    if [ -n "$_meta_cur" ]; then
      eval "FEED_META_$_uname=\"\$_meta_cur
source=\$_ufeed\""
    else
      eval "FEED_META_$_uname=\"source=\$_ufeed\""
    fi
    _USER_FEEDS_MAP="${_USER_FEEDS_MAP}${_uname}${TAB}${_ufeed}
"
  done
}
# ======================================

# BSD (stat -f %m) and GNU (stat -c %Y) disagree on the flag for %epoch-modified.
# GNU goes first: on BSD, `-c` is unknown → stderr-only → clean nonzero → fallback
# runs. The reverse order is unsafe because GNU's `-f` means *filesystem status*,
# not format: `stat -f %m FILE` partially succeeds, dumps verbose filesystem info
# to stdout, and poisons $(mtime_of ...). Degrade to 0 so the caller still has a
# number to do arithmetic with. A missing file also returns 0, which is exactly
# what the staleness check wants.
mtime_of() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

is_disabled() {
  # Tolerate user-friendly CSV like "reddit, lobsters" — the older substring
  # match against a bracketed haystack silently failed to disable any entry
  # whose comma neighbor carried whitespace. Split on ',' under a scoped IFS,
  # tr-strip each entry, and compare equal. The installer normalizes on
  # write too, but hand-edited .env / settings.json land here directly.
  _id_target=$1
  _id_old_ifs=$IFS
  IFS=,
  for _id_e in $FEEDS_DISABLED; do
    case "$(printf '%s' "$_id_e" | tr -d '[:space:]')" in
      "$_id_target") IFS=$_id_old_ifs; return 0 ;;
    esac
  done
  IFS=$_id_old_ifs
  return 1
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

# Parser stage — reads FEED_PARSER/LABEL/JQ from the caller's scope. For
# FEED_PARSER=xml, xml-to-json transforms the body into a JSON array of
# {title, link, description} and jq runs over that; otherwise jq runs on
# the raw body directly (JSON feeds). Both branches emit the same
# label<TAB>title<TAB>url TSV shape so downstream (tr, awk, bucket
# interleave, parse_line) stays format-agnostic.
#
# XML feeds without a JQ filter fall back to _FEED_XML_DEFAULT_JQ — the
# "just give me title + link" case. Plugins wanting filtering, rewrites,
# or label promotion override JQ themselves.
#
# Stderr is intentionally NOT redirected here: _fetch_one pipes through
# `2>/dev/null` so refresh-time noise is hidden, while _test_one_invocation
# captures stderr to a file so parser diagnostics surface in --test-feed.
#
# Missing xml-to-json.js degrades to "empty output" for xml feeds (not a
# crash, not a cryptic `node: cannot open file`) — matches the behavior of
# a failed curl, so the cache keeps the last good line. The debug branch
# surfaces this separately so users know WHY an xml feed went silent. Can
# happen when someone copies statusline.sh alone into a dotfiles repo
# without the sibling JS shim.
_parse_body() {
  case "${FEED_PARSER:-jq}" in
    xml)
      if [ ! -f "$_SCRIPT_DIR/xml-to-json.js" ]; then
        printf 'xml-to-json.js not found alongside statusline.sh; xml feed skipped\n' >&2
        return 0
      fi
      node "$_SCRIPT_DIR/xml-to-json.js" \
        | jq -r --arg default "$LABEL" "${JQ:-$_FEED_XML_DEFAULT_JQ}" ;;
    *)   jq -r --arg default "$LABEL" "$JQ" ;;
  esac
}

# Shared fetch pipeline — reads LABEL, URL, JQ, FEED_PARSER from the
# caller's scope. Extracted so the reddit multi-sub loop and the single-
# feed path share one curl|parse|tr|awk stage. Pipeline: fetch →
# _parse_body emits <label>\t<title>\t<url> (feed may promote a more
# specific label; $default is the fallback the plugin's jq sees; XML
# feeds first pass through xml-to-json before jq runs) → strip C0 control
# bytes (defense in depth: a compromised feed must not smuggle ESC
# sequences that would
# escape from inside our OSC 8 wrapper and hijack the terminal — keep
# \t=0x09 and \n=0x0A, our separators) → drop empties. Caller redirects
# stdout to the refresh tempfile.
_fetch_one() {
  # -L follows 3xx: without it, a single 301 silently empties a bucket for
  # a full refresh cycle the moment any feed migrates endpoints.
  # --retry 1 covers curl's default transient set (408/429/5xx/connect
  # errors). Reddit in particular 429s anonymous clients — without the
  # retry, one 429 blanks a bucket for 10 minutes. --max-time 8 is the
  # TOTAL budget; it already covers the retry + retry-delay.
  curl -fs -L --compressed --retry 1 --retry-delay 1 \
      --connect-timeout 2 --max-time 8 \
      -A "${NEWSLINE_USER_AGENT:-claude-newsline/1.0 (+https://github.com/sitapix/claude-newsline)}" \
      "$URL" 2>/dev/null \
    | _parse_body 2>/dev/null \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | _pipe_strip_c1 \
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
# Default CACHE_CHUNK=1 gives strict round-robin (HN, Reddit, Lobsters, HN,
# Reddit, Lobsters, …) so the "stuck on one feed" window is at most one
# rotation tick. Higher values cluster same-source entries together — some
# users prefer that; bump via NEWSLINE_CACHE_CHUNK if so.
#
# Forks are safe because LABEL/URL/JQ are copied into each child at fork time
# — the parent loop can reassign them for the next iteration without racing
# the already-running children. Parallelism means worst-case refresh is
# bounded by the SLOWEST single fetch (curl --max-time 8) plus jq/awk
# overhead — not the SUM of all fetches. Empirical: 7 parallel fetches
# complete in <1s on a warm connection. Used by STALE_REAP_SEC below.
refresh_all_feeds() {
  # User feeds are sourced lazily here (not at script startup) so fresh-cache
  # ticks that skip refresh don't pay the per-file source cost.
  load_user_feeds
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
      # shellcheck disable=SC2086,SC2154  # Word-split intentional; _params_val assigned via eval above.
      set -- $_params_val
      IFS=$_old_ifs
      for _p in "$@"; do
        # Reset FEED_PARSER before each call so a v2 plugin that sets it
        # doesn't leak into the next iteration's JSON feed. LABEL/URL/JQ
        # are set unconditionally by every feed function, so only
        # FEED_PARSER (optional, v2+) needs an explicit reset.
        FEED_PARSER=
        if "feed_$f" "$_p"; then
          _capture_bucket
        fi
      done
    else
      FEED_PARSER=
      "feed_$f"
      _capture_bucket
    fi
  done
  wait
  # Heartbeat: bump the lock dir's mtime now that all curls are done so
  # the stale-lock reaper (STALE_REAP_SEC, see below) doesn't clobber a
  # live merge phase on a slow disk. The reaper compares now - mtime; we
  # touch right after the network phase so the merge has a fresh budget.
  [ -d "$CACHE_FILE.lock" ] && touch "$CACHE_FILE.lock" 2>/dev/null

  # Round-robin merge: CACHE_CHUNK lines per bucket per pass. Buckets exhaust
  # at different rates (HN returns 30, Lobsters 25, Reddit varies) — the
  # inner bounds check drops exhausted buckets so remaining buckets aren't
  # clumped at the tail.
  if [ "$_bucket_idx" -gt 0 ]; then
    awk -v chunk="$CACHE_CHUNK" '
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
    # Double-buffer: if a cache is already populated, stage the fresh data
    # in a .pending sibling and let the next pos_in_cycle=0 tick promote
    # it. This way the displayed headline never swaps mid-dwell or mid-
    # scroll — a refresh that lands on pos=10 of a 20s rotation won't
    # suddenly show a different title; it waits until the cycle boundary.
    # First-ever fill bypasses .pending so users don't stare at an empty
    # status line until the first rotation completes.
    if [ -s "$CACHE_FILE" ]; then
      mv "$tmp" "$CACHE_FILE.pending"
    else
      mv "$tmp" "$CACHE_FILE"
    fi
  else
    rm -f "$tmp"
  fi
}

# Render the horizontal-scroll transition between two composed headlines.
# The tape is `a_padded + SCROLL_SEPARATOR + b_padded`, where each title is
# right-padded to max(len(a), len(b)). The viewport width matches that same
# max and is constant across every frame — trailing spaces on the terminal
# bg are invisible, so padding b costs nothing visually but keeps the line
# width from collapsing when we reach the final (b-only) frame.
#
# OFFSET MATH — trace it before tweaking:
#
#   slide  = w + ls            (travel distance: start of a to start of b)
#   offset = round((frame+1) * slide / SCROLL_SEC)   for frame ∈ [0, S-1]
#
# Every scroll frame is a motion step: frame 0 shows slide/S progress (no
# duplicate-of-dwell frame), frame S-1 lands exactly at `slide` (b at
# viewport position 1). Gives S approximately-even motion steps instead of
# S-1 larger ones, so the landing doesn't feel disproportionate.
#
# No OSC 8 emitted during scroll — the window rarely maps to a single URL.
# Reads pos_in_cycle, dwell, SCROLL_SEC, SCROLL_SEPARATOR, c_prefix, c_feed,
# PREFIX, RESET from the enclosing scope.
render_scroll_window() {
  _rs_cur=$1
  _rs_nxt=$2
  _rs_frame=$(( pos_in_cycle - dwell ))
  # BSD awk substr() is byte-based, so a slice can bisect a multi-byte
  # codepoint and render as U+FFFD. Pipe through `iconv -c` in the same
  # subshell to drop the orphan bytes — fork-free vs the prior capture-
  # then-re-pipe pattern.
  #
  # Pass untrusted strings (titles, separator) via ENVIRON[] rather than
  # awk -v. POSIX/gawk/mawk/BSD awk all expand C-style backslash escapes
  # (\033, \n, \xHH, \ddd) in -v values — so a feed whose title contained
  # the four text bytes "\033" would get ESC (0x1B) injected here, past
  # the C0/C1 strip in _fetch_one (that strip only removes raw control
  # bytes, not their \ddd text encoding). ENVIRON[] reads the env verbatim
  # with no escape processing, closing the ANSI-injection path while
  # keeping the numeric -v assignments (frame/scroll_sec) — those come
  # from internal integer arithmetic and need no escaping.
  _rs_window=$(_RS_A="$_rs_cur" _RS_B="$_rs_nxt" _RS_SEP="$SCROLL_SEPARATOR" \
               awk -v frame="$_rs_frame" -v scroll_sec="$SCROLL_SEC" '
    BEGIN {
      a = ENVIRON["_RS_A"]; b = ENVIRON["_RS_B"]; sep = ENVIRON["_RS_SEP"]
      la = length(a); lb = length(b); ls = length(sep)
      w = (la > lb) ? la : lb
      # Pad BOTH titles to w so the viewport returns exactly w chars at every
      # offset. Padding only `a` (an earlier attempt) left the final frame
      # returning just `len(b)` chars when b was shorter — the visible line
      # collapsed on the last step of the slide, reading as a disproportionate
      # "jump" onto the dwell spot. Trailing spaces on the terminal bg are
      # invisible, so padding b is free visually but keeps motion uniform.
      if (w > la) a = a sprintf("%*s", w - la, "")
      if (w > lb) b = b sprintf("%*s", w - lb, "")
      combined = a sep b
      slide = w + ls
      # + 0.5 rounds instead of floors — spreads the truncation error
      # evenly across frames so step sizes read as 10,10,10,10,9 rather
      # than 9,10,10,10,10. Caller guarantees scroll_sec >= 1.
      offset = int((frame + 1) * slide / scroll_sec + 0.5)
      print substr(combined, offset + 1, w)
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
  _dbg_show NEWSLINE_CACHE_CHUNK      "$CACHE_CHUNK"
  _dbg_show NEWSLINE_REFRESH_SEC      "$REFRESH_SEC"
  _dbg_show NEWSLINE_MAX_TITLE        "$MAX_TITLE"
  _dbg_show NEWSLINE_SCROLL           "$SCROLL"
  _dbg_show NEWSLINE_SCROLL_SEC       "$SCROLL_SEC"
  _dbg_show NEWSLINE_SCROLL_SEPARATOR "\"$SCROLL_SEPARATOR\""
  _dbg_show NEWSLINE_PREFIX           "\"$PREFIX\""
  _dbg_show NEWSLINE_COLOR_PREFIX     "$COLOR_PREFIX"
  _dbg_show NEWSLINE_COLOR_FEED       "$COLOR_FEED"
  _dbg_show NEWSLINE_SHOW_LABELS      "$SHOW_LABELS"
  _dbg_show NEWSLINE_LABEL_SEP        "\"$LABEL_SEP\""
  _dbg_show NEWSLINE_FEEDS_DISABLED   "$FEEDS_DISABLED"
  _dbg_show NEWSLINE_REDDIT_SUBS      "$REDDIT_SUBS"
  _dbg_show NEWSLINE_HYPERLINKS       "$HYPERLINKS"
  # Debug mode reports what a live refresh would see, so load user feeds
  # now (the refresh path also calls this; load_user_feeds is idempotent).
  load_user_feeds
  echo
  _dbg_enabled=
  for f in $ALL_FEEDS; do
    is_disabled "$f" || _dbg_enabled="$_dbg_enabled $f"
  done
  echo "feeds enabled:$_dbg_enabled"

  # Per-feed metadata dump. Pulls FEED_META_<name> for every feed in
  # ALL_FEEDS (built-ins + user feeds loaded above) and renders whichever
  # keys are present. A feed without metadata just renders its name — no
  # metadata is a valid plugin shape. Parser is newline-oriented so one
  # `key=value` per line; embedded '=' in value survives because we stop
  # at the first '='.
  echo
  echo 'feed metadata:'
  for _mf in $ALL_FEEDS; do
    eval "_mval=\${FEED_META_$_mf:-}"
    if [ -z "$_mval" ]; then
      printf '  %s\n' "$_mf"
      continue
    fi
    printf '  %s\n' "$_mf"
    # Read line-by-line; `IFS=` preserves leading whitespace in descriptions.
    # Splitting on first '=' via parameter expansion avoids an awk fork per
    # key — debug is a one-shot but we keep the same "no gratuitous forks"
    # discipline as the hot path.
    printf '%s\n' "$_mval" | while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      case "$_line" in
        *=*)
          _k=${_line%%=*}
          _v=${_line#*=}
          printf '    %-12s %s\n' "$_k" "$_v"
          ;;
      esac
    done
  done

  # User feeds: show the name → source-file map so "why isn't my feed
  # loading?" has a direct answer. Empty block when nothing's in the dir;
  # the "(none)" path tells the user the directory was checked.
  echo
  echo "user feeds dir:   $USER_FEEDS_DIR"
  if [ -n "$_USER_FEEDS_MAP" ]; then
    # Literal ← (U+2190) instead of printf \u2190 — bash 3.2 (ships with
    # macOS) and dash don't interpret \u escapes, they'd print the literal
    # backslash-u-digits. The source is UTF-8; the byte sequence renders.
    printf '%s' "$_USER_FEEDS_MAP" | while IFS="$TAB" read -r _n _p; do
      [ -n "$_n" ] || continue
      printf '  %-12s ← %s\n' "$_n" "$_p"
    done
  else
    echo '  (none loaded)'
  fi

  # Failed plugins: render name, path, and reason so authors of broken
  # plugins get a direct diagnostic. Without this block, a syntax error in
  # a user plugin looked identical to "I never dropped the file in" —
  # hours of confusion for a missing semicolon.
  if [ -n "$_USER_FEEDS_FAILED" ]; then
    echo
    echo 'user feeds skipped:'
    printf '%s' "$_USER_FEEDS_FAILED" | while IFS="$TAB" read -r _n _p _r; do
      [ -n "$_n" ] || continue
      printf '  %-12s %s\n' "$_n" "$_p"
      printf '  %-12s   reason: %s\n' '' "$_r"
    done
  fi

  # xml-to-json.js presence check. FEED_PARSER=xml plugins depend on this
  # sibling Node shim; someone who copied statusline.sh alone into a
  # dotfiles repo without it will see xml feeds silently return empty.
  # Surface here so "why is my RSS feed not working?" has a direct answer.
  echo
  if [ -f "$_SCRIPT_DIR/xml-to-json.js" ]; then
    echo "xml-to-json.js:   $_SCRIPT_DIR/xml-to-json.js"
  else
    echo "xml-to-json.js:   MISSING ($_SCRIPT_DIR/xml-to-json.js) — FEED_PARSER=xml plugins will be skipped"
  fi

  # NEWSLINE_SCROLL_WIDTH deprecation notice. The knob was removed when
  # render_scroll_window started deriving its width per-frame from the two
  # titles being transitioned (see comment there). A user with the variable
  # pinned in .env or settings.json would otherwise get no signal that their
  # override stopped doing anything.
  if [ -n "${NEWSLINE_SCROLL_WIDTH:-}" ]; then
    echo
    echo 'deprecated:'
    printf '  %-24s %s\n' 'NEWSLINE_SCROLL_WIDTH' "set to \"$NEWSLINE_SCROLL_WIDTH\" but ignored (auto-derived from title lengths since v0.2.0)"
  fi
  exit 0
fi

# NEWSLINE_TEST_FEED=<name> → run one fetch for a single feed and print
# diagnostics (URL, HTTP code, byte count, jq row count, first few sample
# rows, URL-scheme warning). Bypasses the cache, lock, and render path so
# a user authoring a custom feed can see whether their URL + jq filter
# produce usable rows without waiting for a cache refresh window.
#
# Driven by `claude-newsline --test-feed <name>`. Exit codes: 0 on success,
# 1 on runtime failure (HTTP/jq/empty), 2 on bad input.
if [ -n "${NEWSLINE_TEST_FEED:-}" ]; then
  load_user_feeds
  _tfeed="$NEWSLINE_TEST_FEED"

  # Name validation mirrors load_user_feeds: POSIX function-name rules. A
  # caller-typed name could contain shell metacharacters if the Node side
  # didn't filter, so defend in depth before we ever reach `feed_$name`.
  case "$_tfeed" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
      printf 'claude-newsline: invalid feed name: %s\n' "$_tfeed" >&2
      exit 2
      ;;
  esac
  if ! command -v "feed_$_tfeed" >/dev/null 2>&1; then
    printf 'claude-newsline: unknown feed: %s\n' "$_tfeed" >&2
    # shellcheck disable=SC2086  # Word-splitting intentional — $ALL_FEEDS is a space-separated list.
    printf 'available:%s\n' "$(printf ' %s' $ALL_FEEDS)" >&2
    exit 2
  fi

  # Local color names (don't collide with c_feed / c_prefix set below). These
  # respect NO_COLOR/FORCE_COLOR via set_ansi already loaded from colors.sh.
  set_ansi _tc_ok    green
  set_ansi _tc_warn  yellow
  set_ansi _tc_fail  red
  set_ansi _tc_dim   dim

  # Run one (LABEL, URL, JQ) invocation end-to-end with diagnostics. Returns
  # 0 on success (≥1 row produced), 1 on any failure. Reads the three feed
  # globals from caller scope — same contract as _fetch_one. When
  # NEWSLINE_TEST_FEED_FIXTURE is set, skip curl entirely and use the file
  # as the response body — lets authors iterate on jq filters without
  # hammering the real API (or waiting on rate-limited reddit).
  _test_one_invocation() {
    _to_header=${1:-}
    if [ -n "$_to_header" ]; then
      # shellcheck disable=SC2154  # _tc_dim assigned by set_ansi above.
      printf '\n%s%s%s\n' "$_tc_dim" "$_to_header" "$RESET"
    fi
    printf '  URL:      %s\n' "$URL"

    _to_body=$(mktemp "${TMPDIR:-/tmp}/newsline-test.XXXXXX") || return 1
    if [ -n "${NEWSLINE_TEST_FEED_FIXTURE:-}" ]; then
      # Fixture mode: pipe the local file in place of curl's output. Only
      # exercised via `claude-newsline --test-feed <name> --fixture <path>`,
      # which validates the path in Node before we ever get here — so a
      # missing or unreadable file at this point is a real error (e.g. the
      # file was unlinked between Node's stat and now), not a user typo.
      # shellcheck disable=SC2154  # _tc_fail/_tc_ok assigned via set_ansi above; shellcheck can't see through it.
      if ! cp "$NEWSLINE_TEST_FEED_FIXTURE" "$_to_body" 2>/dev/null; then
        printf '  %sfixture:  failed to read %s%s\n' "$_tc_fail" "$NEWSLINE_TEST_FEED_FIXTURE" "$RESET"
        rm -f "$_to_body"
        return 1
      fi
      _to_size=$(wc -c <"$_to_body" | tr -d ' ')
      # shellcheck disable=SC2154  # _tc_ok set via set_ansi above.
      printf '  Fixture:  %s%s%s  (%s bytes, no network)\n' \
        "$_tc_ok" "$NEWSLINE_TEST_FEED_FIXTURE" "$RESET" "$_to_size"
    else
      # -w emits meta as "http_code|size_download|time_total" on stdout; -o
      # writes the body to our tempfile so we can feed it to jq AND read meta
      # independently. -fS makes curl report non-2xx via exit code; we want to
      # SEE the HTTP code even on 4xx/5xx so the user knows what happened,
      # hence bare -sS (no -f) plus an explicit code check below.
      _to_meta=$(curl -sS -L --compressed --retry 1 --retry-delay 1 \
                      --connect-timeout 2 --max-time 8 \
                      -A "${NEWSLINE_USER_AGENT:-claude-newsline/1.0 (+https://github.com/sitapix/claude-newsline)}" \
                      -w '%{http_code}|%{size_download}|%{time_total}' \
                      -o "$_to_body" "$URL" 2>&1)
      _to_curl=$?
      if [ "$_to_curl" -ne 0 ]; then
        printf '  HTTP:     %scurl error %d%s\n            %s\n' "$_tc_fail" "$_to_curl" "$RESET" "$_to_meta"
        rm -f "$_to_body"
        return 1
      fi
      _to_code=${_to_meta%%|*}
      _to_rest=${_to_meta#*|}
      _to_size=${_to_rest%%|*}
      _to_time=${_to_rest#*|}
      case "$_to_code" in
        2*) _to_code_color=$_tc_ok ;;
        *)  _to_code_color=$_tc_fail ;;
      esac
      printf '  HTTP:     %s%s%s  (%ss, %s bytes)\n' \
        "$_to_code_color" "$_to_code" "$RESET" "$_to_time" "$_to_size"
    fi

    _to_errfile=$(mktemp "${TMPDIR:-/tmp}/newsline-test-err.XXXXXX") || {
      rm -f "$_to_body"; return 1;
    }
    # Same C0/C1 stripping pipeline as _fetch_one, so what the user sees
    # here is exactly what would hit the cache. The parser stage routes to
    # jq (default) or xml-to-json|jq (FEED_PARSER=xml) identically to refresh.
    _to_parser="${FEED_PARSER:-jq}"
    _to_rows=$(_parse_body <"$_to_body" 2>"$_to_errfile" \
               | LC_ALL=C tr -d '\000-\010\013-\037\177' \
               | _pipe_strip_c1 \
               | awk 'NF')
    rm -f "$_to_body"
    if [ -s "$_to_errfile" ]; then
      printf '  %s:       %serror%s\n' "$_to_parser" "$_tc_fail" "$RESET"
      sed 's/^/            /' "$_to_errfile"
      rm -f "$_to_errfile"
      return 1
    fi
    rm -f "$_to_errfile"

    if [ -z "$_to_rows" ]; then
      printf '  %s:       %s0 rows%s (feed produced nothing usable)\n' "$_to_parser" "$_tc_fail" "$RESET"
      return 1
    fi
    _to_count=$(printf '%s\n' "$_to_rows" | awk 'END { print NR }')
    printf '  %s:       %s%d rows%s\n' "$_to_parser" "$_tc_ok" "$_to_count" "$RESET"
    printf '  Sample:\n'
    printf '%s\n' "$_to_rows" | head -3 | while IFS="$TAB" read -r _sl _st _su; do
      # Literal U+2022 (•) and U+2192 (→) — bash 3.2 / dash don't do \uXXXX
      # escapes, and the file is already UTF-8 elsewhere (← in the debug
      # report). Matches the style statusline.sh uses for its render output.
      printf '    %s • %s → %s\n' "$_sl" "$_st" "$_su"
    done

    # URL-scheme check: any row whose URL isn't http(s) will render without
    # the OSC 8 hyperlink (per the scheme guard below). Surfacing it here
    # means users notice the drift while authoring, not after they push.
    _to_bad=$(printf '%s\n' "$_to_rows" | awk -F'\t' '
      $3 !~ /^https?:\/\// { print $3; exit }
    ')
    if [ -n "$_to_bad" ]; then
      # shellcheck disable=SC2154  # _tc_warn assigned by set_ansi above.
      printf '  %s⚠ URL scheme not http(s):%s %s\n' "$_tc_warn" "$RESET" "$_to_bad"
      printf '            OSC 8 hyperlink will be dropped; headline still renders.\n'
    fi
    return 0
  }

  # Dispatch: parameterized feeds loop over FEED_PARAMS_<name>'s CSV. The
  # feed function is called per entry — if it `return 1`s an invalid entry,
  # we count that as a failure for this test (same contract as the runtime
  # refresh, just surfaced). An empty parameter variable is a hard fail —
  # nothing to exercise.
  # Header stays uncolored so shell-test assertions can match the whole
  # "Testing feed: <name>" string as one literal — color escapes between
  # the label and the name would break `grep -F 'Testing feed: foo'`.
  printf 'Testing feed: %s' "$_tfeed"
  eval "_t_params_var=\${FEED_PARAMS_$_tfeed:-}"
  if [ -n "$_t_params_var" ]; then
    eval "_t_params_val=\${$_t_params_var:-}"
    # shellcheck disable=SC2154  # _t_params_val assigned by the preceding `eval`.
    printf ' %s(parameterized via %s="%s")%s\n' "$_tc_dim" "$_t_params_var" "$_t_params_val" "$RESET"
    _t_ok=0; _t_fail=0
    _old_ifs=$IFS
    IFS=','
    # shellcheck disable=SC2086
    set -- $_t_params_val
    IFS=$_old_ifs
    _t_total=$#
    if [ "$_t_total" -eq 0 ]; then
      # Most common cause: user set NEWSLINE_<INTERNAL> in their settings.json
      # but their plugin file has no `INTERNAL="${NEWSLINE_INTERNAL:-}"` line,
      # so the dispatch loop's `$INTERNAL` lookup comes back empty. Guide
      # them toward the three possible fixes so they don't have to chase
      # the convention through docs.
      printf '\n%s✗ Parameter variable %s is empty — no entries to test.%s\n' "$_tc_fail" "$_t_params_var" "$RESET"
      printf '\n'
      printf '  To fix, pick one:\n'
      printf '\n'
      printf '    1. Set NEWSLINE_%s in your env or settings.json, AND make sure\n' "$_t_params_var"
      printf '       your plugin file contains this binding line:\n'
      # shellcheck disable=SC2016  # printf format string — `${NEWSLINE_%s:-}` is template text shown to the user, not a shell expansion.
      printf '         %s="${NEWSLINE_%s:-}"\n' "$_t_params_var" "$_t_params_var"
      printf '       (without it, NEWSLINE_%s is read by nothing.)\n' "$_t_params_var"
      printf '\n'
      printf '    2. Test with a one-off override:\n'
      printf '         NEWSLINE_%s=value1,value2 claude-newsline --test-feed %s\n' "$_t_params_var" "$_tfeed"
      printf '\n'
      printf '    3. Give FEED_PARAMS_%s a sensible default in your plugin:\n' "$_tfeed"
      # shellcheck disable=SC2016  # printf format string — `${NEWSLINE_%s:-default-entry}` is template text shown to the user.
      printf '         %s="${NEWSLINE_%s:-default-entry}"\n' "$_t_params_var" "$_t_params_var"
      exit 1
    fi
    _t_idx=0
    for _t_p in "$@"; do
      _t_idx=$((_t_idx + 1))
      FEED_PARSER=
      if "feed_$_tfeed" "$_t_p"; then
        if _test_one_invocation "[$_t_idx/$_t_total] $LABEL"; then
          _t_ok=$((_t_ok + 1))
        else
          _t_fail=$((_t_fail + 1))
        fi
      else
        printf '\n  %s✗ entry rejected by feed_%s:%s %s\n' "$_tc_fail" "$_tfeed" "$RESET" "$_t_p"
        _t_fail=$((_t_fail + 1))
      fi
    done
    printf '\n'
    if [ "$_t_fail" -eq 0 ]; then
      printf '%s✓ All %d entries OK.%s\n' "$_tc_ok" "$_t_ok" "$RESET"
      exit 0
    else
      printf '%s✗ %d failed / %d ok.%s\n' "$_tc_fail" "$_t_fail" "$_t_ok" "$RESET"
      exit 1
    fi
  else
    printf '\n'
    FEED_PARSER=
    "feed_$_tfeed"
    if _test_one_invocation; then
      printf '\n%s✓ OK.%s\n' "$_tc_ok" "$RESET"
      exit 0
    else
      printf '\n%s✗ Feed returned no usable rows.%s\n' "$_tc_fail" "$RESET"
      exit 1
    fi
  fi
fi

# Atomic-mkdir lock serializes concurrent refreshes so a fresh install
# (empty cache → every tick wants a refresh) doesn't fork a thundering
# herd of curl|jq pipelines. Foreground never blocks on network.
mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null

mtime=$(mtime_of "$CACHE_FILE")

# Double-buffer promotion. refresh_all_feeds writes to "$CACHE_FILE.pending"
# whenever a live cache already exists; we promote at rotation boundaries
# (pos=0) so the displayed headline never changes mid-dwell. Stale live
# cache (past REFRESH_SEC) gets immediate promotion — stale content beats
# a visible swap. `mv` is atomic; concurrent ticks in the same second lose
# harmlessly via ENOENT on the source.
if [ -s "$CACHE_FILE.pending" ]; then
  if [ "$((now % ROTATION_SEC))" -eq 0 ] || [ "$((now - mtime))" -gt "$REFRESH_SEC" ]; then
    mv "$CACHE_FILE.pending" "$CACHE_FILE" 2>/dev/null && mtime=$(mtime_of "$CACHE_FILE")
  fi
fi
if [ ! -s "$CACHE_FILE" ] || [ "$((now - mtime))" -gt "$REFRESH_SEC" ]; then
  lock="$CACHE_FILE.lock"
  # Reap stale locks: if a previous refresh was SIGKILLed mid-flight, the
  # lock dir sticks around forever. Fetches are parallel, so worst case is
  # one curl (whole budget = --max-time 8) plus jq/awk merge across many
  # buckets — under disk pressure and lots of feeds, real-world timing has
  # measured up to the 30s mark. 60s is 2× the observed worst case while
  # still well under any realistic NEWSLINE_REFRESH_SEC, so a SIGKILL
  # doesn't block refresh for multiple cycles. refresh_all_feeds touches
  # the lock dir between phases, so a live process keeps its mtime fresh.
  STALE_REAP_SEC=60
  if [ -d "$lock" ]; then
    lock_mtime=$(mtime_of "$lock")
    if [ "$((now - lock_mtime))" -gt "$STALE_REAP_SEC" ]; then
      rmdir "$lock" 2>/dev/null
    fi
  fi
  # Mirror of the lock reaper: SIGKILL mid-refresh leaves a per-pid buckets
  # dir ($CACHE_FILE.buckets.$$) that refresh_all_feeds normally removes on
  # success. Without this, killed refreshes accumulate forever. Same budget
  # as the lock reaper — they represent the same class of stale state.
  for _stale_buckets in "$CACHE_FILE".buckets.*; do
    [ -d "$_stale_buckets" ] || continue
    _stale_mtime=$(mtime_of "$_stale_buckets")
    [ "$((now - _stale_mtime))" -gt "$STALE_REAP_SEC" ] && rm -rf "$_stale_buckets" 2>/dev/null
  done
  # Same SIGKILL class for the merged-tape staging file: refresh_all_feeds
  # writes the awk merge into $CACHE_FILE.new.$$ and only mv's it into place
  # (.pending or the live cache) on success. A kill between awk completion
  # and the mv leaves the .new.<pid> file. Without a reaper these accumulate
  # forever and trip uninstall's `rmdir cache/` with ENOTEMPTY.
  for _stale_new in "$CACHE_FILE".new.*; do
    [ -f "$_stale_new" ] || continue
    _stale_mtime=$(mtime_of "$_stale_new")
    [ "$((now - _stale_mtime))" -gt "$STALE_REAP_SEC" ] && rm -f "$_stale_new" 2>/dev/null
  done
  # An orphaned .pending — e.g., a refresh wrote it but the user's terminal
  # was closed before the next rotation boundary ever fired — would otherwise
  # sit on disk forever and get promoted on the next session's first pos=0
  # tick, showing outdated content as if it were fresh. If pending is older
  # than REFRESH_SEC (the same staleness threshold we apply to the live
  # cache), drop it and let the next refresh write a new one.
  if [ -s "$CACHE_FILE.pending" ]; then
    _pending_mtime=$(mtime_of "$CACHE_FILE.pending")
    if [ "$((now - _pending_mtime))" -gt "$REFRESH_SEC" ]; then
      rm -f "$CACHE_FILE.pending" 2>/dev/null
    fi
  fi
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
#
# dwell is always >= 1 here: guard_num enforces ROTATION_SEC >= 1, and the
# clamp earlier (SCROLL_SEC >= ROTATION_SEC → SCROLL_SEC = ROTATION_SEC - 1)
# guarantees SCROLL_SEC < ROTATION_SEC. So no negative-clamp guard is needed.
pos_in_cycle=$(( now % ROTATION_SEC ))
dwell=$(( ROTATION_SEC - SCROLL_SEC ))

if [ "$SCROLL" != "0" ] && [ "$SCROLL_SEC" -gt 0 ] && [ -n "$next_line" ] && [ "$pos_in_cycle" -ge "$dwell" ]; then
  parse_line "$next_line"
  render_scroll_window "${cur_prefix}${cur_title}" "${_PL_PREFIX}${_PL_TITLE}"
  exit 0
fi

# URL scheme guard. OSC 8 hands the URL off to the terminal emulator's URL
# handler on cmd/ctrl-click — and historically those handlers have had
# argument-injection bugs against schemes like `x-man-page://`, `ssh://`,
# `file://`, and `javascript:` (CVE-2023-46321 iTerm2, Hyper RCE chain).
# Allow only http(s). A tampered feed, a jq filter that drifted, or a paste
# typo can't smuggle in another scheme; worst case is a rendered-but-unlinked
# headline. C0 stripping in _fetch_one is the other half of this defense —
# this layer catches whole-scheme swaps that byte-filtering doesn't see.
# RFC 3986: schemes are case-insensitive. The case-class glob keeps the
# guard pure-shell (no fork) while still accepting `HTTP://` / `Https://`
# variants seen in legacy Atom feeds. Anything else still drops the link.
case "$cur_url" in
  [hH][tT][tT][pP]://*|[hH][tT][tT][pP][sS]://*) _link_ok=1 ;;
  *) _link_ok=0 ;;
esac

if [ -n "$cur_url" ] && [ "$HYPERLINKS_ON" = "1" ] && [ "$_link_ok" = "1" ]; then
  # PREFIX lives OUTSIDE the OSC 8 wrapper so the hover/cmd-click underline
  # doesn't extend under the brand glyph (the trailing space in "Ξ " makes
  # that underline render as a detached fragment, which looks like a glitch).
  # The headline is a big enough click target on its own.
  printf '%s%s%s\033]8;;%s\033\\%s%s%s\033]8;;\033\\\n' \
    "$c_prefix" "$PREFIX" "$RESET" \
    "$cur_url" "$c_feed" "${cur_prefix}${cur_title}" "$RESET"
else
  printf '%s%s%s%s%s%s%s\n' \
    "$c_prefix" "$PREFIX" "$RESET" "$c_feed" "$cur_prefix" "$cur_title" "$RESET"
fi
