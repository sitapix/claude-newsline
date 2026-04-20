#!/bin/bash
# Test suite for claude-newsline. Run with: ./test.sh
#
# Covers: feed-line rendering (bash), install/uninstall via Node, append
# semantics, idempotency, CSV flag handling.
#
# No network required: tests prime the cache manually with a fresh mtime so
# the background refresh never fires.

set -u

# Strip any runtime knobs the caller's shell may have exported (from their own
# claude-newsline install under ~/.claude/settings.json → env, etc.). Tests
# set what they need per-case; anything bleeding in from the host shell makes
# "HN • Title" assertions fail in ways that look unrelated to the test body.
unset NEWSLINE_FEEDS_DISABLED NEWSLINE_REDDIT_SUBS NEWSLINE_ROTATION_SEC \
      NEWSLINE_REFRESH_SEC NEWSLINE_MAX_TITLE NEWSLINE_COLOR_FEED \
      NEWSLINE_COLOR_PREFIX NEWSLINE_PREFIX NEWSLINE_SHOW_LABELS \
      NEWSLINE_LABEL_SEP NEWSLINE_HYPERLINKS NEWSLINE_SCROLL \
      NEWSLINE_SCROLL_SEC NEWSLINE_SCROLL_WIDTH NEWSLINE_SCROLL_SEPARATOR \
      NEWSLINE_CACHE_CHUNK NEWSLINE_CACHE_FILE NEWSLINE_USER_AGENT \
      FORCE_HYPERLINK NEWSLINE_DEBUG

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE="$SCRIPT_DIR/bin/statusline.sh"
CLI="$SCRIPT_DIR/bin/claude-newsline.js"

SANDBOX="$(mktemp -d -t feedstatus-test-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_CONFIG_DIR="$SANDBOX/config"
mkdir -p "$CLAUDE_CONFIG_DIR/cache"
CACHE="$CLAUDE_CONFIG_DIR/cache/feed-titles.txt"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$1")
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if printf '%s' "$haystack" | grep -q -F -- "$needle"; then
    pass "$name"
  else
    fail "$name" "expected to contain: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if printf '%s' "$haystack" | grep -q -F -- "$needle"; then
    fail "$name" "expected NOT to contain: $needle"
  else
    pass "$name"
  fi
}

assert_equals() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  local p="$1" name="$2"
  if [ -f "$p" ] || [ -L "$p" ]; then pass "$name"; else fail "$name" "missing: $p"; fi
}

# Assert an .env key was cleared from settings.json. Uses jq's `//` to turn a
# missing path into the sentinel "gone", so the assertion catches both the
# "key absent" and "key literally set to null" shapes uniformly.
assert_env_gone() {
  local key="$1" name="$2"
  assert_equals "$(jq -r ".env.$key // \"gone\"" "$SETTINGS")" "gone" "$name"
}

assert_file_absent() {
  local p="$1" name="$2"
  if [ -e "$p" ]; then fail "$name" "still present: $p"; else pass "$name"; fi
}

assert_dir_exists() {
  local p="$1" name="$2"
  if [ -d "$p" ]; then pass "$name"; else fail "$name" "missing dir: $p"; fi
}

assert_dir_absent() {
  local p="$1" name="$2"
  if [ -d "$p" ]; then fail "$name" "still present: $p"; else pass "$name"; fi
}

run_statusline() { bash "$STATUSLINE" </dev/null 2>&1; }

run_cli() { node "$CLI" --yes "$@" </dev/null; }
run_uninstall() { node "$CLI" --uninstall </dev/null; }

# section NAME — begins a test section. When RUN_ONLY is set (as an ERE),
# only sections whose name matches run; the rest are skipped entirely (no
# forks, no body execution). Use as: `section "..." && { ...body... }`.
#
# Caveat: some sections depend on state set up by earlier sections (primed
# cache, mock bin dirs from make_mock_bin). A filtered run may fail for those
# unless the filter pattern also matches the setup section.
section() {
  if [ -n "${RUN_ONLY:-}" ] && ! [[ $1 =~ $RUN_ONLY ]]; then
    return 1
  fi
  printf '%s\n' "$1"
}

# make_mock_bin VAR NAME CMD < mock-body
# Writes the heredoc body to $SANDBOX/bin-<NAME>/<CMD>, chmod's it executable,
# and assigns the bin dir to VAR so callers can prepend it to PATH. Takes a
# varname rather than echoing to sidestep bash's heredoc-in-$() parse quirk.
make_mock_bin() {
  local dir="$SANDBOX/bin-$2"
  mkdir -p "$dir"
  cat > "$dir/$3"
  chmod +x "$dir/$3"
  eval "$1=\$dir"
}

# Poll up to 3s for the backgrounded refresh to populate the cache. The
# mocked curl→jq→mv pipeline usually lands in <100ms; CI can be slower.
wait_for_cache() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -s "$CACHE" ] && return 0
    sleep 0.2
  done
  return 1
}

prime_cache() {
  # Uninstall now removes the cache dir when empty; recreate on demand so
  # tests that install/uninstall repeatedly don't race with its absence.
  mkdir -p "$(dirname "$CACHE")"
  printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" > "$CACHE"
  touch "$CACHE"
}

prime_cache_multi() {
  mkdir -p "$(dirname "$CACHE")"
  : > "$CACHE"
  while [ $# -gt 0 ]; do
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CACHE"
    shift 3
  done
  touch "$CACHE"
}

# -----------------------------------------------------------------------------
echo
echo "=== statusline.sh ==="

section "colors.sh is sourceable standalone" && {
out=$(sh -c ". $SCRIPT_DIR/bin/colors.sh && set_ansi x red && printf '%s' \"\$x\"")
expected=$(printf '\033[31m')
assert_equals "$out" "$expected" "set_ansi red → ESC[31m"

out=$(sh -c ". $SCRIPT_DIR/bin/colors.sh && set_ansi x bold_green && printf '%s' \"\$x\"")
expected=$(printf '\033[1;32m')
assert_equals "$out" "$expected" "set_ansi bold_green → ESC[1;32m"

out=$(sh -c ". $SCRIPT_DIR/bin/colors.sh && set_ansi x '38;5;208' && printf '%s' \"\$x\"")
expected=$(printf '\033[38;5;208m')
assert_equals "$out" "$expected" "set_ansi accepts raw SGR params"

out=$(sh -c ". $SCRIPT_DIR/bin/colors.sh && set_ansi x none && printf '[%s]' \"\$x\"")
assert_equals "$out" "[]" "set_ansi none emits empty string"

# Palette names resolve according to detected depth — force each depth via
# COLORTERM / FORCE_COLOR / NO_COLOR and verify the right fallback fires.
out=$(sh -c "COLORTERM=truecolor . $SCRIPT_DIR/bin/colors.sh && set_ansi x amber && printf '%s' \"\$x\"")
expected=$(printf '\033[38;2;255;193;7m')
assert_equals "$out" "$expected" "palette amber → truecolor when COLORTERM=truecolor"

out=$(sh -c "unset COLORTERM; FORCE_COLOR=2 . $SCRIPT_DIR/bin/colors.sh && set_ansi x amber && printf '%s' \"\$x\"")
expected=$(printf '\033[38;5;214m')
assert_equals "$out" "$expected" "palette amber → 256-color when FORCE_COLOR=2"

out=$(sh -c "unset COLORTERM; NO_COLOR=1 . $SCRIPT_DIR/bin/colors.sh && set_ansi x amber && printf '%s' \"\$x\"")
assert_equals "$out" "" "NO_COLOR=1 fully suppresses palette colors (no-color.org spec)"

out=$(sh -c "unset COLORTERM; NO_COLOR=1 . $SCRIPT_DIR/bin/colors.sh && set_ansi x red && printf '%s' \"\$x\"")
assert_equals "$out" "" "NO_COLOR=1 fully suppresses SGR-named colors"

out=$(sh -c "unset COLORTERM; NO_COLOR=1 . $SCRIPT_DIR/bin/colors.sh && printf '%s' \"\$RESET\"")
assert_equals "$out" "" "NO_COLOR=1 blanks RESET too (no stray \\e[0m)"

out=$(sh -c "unset COLORTERM; FORCE_COLOR=0 . $SCRIPT_DIR/bin/colors.sh && set_ansi x amber && printf '%s' \"\$x\"")
assert_equals "$out" "" "FORCE_COLOR=0 matches NO_COLOR (force-color.org spec)"

out=$(sh -c "COLORTERM=truecolor . $SCRIPT_DIR/bin/colors.sh && set_ansi x pink && printf '%s' \"\$x\"")
expected=$(printf '\033[38;2;255;105;180m')
assert_equals "$out" "$expected" "palette pink → truecolor RGB"

}
section "JS colorDepth() and sh COLOR_DEPTH agree across env matrix" && {
# The wizard preview (JS) and the installed hot path (sh) must pick the same
# depth for the same environment, or palette colors will render differently
# in the wizard vs. the actual status line. JS mirrors sh's detection logic
# byte-for-byte — walk the cases to make sure neither side drifts.
#
# Matrix is a single string per row: "ENV_ASSIGNMENTS|EXPECTED_DEPTH". Envs
# are newline-separated inside the row (one `export` per line in sh, one
# assignment per line for node) so we can clear COLORTERM/TERM independently
# without cross-contamination from the parent env.
while IFS='|' read -r envs expected; do
  [ -z "$envs$expected" ] && continue
  # sh side: unset the lot first so the outer shell's TERM/COLORTERM can't
  # leak into the case statement, then apply the row's assignments.
  sh_depth=$(sh -c "unset NO_COLOR FORCE_COLOR COLORTERM TERM; $envs . $SCRIPT_DIR/bin/colors.sh && printf '%s' \"\$COLOR_DEPTH\"")
  # JS side: same env scrubbing via `env -i`, then forward the row's vars.
  # Node's own getColorDepth() is no longer consulted — colorDepth() is now
  # pure env reads, so the result is deterministic.
  js_depth=$(env -i PATH="$PATH" sh -c "$envs node -e \"process.stdout.write(String(require('$CLI').colorDepth()))\"")
  if [ "$sh_depth" = "$expected" ] && [ "$js_depth" = "$expected" ]; then
    pass "COLOR_DEPTH=$expected for env: ${envs//$'\n'/ }"
  else
    fail "COLOR_DEPTH=$expected for env: ${envs//$'\n'/ }" "sh=$sh_depth js=$js_depth"
  fi
done <<'MATRIX'
NO_COLOR=1|0
FORCE_COLOR=0|0
FORCE_COLOR=false|0
FORCE_COLOR=no|0
FORCE_COLOR=1|4
FORCE_COLOR=true|4
FORCE_COLOR=yes|4
FORCE_COLOR=2|8
FORCE_COLOR=3|24
NO_COLOR=1 FORCE_COLOR=3|0
COLORTERM=truecolor|24
COLORTERM=24bit|24
TERM=dumb|0
TERM=xterm-256color|8
TERM=xterm|8
|4
MATRIX

}
section "feed line rendering from cache" && {
prime_cache "HN" "Hello World" "https://example.com/1"
out=$(run_statusline)
assert_contains "$out" "HN • Hello World" "per-line label rendered"
assert_contains "$out" $'\e]8;;https://example.com/1' "title wrapped in OSC 8 hyperlink"

}
section "stdin is ignored" && {
out=$(printf '{"bogus":"data"}' | bash "$STATUSLINE" 2>&1)
assert_contains "$out" "HN • Hello World" "feed line renders even with JSON on stdin"

}
section "multi-feed cache cycles through labels" && {
prime_cache_multi \
  "HN"       "Story One"   "https://example.com/1" \
  "r/prog"   "Story Two"   "https://example.com/2" \
  "Lobsters" "Story Three" "https://example.com/3"
make_mock_bin fakedate_dir fakedate date <<'SH'
#!/bin/sh
[ "$1" = "+%s" ] && echo "${FAKE_NOW:-0}" || exec /bin/date "$@"
SH
out=$(FAKE_NOW=0 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN • Story One" "rotation index 0 shows first feed"
out=$(FAKE_NOW=20 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "r/prog • Story Two" "rotation advances at ROTATION_SEC=20"
out=$(FAKE_NOW=40 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "Lobsters • Story Three" "third tick lands on third feed"

}
section "scroll transition between headlines" && {
# Cache still primed with the 3-line set from the rotation block.
# Defaults: ROTATION_SEC=20, SCROLL_SEC=5, dwell=15. FAKE_NOW=5 → pos=5 (dwell
# window) → static with hyperlink. FAKE_NOW=19 → pos=19, scroll frame 4
# (final) → next headline visible in window, no hyperlink.
out=$(FAKE_NOW=5 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN • Story One" "dwell window renders static current headline"
assert_contains "$out" $'\e]8;;https://example.com/1' "static frame keeps OSC 8 hyperlink"

out=$(FAKE_NOW=19 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "r/prog • Story Two" "final scroll frame reveals next headline"
assert_not_contains "$out" $'\e]8;;' "scroll frames omit OSC 8 hyperlink"

out=$(NEWSLINE_SCROLL=0 FAKE_NOW=19 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN • Story One" "NEWSLINE_SCROLL=0 disables the transition (stays on current)"
assert_contains "$out" $'\e]8;;https://example.com/1' "NEWSLINE_SCROLL=0 keeps OSC 8 at end of cycle"

# Single-line cache → scroll never engages (no next headline to slide to).
prime_cache "HN" "Alone" "https://example.com/alone"
out=$(FAKE_NOW=19 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN • Alone" "single-line cache stays static through scroll window"
assert_contains "$out" $'\e]8;;https://example.com/alone' "single-line cache keeps OSC 8 at end of cycle"

# Boundary: ROTATION_SEC=1 means there's no dwell + scroll budget at all. The
# clamp in statusline.sh forces SCROLL_SEC to max(0, ROTATION_SEC-1) = 0,
# which then trips the `SCROLL_SEC -gt 0` guard and falls back to static
# rendering. Previously this was unexercised — a future change to the clamp
# (e.g. "keep 1s of dwell minimum") could accidentally leave SCROLL_SEC
# negative and divide-by-zero in render_scroll_window.
prime_cache_multi \
  "HN"     "Story One"  "https://example.com/1" \
  "r/prog" "Story Two"  "https://example.com/2"
for fake_now in 0 1 2 3 4 5; do
  out=$(NEWSLINE_ROTATION_SEC=1 FAKE_NOW=$fake_now PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
  if printf '%s' "$out" | grep -qE "(Story One|Story Two)"; then
    pass "NEWSLINE_ROTATION_SEC=1 renders statically at FAKE_NOW=$fake_now"
  else
    fail "NEWSLINE_ROTATION_SEC=1 renders statically at FAKE_NOW=$fake_now" "got: $out"
  fi
done

}
section "title truncation" && {
long="This is a very long headline that should definitely get truncated by the max title setting"
prime_cache "HN" "$long" "https://example.com/3"
out=$(NEWSLINE_MAX_TITLE=30 bash "$STATUSLINE" </dev/null)
assert_contains "$out" "..." "truncates long titles with ellipsis"
assert_not_contains "$out" "truncated by the max" "removes overflow characters"

}
section "hyperlink toggle" && {
prime_cache "HN" "Hyperlink Test" "https://example.com/h"
out=$(NEWSLINE_HYPERLINKS=never bash "$STATUSLINE" </dev/null)
assert_not_contains "$out" $'\e]8;;' "NEWSLINE_HYPERLINKS=never suppresses OSC 8 escape"
assert_contains "$out" "HN • Hyperlink Test" "title still rendered without link"
out=$(NEWSLINE_HYPERLINKS=auto TERM_PROGRAM=Apple_Terminal bash "$STATUSLINE" </dev/null)
assert_not_contains "$out" $'\e]8;;' "auto mode disables links for Apple_Terminal"
out=$(NEWSLINE_HYPERLINKS=always TERM_PROGRAM=Apple_Terminal bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e]8;;https://example.com/h' "always mode overrides auto-detection"

}
section "FORCE_HYPERLINK overrides NEWSLINE_HYPERLINKS and auto-detection" && {
# Claude Code honors FORCE_HYPERLINK globally; we let it trump our knob so a
# user who disabled hyperlinks upstream doesn't have to configure us twice.
out=$(FORCE_HYPERLINK=0 NEWSLINE_HYPERLINKS=always bash "$STATUSLINE" </dev/null)
assert_not_contains "$out" $'\e]8;;' "FORCE_HYPERLINK=0 trumps NEWSLINE_HYPERLINKS=always"
out=$(FORCE_HYPERLINK=1 NEWSLINE_HYPERLINKS=never bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e]8;;https://example.com/h' "FORCE_HYPERLINK=1 trumps NEWSLINE_HYPERLINKS=never"
out=$(FORCE_HYPERLINK=1 TERM_PROGRAM=Apple_Terminal bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e]8;;' "FORCE_HYPERLINK=1 trumps Apple_Terminal auto-disable"

}
section "NO_COLOR suppresses all ANSI color output end-to-end" && {
out=$(NO_COLOR=1 bash "$STATUSLINE" </dev/null)
# No ESC[xxm anywhere — matches anything starting with ESC[ followed by
# digits and ending in m. OSC 8 hyperlink escapes (ESC]8;;…) don't carry
# color and are allowed through.
if printf '%s' "$out" | grep -qE $'\e\\[[0-9;]*m'; then
  fail "NO_COLOR=1 emits no ANSI color escapes" "found SGR codes in output"
else
  pass "NO_COLOR=1 emits no ANSI color escapes"
fi

}
section "NEWSLINE_DEBUG=1 prints config report and exits" && {
out=$(NEWSLINE_DEBUG=1 NEWSLINE_COLOR_FEED=red bash "$STATUSLINE" </dev/null)
assert_contains "$out" "claude-newsline debug"          "debug banner present"
assert_contains "$out" "CLAUDE_CONFIG_DIR ="            "shows config dir"
assert_contains "$out" "NEWSLINE_COLOR_FEED"            "shows a knob name"
assert_contains "$out" "red"                            "shows its resolved value"
# Attribution: NEWSLINE_COLOR_FEED was set in env, should say "env";
# NEWSLINE_ROTATION_SEC was not, should say "default".
line=$(printf '%s' "$out" | grep 'NEWSLINE_COLOR_FEED ')
case "$line" in *env*) pass "debug: NEWSLINE_COLOR_FEED attributed to env" ;; *) fail "debug: NEWSLINE_COLOR_FEED attributed to env" "got: $line" ;; esac
line=$(printf '%s' "$out" | grep 'NEWSLINE_ROTATION_SEC')
case "$line" in *default*) pass "debug: NEWSLINE_ROTATION_SEC attributed to default" ;; *) fail "debug: NEWSLINE_ROTATION_SEC attributed to default" "got: $line" ;; esac

}
section "PREFIX brand glyph renders to the left of every headline" && {
prime_cache "HN" "Hello World" "https://example.com/1"
# Strip ANSI SGR escapes so we assert on visible text only — the prefix has
# its own color block, so raw bytes carry \e[0m between the glyph and the label.
strip_ansi() { printf '%s' "$1" | LC_ALL=C sed -E 's/'$'\e''\[[0-9;]*m//g'; }

out=$(bash "$STATUSLINE" </dev/null)
visible=$(strip_ansi "$out")
assert_contains "$visible" "Ξ HN • Hello World" "default NEWSLINE_PREFIX=Ξ renders before label"

out=$(NEWSLINE_PREFIX="» " NEWSLINE_COLOR_PREFIX=none bash "$STATUSLINE" </dev/null)
visible=$(strip_ansi "$out")
assert_contains "$visible" "» HN • Hello World" "custom NEWSLINE_PREFIX overrides default"

out=$(NEWSLINE_PREFIX="" bash "$STATUSLINE" </dev/null)
visible=$(strip_ansi "$out")
assert_not_contains "$visible" "Ξ" "NEWSLINE_PREFIX='' disables the brand glyph"
case "$visible" in
  " "*) fail "NEWSLINE_PREFIX='' leaves no leading space" "visible text starts with space: [$visible]" ;;
  *) pass "NEWSLINE_PREFIX='' leaves no leading space" ;;
esac

# NEWSLINE_PREFIX lives inside the OSC 8 wrapper so the whole line (including
# glyph) is clickable — the hyperlink payload wraps everything.
out=$(bash "$STATUSLINE" </dev/null)
case "$out" in
  *$'\e]8;;https://example.com/1\e\\'*"Ξ"*"Hello World"*$'\e]8;;\e\\'*)
    pass "NEWSLINE_PREFIX sits inside the OSC 8 hyperlink" ;;
  *) fail "NEWSLINE_PREFIX sits inside the OSC 8 hyperlink" "glyph not between OSC 8 open/close" ;;
esac

}
section "NEWSLINE_SHOW_LABELS=0 hides the source prefix" && {
prime_cache "HN" "Just the Headline" "https://example.com/bare"
out=$(NEWSLINE_SHOW_LABELS=0 bash "$STATUSLINE" </dev/null)
assert_contains "$out" "Just the Headline" "headline still rendered with NEWSLINE_SHOW_LABELS=0"
assert_not_contains "$out" "HN •" "source label suppressed with NEWSLINE_SHOW_LABELS=0"
assert_contains "$out" $'\e]8;;https://example.com/bare' "OSC 8 hyperlink still applied"

}
section "NEWSLINE_LABEL_SEP override" && {
out=$(NEWSLINE_LABEL_SEP=" | " bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN | Just the Headline" "custom NEWSLINE_LABEL_SEP rendered between label and title"
assert_not_contains "$out" "HN •" "default separator replaced when NEWSLINE_LABEL_SEP is set"

}
section "empty-label cache line (no prefix, url still linked)" && {
prime_cache "" "Unlabeled Title" "https://example.com/unlabeled"
out=$(run_statusline)
assert_contains "$out" "Unlabeled Title" "unlabeled title still rendered"
assert_contains "$out" $'\e]8;;https://example.com/unlabeled' "unlabeled url still linked"
assert_not_contains "$out" "HN •" "no label prefix when label is empty"

}
section "NEWSLINE_COLOR_FEED override" && {
prime_cache "HN" "Color Test" "https://example.com/c"
out=$(NEWSLINE_COLOR_FEED=magenta bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e[35m' "NEWSLINE_COLOR_FEED=magenta emits ESC[35m"
out=$(NEWSLINE_COLOR_FEED="38;5;208" bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e[38;5;208m' "NEWSLINE_COLOR_FEED accepts raw ANSI SGR params"
out=$(NEWSLINE_COLOR_FEED=none bash "$STATUSLINE" </dev/null)
assert_not_contains "$out" $'\e[33m' "NEWSLINE_COLOR_FEED=none suppresses the color code"

}
section "empty cache → no output" && {
: > "$CACHE"
out=$(run_statusline)
assert_equals "$out" "" "nothing printed when cache is empty"

}
section "non-numeric ROTATION_SEC/REFRESH_SEC/MAX_TITLE fall back to defaults silently" && {
prime_cache "HN" "Numeric Guard" "https://example.com/n"
# Zero/negative/garbage must not produce awk or [ errors on stderr.
err=$(NEWSLINE_ROTATION_SEC=0     bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
assert_equals "$err" "" "NEWSLINE_ROTATION_SEC=0 emits no stderr"
err=$(NEWSLINE_ROTATION_SEC=abc   bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
assert_equals "$err" "" "NEWSLINE_ROTATION_SEC=abc emits no stderr"
err=$(NEWSLINE_REFRESH_SEC=foo    bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
assert_equals "$err" "" "NEWSLINE_REFRESH_SEC=foo emits no stderr"
err=$(NEWSLINE_MAX_TITLE=0        bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
assert_equals "$err" "" "NEWSLINE_MAX_TITLE=0 emits no stderr"
err=$(NEWSLINE_SCROLL_WIDTH=xyz   bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
assert_equals "$err" "" "NEWSLINE_SCROLL_WIDTH=xyz emits no stderr"

}
section "multi-byte title truncation does not produce U+FFFD replacement char" && {
# Japanese "日本語テスト" = 18 UTF-8 bytes over 6 codepoints. A byte-cut at
# byte 7 (room = MAX - 3) lands mid-codepoint of 本 (E6 9C AC) and naïvely
# renders as U+FFFD. iconv -c must strip the orphan bytes.
prime_cache "HN" "日本語テスト" "https://example.com/m"
out=$(NEWSLINE_MAX_TITLE=10 bash "$STATUSLINE" </dev/null)
fffd=$(printf '\xef\xbf\xbd')
assert_not_contains "$out" "$fffd" "truncated multibyte title has no U+FFFD byte sequence"
assert_contains     "$out" "..."   "multibyte truncation still appends ellipsis"

}
section "multi-byte title in scroll window emits valid UTF-8 (no orphan bytes)" && {
# BSD awk's substr() is byte-based, so a scroll-window slice can bisect a
# CJK/emoji codepoint, leaving orphan continuation bytes that a terminal
# renders as U+FFFD (replacement char). render_scroll_window now post-
# processes through `iconv -c` to drop any partial sequences.
#
# Correct assertion: the output must parse as valid UTF-8 end-to-end. We
# pipe through `iconv -f UTF-8 -t UTF-8` (no -c) and require exit 0. This
# catches the raw-bytes-that-would-render-as-U+FFFD case, which plain
# string-matching on U+FFFD bytes misses.
prime_cache_multi \
  "HN"     "日本語テスト ABC"  "https://example.com/jp1" \
  "r/dev"  "日本語テスト XYZ"  "https://example.com/jp2"
# Offset at each frame with ROTATION_SEC=20, SCROLL_SEC=5, SCROLL_WIDTH=60:
# pos=15→0, pos=16→15, pos=17→30, pos=18→45, pos=19→60. Offsets 15/30/45
# all land inside the 3-byte CJK codepoints when the prefix is "HN • "
# (7 bytes) — so without the fix, frames 16/17/18 fail UTF-8 validation.
for t in 15 16 17 18 19; do
  out=$(FAKE_NOW=$t PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
  if printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    pass "scroll frame FAKE_NOW=$t emits valid UTF-8"
  else
    fail "scroll frame FAKE_NOW=$t emits valid UTF-8" "iconv found invalid UTF-8 bytes"
  fi
done

}
section "control bytes in cache are stripped at refresh (defense-in-depth)" && {
# refresh_all_feeds pipes through `tr -d` to strip 0x00-0x08 + 0x0B-0x1F + 0x7F.
# A title primed directly into the cache bypasses that path — but our feed
# pipeline is the only producer in real usage. Verify tr -d against a payload.
# Only \x1b (ESC, 0x1B) and \x07 (BEL, 0x07) should be removed; the surrounding
# "[31m", "ESC" and "BEL" letters are printable ASCII and stay.
raw=$(printf 'safe\x1b[31mESC\x07BEL')
clean=$(printf '%s' "$raw" | LC_ALL=C tr -d '\000-\010\013-\037\177')
assert_equals "$clean" "safe[31mESCBEL" "tr -d strips ESC + BEL control bytes only"

}
section "reddit dispatch normalizes r/ /r/ m/ /m/ to the same URL (shell-side parity)" && {
# Parity check: the installer normalizes prefixes via parseRedditSubs →
# normalizeRedditEntry. Since users can hand-edit .env, the runtime has its
# own POSIX-glob mirror in refresh_all_feeds. This test fires the real
# refresh pipeline with a mock curl that echoes each requested URL back as
# the post title, then asserts every variant resolves to the canonical
# /r/<name>/top.json shape. If the two tiers drift, one of the assertions
# below fails loudly at CI time.
make_mock_bin mock_dir mockcurl curl <<'SH'
#!/bin/sh
# Echo the URL arg into a minimal shape the feed's jq filter accepts. The
# URL appears verbatim in the post title so the cache records what we asked for.
url=""
for arg in "$@"; do
  case "$arg" in https://*) url="$arg" ;; esac
done
printf '{"data":{"children":[{"data":{"title":"URL=%s","permalink":"/x"}}]}}\n' "$url"
SH
rm -f "$CACHE" "$CACHE.lock"
NEWSLINE_REDDIT_SUBS="r/rust, /r/test, m/foo, /m/bar, programming" \
  NEWSLINE_FEEDS_DISABLED="hn,lobsters" \
  PATH="$mock_dir:$PATH" \
  bash "$STATUSLINE" </dev/null >/dev/null 2>&1
wait_for_cache
out=$(cat "$CACHE" 2>/dev/null || printf '')
assert_contains "$out" "URL=https://www.reddit.com/r/rust/top.json"        "r/rust resolves to /r/rust"
assert_contains "$out" "URL=https://www.reddit.com/r/test/top.json"        "/r/test resolves to /r/test"
assert_contains "$out" "URL=https://www.reddit.com/r/foo/top.json"         "m/foo resolves to /r/foo"
assert_contains "$out" "URL=https://www.reddit.com/r/bar/top.json"         "/m/bar resolves to /r/bar"
assert_contains "$out" "URL=https://www.reddit.com/r/programming/top.json" "bare sub resolves to /r/programming"

}
section "cache interleaves buckets round-robin so one feed can't monopolize the rotation" && {
# Mock HN (5 items) + 2 reddit subs (3 items each) with distinct titles per
# bucket. With CACHE_CHUNK=2 the expected order is:
#   HN1 HN2  R1a R1b  R2a R2b   ← pos=0 pass over 3 buckets
#   HN3 HN4  R1c      R2c       ← pos=2 (R1 and R2 exhaust)
#   HN5                         ← pos=4 (HN only)
# Concretely: we assert R1a appears before HN3, which is the property that
# matters — no one bucket can drain fully before another starts.
make_mock_bin mock_dir2 mockinterleave curl <<'SH'
#!/bin/sh
url=""; for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
case "$url" in
  *hn.algolia*)
    printf '{"hits":['
    i=1; sep=""
    while [ "$i" -le 5 ]; do
      printf '%s{"title":"HN%d","objectID":"%d"}' "$sep" "$i" "$i"
      sep=','; i=$((i+1))
    done
    printf ']}\n'
    ;;
  *r/rust*)
    printf '{"data":{"children":[{"data":{"title":"RUST1","permalink":"/1"}},{"data":{"title":"RUST2","permalink":"/2"}},{"data":{"title":"RUST3","permalink":"/3"}}]}}\n'
    ;;
  *r/golang*)
    printf '{"data":{"children":[{"data":{"title":"GO1","permalink":"/1"}},{"data":{"title":"GO2","permalink":"/2"}},{"data":{"title":"GO3","permalink":"/3"}}]}}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
rm -f "$CACHE" "$CACHE.lock"
NEWSLINE_CACHE_CHUNK=2 NEWSLINE_REDDIT_SUBS="rust,golang" NEWSLINE_FEEDS_DISABLED="lobsters" \
  PATH="$mock_dir2:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1
wait_for_cache
# Line-number lookups — if any of these greps fail, the bucket wasn't emitted.
hn3_line=$(grep -n 'HN3' "$CACHE" | head -1 | cut -d: -f1)
rust1_line=$(grep -n 'RUST1' "$CACHE" | head -1 | cut -d: -f1)
go1_line=$(grep -n 'GO1' "$CACHE" | head -1 | cut -d: -f1)
if [ -n "$rust1_line" ] && [ -n "$hn3_line" ] && [ "$rust1_line" -lt "$hn3_line" ]; then
  pass "reddit entry appears before HN's 3rd entry (interleave engaged)"
else
  fail "reddit entry appears before HN's 3rd entry (interleave engaged)" "RUST1 at $rust1_line, HN3 at $hn3_line"
fi
if [ -n "$go1_line" ] && [ -n "$hn3_line" ] && [ "$go1_line" -lt "$hn3_line" ]; then
  pass "second reddit sub appears before HN's 3rd entry"
else
  fail "second reddit sub appears before HN's 3rd entry" "GO1 at $go1_line, HN3 at $hn3_line"
fi

}

# -----------------------------------------------------------------------------
echo
echo "=== bin/claude-newsline.js (install) ==="

section "install preserves unrelated keys" && {
cat > "$SETTINGS" <<'JSON'
{
  "model": "claude-opus-4-7",
  "permissions": {"allow": ["Bash(*)"]}
}
JSON
run_cli >/dev/null 2>&1
model=$(jq -r '.model' "$SETTINGS")
perms=$(jq -r '.permissions.allow[0]' "$SETTINGS")
assert_equals "$model" "claude-opus-4-7" "model key preserved"
assert_equals "$perms" "Bash(*)" "permissions key preserved"

}
section "install creates statusLine when none existed" && {
type=$(jq -r '.statusLine.type' "$SETTINGS")
cmd=$(jq -r '.statusLine.command' "$SETTINGS")
interval=$(jq -r '.statusLine.refreshInterval' "$SETTINGS")
assert_equals "$type" "command" "statusLine.type = command"
assert_contains "$cmd" "claude-newsline.sh" "command points at installed script"
assert_equals "$interval" "1" "refreshInterval set to 1 when unset (drives scroll animation)"

}
section "install appends to existing statusLine.command" && {
cat > "$SETTINGS" <<'JSON'
{
  "statusLine": {"type": "command", "command": "bash /usr/local/bin/my-statusline.sh", "refreshInterval": 5}
}
JSON
run_cli >/dev/null 2>&1
cmd=$(jq -r '.statusLine.command' "$SETTINGS")
assert_contains "$cmd" "my-statusline.sh" "existing user script preserved"
assert_contains "$cmd" "claude-newsline.sh" "claude-newsline appended"
assert_contains "$cmd" ";" "commands chained with semicolon"
interval=$(jq -r '.statusLine.refreshInterval' "$SETTINGS")
assert_equals "$interval" "5" "existing refreshInterval preserved"

}
section "install is idempotent (no double-append)" && {
run_cli >/dev/null 2>&1
cmd_after=$(jq -r '.statusLine.command' "$SETTINGS")
count=$(printf '%s' "$cmd_after" | grep -o 'claude-newsline.sh' | wc -l | tr -d ' ')
assert_equals "$count" "1" "re-install does not add a second claude-newsline reference"
assert_contains "$cmd_after" "my-statusline.sh" "user script still preserved after re-install"

}
section "install copies both statusline.sh and colors.sh" && {
assert_file_exists "$CLAUDE_CONFIG_DIR/claude-newsline.sh" "claude-newsline.sh installed"
assert_file_exists "$CLAUDE_CONFIG_DIR/colors.sh"         "colors.sh installed"

}
section "--disable writes .env.NEWSLINE_FEEDS_DISABLED" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --disable reddit,lobsters >/dev/null 2>&1
fd=$(jq -r '.env.NEWSLINE_FEEDS_DISABLED' "$SETTINGS")
assert_equals "$fd" "reddit,lobsters" "disabled feeds written to .env.NEWSLINE_FEEDS_DISABLED"

}
section "--only inverts into FEEDS_DISABLED" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --only hn >/dev/null 2>&1
fd=$(jq -r '.env.NEWSLINE_FEEDS_DISABLED' "$SETTINGS")
assert_contains "$fd" "reddit" "--only hn disables reddit"
assert_contains "$fd" "lobsters" "--only hn disables lobsters"
assert_not_contains "$fd" "hn" "--only hn keeps hn enabled"

}
section "--disable \"\" clears a pre-existing FEEDS_DISABLED" && {
# The explicit-empty shape is the user saying "I want no feeds disabled,
# revert to the default (all enabled)." Without clear semantics the key
# would survive forever until the wizard was re-run.
cat > "$SETTINGS" <<JSON
{"env": {"NEWSLINE_FEEDS_DISABLED": "reddit"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --disable "" >/dev/null 2>&1
assert_env_gone NEWSLINE_FEEDS_DISABLED "--disable \"\" deletes FEEDS_DISABLED"
# Unrelated keys must survive the clear — only the targeted key is touched.
cat > "$SETTINGS" <<JSON
{"env": {"NEWSLINE_FEEDS_DISABLED": "reddit", "NEWSLINE_COLOR_FEED": "sky"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --disable "" >/dev/null 2>&1
assert_env_gone NEWSLINE_FEEDS_DISABLED "--disable \"\" clears only the targeted key"
assert_equals "$(jq -r '.env.NEWSLINE_COLOR_FEED' "$SETTINGS")" "sky" \
  "--disable \"\" preserves unrelated owned keys"

}
section "--color \"\" clears a pre-existing COLOR_FEED" && {
# Symmetric with --disable "": empty value = revert to runtime default.
# Previously `--color=""` was silently a no-op (empty string treated as
# "not passed"); now it's an explicit clear signal.
cat > "$SETTINGS" <<JSON
{"env": {"NEWSLINE_COLOR_FEED": "sky"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --color "" >/dev/null 2>&1
assert_env_gone NEWSLINE_COLOR_FEED "--color \"\" deletes COLOR_FEED"

}
section "--separator \"\" clears a pre-existing LABEL_SEP" && {
cat > "$SETTINGS" <<JSON
{"env": {"NEWSLINE_LABEL_SEP": " | "}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --separator "" >/dev/null 2>&1
assert_env_gone NEWSLINE_LABEL_SEP "--separator \"\" deletes LABEL_SEP"

}
section "--rotation \"\" clears a pre-existing ROTATION_SEC" && {
cat > "$SETTINGS" <<JSON
{"env": {"NEWSLINE_ROTATION_SEC": "45"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --rotation "" >/dev/null 2>&1
assert_env_gone NEWSLINE_ROTATION_SEC "--rotation \"\" deletes ROTATION_SEC"

}
section "--reddit-subs \"\" clears a pre-existing REDDIT_SUBS" && {
cat > "$SETTINGS" <<JSON
{"env": {"NEWSLINE_REDDIT_SUBS": "rust"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --reddit-subs "" >/dev/null 2>&1
assert_env_gone NEWSLINE_REDDIT_SUBS "--reddit-subs \"\" deletes REDDIT_SUBS"

}
section "--color writes .env.NEWSLINE_COLOR_FEED" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --color bold_magenta >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_COLOR_FEED' "$SETTINGS")" "bold_magenta" "--color writes COLOR_FEED"

}
section "--no-labels writes .env.NEWSLINE_SHOW_LABELS=0" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --no-labels >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_SHOW_LABELS' "$SETTINGS")" "0" "--no-labels writes SHOW_LABELS=0"

}
section "--separator writes .env.NEWSLINE_LABEL_SEP (preserving spaces)" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --separator " | " >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_LABEL_SEP' "$SETTINGS")" " | " "--separator writes LABEL_SEP with surrounding spaces"

}
section "--rotation writes .env.NEWSLINE_ROTATION_SEC (non-default only)" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --rotation 45 >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_ROTATION_SEC' "$SETTINGS")" "45" "--rotation 45 writes ROTATION_SEC=45"

}
section "--rotation at runtime default is elided from .env" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --rotation 20 >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_ROTATION_SEC // "unset"' "$SETTINGS")" "unset" "--rotation 20 (default) doesn't clutter .env"

}
section "--rotation rejects invalid values" && {
if run_cli --rotation abc >/dev/null 2>&1; then
  fail "--rotation abc exits non-zero" "exited 0 on --rotation abc"
else
  pass "--rotation abc exits non-zero"
fi
if run_cli --rotation 0 >/dev/null 2>&1; then
  fail "--rotation 0 exits non-zero" "exited 0 on --rotation 0"
else
  pass "--rotation 0 exits non-zero"
fi
if run_cli --rotation 99999 >/dev/null 2>&1; then
  fail "--rotation 99999 exits non-zero" "exited 0 on --rotation 99999"
else
  pass "--rotation 99999 exits non-zero"
fi

}
section "--motion static writes SCROLL=0 and clears SCROLL_SEC" && {
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_SCROLL_SEC": "8"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --motion static >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_SCROLL' "$SETTINGS")" "0" "--motion static writes SCROLL=0"
assert_env_gone NEWSLINE_SCROLL_SEC "--motion static clears SCROLL_SEC (meaningless when SCROLL=0)"

}
section "--motion quick writes SCROLL_SEC=3 and clears SCROLL" && {
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_SCROLL": "0"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --motion quick >/dev/null 2>&1
assert_env_gone NEWSLINE_SCROLL "--motion quick clears SCROLL (revert to runtime default 1)"
assert_equals "$(jq -r '.env.NEWSLINE_SCROLL_SEC' "$SETTINGS")" "3" "--motion quick writes SCROLL_SEC=3"

}
section "--motion slide clears both owned scroll keys" && {
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_SCROLL": "0", "NEWSLINE_SCROLL_SEC": "8"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --motion slide >/dev/null 2>&1
assert_env_gone NEWSLINE_SCROLL     "--motion slide clears SCROLL"
assert_env_gone NEWSLINE_SCROLL_SEC "--motion slide clears SCROLL_SEC"

}
section "--motion \"\" clears both owned scroll keys (explicit reset)" && {
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_SCROLL": "0", "NEWSLINE_SCROLL_SEC": "3"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --motion "" >/dev/null 2>&1
assert_env_gone NEWSLINE_SCROLL     "--motion \"\" clears SCROLL"
assert_env_gone NEWSLINE_SCROLL_SEC "--motion \"\" clears SCROLL_SEC"

}
section "--motion rejects invalid values" && {
if run_cli --motion zippy >/dev/null 2>&1; then
  fail "--motion zippy exits non-zero" "exited 0 on --motion zippy"
else
  pass "--motion zippy exits non-zero"
fi
if run_cli --motion STATIC >/dev/null 2>&1; then
  fail "--motion STATIC exits non-zero (case-sensitive)" "exited 0 on --motion STATIC"
else
  pass "--motion STATIC exits non-zero (case-sensitive)"
fi

}
section "--motion leaves unrelated owned keys alone" && {
# Flag-driven install (no wizard) must not purge other owned keys just
# because --motion was passed — only the motion-related keys get rewritten.
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_COLOR_FEED": "sky", "NEWSLINE_FEEDS_DISABLED": "reddit"}, "statusLine": {"type":"command","command":"echo x"}}
JSON
run_cli --motion static >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_COLOR_FEED' "$SETTINGS")" "sky" "--motion preserves COLOR_FEED"
assert_equals "$(jq -r '.env.NEWSLINE_FEEDS_DISABLED' "$SETTINGS")" "reddit" "--motion preserves FEEDS_DISABLED"
assert_equals "$(jq -r '.env.NEWSLINE_SCROLL' "$SETTINGS")" "0" "--motion static still wrote SCROLL=0"

}
section "default --labels does NOT write SHOW_LABELS (it's the runtime default)" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --labels >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_SHOW_LABELS // "unset"' "$SETTINGS")" "unset" "--labels alone doesn't clutter .env"

}
section "--labels undoes a prior --no-labels without entering the wizard" && {
# Flag-driven install skips clearStaleEnv, so a stale SHOW_LABELS=0 used to
# survive a later --labels run. buildEnvUpdates now emits SHOW_LABELS=undefined
# for --labels, which reconcileEnv interprets as "delete the key so the
# runtime default (labels on) takes over".
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_SHOW_LABELS": "0"}}
JSON
run_cli --labels >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_SHOW_LABELS // "cleared"' "$SETTINGS")" "cleared" \
  "--labels clears a previously-set SHOW_LABELS=0"

}
section "--reddit-subs writes .env.NEWSLINE_REDDIT_SUBS (normalized, validated)" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --reddit-subs "programming, rust ,golang" >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_REDDIT_SUBS' "$SETTINGS")" "programming,rust,golang" "--reddit-subs writes trimmed CSV"

}
section "--reddit-subs strips r/, /r/, m/, /m/ (URL-bar copy-paste)" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --reddit-subs "r/rust, r/golang+linux, /r/test, m/foo, /m/bar+baz" >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_REDDIT_SUBS' "$SETTINGS")" "rust,golang+linux,test,foo,bar+baz" "r/, /r/, m/, /m/ prefixes normalized away"

}
section "--reddit-subs accepts '+' combined-feed syntax" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --reddit-subs "rust+golang+linux" >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_REDDIT_SUBS' "$SETTINGS")" "rust+golang+linux" "'+'-joined multi stored unchanged"

}
section "--reddit-subs accepts 'user/multi' named-multi syntax" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --reddit-subs "mawburn/techsubs" >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_REDDIT_SUBS' "$SETTINGS")" "mawburn/techsubs" "user/multi stored unchanged"

}
section "--reddit-subs accepts a mix" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --reddit-subs "programming,rust+golang,mawburn/techsubs" >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_REDDIT_SUBS' "$SETTINGS")" "programming,rust+golang,mawburn/techsubs" "mixed entries preserved"

}
section "--reddit-subs rejects invalid entries" && {
if run_cli --reddit-subs "has space" >/dev/null 2>&1; then
  fail "rejects entry with space" "exited 0"
else
  pass "rejects entry with space"
fi
for bad in "+foo" "foo+" "foo++bar" "foo/bar/baz" "foo/" "/bar"; do
  if run_cli --reddit-subs "$bad" >/dev/null 2>&1; then
    fail "rejects malformed entry '$bad'" "exited 0"
  else
    pass "rejects malformed entry '$bad'"
  fi
done

}
section "--reddit-subs rejects too-long lists" && {
# Build a 20-element CSV in pure bash so the test suite has no python3 dep.
# 20 > MAX_REDDIT_SUBS (15) → validation rejects.
many=$(i=0; s=""; while [ "$i" -lt 20 ]; do [ -n "$s" ] && s="$s,"; s="${s}sub${i}"; i=$((i+1)); done; printf '%s' "$s")
if run_cli --reddit-subs "$many" >/dev/null 2>&1; then
  fail "rejects subreddit list over cap" "exited 0 (list: $many)"
else
  pass "rejects subreddit list over cap"
fi

}
section "--reddit-subs at exactly MAX_REDDIT_SUBS is accepted" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
boundary=$(i=0; s=""; while [ "$i" -lt 15 ]; do [ -n "$s" ] && s="$s,"; s="${s}sub${i}"; i=$((i+1)); done; printf '%s' "$s")
if run_cli --reddit-subs "$boundary" >/dev/null 2>&1; then
  pass "accepts 15-subreddit list at boundary"
else
  fail "accepts 15-subreddit list at boundary" "rejected at the cap itself"
fi

}
section "--reddit-subs=programming (default) does NOT clutter .env" && {
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --reddit-subs programming >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_REDDIT_SUBS // "unset"' "$SETTINGS")" "unset" "default subreddit skips .env write"

}
section "uninstall cleans up SHOW_LABELS and LABEL_SEP" && {
cat > "$SETTINGS" <<JSON
{
  "statusLine":{"type":"command","command":"bash '$CLAUDE_CONFIG_DIR/claude-newsline.sh'"},
  "env":{"NEWSLINE_SHOW_LABELS":"0","NEWSLINE_LABEL_SEP":" | ","NEWSLINE_REDDIT_SUBS":"rust,golang","USER_KEEP_ME":"intact"}
}
JSON
run_uninstall >/dev/null 2>&1
assert_env_gone NEWSLINE_SHOW_LABELS "SHOW_LABELS removed on uninstall"
assert_env_gone NEWSLINE_LABEL_SEP   "LABEL_SEP removed on uninstall"
assert_env_gone NEWSLINE_REDDIT_SUBS "REDDIT_SUBS removed on uninstall"
assert_equals "$(jq -r '.env.USER_KEEP_ME' "$SETTINGS")" "intact" "user keys preserved"

}
section "--disable <unknown> exits non-zero" && {
if run_cli --disable bogus >/dev/null 2>&1; then
  fail "rejects unknown feed name" "exited 0"
else
  pass "rejects unknown feed name"
fi

}
section "--list-feeds prints feed list" && {
out=$(node "$CLI" --list-feeds)
assert_contains "$out" "hn" "--list-feeds includes hn"
assert_contains "$out" "reddit" "--list-feeds includes reddit"
assert_contains "$out" "lobsters" "--list-feeds includes lobsters"

}
section "--help prints usage" && {
out=$(node "$CLI" --help)
assert_contains "$out" "Usage:" "--help prints Usage"
assert_contains "$out" "--disable" "--help lists --disable"

}
section "install creates timestamped backup" && {
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
rm -f "$SETTINGS".bak.*
run_cli >/dev/null 2>&1
bak_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$bak_count" -ge 1 ]; then
  pass "backup created"
else
  fail "backup created" "no .bak.* file present"
fi

}
section "backup dedups against prior .bak when content is unchanged" && {
# Back-to-back no-op installs shouldn't keep creating byte-identical .bak
# files forever. The second pass below re-runs install on a settings.json
# that already contains our suffix — the backup step should see it matches
# the prior .bak and reuse it instead of writing another copy.
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
rm -f "$SETTINGS".bak.*
run_cli >/dev/null 2>&1          # bak.1 = original
sleep 1                           # force a different ts if a new bak were created
run_cli >/dev/null 2>&1          # bak.2 = post-install-1 (differs from bak.1)
sleep 1
count_before=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
run_cli >/dev/null 2>&1          # no-op: settings unchanged since bak.2
count_after=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$count_before" "2" "two distinct backups from two real changes"
assert_equals "$count_after"  "2" "no-op reinstall reuses the prior backup"

}
section "backup keeps at most MAX_BACKUPS distinct .bak files" && {
# Dedup prevents byte-identical backups from piling up, but a long-lived
# user editing settings.json repeatedly would still accumulate legitimately-
# distinct backups forever. Pruning caps the tail. We simulate by dropping
# a bunch of pre-dated .bak files next to SETTINGS and running install —
# the resulting directory should contain at most MAX_BACKUPS of them
# (counting the one install just created). Oldest-first deletion keeps
# the most recent history intact.
rm -f "$SETTINGS".bak.*
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
# Seed 14 fake backups with strictly increasing timestamps so lex order
# matches chronological order (mirrors how listBackups sorts them).
base_ts=1700000000
for i in $(seq 0 13); do
  ts=$((base_ts + i))
  printf '{"seed":%s}\n' "$i" > "$SETTINGS.bak.$ts"
done
seed_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$seed_count" "14" "seeded 14 fake backups before install"
run_cli >/dev/null 2>&1         # creates one more real backup → 15 total before prune
final_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
max_backups=$(node -e "console.log(require('$CLI').MAX_BACKUPS)")
assert_equals "$final_count" "$max_backups" "prune keeps exactly MAX_BACKUPS"
# Oldest seeds pruned first: .bak.1700000000 (the first one) must be gone,
# but the latest seed (.bak.1700000013) must survive as part of the tail.
if [ -e "$SETTINGS.bak.$base_ts" ]; then
  fail "oldest backup pruned" "still exists: $SETTINGS.bak.$base_ts"
else
  pass "oldest backup pruned"
fi
assert_file_exists "$SETTINGS.bak.$((base_ts + 13))" "newest seed survives pruning"

}
section "install emits CLAUDE_NEWSLINE=<ver> marker prefix" && {
# Ownership marker: installer writes `CLAUDE_NEWSLINE=v1 bash '<path>'` so
# future installers can identify their own past work by sentinel rather
# than by the (still-matched) path basename. The env-var-as-command-prefix
# syntax is POSIX — it scopes VAR to just that command, no export leak.
# Compose the expected prefix from module exports so a MARKER_VALUE bump
# doesn't silently pass a stale literal.
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
run_cli >/dev/null 2>&1
cmd=$(jq -r '.statusLine.command' "$SETTINGS")
marker=$(node -e "const m = require('$CLI'); process.stdout.write(m.MARKER_VAR + '=' + m.MARKER_VALUE)")
assert_contains "$cmd" "$marker bash '" "installed command carries marker prefix"
# Runtime sanity: the marker prefix must not break execution through sh.
rm -rf "$CLAUDE_CONFIG_DIR/cache"
sh -c "$cmd" </dev/null >/dev/null 2>&1
assert_dir_exists "$CLAUDE_CONFIG_DIR/cache" "command with marker prefix runs through sh -c"

}
section "install leaves no .tmp.* files in cfgDir on happy path" && {
# Transactional install stages scriptDest / colorsDest through sibling tmp
# files and renames them over the destination after writeSettings succeeds.
# The cleanup() handler only matters on the failure path, but a stray tmp
# file on the happy path would indicate a rename that silently didn't
# happen — which would point at a stale script of a prior version.
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
run_cli >/dev/null 2>&1
tmp_count=$(ls "$CLAUDE_CONFIG_DIR"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$tmp_count" "0" "no .tmp.* files left after successful install"
assert_file_exists "$CLAUDE_CONFIG_DIR/claude-newsline.sh" "scriptDest is in place"
assert_file_exists "$CLAUDE_CONFIG_DIR/colors.sh"         "colorsDest is in place"

}
section "readSettings refuses to silently treat a blank file as {}" && {
# A zero-byte or whitespace-only settings.json almost certainly means a
# writer was killed mid-flush. Silently returning {} would make the next
# install overwrite whatever was there. The installer now errors instead.
printf '' > "$SETTINGS"
if node "$CLI" --yes </dev/null >/dev/null 2>&1; then
  fail "blank settings.json aborts install" "exited 0"
else
  pass "blank settings.json aborts install"
fi
printf '   \n\t  \n' > "$SETTINGS"
if node "$CLI" --yes </dev/null >/dev/null 2>&1; then
  fail "whitespace-only settings.json aborts install" "exited 0"
else
  pass "whitespace-only settings.json aborts install"
fi
# Restore a valid file AND a live install for the next section, which
# reads statusLine.command expecting our suffix to be present.
echo '{}' > "$SETTINGS"
run_cli >/dev/null 2>&1

}
section "install writes a single-quoted, shell-safe path" && {
# The installer must quote the path so ; $ backtick and spaces in $HOME can't
# break the chained command. Since the path is quoted, it should appear
# surrounded by single quotes in the command.
cmd=$(jq -r '.statusLine.command' "$SETTINGS")
quoted_marker=$(printf "bash '[^']*claude-newsline.sh'")
if printf '%s' "$cmd" | grep -Eq "$quoted_marker"; then
  pass "installed command uses single-quoted path"
else
  fail "installed command uses single-quoted path" "got: $cmd"
fi

}
section "install survives CLAUDE_CONFIG_DIR with a space" && {
SPACE_SANDBOX="$SANDBOX/has space/config"
(
  export CLAUDE_CONFIG_DIR="$SPACE_SANDBOX"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{}
JSON
  node "$CLI" --yes </dev/null >/dev/null 2>&1
)
space_cmd=$(jq -r '.statusLine.command' "$SPACE_SANDBOX/settings.json")
assert_contains "$space_cmd" "has space" "path with space preserved in .statusLine.command"
# The runtime must actually execute. Simulate what Claude Code does: eval
# through sh -c and confirm the script runs (mkdir'ing its cache dir is a
# non-destructive side effect we can detect).
rm -rf "$SPACE_SANDBOX/cache"
CLAUDE_CONFIG_DIR="$SPACE_SANDBOX" sh -c "$space_cmd" </dev/null >/dev/null 2>&1
assert_dir_exists "$SPACE_SANDBOX/cache" "command runs through sh -c with spaces"

}
section "--color rejects unknown color names" && {
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
if run_cli --color reed >/dev/null 2>&1; then
  fail "rejects unknown color name" "exited 0 on --color reed"
else
  pass "rejects unknown color name"
fi
# Raw SGR params are allowed even though they aren't in NAMED_COLORS.
if run_cli --color "38;5;208" >/dev/null 2>&1; then
  pass "--color accepts raw SGR params"
else
  fail "--color accepts raw SGR params" "rejected valid SGR sequence"
fi
# Palette names from PALETTE (amber/coral/pink/etc) must be accepted too.
if run_cli --color amber >/dev/null 2>&1; then
  pass "--color accepts palette name 'amber'"
else
  fail "--color accepts palette name 'amber'" "rejected palette name"
fi

}
section "value flag with missing argument exits non-zero" && {
# `--color` with no arg must not silently set color=undefined (a no-op), and
# `--color --yes` must not swallow --yes as the color value. Both fail loudly.
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
if node "$CLI" --color </dev/null >/dev/null 2>&1; then
  fail "--color with no argument exits non-zero" "exited 0"
else
  pass "--color with no argument exits non-zero"
fi
if node "$CLI" --color --yes </dev/null >/dev/null 2>&1; then
  fail "--color followed by --yes exits non-zero" "exited 0 (swallowed --yes as value)"
else
  pass "--color followed by --yes exits non-zero"
fi
if node "$CLI" --reddit-subs </dev/null >/dev/null 2>&1; then
  fail "--reddit-subs with no argument exits non-zero" "exited 0"
else
  pass "--reddit-subs with no argument exits non-zero"
fi

}
section "install refuses to auto-confirm on non-TTY without --yes" && {
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
# No --yes, stdin is piped (non-TTY) → must exit non-zero and not touch settings.
pre_hash=$(md5 -q "$SETTINGS" 2>/dev/null || md5sum "$SETTINGS" | cut -d' ' -f1)
if node "$CLI" </dev/null >/dev/null 2>&1; then
  fail "non-TTY without --yes exits non-zero" "exited 0"
else
  pass "non-TTY without --yes exits non-zero"
fi
post_hash=$(md5 -q "$SETTINGS" 2>/dev/null || md5sum "$SETTINGS" | cut -d' ' -f1)
assert_equals "$post_hash" "$pre_hash" "non-TTY refusal leaves settings.json untouched"

}
section "install follows a settings.json symlink without replacing it" && {
# Dotfiles setup: ~/.claude/settings.json → ~/dotfiles/claude-settings.json.
# writeSettings must dereference the symlink, write to the real path, and
# leave the link itself intact — a naive rename() would replace the symlink
# with a regular file, orphaning the dotfile.
mkdir -p "$SANDBOX/dotfiles"
echo '{"model":"claude-opus-4-7"}' > "$SANDBOX/dotfiles/real-settings.json"
rm -f "$SETTINGS"
ln -s "$SANDBOX/dotfiles/real-settings.json" "$SETTINGS"
run_cli >/dev/null 2>&1
if [ -L "$SETTINGS" ]; then
  pass "settings.json symlink preserved after install"
else
  fail "settings.json symlink preserved after install" "link replaced by regular file"
fi
# The real file should have been updated through the link.
if grep -q "claude-newsline" "$SANDBOX/dotfiles/real-settings.json"; then
  pass "install wrote through symlink to real target"
else
  fail "install wrote through symlink to real target" "real file untouched"
fi
# Cleanup — subsequent tests expect $SETTINGS to be a regular file.
rm -f "$SETTINGS"
rm -rf "$SANDBOX/dotfiles"
echo '{}' > "$SETTINGS"

}
section "install aborts on malformed settings.json without orphaning a backup" && {
cat > "$SETTINGS" <<'JSON'
{ this is : not valid JSON at all
JSON
rm -f "$SETTINGS".bak.*
if node "$CLI" --yes </dev/null >/dev/null 2>&1; then
  fail "malformed JSON aborts install" "exited 0"
else
  pass "malformed JSON aborts install"
fi
bak_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$bak_count" "0" "no .bak.* orphaned after parse failure"
# Restore a sane file for downstream tests.
echo '{}' > "$SETTINGS"

}
section "install tolerates a non-string statusLine.command field" && {
# Claude Code's schema makes this a string, but a hand-edited `null`, a
# number, or an object would otherwise crash stripSuffix()'s .replace call
# with a cryptic TypeError. The guard treats non-strings as empty so we
# overwrite cleanly. Runs the same check against install and uninstall.
for bad_cmd in 'null' '42' '{"nested":"obj"}' '["a","b"]'; do
  cat > "$SETTINGS" <<JSON
{"statusLine": {"type":"command","command": $bad_cmd}}
JSON
  if run_cli >/dev/null 2>&1; then
    pass "install survives .statusLine.command=$bad_cmd"
  else
    fail "install survives .statusLine.command=$bad_cmd" "crashed or exited non-zero"
  fi
  # After install, command should be our canonical string form.
  out=$(jq -r '.statusLine.command' "$SETTINGS")
  if printf '%s' "$out" | grep -q "claude-newsline.sh"; then
    pass "install overwrites non-string command with $bad_cmd"
  else
    fail "install overwrites non-string command with $bad_cmd" "got: $out"
  fi
done
# Same for uninstall — a malformed pre-existing command must not crash cleanup.
cat > "$SETTINGS" <<'JSON'
{"statusLine": {"type":"command","command": 42}}
JSON
if run_uninstall >/dev/null 2>&1; then
  pass "uninstall survives non-string .statusLine.command"
else
  fail "uninstall survives non-string .statusLine.command" "crashed"
fi
echo '{}' > "$SETTINGS"

}
section "ALL_FEEDS stays in sync between statusline.sh and claude-newsline.js" && {
js_feeds=$(node -e "console.log(require('$CLI').ALL_FEEDS.join(' '))")
sh_feeds=$(grep -E "^ALL_FEEDS=" "$SCRIPT_DIR/bin/statusline.sh" | sed "s/.*='\(.*\)'/\1/")
assert_equals "$js_feeds" "$sh_feeds" "ALL_FEEDS constant matches across JS and sh"

}
section "re-install with identical flags prints 'Configuration already matches'" && {
# The noop-detection branch in describePlan exists so a user re-running the
# wizard and accepting all defaults sees "nothing changed" instead of a
# misleading list of identical env assignments.
cat > "$SETTINGS" <<'JSON'
{"model": "claude-opus-4-7"}
JSON
run_cli --color amber >/dev/null 2>&1
out=$(run_cli --color amber 2>&1)
assert_contains "$out" "Configuration already matches" \
  "identical re-install reports no settings change"
assert_not_contains "$out" "Planned changes to settings.json" \
  "identical re-install suppresses the bulletted change list"

}

# -----------------------------------------------------------------------------
echo
echo "=== bin/claude-newsline.js (uninstall) ==="

section "uninstall strips our suffix, preserves user command" && {
cat > "$SETTINGS" <<JSON
{
  "statusLine": {"type": "command", "command": "bash /opt/mine.sh ; bash $CLAUDE_CONFIG_DIR/claude-newsline.sh", "refreshInterval": 20}
}
JSON
run_uninstall >/dev/null 2>&1
cmd=$(jq -r '.statusLine.command // "gone"' "$SETTINGS")
assert_equals "$cmd" "bash /opt/mine.sh" "uninstall strips our suffix, leaves user command"
assert_equals "$(jq -r '.statusLine.type' "$SETTINGS")" "command" "statusLine.type preserved"

}
section "uninstall removes statusLine entirely when only ours was present" && {
cat > "$SETTINGS" <<JSON
{
  "model": "claude-opus-4-7",
  "statusLine": {"type": "command", "command": "bash $CLAUDE_CONFIG_DIR/claude-newsline.sh"}
}
JSON
run_uninstall >/dev/null 2>&1
assert_equals "$(jq 'has("statusLine")' "$SETTINGS")" "false" "statusLine removed when only ours present"
assert_equals "$(jq -r '.model' "$SETTINGS")" "claude-opus-4-7" "unrelated keys preserved"

}
section "uninstall removes our .env keys, preserves user keys" && {
cat > "$SETTINGS" <<JSON
{
  "statusLine":{"type":"command","command":"bash $CLAUDE_CONFIG_DIR/claude-newsline.sh"},
  "env":{
    "NEWSLINE_COLOR_FEED":"dim",
    "NEWSLINE_FEEDS_DISABLED":"reddit",
    "NEWSLINE_ROTATION_SEC":"45",
    "NEWSLINE_SCROLL":"0",
    "NEWSLINE_SCROLL_SEC":"3",
    "USER_KEEP_ME":"intact"
  }
}
JSON
run_uninstall >/dev/null 2>&1
assert_env_gone NEWSLINE_COLOR_FEED     "COLOR_FEED removed"
assert_env_gone NEWSLINE_FEEDS_DISABLED "FEEDS_DISABLED removed"
assert_env_gone NEWSLINE_ROTATION_SEC   "ROTATION_SEC removed"
assert_env_gone NEWSLINE_SCROLL         "SCROLL removed"
assert_env_gone NEWSLINE_SCROLL_SEC     "SCROLL_SEC removed"
assert_equals "$(jq -r '.env.USER_KEEP_ME' "$SETTINGS")" "intact" "user keys preserved"

}
section "uninstall removes .env entirely when only our keys remained" && {
cat > "$SETTINGS" <<JSON
{
  "statusLine":{"type":"command","command":"bash $CLAUDE_CONFIG_DIR/claude-newsline.sh"},
  "env":{"NEWSLINE_COLOR_FEED":"bold","NEWSLINE_FEEDS_DISABLED":"reddit"}
}
JSON
run_uninstall >/dev/null 2>&1
assert_equals "$(jq 'has("env")' "$SETTINGS")" "false" ".env key deleted when only our keys were in it"

}
section "uninstall removes installed script, colors.sh, and cache" && {
run_cli >/dev/null 2>&1
prime_cache "cache cleanup test" "https://example.com/cache"
run_uninstall >/dev/null 2>&1
assert_file_absent "$CLAUDE_CONFIG_DIR/claude-newsline.sh" "script deleted"
assert_file_absent "$CLAUDE_CONFIG_DIR/colors.sh"          "colors.sh deleted"
assert_file_absent "$CACHE"                                "cache file removed"

}
section "uninstall is idempotent on clean config" && {
rm -f "$SETTINGS".bak.*
if run_uninstall >/dev/null 2>&1; then
  pass "second uninstall exits cleanly"
else
  fail "second uninstall exits cleanly" "non-zero exit on no-op"
fi

}
section "uninstall aborts on malformed settings.json without orphaning a backup" && {
cat > "$SETTINGS" <<'JSON'
{ definitely not JSON
JSON
rm -f "$SETTINGS".bak.*
if run_uninstall >/dev/null 2>&1; then
  fail "malformed JSON aborts uninstall" "exited 0"
else
  pass "malformed JSON aborts uninstall"
fi
bak_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$bak_count" "0" "no .bak.* orphaned after uninstall parse failure"

}
section "uninstall removes empty cache directory" && {
rm -rf "$CLAUDE_CONFIG_DIR"
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{}' > "$SETTINGS"
run_cli >/dev/null 2>&1
run_uninstall >/dev/null 2>&1
assert_dir_absent "$CLAUDE_CONFIG_DIR/cache" "empty cache/ dir removed on uninstall"

}
section "uninstall preserves non-empty cache directory" && {
rm -rf "$CLAUDE_CONFIG_DIR"
mkdir -p "$CLAUDE_CONFIG_DIR/cache"
echo "user data" > "$CLAUDE_CONFIG_DIR/cache/user-stuff.txt"
echo '{}' > "$SETTINGS"
run_cli >/dev/null 2>&1
run_uninstall >/dev/null 2>&1
assert_dir_exists  "$CLAUDE_CONFIG_DIR/cache"                   "non-empty cache/ dir preserved"
assert_file_exists "$CLAUDE_CONFIG_DIR/cache/user-stuff.txt"    "user file in cache/ preserved"
rm -rf "$CLAUDE_CONFIG_DIR"
mkdir -p "$CLAUDE_CONFIG_DIR/cache"
echo '{}' > "$SETTINGS"

}
section "uninstall handles missing settings.json" && {
rm -f "$SETTINGS"
if run_uninstall >/dev/null 2>&1; then
  pass "no crash when settings.json is absent"
else
  fail "no crash when settings.json is absent" "non-zero exit"
fi

}

# -----------------------------------------------------------------------------
echo
section "unit helpers" && {

# stripSuffix / invertOnly are exported for direct unit-testing — avoids
# paying the full install round-trip when we only want to verify string
# manipulation. Anything exported from claude-newsline.js goes here.

out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix('bash /x/y.sh ; bash /z/claude-newsline.sh'));
")
assert_equals "$out" "bash /x/y.sh" "stripSuffix removes chained suffix"

out=$(node -e "
  const m = require('$CLI');
  console.log('[' + m.stripSuffix('bash /z/claude-newsline.sh') + ']');
")
assert_equals "$out" "[]" "stripSuffix blanks standalone claude-newsline command"

out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix('bash /x/y.sh'));
")
assert_equals "$out" "bash /x/y.sh" "stripSuffix leaves unrelated commands alone"

out=$(node -e "
  const m = require('$CLI');
  console.log(m.invertOnly('hn'));
")
assert_equals "$out" "reddit,lobsters" "invertOnly('hn') → reddit,lobsters"

# Regression guards for stripSuffix edge cases.

# '||' separator must not trigger a strip. A loose regex ([^;&]*) would eat
# the 'bash /x.sh || ' preamble and blank the whole command. With the
# tightened regex, a pipe between the two commands blocks the match entirely,
# so stripSuffix is a no-op.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix('bash /x/y.sh || bash /z/claude-newsline.sh'));
")
assert_equals "$out" "bash /x/y.sh || bash /z/claude-newsline.sh" \
  "stripSuffix leaves '||' chained commands alone"

# A user-owned file that merely ends in '-claude-newsline.sh' must not be
# mis-matched. The regex requires the basename to be exactly /claude-newsline.sh.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix('bash /opt/my-claude-newsline.sh'));
")
assert_equals "$out" "bash /opt/my-claude-newsline.sh" \
  "stripSuffix leaves 'my-claude-newsline.sh' alone"

# Quoted form (current installs write this) must strip cleanly — both
# chained and standalone.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"bash /x/y.sh ; bash '/z/claude-newsline.sh'\"));
")
assert_equals "$out" "bash /x/y.sh" "stripSuffix handles single-quoted suffix"

out=$(node -e "
  const m = require('$CLI');
  console.log('[' + m.stripSuffix(\"bash '/z/claude-newsline.sh'\") + ']');
")
assert_equals "$out" "[]" "stripSuffix blanks quoted standalone command"

# Mid-chain: user appended a command AFTER our suffix before reinstalling.
# Without mid-chain handling, reinstall would have duplicated our segment.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"a ; bash '/z/claude-newsline.sh' ; b\"));
")
assert_equals "$out" "a ; b" "stripSuffix removes mid-chain occurrence"

# Start-of-chain: our suffix leads, user chained commands after.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"bash '/z/claude-newsline.sh' ; b\"));
")
assert_equals "$out" "b" "stripSuffix removes start-of-chain occurrence"

# Mid-chain regression guard: a lookalike elsewhere in the string must not
# disturb an unrelated bash command.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"a ; bash /opt/my-tool.sh ; bash '/z/claude-newsline.sh'\"));
")
assert_equals "$out" "a ; bash /opt/my-tool.sh" \
  "stripSuffix leaves unrelated bash scripts alone when stripping the end"

# Paths with spaces round-trip through install → strip.
out=$(node -e "
  const m = require('$CLI');
  const p = '/Users/jane doe/.claude/claude-newsline.sh';
  const cmd = \"my-cmd ; bash \" + m.shellQuote(p);
  console.log(m.stripSuffix(cmd));
")
assert_equals "$out" "my-cmd" "stripSuffix handles path with a space via shellQuote"

# Marker-prefixed form (what current installer writes). Must strip in all
# three positions: end-of-chain, standalone, mid-chain, start-of-chain.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"a ; CLAUDE_NEWSLINE=v1 bash '/z/claude-newsline.sh'\"));
")
assert_equals "$out" "a" "stripSuffix removes end-of-chain marker-prefixed suffix"

out=$(node -e "
  const m = require('$CLI');
  console.log('[' + m.stripSuffix(\"CLAUDE_NEWSLINE=v1 bash '/z/claude-newsline.sh'\") + ']');
")
assert_equals "$out" "[]" "stripSuffix blanks marker-prefixed standalone command"

out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"a ; CLAUDE_NEWSLINE=v1 bash '/z/claude-newsline.sh' ; b\"));
")
assert_equals "$out" "a ; b" "stripSuffix removes mid-chain marker-prefixed occurrence"

out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"CLAUDE_NEWSLINE=v1 bash '/z/claude-newsline.sh' ; b\"));
")
assert_equals "$out" "b" "stripSuffix removes start-of-chain marker-prefixed occurrence"

# Back-compat: a pre-marker install (bare `bash <path>`) must still strip
# cleanly after upgrade. Without this, users on the first release would see
# the old suffix left behind beside a new one after running the updated
# installer.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.stripSuffix(\"a ; bash '/z/claude-newsline.sh'\"));
")
assert_equals "$out" "a" "stripSuffix still handles pre-marker installs (upgrade path)"

# Round-trip: install command shape emitted today must strip to empty
# after stripSuffix. This catches drift between the MARKER_PREFIX regex
# and the actual newslineCmd template in planInstall.
out=$(node -e "
  const m = require('$CLI');
  const cmd = m.MARKER_VAR + '=' + m.MARKER_VALUE + \" bash '/abs/path/claude-newsline.sh'\";
  console.log('[' + m.stripSuffix(cmd) + ']');
")
assert_equals "$out" "[]" "current install shape round-trips through stripSuffix"

# shellQuote escapes embedded ' using the POSIX '\\'' idiom.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.shellQuote(\"it's a path\"));
")
assert_equals "$out" "'it'\\''s a path'" "shellQuote escapes embedded quote"

# reconcileEnv with clearStale=true purges owned keys not in the updates
# (wizard re-run where the user turned a setting off). Flag-driven path
# leaves unrelated keys alone.
out=$(node -e "
  const m = require('$CLI');
  const env = { NEWSLINE_FEEDS_DISABLED: 'reddit', NEWSLINE_COLOR_FEED: 'red', NEWSLINE_LABEL_SEP: ' | ', USER_KEEP: 'yes' };
  m.reconcileEnv(env, { NEWSLINE_COLOR_FEED: 'blue' }, true);
  console.log(JSON.stringify(env));
")
assert_equals "$out" '{"NEWSLINE_COLOR_FEED":"blue","USER_KEEP":"yes"}' \
  "reconcileEnv clearStale=true drops owned keys not in update, keeps user keys"

# Flag-driven path: clearStale=false leaves existing keys alone, only merges.
out=$(node -e "
  const m = require('$CLI');
  const env = { NEWSLINE_FEEDS_DISABLED: 'reddit', NEWSLINE_COLOR_FEED: 'red', USER_KEEP: 'yes' };
  m.reconcileEnv(env, { NEWSLINE_COLOR_FEED: 'blue' }, false);
  console.log(JSON.stringify(env));
")
assert_equals "$out" '{"NEWSLINE_FEEDS_DISABLED":"reddit","NEWSLINE_COLOR_FEED":"blue","USER_KEEP":"yes"}' \
  "reconcileEnv clearStale=false merges, preserves existing owned keys"

# validateColor accepts named + SGR, rejects typos.
out=$(node -e "
  const m = require('$CLI');
  try { m.validateColor('bold_magenta'); console.log('ok'); }
  catch (e) { console.log('threw: ' + e.message.split('\\n')[0]); }
")
assert_equals "$out" "ok" "validateColor accepts 'bold_magenta'"
out=$(node -e "
  const m = require('$CLI');
  try { m.validateColor('38;5;208'); console.log('ok'); }
  catch (e) { console.log('threw'); }
")
assert_equals "$out" "ok" "validateColor accepts raw SGR '38;5;208'"
out=$(node -e "
  const m = require('$CLI');
  try { m.validateColor('reed'); console.log('ok'); }
  catch (e) { console.log('threw'); }
")
assert_equals "$out" "threw" "validateColor rejects typo 'reed'"

# Palette names are also valid: amber, coral, pink, mint, sky, lavender, lime.
out=$(node -e "
  const m = require('$CLI');
  try { m.validateColor('amber'); m.validateColor('sky'); m.validateColor('lavender'); console.log('ok'); }
  catch (e) { console.log('threw: ' + e.message.split('\\n')[0]); }
")
assert_equals "$out" "ok" "validateColor accepts palette names (amber/sky/lavender)"

# colorize() emits truecolor when FORCE_COLOR=3, 256-color when FORCE_COLOR=2.
out=$(FORCE_COLOR=3 node -e "
  const m = require('$CLI');
  process.stdout.write(JSON.stringify(m.colorize('x', 'amber')));
")
assert_equals "$out" '"\u001b[38;2;255;193;7mx\u001b[0m"' "colorize(amber) → truecolor under FORCE_COLOR=3"

out=$(FORCE_COLOR=2 node -e "
  const m = require('$CLI');
  process.stdout.write(JSON.stringify(m.colorize('x', 'amber')));
")
assert_equals "$out" '"\u001b[38;5;214mx\u001b[0m"' "colorize(amber) → 256-color under FORCE_COLOR=2"

out=$(NO_COLOR=1 node -e "
  const m = require('$CLI');
  process.stdout.write(JSON.stringify(m.colorize('x', 'amber')));
")
assert_equals "$out" '"x"' "colorize(amber) → plain text under NO_COLOR"

out=$(FORCE_COLOR=0 node -e "
  const m = require('$CLI');
  process.stdout.write(JSON.stringify(m.colorize('x', 'red')));
")
assert_equals "$out" '"x"' "colorize(red) → plain text under FORCE_COLOR=0"

# Raw SGR sequences pass through colorize, matching set_ansi's `*)` fallthrough
# in colors.sh. Without this, the wizard/preview would silently render
# uncolored text for a raw-SGR COLOR_FEED while the status line would color it.
out=$(FORCE_COLOR=2 node -e "
  const m = require('$CLI');
  process.stdout.write(JSON.stringify(m.colorize('x', '38;5;208')));
")
assert_equals "$out" '"\u001b[38;5;208mx\u001b[0m"' "colorize passes raw SGR sequences through (parity with set_ansi *))"

# 'none' (and the empty string) must emit bare text at any depth — the
# wizard exposes this as "No color" and relies on it round-tripping cleanly.
out=$(FORCE_COLOR=3 node -e "
  const m = require('$CLI');
  process.stdout.write(JSON.stringify(m.colorize('x', 'none')));
")
assert_equals "$out" '"x"' "colorize(none) → plain text even with colors forced on"

# validateRotation returns normalized number or null.
out=$(node -e "
  const m = require('$CLI');
  console.log(JSON.stringify([
    m.validateRotation('45'),
    m.validateRotation(45),
    m.validateRotation(''),
    m.validateRotation(null),
  ]));
")
assert_equals "$out" "[45,45,null,null]" "validateRotation returns normalized number|null"

out=$(node -e "
  const m = require('$CLI');
  try { m.validateRotation('abc'); console.log('ok'); }
  catch (e) { console.log('threw'); }
")
assert_equals "$out" "threw" "validateRotation rejects non-numeric"

out=$(node -e "
  const m = require('$CLI');
  try { m.validateRotation('999999'); console.log('ok'); }
  catch (e) { console.log('threw'); }
")
assert_equals "$out" "threw" "validateRotation rejects out-of-range"

# validateMotion — accepts the three presets + '' + null, rejects anything
# else. Case-sensitive on purpose ('static' vs 'STATIC'); flag parsing is
# case-sensitive throughout the installer and normalizing here would hide
# typos from users.
out=$(node -e "
  const m = require('$CLI');
  console.log(JSON.stringify([
    m.validateMotion('static'),
    m.validateMotion('slide'),
    m.validateMotion('quick'),
    m.validateMotion(''),
    m.validateMotion(null),
  ]));
")
assert_equals "$out" '["static","slide","quick","",null]' "validateMotion accepts presets + clear sentinel"

# Rejects the old 'smooth' name too — honest naming means we don't silently
# accept the misleading alias.
out=$(node -e "
  const m = require('$CLI');
  try { m.validateMotion('smooth'); console.log('ok'); }
  catch (e) { console.log('threw'); }
")
assert_equals "$out" "threw" "validateMotion rejects 'smooth' (stepped at 1 FPS is not smooth)"

out=$(node -e "
  const m = require('$CLI');
  try { m.validateMotion('zippy'); console.log('ok'); }
  catch (e) { console.log('threw'); }
")
assert_equals "$out" "threw" "validateMotion rejects unknown preset"

# Motion preset constants — MOTION_OPTIONS must stay in sync with the three
# strings validateMotion accepts. This is a drift guard, not a spec.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.MOTION_OPTIONS.join(','));
")
assert_equals "$out" "static,slide,quick" "MOTION_OPTIONS listed in display order"

# DEFAULT_SCROLL_SEC in JS ↔ statusline.sh must agree (the 'slide' preset's
# hint copy references it, and the wizard uses it to infer 'quick' vs 'slide'
# from an existing NEWSLINE_SCROLL_SEC value).
js_scroll=$(node -e "console.log(require('$CLI').DEFAULT_SCROLL_SEC)")
sh_scroll=$(grep -E 'NEWSLINE_SCROLL_SEC:-' "$SCRIPT_DIR/bin/statusline.sh" | head -1 | \
  sed -E 's/.*:-([^}]+)\}.*/\1/')
assert_equals "$js_scroll" "$sh_scroll" "DEFAULT_SCROLL_SEC matches statusline.sh"

# PALETTE names in JS ↔ colors.sh _palette cases must agree.
js_palette=$(node -e "
  const m = require('$CLI');
  console.log(Object.keys(m.PALETTE).sort().join(' '));
")
sh_palette=$(grep -E '^\s*[a-z]+\)\s+_palette' "$SCRIPT_DIR/bin/colors.sh" | \
  sed -E 's/^[[:space:]]*([a-z]+)\).*/\1/' | sort | tr '\n' ' ' | sed 's/ $//')
assert_equals "$js_palette" "$sh_palette" "palette names match across JS and colors.sh"

# Runtime defaults in JS ↔ statusline.sh must agree.
js_rotation=$(node -e "console.log(require('$CLI').DEFAULT_ROTATION_SEC)")
sh_rotation=$(grep -E 'NEWSLINE_ROTATION_SEC:-' "$SCRIPT_DIR/bin/statusline.sh" | head -1 | \
  sed -E 's/.*:-([^}]+)\}.*/\1/')
assert_equals "$js_rotation" "$sh_rotation" "DEFAULT_ROTATION_SEC matches statusline.sh"

js_reddit=$(node -e "console.log(require('$CLI').DEFAULT_REDDIT_SUB)")
sh_reddit=$(grep -E 'NEWSLINE_REDDIT_SUBS:-' "$SCRIPT_DIR/bin/statusline.sh" | head -1 | \
  sed -E 's/.*:-([^}]+)\}.*/\1/')
assert_equals "$js_reddit" "$sh_reddit" "DEFAULT_REDDIT_SUB matches statusline.sh"

# Wizard initial state: helper folds currentEnv into safe defaults.
out=$(node -e "
  const m = require('$CLI');
  const r = m.wizardInitialValues(
    { NEWSLINE_FEEDS_DISABLED: 'reddit', NEWSLINE_COLOR_FEED: 'sky',
      NEWSLINE_SHOW_LABELS: '0', NEWSLINE_LABEL_SEP: ' | ',
      NEWSLINE_ROTATION_SEC: '45', NEWSLINE_REDDIT_SUBS: 'rust' },
    [10, 20, 30, 60, 120], [' \u2022 ', ' | '],
  );
  console.log(JSON.stringify(r));
")
assert_contains "$out" '"feeds":["hn","lobsters"]'  "wizard pre-fills feeds from FEEDS_DISABLED"
assert_contains "$out" '"color":"sky"'              "wizard pre-fills color from env"
assert_contains "$out" '"showLabels":false'         "wizard pre-fills SHOW_LABELS=0 as false"
assert_contains "$out" '"separator":" | "'          "wizard pre-fills separator when in options"
assert_contains "$out" '"redditSubs":"rust"'        "wizard pre-fills reddit subs"
# Rotation 45 isn't in the option list — must fall back to default (20).
assert_contains "$out" '"rotation":20'              "wizard falls back when rotation not in options"

# Fresh/empty env → wizard reverts to stock defaults.
out=$(node -e "
  const m = require('$CLI');
  const r = m.wizardInitialValues({}, [10, 20, 30], [' \u2022 ']);
  console.log(JSON.stringify(r));
")
assert_contains "$out" '"feeds":["hn","reddit","lobsters"]' "wizard defaults all feeds enabled when env empty"
assert_contains "$out" '"color":"amber"'                    "wizard defaults color=amber"
assert_contains "$out" '"showLabels":true'                  "wizard defaults showLabels=true"
assert_contains "$out" '"motion":"slide"'                   "wizard defaults motion=slide when env empty"

# Motion inference from existing env — NEWSLINE_SCROLL=0 → static regardless
# of NEWSLINE_SCROLL_SEC; NEWSLINE_SCROLL_SEC<default → quick; otherwise → slide.
out=$(node -e "
  const m = require('$CLI');
  console.log(JSON.stringify([
    m.wizardInitialValues({ NEWSLINE_SCROLL: '0' }, [20], [' \u2022 ']).motion,
    m.wizardInitialValues({ NEWSLINE_SCROLL: '0', NEWSLINE_SCROLL_SEC: '3' }, [20], [' \u2022 ']).motion,
    m.wizardInitialValues({ NEWSLINE_SCROLL_SEC: '3' }, [20], [' \u2022 ']).motion,
    m.wizardInitialValues({ NEWSLINE_SCROLL_SEC: '5' }, [20], [' \u2022 ']).motion,
    m.wizardInitialValues({ NEWSLINE_SCROLL_SEC: '8' }, [20], [' \u2022 ']).motion,
    m.wizardInitialValues({}, [20], [' \u2022 ']).motion,
  ]));
")
assert_equals "$out" '["static","static","quick","slide","slide","slide"]' \
  "wizard infers motion preset from NEWSLINE_SCROLL + NEWSLINE_SCROLL_SEC"

# Reddit regex parity: round-trip a fuzz corpus through JS and sh.
# JS accept/reject must match sh's dispatch (statusline.sh's case branches).
# If either side's rules drift, one column diverges and the test fails.
mkdir -p "$CLAUDE_CONFIG_DIR/cache"
: > "$CACHE"
cat > "$CLAUDE_CONFIG_DIR/reddit-fuzz.sh" <<'EOSH'
#!/bin/sh
# Mirrors the dispatch in refresh_all_feeds — validates a single entry.
sub=$1
case "$sub" in
  /r/*|/m/*) sub=${sub#/} ;;
esac
case "$sub" in
  r/*|m/*)
    _rest=${sub#[rm]/}
    case "$_rest" in
      */*) : ;;
      *) sub=$_rest ;;
    esac
    ;;
esac
case "$sub" in
  */*)
    _user=${sub%%/*}
    _multi=${sub#*/}
    case "$_user" in ''|*[!A-Za-z0-9_-]*) echo reject; exit 0 ;; esac
    case "$_multi" in ''|*[!A-Za-z0-9_]*|*/*) echo reject; exit 0 ;; esac
    echo accept
    ;;
  *)
    case "$sub" in
      ''|*[!A-Za-z0-9_+]*|+*|*+|*++*) echo reject ;;
      *) echo accept ;;
    esac
    ;;
esac
EOSH

fuzz_cases="programming rust+golang mawburn/techsubs r/programming /m/rust+go m/ab r/ '' foo/bar/baz bad!char user-dashes/mymulti ++badedge a++b"
mismatches=0
for raw in $fuzz_cases; do
  entry=$raw
  [ "$entry" = "''" ] && entry=""
  js=$(node -e "
    const m = require('$CLI');
    console.log(m.isValidRedditEntry($(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$entry")) ? 'accept' : 'reject');
  " 2>/dev/null)
  sh=$(sh "$CLAUDE_CONFIG_DIR/reddit-fuzz.sh" "$entry")
  if [ "$js" != "$sh" ]; then
    mismatches=$((mismatches + 1))
    echo "  [drift] entry='$entry'  js=$js  sh=$sh"
  fi
done
assert_equals "$mismatches" "0" "reddit validation matches between JS and sh dispatch"
rm -f "$CLAUDE_CONFIG_DIR/reddit-fuzz.sh"

# Uninstall refreshInterval: our-default gets cleaned, user-set is preserved.
cat > "$SETTINGS" <<JSON
{
  "statusLine": {
    "type": "command",
    "command": "bash /opt/mine.sh ; bash $CLAUDE_CONFIG_DIR/claude-newsline.sh",
    "refreshInterval": 1
  }
}
JSON
run_uninstall >/dev/null 2>&1
out=$(jq -r '.statusLine.refreshInterval // "gone"' "$SETTINGS")
assert_equals "$out" "gone" "uninstall removes refreshInterval=1 (our default)"
assert_equals "$(jq -r '.statusLine.command' "$SETTINGS")" "bash /opt/mine.sh" "uninstall still strips our suffix"

cat > "$SETTINGS" <<JSON
{
  "statusLine": {
    "type": "command",
    "command": "bash /opt/mine.sh ; bash $CLAUDE_CONFIG_DIR/claude-newsline.sh",
    "refreshInterval": 5
  }
}
JSON
run_uninstall >/dev/null 2>&1
out=$(jq -r '.statusLine.refreshInterval' "$SETTINGS")
assert_equals "$out" "5" "uninstall preserves user-set refreshInterval"

}

# -----------------------------------------------------------------------------
echo
echo "=== summary ==="
printf '  passed: \033[32m%d\033[0m\n' "$PASS"
printf '  failed: \033[31m%d\033[0m\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    printf '  - %s\n' "$t"
  done
  exit 1
fi
echo "  all good."
