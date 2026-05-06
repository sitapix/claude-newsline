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
      NEWSLINE_SCROLL_SEC NEWSLINE_SCROLL_SEPARATOR \
      NEWSLINE_CACHE_CHUNK NEWSLINE_CACHE_FILE NEWSLINE_USER_AGENT \
      FORCE_HYPERLINK NEWSLINE_DEBUG \
      NO_COLOR FORCE_COLOR COLORTERM

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

# Bootstrap a baseline install for sections that only inspect post-install
# state. Idempotent: if the runtime files are already in place from a prior
# section, no-op. Without this, a narrow RUN_ONLY filter that targets an
# inspect-only section (e.g. "install copies runtime scripts") would fail
# because the prior section that ran the install was skipped.
ensure_installed() {
  [ -f "$CLAUDE_CONFIG_DIR/claude-newsline.sh" ] && return 0
  [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
  run_cli >/dev/null 2>&1
}

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
  # Drop any sibling double-buffer slot left over from a previous section —
  # without this, a pending file from the last test can leak in and be
  # promoted here, silently corrupting the primed content.
  rm -f "$CACHE.pending"
  printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" > "$CACHE"
  touch "$CACHE"
}

prime_cache_multi() {
  mkdir -p "$(dirname "$CACHE")"
  rm -f "$CACHE.pending"
  : > "$CACHE"
  while [ $# -gt 0 ]; do
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CACHE"
    shift 3
  done
  touch "$CACHE"
}

# Sections that drive the rotation/scroll math need a `date +%s` mock so
# FAKE_NOW=… is deterministic. Originally this was set up once in the
# "multi-feed cache cycles through labels" section and downstream sections
# inherited it — which broke under narrow RUN_ONLY filters. ensure_fakedate
# is idempotent: any consumer can call it; the first call seeds the mock,
# the rest are no-ops. Sets the global $fakedate_dir.
ensure_fakedate() {
  [ -n "${fakedate_dir:-}" ] && [ -x "$fakedate_dir/date" ] && return 0
  make_mock_bin fakedate_dir fakedate date <<'SH'
#!/bin/sh
[ "$1" = "+%s" ] && echo "${FAKE_NOW:-0}" || exec /bin/date "$@"
SH
}

# -----------------------------------------------------------------------------
echo
echo "=== statusline.sh ==="

section "colors.sh is sourceable standalone" && {
# FORCE_COLOR=1 pins COLOR_DEPTH to 4 (16-color). CI runners have TERM=dumb and
# no COLORTERM, which legitimately resolves to COLOR_DEPTH=0 — these tests
# assert set_ansi's mapping, not the depth detector, so force the depth.
out=$(sh -c "FORCE_COLOR=1 . $SCRIPT_DIR/bin/colors.sh && set_ansi x red && printf '%s' \"\$x\"")
expected=$(printf '\033[31m')
assert_equals "$out" "$expected" "set_ansi red → ESC[31m"

out=$(sh -c "FORCE_COLOR=1 . $SCRIPT_DIR/bin/colors.sh && set_ansi x bold_green && printf '%s' \"\$x\"")
expected=$(printf '\033[1;32m')
assert_equals "$out" "$expected" "set_ansi bold_green → ESC[1;32m"

out=$(sh -c "FORCE_COLOR=1 . $SCRIPT_DIR/bin/colors.sh && set_ansi x '38;5;208' && printf '%s' \"\$x\"")
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
ensure_fakedate
out=$(FAKE_NOW=0 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN • Story One" "rotation index 0 shows first feed"
out=$(FAKE_NOW=20 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "r/prog • Story Two" "rotation advances at ROTATION_SEC=20"
out=$(FAKE_NOW=40 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "Lobsters • Story Three" "third tick lands on third feed"

}
section "scroll transition between headlines" && {
# Standalone setup so RUN_ONLY=scroll works without the rotation section.
# ensure_fakedate is idempotent — the rotation section's call wins on a
# full run, this is just the safety net for narrow filters.
prime_cache_multi \
  "HN"       "Story One"   "https://example.com/1" \
  "r/prog"   "Story Two"   "https://example.com/2" \
  "Lobsters" "Story Three" "https://example.com/3"
ensure_fakedate
# Defaults: ROTATION_SEC=20, SCROLL_SEC=5, dwell=15. FAKE_NOW=5 → pos=5 (dwell
# window) → static with hyperlink. FAKE_NOW=19 → pos=19, scroll frame 4
# (final) → next headline visible in window, no hyperlink.
out=$(FAKE_NOW=5 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "HN • Story One" "dwell window renders static current headline"
assert_contains "$out" $'\e]8;;https://example.com/1' "static frame keeps OSC 8 hyperlink"

out=$(FAKE_NOW=19 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "r/prog • Story Two" "final scroll frame reveals next headline"
assert_not_contains "$out" $'\e]8;;' "scroll frames omit OSC 8 hyperlink"

# Regression guard (M4): at the first scroll frame, the NEXT headline must
# not yet be visible in the viewport. The original bug was that a fixed-
# width viewport (SCROLL_WIDTH=MAX_TITLE=60) was wider than `cur + sep + next`
# combined, so the next headline sat in-frame from the moment the scroll
# started — it looked like a hard cut rather than a slide. We now size the
# viewport per-frame to max(len(cur), len(next)) and pad both titles, so
# `next` is genuinely off-viewport at the first motion step and slides in.
#
# We intentionally don't assert that `cur` is *fully* visible at frame 0 —
# the current offset formula starts motion immediately (frame 0 shows
# slide/S progress, not offset 0), so part of `cur` has already slid off
# the left edge by frame 0. That's correct: every scroll frame is a motion
# step, no frame duplicates the dwell.
out=$(FAKE_NOW=15 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_not_contains "$out" "Story Two" "first scroll frame must NOT expose the next headline yet"
assert_contains "$out" "Story One" "first scroll frame still has cur visible (partial, but present)"

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
section "double-buffered cache: refresh is deferred to rotation boundary" && {
# Regression guard: a cache refresh that lands mid-dwell must NOT change the
# displayed headline until the next pos_in_cycle=0. Without double-buffering
# (M3 in the audit), a user watching "Old Story" would suddenly see "New
# Story" 3 seconds in because refresh_all_feeds overwrote $CACHE directly.
ensure_fakedate
prime_cache_multi \
  "HN" "OldOne" "https://example.com/old1" \
  "HN" "OldTwo" "https://example.com/old2"
# Pre-seed a .pending that would normally be written by refresh_all_feeds
# once a fresh cache exists.
printf '%s\t%s\t%s\n' "HN" "NewOne" "https://example.com/new1" >  "$CACHE.pending"
printf '%s\t%s\t%s\n' "HN" "NewTwo" "https://example.com/new2" >> "$CACHE.pending"
# Make pending freshly-written so the REFRESH_SEC-based "stale cache → promote
# immediately" path doesn't kick in (cache itself is just-touched too).
touch "$CACHE.pending" "$CACHE"

# FAKE_NOW=5: pos=5 of 20-sec rotation, mid-dwell of entry 1. Pending must
# not be promoted; we must still see Old content.
out=$(FAKE_NOW=5 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains     "$out" "OldOne" "mid-dwell keeps showing old cache"
assert_not_contains "$out" "NewOne" "pending cache not promoted mid-dwell"
# Sanity: pending file should still exist after that read.
if [ -s "$CACHE.pending" ]; then
  pass "pending file survives a mid-dwell tick"
else
  fail "pending file survives a mid-dwell tick" "pending vanished at FAKE_NOW=5"
fi

# FAKE_NOW=20: pos_in_cycle = 20 % 20 = 0 (rotation boundary). Rotation
# index advances: (int(20/20) % NR) + 1 = (1 % 2) + 1 = 2, so after
# promotion we land on entry 2 = "NewTwo" (NOT NewOne — that's the entry
# we'd see at FAKE_NOW=0, a full cycle earlier). Pending promotes and the
# test proves both that the promotion happened AND that the rotation math
# is consistent with the live cache.
printf '%s\t%s\t%s\n' "HN" "NewOne" "https://example.com/new1" >  "$CACHE.pending"
printf '%s\t%s\t%s\n' "HN" "NewTwo" "https://example.com/new2" >> "$CACHE.pending"
touch "$CACHE.pending" "$CACHE"
out=$(FAKE_NOW=20 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "NewTwo" "rotation boundary promotes pending (post-promotion entry 2 = NewTwo)"
if [ ! -f "$CACHE.pending" ]; then
  pass "pending file consumed after promotion"
else
  fail "pending file consumed after promotion" "pending still exists"
fi

# Stale-cache shortcut: if the live cache is past REFRESH_SEC, promotion
# happens immediately regardless of pos_in_cycle. This keeps first-launch
# and long-absence scenarios from forcing users to stare at stale content
# until the next rotation boundary.
#
# We need three things for this test:
#   1. Cache mtime = known, far-past → we use `perl utime` to set epoch 0.
#      (touch -t is TZ-dependent and can't reach negative/zero epoch.)
#   2. FAKE_NOW > REFRESH_SEC (600) so age > REFRESH_SEC triggers staleness.
#   3. FAKE_NOW NOT a multiple of ROTATION_SEC (20) so pos != 0, to prove
#      the staleness shortcut — not the boundary — fires the promotion.
# 703 satisfies both: 703 - 0 = 703 > 600 ✓ stale, 703 % 20 = 3 ✗ not boundary.
prime_cache "HN" "Stale" "https://example.com/stale"
perl -e 'utime 0, 0, $ARGV[0]' "$CACHE"
printf '%s\t%s\t%s\n' "HN" "Fresh" "https://example.com/fresh" > "$CACHE.pending"
out=$(FAKE_NOW=703 PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
assert_contains "$out" "Fresh" "stale cache triggers immediate pending promotion (no waiting for pos=0)"

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
section "OSC 8 URL scheme guard: non-http(s) URLs drop the hyperlink" && {
# Defense against terminal URL-handler argument injection (CVE-2023-46321 iTerm2
# x-man-page://, iTerm2 ssh://-E, Hyper RCE chains). A URL that escapes the
# jq filter's expected http(s) shape or arrives via a tampered feed payload
# must not be passed to the terminal's URL-handler via OSC 8 — we still
# render the headline, just without the clickable link.

# Malicious/non-http schemes get rendered unlinked
for bad_url in 'x-man-page://foo' 'ssh://-E.profile' 'javascript:alert(1)' 'file:///etc/passwd' 'data:text/html,x'; do
  prime_cache "HN" "Scheme Test" "$bad_url"
  out=$(NEWSLINE_HYPERLINKS=always bash "$STATUSLINE" </dev/null)
  assert_not_contains "$out" $'\e]8;;' "URL scheme '$bad_url' dropped from OSC 8"
  assert_contains "$out" "HN • Scheme Test" "headline still rendered despite bad scheme"
done

# Control: http and https both pass through
prime_cache "HN" "HTTP OK" "http://example.com/a"
out=$(NEWSLINE_HYPERLINKS=always bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e]8;;http://example.com/a' "http:// passes the scheme guard"
prime_cache "HN" "HTTPS OK" "https://example.com/b"
out=$(NEWSLINE_HYPERLINKS=always bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e]8;;https://example.com/b' "https:// passes the scheme guard"

# RFC 3986: schemes are case-insensitive. Legacy Atom feeds occasionally
# emit HTTP:// / Https:// — the guard should pass them through unchanged.
for ok_url in 'HTTP://example.com/upper' 'Https://example.com/mixed' 'HTTPS://example.com/all'; do
  prime_cache "HN" "Case Test" "$ok_url"
  out=$(NEWSLINE_HYPERLINKS=always bash "$STATUSLINE" </dev/null)
  assert_contains "$out" $'\e]8;;'"$ok_url" "case-variant '$ok_url' passes the scheme guard"
done

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
assert_contains "$out" "xml-to-json.js:"                "debug surfaces xml-to-json.js presence"
# Attribution: NEWSLINE_COLOR_FEED was set in env, should say "env";
# NEWSLINE_ROTATION_SEC was not, should say "default".
line=$(printf '%s' "$out" | grep 'NEWSLINE_COLOR_FEED ')
case "$line" in *env*) pass "debug: NEWSLINE_COLOR_FEED attributed to env" ;; *) fail "debug: NEWSLINE_COLOR_FEED attributed to env" "got: $line" ;; esac
line=$(printf '%s' "$out" | grep 'NEWSLINE_ROTATION_SEC')
case "$line" in *default*) pass "debug: NEWSLINE_ROTATION_SEC attributed to default" ;; *) fail "debug: NEWSLINE_ROTATION_SEC attributed to default" "got: $line" ;; esac

# Deprecation notice: NEWSLINE_SCROLL_WIDTH was removed when render_scroll_window
# started auto-deriving its width. A pinned user value must not silently noop —
# debug surfaces it under a 'deprecated:' block with the ignored value echoed.
out_dep=$(NEWSLINE_DEBUG=1 NEWSLINE_SCROLL_WIDTH=42 bash "$STATUSLINE" </dev/null)
assert_contains "$out_dep" "deprecated:"              "debug surfaces deprecated-knob block when set"
assert_contains "$out_dep" "NEWSLINE_SCROLL_WIDTH"    "deprecated knob is named"
assert_contains "$out_dep" "42"                       "deprecated knob's ignored value is echoed"
# And the block must NOT appear when the user has not set the variable.
out_clean=$(env -u NEWSLINE_SCROLL_WIDTH NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null)
assert_not_contains "$out_clean" "deprecated:"        "deprecated block absent when NEWSLINE_SCROLL_WIDTH unset"

# Missing xml-to-json.js: copy only statusline.sh + colors.sh into a sandbox
# and confirm the debug report tags it MISSING rather than pretending all is
# well. The _SCRIPT_DIR check resolves at runtime, so relocating the script
# is enough to trigger the missing-sibling path.
orphan_dir="$SANDBOX/orphan-scripts"
mkdir -p "$orphan_dir"
cp "$STATUSLINE" "$orphan_dir/claude-newsline.sh"
cp "$SCRIPT_DIR/bin/colors.sh" "$orphan_dir/colors.sh"
out_missing=$(NEWSLINE_DEBUG=1 bash "$orphan_dir/claude-newsline.sh" </dev/null)
assert_contains "$out_missing" "MISSING"              "debug flags missing xml-to-json.js"
assert_contains "$out_missing" "FEED_PARSER=xml"      "missing-shim line names the parser it gates"

}
section "user feeds in \$NEWSLINE_FEEDS_DIR load and appear in rotation" && {
# Scope the dir to this section so tests that don't set it keep using the
# default empty behavior. `user_feeds_dir` is local-ish (bash 3+ quirk: a
# bare "local" outside a function is a syntax error in some ports, but this
# test harness is bash-only — we can use it freely).
user_feeds_dir="$SANDBOX/user-feeds"
mkdir -p "$user_feeds_dir"

# A vanilla user feed. Same shape as built-ins: feed_<name>() sets LABEL/URL/JQ.
cat > "$user_feeds_dir/myfeed.sh" <<'SH'
feed_myfeed() {
  LABEL='Mine'
  URL='https://example.test/me'
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
SH

out=$(NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null)
assert_contains "$out" "myfeed"            "user feed 'myfeed' appears in debug report"
assert_contains "$out" "$user_feeds_dir"   "debug report shows user feeds dir path"
case "$out" in *"feeds enabled:"*"myfeed"*) pass "myfeed joins the enabled-feeds line" ;;
               *) fail "myfeed joins the enabled-feeds line" "got: $(printf '%s' "$out" | grep 'feeds enabled')" ;; esac

# Cleanup for subsequent sections.
rm -rf "$user_feeds_dir"

}
section "user feeds: malformed or bad-name files are skipped and reported" && {
user_feeds_dir="$SANDBOX/user-feeds-skip"
mkdir -p "$user_feeds_dir"

# Syntax-broken file — `. file` fails, no name appended to ALL_FEEDS.
cat > "$user_feeds_dir/broken.sh" <<'SH'
feed_broken() {
  LABEL='Broken
SH

# File that sources fine but never defines feed_nodef — `command -v` guard
# catches it, name is not appended.
cat > "$user_feeds_dir/nodef.sh" <<'SH'
# no feed_nodef defined here
echo 'side effect suppressed' >/dev/null
SH

# Bad filename: leading digit → not a legal sh function name suffix.
cat > "$user_feeds_dir/2fa.sh" <<'SH'
feed_2fa() { LABEL='2FA'; URL='x'; JQ='.'; }
SH

# Bad filename: contains hyphen.
cat > "$user_feeds_dir/my-feed.sh" <<'SH'
feed_my-feed() { :; }
SH

out=$(NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null 2>&1)

# Skipped plugins must NOT appear on the `feeds enabled:` line — they're
# not wired into the rotation. Isolate that line so a later-block mention
# (under "user feeds skipped:") doesn't cross-contaminate the assertion.
enabled_line=$(printf '%s' "$out" | grep 'feeds enabled:')
assert_not_contains "$enabled_line" "broken"   "syntax-broken plugin not in feeds enabled"
assert_not_contains "$enabled_line" "nodef"    "plugin without feed_<name> not in feeds enabled"
assert_not_contains "$enabled_line" "2fa"      "bad filename (leading digit) not in feeds enabled"
assert_not_contains "$enabled_line" "my-feed"  "bad filename (hyphen) not in feeds enabled"

# And they MUST appear under `user feeds skipped:` with a diagnostic —
# this is the whole point of the surfaced-failure contract.
assert_contains "$out" "user feeds skipped:"                "debug report has 'user feeds skipped:' header"
assert_contains "$out" "broken"                             "syntax-broken plugin surfaced as skipped"
assert_contains "$out" "source failed"                      "syntax-broken plugin reports source failure"
assert_contains "$out" "nodef"                              "plugin without feed_<name> surfaced as skipped"
assert_contains "$out" "feed_nodef function not defined"    "missing function reported with function name"
assert_contains "$out" "2fa"                                "bad filename (leading digit) surfaced as skipped"
assert_contains "$out" "bad filename"                       "bad filename diagnostic is present"
assert_contains "$out" "my-feed"                            "bad filename (hyphen) surfaced as skipped"

rm -rf "$user_feeds_dir"

}
section "user feed named 'hn' overrides built-in without duplicating the rotation slot" && {
user_feeds_dir="$SANDBOX/user-feeds-override"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/hn.sh" <<'SH'
feed_hn() { LABEL='HN-override'; URL='https://example.test/hn'; JQ='.[] | [$default, .t, .u] | @tsv'; }
SH

out=$(NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null)
# "feeds enabled: hn reddit lobsters" — user override must NOT add a second hn.
enabled_line=$(printf '%s' "$out" | grep 'feeds enabled:')
hn_count=$(printf '%s\n' "$enabled_line" | tr ' ' '\n' | grep -c '^hn$')
assert_equals "$hn_count" "1" "override does not duplicate 'hn' in ALL_FEEDS"

rm -rf "$user_feeds_dir"

}
section "missing \$NEWSLINE_FEEDS_DIR is not an error" && {
out=$(NEWSLINE_FEEDS_DIR="$SANDBOX/does-not-exist" NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null 2>&1)
assert_contains "$out" "feeds enabled:" "statusline still produces a debug report"
assert_contains "$out" "(none loaded)"  "debug report reports empty user feeds cleanly"

}
section "PREFIX brand glyph renders to the left of every headline" && {
prime_cache "HN" "Hello World" "https://example.com/1"
# Strip ANSI SGR escapes and OSC 8 hyperlink wrappers so we assert on visible
# text only — the prefix has its own color block (\e[0m between glyph and
# label), and the glyph now sits outside the OSC 8 wrapper (so a \e]8;;URL\e\\
# open escape sits between the glyph and the headline in raw bytes).
strip_ansi() {
  printf '%s' "$1" \
    | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g' \
    | LC_ALL=C sed $'s/\x1b]8;;[^\x1b]*\x1b\\\\//g'
}

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

# NEWSLINE_PREFIX lives OUTSIDE the OSC 8 wrapper so the hover/cmd-click
# underline doesn't extend under the brand glyph. The headline alone is the
# clickable target.
out=$(bash "$STATUSLINE" </dev/null)
case "$out" in
  *"Ξ"*$'\e]8;;https://example.com/1\e\\'*"Hello World"*$'\e]8;;\e\\'*)
    pass "NEWSLINE_PREFIX sits outside the OSC 8 hyperlink" ;;
  *) fail "NEWSLINE_PREFIX sits outside the OSC 8 hyperlink" "glyph not before OSC 8 open" ;;
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
# FORCE_COLOR=1: CI runners set TERM=dumb → COLOR_DEPTH=0 → colors.sh suppresses
# everything (by design — see NO_COLOR/dumb handling). The `=none` test below
# still passes without it because "expect no color" holds trivially; the two
# positive assertions need color forced on.
out=$(FORCE_COLOR=1 NEWSLINE_COLOR_FEED=magenta bash "$STATUSLINE" </dev/null)
assert_contains "$out" $'\e[35m' "NEWSLINE_COLOR_FEED=magenta emits ESC[35m"
out=$(FORCE_COLOR=1 NEWSLINE_COLOR_FEED="38;5;208" bash "$STATUSLINE" </dev/null)
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

# Leading-zero values would otherwise trip POSIX `$(( ))` octal parsing on
# every refresh tick (`$((20 - 008))` → "value too great for base"). guard_num
# must fold them into the silent-fallback branch.
for bad in 008 09 0123; do
  err=$(NEWSLINE_ROTATION_SEC=$bad bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
  assert_equals "$err" "" "NEWSLINE_ROTATION_SEC=$bad emits no stderr"
  err=$(NEWSLINE_SCROLL_SEC=$bad bash "$STATUSLINE" </dev/null 2>&1 >/dev/null)
  assert_equals "$err" "" "NEWSLINE_SCROLL_SEC=$bad emits no stderr"
done

}
section "NEWSLINE_CACHE_CHUNK guards against awk infinite loop on bad values" && {
# `pos += chunk` with chunk coerced to 0 (empty / non-numeric / "0") would
# never advance — awk pegs CPU and holds the lock until reaper. guard_num
# coerces those back to 1, so the cache builds normally and the call returns.
mkdir -p "$CLAUDE_CONFIG_DIR/cache"
make_mock_bin chunk_curl chunkcurl curl <<'SH'
#!/bin/sh
# Tiny RSS-like JSON for the HN feed; one item is enough for the merge to land.
url=""; for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
case "$url" in
  *hn.algolia*) printf '{"hits":[{"title":"Chunk Test","objectID":"42"}]}\n' ;;
  *)            printf '{}\n' ;;
esac
SH
for bad in 0 abc -1 ''; do
  rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
  if NEWSLINE_FEEDS_DISABLED="reddit,lobsters" \
     NEWSLINE_CACHE_CHUNK="$bad" \
     PATH="$chunk_curl:$PATH" \
     timeout 5 bash "$STATUSLINE" </dev/null >/dev/null 2>&1; then
    pass "NEWSLINE_CACHE_CHUNK=${bad:-(empty)} returns within timeout"
  else
    fail "NEWSLINE_CACHE_CHUNK=${bad:-(empty)} returns within timeout" "awk-loop hang or non-zero exit"
  fi
  wait_for_cache
  if [ -s "$CACHE" ]; then
    pass "NEWSLINE_CACHE_CHUNK=${bad:-(empty)} still produced cache content"
  else
    fail "NEWSLINE_CACHE_CHUNK=${bad:-(empty)} still produced cache content" "cache empty"
  fi
done
rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"

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
ensure_fakedate
prime_cache_multi \
  "HN"     "日本語テスト ABC"  "https://example.com/jp1" \
  "r/dev"  "日本語テスト XYZ"  "https://example.com/jp2"
# The viewport + offset formula (see render_scroll_window) is byte-based, so
# at several intermediate frames the substr() slice lands mid-codepoint
# inside the 3-byte CJK characters. iconv -c must drop the orphan bytes so
# the final output is valid UTF-8. We don't hardcode offsets here — the
# viewport width is now derived from the two headlines and may shift with
# any algorithm tweak — so we exhaustively walk every scroll frame and
# assert end-to-end UTF-8 validity instead of picking individual offsets.
for t in 15 16 17 18 19; do
  out=$(FAKE_NOW=$t PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
  if printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    pass "scroll frame FAKE_NOW=$t emits valid UTF-8"
  else
    fail "scroll frame FAKE_NOW=$t emits valid UTF-8" "iconv found invalid UTF-8 bytes"
  fi
done

}
section "scroll render does not decode literal \\033 bytes in titles (ANSI injection guard)" && {
# A feed title can legitimately contain the four text bytes "\033" (backslash,
# '0', '3', '3') — the tr -d C0/C1 strip in _fetch_one only removes RAW
# control bytes, not their \ddd text encoding. Prior render_scroll_window
# code passed titles via `awk -v a=...`, which decodes POSIX string escapes
# (\033 → ESC, \n → LF, \xHH, etc.) in the value before the awk program
# runs. That turned attacker-controlled title text into real terminal
# escape sequences during every scroll frame.
#
# The fix routes untrusted strings through ENVIRON[] (read verbatim, no
# escape processing). This test primes a two-line cache with payload titles
# and walks every scroll frame, asserting zero 0x1B bytes are sourced from
# the title injection. Any regression (a future refactor that goes back to
# `-v` for these inputs) fails loudly here.
ensure_fakedate
prime_cache_multi \
  "HN"     'pre\033[41;97mHIJACK\033[0m post' "https://example.com/poc1" \
  "r/sec"  'next\033[32mX\033[0m'             "https://example.com/poc2"
# Default ROTATION_SEC=20, SCROLL_SEC=5 → frames at pos=15..19. Disable
# color so the accent escapes from set_ansi don't pollute the ESC count;
# the only 0x1B bytes remaining would then come from injection.
for t in 15 16 17 18 19; do
  out=$(NO_COLOR=1 FAKE_NOW=$t PATH="$fakedate_dir:$PATH" bash "$STATUSLINE" </dev/null)
  esc_count=$(printf '%s' "$out" | LC_ALL=C tr -cd '\033' | wc -c | tr -d ' ')
  if [ "$esc_count" = "0" ]; then
    pass "scroll frame FAKE_NOW=$t contains no injected ESC bytes"
  else
    fail "scroll frame FAKE_NOW=$t contains no injected ESC bytes" "found $esc_count ESC byte(s)"
  fi
  # Payload bytes (the literal \033 text) MUST survive intact so the user
  # sees what the feed actually said, not a silently-mangled string.
  assert_contains "$out" '\033[' "literal backslash-ddd sequence preserved in scroll frame FAKE_NOW=$t"
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
echo "=== bin/xml-to-json.js (RSS/Atom → JSON) ==="

# xml-to-json.js reads an RSS or Atom document from stdin and writes a JSON
# array of {title, link, description} objects — no label, no TSV. Labeling
# and field projection happen in jq downstream, same as for JSON feeds. The
# shape means an XML feed can use the full jq toolbox (filter, select,
# rewrite titles, promote labels) — not just "title + link or bust."
XML_TO_JSON="$SCRIPT_DIR/bin/xml-to-json.js"

xml_to_json() {
  # Usage: xml_to_json < xml_input — returns JSON on stdout, stderr merged
  # so a parser throw surfaces in assertion failures rather than vanishing.
  node "$XML_TO_JSON" 2>&1
}

section "xml-to-json: basic RSS emits array of objects" && {
out=$(xml_to_json <<'XML'
<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>Feed</title>
  <item>
    <title>First Post</title>
    <link>https://example.com/1</link>
    <description>First body</description>
  </item>
  <item>
    <title>Second Post</title>
    <link>https://example.com/2</link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq 'length')"               "2"                         "two items extracted"
assert_equals "$(echo "$out" | jq -r '.[0].title')"        "First Post"                "first item title"
assert_equals "$(echo "$out" | jq -r '.[0].link')"         "https://example.com/1"     "first item link"
assert_equals "$(echo "$out" | jq -r '.[0].description')"  "First body"                "first item description"
assert_equals "$(echo "$out" | jq -r '.[1].title')"        "Second Post"               "second item title"
assert_equals "$(echo "$out" | jq -r '.[1].description')"  "null"                      "missing description → null"

}
section "xml-to-json: basic Atom uses href attribute for link" && {
out=$(xml_to_json <<'XML'
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Atom One</title>
    <link href="https://example.com/a1"/>
    <summary>A summary</summary>
  </entry>
  <entry>
    <title>Atom Two</title>
    <link rel="alternate" href="https://example.com/a2" type="text/html"/>
  </entry>
</feed>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].link')"        "https://example.com/a1"  "Atom link from href attribute"
assert_equals "$(echo "$out" | jq -r '.[0].description')" "A summary"               "Atom <summary> maps to description"
assert_equals "$(echo "$out" | jq -r '.[1].link')"        "https://example.com/a2"  "ignores rel/type on link tag"

}
section "xml-to-json: decodes named + numeric entities" && {
# &amp; decoded LAST. Input &amp;lt; must stay as literal &lt;, not decode
# twice to <. Numeric (&#58;) and hex (&#x2014;) both handled.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title>Tom &amp; Jerry&#58; &lt;Chase&gt; &#x2014; Don&#8217;t</title>
    <link>https://example.com/ent</link>
  </item>
</channel></rss>
XML
)
expected=$(printf 'Tom & Jerry: <Chase> \xe2\x80\x94 Don\xe2\x80\x99t')
assert_equals "$(echo "$out" | jq -r '.[0].title')" "$expected" "named + decimal + hex entities all decode"

}
section "xml-to-json: numeric and hex entities do NOT over-decode into named" && {
# Regression: an earlier impl ran three sequential .replace() passes
# (numeric → hex → named). Input "&#38;lt;" went numeric→"&lt;"→named→"<",
# losing the literal "&lt;" the feed intended. Same for "&#x26;lt;".
# Single combined regex pass closes that re-scan window.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title>numeric: &#38;lt; hex: &#x26;gt; mixed: &amp;amp;</title>
    <link>https://example.com/no-overdecode</link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].title')" \
  "numeric: &lt; hex: &gt; mixed: &amp;" \
  "&#38;lt; / &#x26;gt; / &amp;amp; each decode exactly once"

}
section "xml-to-json: strips CDATA in title and link" && {
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title><![CDATA[Inside CDATA <with> "html"]]></title>
    <link><![CDATA[https://example.com/cdata]]></link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].title')" 'Inside CDATA <with> "html"' "CDATA unwrapped in title"
assert_equals "$(echo "$out" | jq -r '.[0].link')"  'https://example.com/cdata'  "CDATA unwrapped in link"

}
section "xml-to-json: CDATA-internal </item> does not truncate parsing" && {
# Regression guard: pre-fix, ITEM_RE ran on the raw XML, so a non-greedy match
# stopped at the FIRST literal </item> — even one buried inside CDATA. A
# single feed item that quoted "</item>" anywhere in CDATA would silently
# drop every subsequent item from the document. Now CDATA blocks are
# placeholder-substituted before any regex sees them, and the close-tag
# inside CDATA can no longer fool the item walker.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title><![CDATA[Story about </item> tags in CDATA]]></title>
    <link>https://example.com/first</link>
  </item>
  <item>
    <title>Second item must survive</title>
    <link>https://example.com/second</link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq 'length')"        "2"                            "both items extracted (CDATA didn't truncate)"
assert_equals "$(echo "$out" | jq -r '.[0].title')" "Story about </item> tags in CDATA" "CDATA-internal close-tag preserved verbatim"
assert_equals "$(echo "$out" | jq -r '.[1].title')" "Second item must survive"     "subsequent item still parses"
assert_equals "$(echo "$out" | jq -r '.[1].link')"  "https://example.com/second"   "subsequent item link still parses"

}
section "xml-to-json: entities inside CDATA are preserved verbatim (XML spec)" && {
# Per XML spec, CDATA disables entity processing. The earlier impl unwrapped
# CDATA at the top level then ran decode() across everything, so a literal
# &amp; inside CDATA decoded to &, contradicting the feed author's intent.
# Verbatim restore at field-emit time keeps CDATA content as-is while
# entities OUTSIDE CDATA still decode normally — both behaviours asserted
# in one test so a future refactor that re-unifies the paths fails loudly.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title><![CDATA[Tom &amp; Jerry: literal &lt;]]></title>
    <link>https://example.com/cdata-ent</link>
  </item>
  <item>
    <title>Tom &amp; Jerry: decoded &lt;</title>
    <link>https://example.com/plain-ent</link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].title')" "Tom &amp; Jerry: literal &lt;" "entities inside CDATA stay literal"
assert_equals "$(echo "$out" | jq -r '.[1].title')" "Tom & Jerry: decoded <"        "entities outside CDATA still decode"

}
section "xml-to-json: single-line minified XML still parses" && {
out=$(xml_to_json <<'XML'
<rss><channel><item><title>Minified</title><link>https://example.com/m</link></item><item><title>Two</title><link>https://example.com/m2</link></item></channel></rss>
XML
)
assert_equals "$(echo "$out" | jq 'length')"        "2"                        "both items found"
assert_equals "$(echo "$out" | jq -r '.[1].title')" "Two"                      "second item parsed"
assert_equals "$(echo "$out" | jq -r '.[1].link')"  "https://example.com/m2"   "second item link parsed"

}
section "xml-to-json: skips items missing title or link" && {
out=$(xml_to_json <<'XML'
<rss><channel>
  <item><title>Has Both</title><link>https://example.com/ok</link></item>
  <item><title>No Link</title></item>
  <item><link>https://example.com/no-title</link></item>
  <item><title>Has Both Two</title><link>https://example.com/ok2</link></item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq 'length')"        "2"              "only complete items emitted"
assert_equals "$(echo "$out" | jq -r '.[0].title')" "Has Both"       "first complete item"
assert_equals "$(echo "$out" | jq -r '.[1].title')" "Has Both Two"   "second complete item (skipping middle two)"

}
section "xml-to-json: <link> URLs preserve no-whitespace shape across line wraps" && {
# Pretty-printed RSS feeds wrap CDATA content. Pre-fix, the `clean()` helper
# collapsed all whitespace to a single space, so a line-wrapped URL became
# "https://example.com/a /b" — terminal hyperlink handlers split on the
# space and the link broke silently. cleanUrl strips whitespace outright.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title>Wrapped URL</title>
    <link><![CDATA[https://example.com/very/long/path/
with-line-break]]></link>
  </item>
  <item>
    <title>Atom href Wrap</title>
    <link href="https://example.com/atom/
wrapped"/>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].link')" \
  "https://example.com/very/long/path/with-line-break" \
  "<link>CDATA URL strips embedded newline+indent (no space injection)"
assert_equals "$(echo "$out" | jq -r '.[1].link')" \
  "https://example.com/atom/wrapped" \
  "Atom href value strips embedded whitespace too"
# Titles are still allowed to collapse whitespace — the prior contract.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title>Wrapped
title</title>
    <link>https://example.com/t</link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].title')" "Wrapped title" "title still collapses whitespace"

}
section "xml-to-json: normalizes embedded tabs and newlines in fields" && {
# A raw tab or newline in a title would render fine as JSON (escaped as \t
# / \n), but downstream the jq filter emits @tsv and any literal \t/\n in
# a field would corrupt the TSV record. Normalize to single space here so
# the JSON shape is safe to feed directly to jq's @tsv.
out=$(xml_to_json <<'XML'
<rss><channel>
  <item>
    <title>Line one
Line two	tabbed</title>
    <link>https://example.com/ws</link>
  </item>
</channel></rss>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].title')" "Line one Line two tabbed" "tabs + newlines in title collapse to spaces"

}
section "xml-to-json: empty input emits an empty array" && {
out=$(printf '' | node "$XML_TO_JSON" 2>&1)
status=$?
assert_equals "$status" "0"  "empty stdin exits 0"
assert_equals "$out" "[]"    "empty stdin → []"

}
section "xml-to-json: garbage input emits an empty array" && {
out=$(printf 'not xml at all { "json": true }' | node "$XML_TO_JSON" 2>&1)
status=$?
assert_equals "$status" "0"  "non-XML garbage exits 0 (no crash)"
assert_equals "$out" "[]"    "non-XML garbage → [] (jq never sees bad input)"

}
section "xml-to-json: Atom link falls back to text content" && {
out=$(xml_to_json <<'XML'
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Text Link</title>
    <link>https://example.com/tl</link>
  </entry>
</feed>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].link')" "https://example.com/tl" "non-spec <link>text</link> in Atom accepted"

}
section "xml-to-json: Atom prefers alternate link over self" && {
out=$(xml_to_json <<'XML'
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Alternate Link</title>
    <link rel="self" href="https://example.com/feed/entry/1"/>
    <link rel="alternate" href="https://example.com/story/1"/>
  </entry>
  <entry>
    <title>No Rel Link</title>
    <link rel="self" href="https://example.com/feed/entry/2"/>
    <link href="https://example.com/story/2"/>
  </entry>
</feed>
XML
)
assert_equals "$(echo "$out" | jq -r '.[0].link')" "https://example.com/story/1" "Atom rel=alternate preferred over rel=self"
assert_equals "$(echo "$out" | jq -r '.[1].link')" "https://example.com/story/2" "Atom link with no rel preferred over rel=self"

}
section "xml-to-json: output is a valid JSON array (jq parseable)" && {
# Structural invariant: regardless of input, output must always be valid
# JSON — so the downstream jq never errors. This test covers the "the
# pipeline contract holds" property across several inputs.
for sample in \
  '<?xml version="1.0"?><rss><channel></channel></rss>' \
  '<rss><channel><item><title>x</title><link>https://x/1</link></item></channel></rss>' \
  '' \
  'garbage'; do
  out=$(printf '%s' "$sample" | node "$XML_TO_JSON" 2>&1)
  if echo "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    pass "valid JSON array for input: ${sample:0:40}"
  else
    fail "valid JSON array for input: ${sample:0:40}" "got: $out"
  fi
done

}

# -----------------------------------------------------------------------------
echo
echo "=== FEED_PARSER=xml plugin integration ==="

# A plugin declaring FEED_PARSER=xml prepends xml-to-json.js to the jq
# pipeline in _fetch_one. JQ then runs against a JSON array of
# {title, link, description} objects — same jq expressiveness as a JSON
# feed, just with an XML-parse step added upfront. When JQ is empty,
# _parse_body supplies a default filter so the trivial "title + link"
# case needs zero jq in the plugin.

section "xml feed: refresh pipeline populates cache using default jq filter when JQ is empty" && {
user_feeds_dir="$SANDBOX/user-feeds-xml"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/xmlfeed.sh" <<'SH'
feed_xmlfeed() {
  LABEL='XFeed'
  URL='https://example.test/rss.xml'
  FEED_PARSER=xml
}
FEED_META_xmlfeed='api=2
category=Custom
description=Test RSS'
SH

# Mock curl: return a minimal RSS body. Discard all flags; shape is hard-
# coded so the test is hermetic. `_fetch_one` invokes curl with --max-time
# etc.; we just need stdout to produce valid RSS.
make_mock_bin mock_curl_xml xmlfetch curl <<'MOCK'
#!/bin/sh
# Swallow args; emit a fixed RSS payload on stdout for _fetch_one's pipe.
cat <<'XML'
<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>Test Feed</title>
  <item>
    <title>XML Story One</title>
    <link>https://example.test/xml/1</link>
  </item>
  <item>
    <title>XML &amp; Story Two</title>
    <link>https://example.test/xml/2</link>
  </item>
</channel></rss>
XML
MOCK

rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
  PATH="$mock_curl_xml:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1
wait_for_cache
if [ -s "$CACHE" ]; then
  pass "xml feed refresh populates cache (default jq filter)"
else
  fail "xml feed refresh populates cache (default jq filter)" "cache empty after refresh"
fi

# Entity decoding happens in xml-to-json; the TSV emission happens in jq.
# `&amp;` must render as a literal `&` on the cache line or the render
# path will just pass the escape through as-is.
assert_contains "$(cat "$CACHE")" "$(printf 'XFeed\tXML Story One\thttps://example.test/xml/1')" \
  "first item written as XFeed\\tTitle\\tURL"
assert_contains "$(cat "$CACHE")" "$(printf 'XFeed\tXML & Story Two\thttps://example.test/xml/2')" \
  "entity-decoded title survives the full xml-to-json | jq pipeline"

if grep -q $'\t\t' "$CACHE"; then
  fail "cache records are well-formed (no empty fields)" "$(grep -n $'\t\t' "$CACHE")"
else
  pass "cache records are well-formed (no empty fields)"
fi

rm -rf "$user_feeds_dir"
rm -f "$CACHE" "$CACHE.pending"

}
section "xml feed: custom JQ filter runs on xml-to-json output" && {
# The payoff of the xml-to-json refactor: XML feeds get full jq
# expressiveness. This test proves it by declaring a filter that
# (a) rewrites the label per-item based on the title and (b) drops
# items matching a keyword — both impossible with a hardcoded TSV
# emitter. Mirrors what feed_hn does for "Show HN:" prefixes.
user_feeds_dir="$SANDBOX/user-feeds-xml-jq"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/xmljq.sh" <<'SH'
feed_xmljq() {
  LABEL='X'
  URL='https://example.test/rss.xml'
  FEED_PARSER=xml
  JQ='.[]
      | select(.title | test("skip"; "i") | not)
      | if (.title | test("^BREAKING: "))
        then {label: "BREAKING", title: (.title | sub("^BREAKING: "; "")), link}
        else {label: $default, title, link}
        end
      | [.label, .title, .link] | @tsv'
}
SH

make_mock_bin mock_curl_xmljq xmljqfetch curl <<'MOCK'
#!/bin/sh
cat <<'XML'
<rss><channel>
  <item><title>BREAKING: Market drops</title><link>https://example.test/1</link></item>
  <item><title>Normal item</title><link>https://example.test/2</link></item>
  <item><title>Please skip me</title><link>https://example.test/3</link></item>
  <item><title>BREAKING: New announcement</title><link>https://example.test/4</link></item>
</channel></rss>
XML
MOCK

rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
  PATH="$mock_curl_xmljq:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1
wait_for_cache
cache_content=$(cat "$CACHE" 2>/dev/null)

assert_contains "$cache_content" "$(printf 'BREAKING\tMarket drops\thttps://example.test/1')" \
  "BREAKING prefix promoted to label, stripped from title"
assert_contains "$cache_content" "$(printf 'X\tNormal item\thttps://example.test/2')" \
  "non-BREAKING item uses \$default label"
assert_not_contains "$cache_content" "Please skip me" \
  "item matching jq select() filter is excluded"
assert_contains "$cache_content" "$(printf 'BREAKING\tNew announcement\thttps://example.test/4')" \
  "second BREAKING item also promoted"

rm -rf "$user_feeds_dir"
rm -f "$CACHE" "$CACHE.pending"

}
section "xml feed: renders through statusline just like a jq feed" && {
# Once the cache has a TSV line, the render path is identical to any other
# feed — OSC 8 wrapping, label separator, color, the lot. This guards
# against "works at refresh but breaks at render" drift: parse_line, the
# URL scheme guard, and the label prefix all assume the TSV shape xml-to-
# tsv produces.
prime_cache "XFeed" "Rendered Headline" "https://example.test/x"
out=$(run_statusline)
assert_contains "$out" "XFeed • Rendered Headline"              "xml-sourced line renders with label prefix"
assert_contains "$out" $'\e]8;;https://example.test/x'          "xml-sourced URL wrapped in OSC 8 hyperlink"

}
section "--test-feed works on an FEED_PARSER=xml plugin via --fixture" && {
user_feeds_dir="$SANDBOX/user-feeds-xml-test"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/xmltest.sh" <<'SH'
feed_xmltest() {
  LABEL='XT'
  URL='https://example.test/t.xml'
  FEED_PARSER=xml
}
SH

fixture="$SANDBOX/xmltest.xml"
cat > "$fixture" <<'XML'
<?xml version="1.0"?>
<rss><channel>
  <item><title>Diag One</title><link>https://example.test/t/1</link></item>
  <item><title>Diag Two</title><link>https://example.test/t/2</link></item>
</channel></rss>
XML

out=$(NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed xmltest --fixture "$fixture" 2>&1)
status=$?
assert_equals "$status" "0"                          "--test-feed on xml plugin exits 0"
assert_contains "$out" "Testing feed: xmltest"       "header names the xml feed"
assert_contains "$out" "2 rows"                      "row count surfaced in diagnostics"
assert_contains "$out" "XT • Diag One"               "first xml row shown in sample"
assert_contains "$out" "XT • Diag Two"               "second xml row shown in sample"

rm -rf "$user_feeds_dir" "$fixture"

}
section "xml feed: plugin WITHOUT FEED_PARSER still flows through jq (regression)" && {
# Drop a plugin that does NOT set FEED_PARSER; its JQ filter must still
# run directly on the JSON body (no xml-to-json prefix). If the branch
# leak accidentally routed JSON feeds through xml-to-json, the row count
# would be zero (no <item> tags in JSON) and the cache would stay empty.
user_feeds_dir="$SANDBOX/user-feeds-nonxml"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/jsonfeed.sh" <<'SH'
feed_jsonfeed() {
  LABEL='JF'
  URL='https://example.test/j'
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
SH
make_mock_bin mock_curl_json jsonfetch curl <<'MOCK'
#!/bin/sh
cat <<'JSON'
{"items":[{"title":"Jay","url":"https://example.test/j/1"}]}
JSON
MOCK
rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
  PATH="$mock_curl_json:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1
wait_for_cache
assert_contains "$(cat "$CACHE")" "$(printf 'JF\tJay\thttps://example.test/j/1')" \
  "plugin without FEED_PARSER still uses jq on the raw body (not xml-to-json)"
rm -rf "$user_feeds_dir"
rm -f "$CACHE" "$CACHE.pending"

}
section "xml feed: missing node binary degrades gracefully to empty bucket" && {
# If node somehow isn't on PATH at refresh time, the xml pipeline produces
# empty output — NOT a crash that would poison the cache. _fetch_one's
# existing `2>/dev/null` discipline swallows spawn errors; `awk 'NF'` drops
# empty lines, so the bucket for this feed just doesn't fill. Other feeds
# in the same refresh tick are unaffected.
user_feeds_dir="$SANDBOX/user-feeds-xml-nonode"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/xn.sh" <<'SH'
feed_xn() {
  LABEL='XN'
  URL='https://example.test/xn'
  FEED_PARSER=xml
}
SH

# PATH with only the mock curl dir + coreutils, no node. Use a minimal
# PATH that deliberately excludes node's install dir. We shadow `node`
# with a missing-command stub inside a dedicated dir to force failure
# regardless of where the real binary lives on the test host.
make_mock_bin mock_curl_xn xn_fetch curl <<'MOCK'
#!/bin/sh
cat <<'XML'
<rss><channel><item><title>Should Never Appear</title><link>https://x/n</link></item></channel></rss>
XML
MOCK

# "Break" node by putting a deliberately non-executable same-named file
# earlier in PATH. Refresh finds our stub first, exec fails, downstream
# awk 'NF' drops empties. Cache stays empty for this feed.
mock_nonode="$SANDBOX/bin-nonode"
mkdir -p "$mock_nonode"
printf '#!/bin/sh\nexit 127\n' > "$mock_nonode/node"
chmod +x "$mock_nonode/node"

rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
  PATH="$mock_nonode:$mock_curl_xn:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1
# Bounded poll instead of a flat sleep: exits early if the cache somehow
# DOES fill (would be a leak), and caps at 0.5s total so the suite isn't
# paying a fixed 0.5s penalty on every run. Matches wait_for_cache's shape
# without its "cache must exist" semantics.
for _i in 1 2 3 4 5; do
  [ -s "$CACHE" ] && break
  sleep 0.1
done
if [ -s "$CACHE" ]; then
  # Cache exists but must not contain the xml feed's data (since node failed).
  if grep -q "Should Never Appear" "$CACHE"; then
    fail "broken node degrades xml feed to empty bucket" "xml content leaked in"
  else
    pass "broken node degrades xml feed to empty bucket"
  fi
else
  pass "broken node degrades xml feed to empty bucket"
fi

rm -rf "$user_feeds_dir" "$mock_nonode"
rm -f "$CACHE" "$CACHE.pending"

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
ensure_installed
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
# Set up the state the prior section established (existing user statusLine
# + first install) so RUN_ONLY filters can hit this one in isolation. The
# original first install happened in "install appends to existing
# statusLine.command" — bootstrap the same shape here on cold runs.
if ! grep -q 'my-statusline.sh' "$SETTINGS" 2>/dev/null; then
  cat > "$SETTINGS" <<'JSON'
{
  "statusLine": {"type": "command", "command": "bash /usr/local/bin/my-statusline.sh", "refreshInterval": 5}
}
JSON
  run_cli >/dev/null 2>&1
fi
run_cli >/dev/null 2>&1
cmd_after=$(jq -r '.statusLine.command' "$SETTINGS")
count=$(printf '%s' "$cmd_after" | grep -o 'claude-newsline.sh' | wc -l | tr -d ' ')
assert_equals "$count" "1" "re-install does not add a second claude-newsline reference"
assert_contains "$cmd_after" "my-statusline.sh" "user script still preserved after re-install"

}
section "install copies runtime scripts (statusline.sh, colors.sh, xml-to-json.js)" && {
ensure_installed
assert_file_exists "$CLAUDE_CONFIG_DIR/claude-newsline.sh" "claude-newsline.sh installed"
assert_file_exists "$CLAUDE_CONFIG_DIR/colors.sh"         "colors.sh installed"
# xml-to-json.js runs at refresh time for FEED_PARSER=xml plugins — must
# ship alongside statusline.sh or the v2 plugin contract silently breaks
# (refresh would exec a missing file → empty bucket, no error surfaced).
assert_file_exists "$CLAUDE_CONFIG_DIR/xml-to-json.js"    "xml-to-json.js installed"
# Must be executable so the shebang line works when statusline.sh invokes
# it via `node "$_SCRIPT_DIR/xml-to-json.js"` — node doesn't require +x on
# the script argument, but shipping it non-executable would be a latent
# trap for anyone who ever runs it directly.
if [ -x "$CLAUDE_CONFIG_DIR/xml-to-json.js" ]; then
  pass "xml-to-json.js is executable after install"
else
  fail "xml-to-json.js is executable after install" "mode: $(stat -f '%Lp' "$CLAUDE_CONFIG_DIR/xml-to-json.js" 2>/dev/null || stat -c '%a' "$CLAUDE_CONFIG_DIR/xml-to-json.js" 2>/dev/null)"
fi

}
section "install scaffolds the user-feeds dir + README on first install" && {
# Path must match statusline.sh's default: $CONFIG_DIR/claude-newsline/feeds.
feeds_dir="$CLAUDE_CONFIG_DIR/claude-newsline/feeds"
readme="$feeds_dir/README.md"
assert_dir_exists "$feeds_dir" "user-feeds dir created"
assert_file_exists "$readme"    "user-feeds README.md created"
assert_contains "$(cat "$readme")" "feed_nyt"        "README includes the minimal feed template"
assert_contains "$(cat "$readme")" "FEED_PARAMS"     "README documents parameterized feeds"

}
section "install does NOT overwrite a hand-edited user-feeds README" && {
# Pre-seed a distinctive README, re-run install, verify content is preserved.
feeds_dir="$CLAUDE_CONFIG_DIR/claude-newsline/feeds"
readme="$feeds_dir/README.md"
printf 'MY OWN NOTES\n' > "$readme"
run_cli >/dev/null 2>&1
assert_equals "$(cat "$readme")" "MY OWN NOTES" "hand-edited README survives re-install"

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
section "--rotation 20 (default) clears a stale prior override" && {
# Regression: an earlier impl elided the write entirely when the chosen
# value equaled the runtime default. That left a pre-existing
# NEWSLINE_ROTATION_SEC=30 in place after the user explicitly passed
# --rotation 20, so the explicit choice silently did nothing.
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_ROTATION_SEC": "30"}}
JSON
run_cli --rotation 20 >/dev/null 2>&1
assert_env_gone NEWSLINE_ROTATION_SEC "explicit default clears stale override"

}
section "--reddit-subs programming (default) clears a stale prior override" && {
# Same regression class as --rotation: choosing the runtime default must
# clear a stale .env value, not silently leave it alone.
cat > "$SETTINGS" <<'JSON'
{"env": {"NEWSLINE_REDDIT_SUBS": "rust,golang"}}
JSON
run_cli --reddit-subs programming >/dev/null 2>&1
assert_env_gone NEWSLINE_REDDIT_SUBS "explicit default clears stale reddit override"

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
section "backup prune sorts collision counters numerically (>9 in one second)" && {
# Lex sort breaks once the collision counter rolls past 9: '.bak.<ts>.10'
# sorts BEFORE '.bak.<ts>.2' because '1' < '2'. Pre-fix this meant pruning
# could delete the wrong file when more than 10 backups landed in the same
# second. Seed a single timestamp with 12 collision-counter siblings, run
# install, and assert the survivors are the highest counters — not the
# lex-tail.
rm -f "$SETTINGS".bak.*
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
collide_ts=1700100000
# Seed: .bak.1700100000 (counter 0) plus .bak.1700100000.1 ... .bak.1700100000.11.
# Total = 12 backups, all "in the same second" from the prune logic's perspective.
printf '{"seed":0}\n' > "$SETTINGS.bak.$collide_ts"
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  printf '{"seed":%s}\n' "$n" > "$SETTINGS.bak.$collide_ts.$n"
done
seed_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$seed_count" "12" "seeded 12 collision-counter backups"
run_cli >/dev/null 2>&1
max_backups=$(node -e "console.log(require('$CLI').MAX_BACKUPS)")
final_count=$(ls "$SETTINGS".bak.* 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$final_count" "$max_backups" "prune keeps exactly MAX_BACKUPS at collision boundary"
# .bak.<ts>.11 is the chronologically newest seed — it MUST survive. Lex sort
# would have placed it under .bak.<ts>.2, marked it "old", and deleted it.
assert_file_exists "$SETTINGS.bak.$collide_ts.11" "highest collision counter survives prune"
# .bak.<ts> (counter 0) is the oldest — it MUST be gone with 12 → 10 prune.
if [ -e "$SETTINGS.bak.$collide_ts" ]; then
  fail "lowest collision counter pruned" "still exists: $SETTINGS.bak.$collide_ts"
else
  pass "lowest collision counter pruned"
fi

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
section "install preserves settings.json file mode (no permission widening)" && {
# settings.json's `env` block frequently holds API keys. A naive write-then-
# rename inherits the umask (typically 0o644) and silently widens a security-
# conscious user's `chmod 600`. writeSettings stat()s the existing file (or
# the symlink target) and reapplies its mode to the temp file before rename.
#
# Reproducer pre-fix: chmod 600 → install → mode is now 644.
rm -f "$SETTINGS"
echo '{"model":"claude-opus-4-7"}' > "$SETTINGS"
chmod 600 "$SETTINGS"
run_cli >/dev/null 2>&1
mode=$(stat -c '%a' "$SETTINGS" 2>/dev/null || stat -f '%OLp' "$SETTINGS" 2>/dev/null)
assert_equals "$mode" "600" "0o600 preserved across install"

# 0o640 — uncommon but legitimate (group-readable, owner-only writable). The
# preserve path must be byte-faithful, not "normalize to 600".
chmod 640 "$SETTINGS"
run_cli >/dev/null 2>&1
mode=$(stat -c '%a' "$SETTINGS" 2>/dev/null || stat -f '%OLp' "$SETTINGS" 2>/dev/null)
assert_equals "$mode" "640" "0o640 preserved across install (no normalization)"

# Uninstall round-trips through writeSettings the same way, so the mode
# must survive that path too. Without this assertion, a fix that handled
# install but missed uninstall would slip through.
chmod 600 "$SETTINGS"
run_uninstall >/dev/null 2>&1
if [ -f "$SETTINGS" ]; then
  mode=$(stat -c '%a' "$SETTINGS" 2>/dev/null || stat -f '%OLp' "$SETTINGS" 2>/dev/null)
  assert_equals "$mode" "600" "0o600 preserved across uninstall"
fi

# Cleanup: make sure subsequent sections start with a writable settings.json.
echo '{}' > "$SETTINGS"

}
section "install on first-touch settings.json defaults to 0o600" && {
# No prior settings.json (e.g. fresh install on a new machine). writeSettings
# can't preserve a mode it doesn't have a source for — it must default to a
# conservative one. settings.json holds env (frequently API keys), so 0o600
# is the right default; widening to umask would silently expose secrets on
# multi-user hosts.
rm -f "$SETTINGS"
run_cli >/dev/null 2>&1
mode=$(stat -c '%a' "$SETTINGS" 2>/dev/null || stat -f '%OLp' "$SETTINGS" 2>/dev/null)
assert_equals "$mode" "600" "fresh-install settings.json defaults to 0o600"

# Restore for downstream sections.
echo '{}' > "$SETTINGS"

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
section "FEED_PARAMS_<name> registry points at declared internal variables" && {
# Every FEED_PARAMS_foo='BAR' declaration in statusline.sh must have a matching
# `BAR="${NEWSLINE_BAR:-default}"` config line — otherwise the dispatch loop
# reads an undefined variable and the parameterized feed silently never fires.
# Catches the drift where someone adds FEED_PARAMS_newfeed='NEWFEED_SRCS' but
# forgets to add the NEWFEED_SRCS="${NEWSLINE_NEWFEED_SRCS:-...}" line.
missing=''
while IFS= read -r declaration; do
  # "FEED_PARAMS_reddit='REDDIT_SUBS'" → "REDDIT_SUBS"
  internal=$(printf '%s' "$declaration" | sed "s/.*='\(.*\)'/\1/")
  [ -n "$internal" ] || continue
  if ! grep -qE "^${internal}=\"\\\$\\{NEWSLINE_${internal}[:-]" "$SCRIPT_DIR/bin/statusline.sh"; then
    missing="$missing $internal"
  fi
done < <(grep -E "^FEED_PARAMS_[A-Za-z_][A-Za-z0-9_]*=" "$SCRIPT_DIR/bin/statusline.sh")
if [ -z "$missing" ]; then
  pass "every FEED_PARAMS_* has a matching internal config binding"
else
  fail "every FEED_PARAMS_* has a matching internal config binding" "missing config for:$missing"
fi

}
section "--test-feed runs one fetch and reports diagnostics" && {
# End-to-end happy path + failure modes for `claude-newsline --test-feed foo`.
# Uses a mock curl in PATH that echoes a fixed meta line and writes a body to
# the -o path. Real jq processes the body so the test exercises the full
# curl → jq → tr → awk pipeline that statusline.sh uses at refresh time.

# Drop a user feed that produces one good row.
user_feeds_dir="$SANDBOX/user-feeds-testfeed"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/sample.sh" <<'SH'
feed_sample() {
  LABEL='Sample'
  URL='https://example.test/feed.json'
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
SH

# Mock curl: writes a body to the file at -o and emits the meta format
# statusline.sh requests via -w ("http_code|size_download|time_total").
# The real shell-side parser splits on `|`, so match that shape exactly.
make_mock_bin mock_curl_dir testfeed_ok curl <<'MOCK'
#!/bin/sh
# Consume args until -o, capture next arg as body path. Everything else
# is ignored; we hard-code the response so the test is hermetic.
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) body=$2; shift 2 ;;
    *)  shift ;;
  esac
done
cat > "$body" <<'JSON'
{"items":[{"title":"First","url":"https://example.test/a"},
          {"title":"Second","url":"https://example.test/b"}]}
JSON
printf '200|143|0.042'
MOCK

out=$(PATH="$mock_curl_dir:$PATH" NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed sample 2>&1)
status=$?
assert_equals "$status" "0"                         "--test-feed exits 0 on success"
assert_contains "$out" "Testing feed: sample"       "header names the feed"
assert_contains "$out" "URL:"                        "shows URL line"
assert_contains "$out" "https://example.test/feed.json" "shows resolved URL"
assert_contains "$out" "200"                         "shows HTTP code"
assert_contains "$out" "2 rows"                      "shows jq row count"
assert_contains "$out" "Sample • First"              "sample shows first row"
assert_contains "$out" "Sample • Second"             "sample shows second row"
assert_contains "$out" $'\xe2\x9c\x93'               "success marker rendered"

# Failure: jq produces zero rows (empty items array, valid JSON shape)
make_mock_bin mock_curl_dir2 testfeed_empty curl <<'MOCK'
#!/bin/sh
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) body=$2; shift 2 ;; *) shift ;; esac
done
printf '{"items":[]}' > "$body"
printf '200|12|0.01'
MOCK
out=$(PATH="$mock_curl_dir2:$PATH" NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed sample 2>&1)
status=$?
assert_equals "$status" "1"                          "--test-feed exits non-zero on zero rows"
assert_contains "$out" "0 rows"                      "zero-row failure is reported"

# Warning: non-http URL in jq output triggers scheme-guard notice
cat > "$user_feeds_dir/bad_scheme.sh" <<'SH'
feed_bad_scheme() {
  LABEL='Bad'
  URL='https://example.test/feed.json'
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
SH
make_mock_bin mock_curl_dir3 testfeed_badurl curl <<'MOCK'
#!/bin/sh
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) body=$2; shift 2 ;; *) shift ;; esac
done
cat > "$body" <<'JSON'
{"items":[{"title":"Sketchy","url":"javascript:alert(1)"}]}
JSON
printf '200|60|0.01'
MOCK
out=$(PATH="$mock_curl_dir3:$PATH" NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed bad_scheme 2>&1)
assert_contains "$out" "URL scheme not http(s)"      "scheme guard warning surfaces"
assert_contains "$out" "javascript:alert(1)"         "offending URL is shown"

# Unknown feed: exits 2 with available list
out=$(node "$CLI" --test-feed nonexistent 2>&1)
status=$?
assert_equals "$status" "2"                          "--test-feed unknown exits 2"
assert_contains "$out" "unknown feed: nonexistent"   "unknown feed error is clear"
assert_contains "$out" "available:"                  "available feeds listed"

# Name validation: a shell-metachar name is rejected in Node before shelling out
out=$(node "$CLI" --test-feed 'foo;rm' 2>&1)
status=$?
assert_equals "$status" "2"                          "--test-feed rejects shell-metachar name"
assert_contains "$out" "valid feed name"             "metachar rejection message is clear"

# Settings.json env passthrough: a FEED_PARAMS feed reads its CSV from the
# env var. When settings.json has it, the child should see it.
cat > "$user_feeds_dir/pfeed.sh" <<'SH'
feed_pfeed() {
  _e=$1
  case "$_e" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  LABEL="p/$_e"
  URL="https://example.test/$_e"
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
FEED_PARAMS_pfeed='PFEED_ENTRIES'
SH
# settings.env.PFEED_ENTRIES is consulted by the installer and injected
# into the spawned shell; statusline.sh resolves the internal name
# via PFEED_ENTRIES="${NEWSLINE_PFEED_ENTRIES:-...}" — for user feeds the
# internal var is set directly by convention.
cat > "$SETTINGS" <<'JSON'
{"env":{"PFEED_ENTRIES":"alpha,beta"}}
JSON
make_mock_bin mock_curl_dir4 testfeed_pfeed curl <<'MOCK'
#!/bin/sh
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) body=$2; shift 2 ;; *) shift ;; esac
done
cat > "$body" <<'JSON'
{"items":[{"title":"p","url":"https://x.test/p"}]}
JSON
printf '200|40|0.01'
MOCK
out=$(PATH="$mock_curl_dir4:$PATH" NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed pfeed 2>&1)
status=$?
assert_equals "$status" "0"                          "--test-feed iterates FEED_PARAMS entries"
assert_contains "$out" "parameterized via PFEED_ENTRIES" "shows param var name in header"
assert_contains "$out" "[1/2]"                        "per-entry progress shown (1/2)"
assert_contains "$out" "[2/2]"                        "per-entry progress shown (2/2)"
assert_contains "$out" "p/alpha"                      "first CSV entry resolved"
assert_contains "$out" "p/beta"                       "second CSV entry resolved"
assert_contains "$out" "All 2 entries OK"             "summary counts successes"

# Cleanup
rm -rf "$user_feeds_dir"
echo '{}' > "$SETTINGS"

}

section "--test-feed --fixture skips the network and pipes the file into jq" && {
# Fixture mode replaces curl with a local file read. The test asserts that:
#   - exit 0 when jq accepts the fixture
#   - no 'HTTP:' line is printed (curl wasn't invoked)
#   - a 'Fixture:' line is printed with the path and byte count
#   - jq output is identical to what a live-URL run would produce
# Also covers the guard rails: missing file fails fast (exit 2), and
# --fixture without --test-feed is rejected up front (no silent discard).
user_feeds_dir="$SANDBOX/user-feeds-fixture"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/fixfeed.sh" <<'SH'
feed_fixfeed() {
  LABEL='Fix'
  URL='https://example.test/would-be-live.json'
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
SH
fixture_path="$SANDBOX/fixture-happy.json"
cat > "$fixture_path" <<'JSON'
{"items":[{"title":"OfflineA","url":"https://example.test/a"},
          {"title":"OfflineB","url":"https://example.test/b"}]}
JSON

# Shadow curl with a failing stub. If fixture mode leaks into the curl
# branch, the test fails loudly instead of silently masking the regression.
no_curl_dir="$SANDBOX/no-curl"
mkdir -p "$no_curl_dir"
cat > "$no_curl_dir/curl" <<'SH'
#!/bin/sh
echo "FIXTURE MODE SHOULD NOT CALL CURL" >&2
exit 99
SH
chmod +x "$no_curl_dir/curl"

out=$(PATH="$no_curl_dir:$PATH" NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed fixfeed --fixture "$fixture_path" 2>&1)
status=$?
assert_equals "$status" "0"                         "--test-feed --fixture exits 0"
assert_contains "$out" "Fixture:"                   "Fixture: line is printed"
assert_contains "$out" "$fixture_path"              "fixture path is shown"
assert_contains "$out" "no network"                 "offline tag is shown"
assert_contains "$out" "2 rows"                     "jq still processed fixture rows"
assert_contains "$out" "Fix • OfflineA"             "first sample row renders"
assert_contains "$out" "Fix • OfflineB"             "second sample row renders"
case "$out" in
  *"HTTP:"*) fail "--test-feed --fixture must NOT print HTTP: (curl was called)" ;;
  *)         pass "--test-feed --fixture does not call curl" ;;
esac

# Missing fixture: Node validates before spawning bash.
out=$(NEWSLINE_FEEDS_DIR="$user_feeds_dir" \
      node "$CLI" --test-feed fixfeed --fixture /definitely/does/not/exist 2>&1)
status=$?
assert_equals "$status" "2"                         "--test-feed --fixture rejects missing file"
assert_contains "$out" "--fixture"                  "error message mentions --fixture"

# --fixture without --test-feed: nonsense combo.
out=$(node "$CLI" --fixture "$fixture_path" 2>&1)
status=$?
assert_equals "$status" "2"                         "--fixture without --test-feed rejected"
assert_contains "$out" "--fixture requires --test-feed" "error identifies the right missing flag"

rm -rf "$user_feeds_dir" "$no_curl_dir" "$fixture_path"

}

section "--new-feed scaffolds a loadable plugin file" && {
# Stamps a starter feed_<name> plugin into \$CLAUDE_CONFIG_DIR/claude-newsline/feeds/
# and asserts the resulting file is syntactically valid + loadable by sh.
# Also covers: existing files are not overwritten, invalid names are
# rejected, and a built-in collision emits a warning (but still succeeds —
# user override is a documented feature).
scaffold_dir="$SANDBOX/cfg-scaffold"
rm -rf "$scaffold_dir"
mkdir -p "$scaffold_dir"

out=$(CLAUDE_CONFIG_DIR="$scaffold_dir" node "$CLI" --new-feed nyt 2>&1)
status=$?
assert_equals "$status" "0"                          "--new-feed nyt exits 0"
assert_contains "$out" "Created"                     "success message printed"
assert_contains "$out" "nyt.sh"                      "filename is shown"
assert_contains "$out" "--test-feed nyt"             "next-steps hint shows test command"

plugin="$scaffold_dir/claude-newsline/feeds/nyt.sh"
[ -s "$plugin" ] && pass "scaffolded file exists and is non-empty" \
                 || fail "scaffolded file missing at $plugin"
grep -q '^feed_nyt()' "$plugin" && pass "scaffolded file defines feed_nyt()" \
                               || fail "scaffolded file lacks feed_nyt()"
grep -q '^FEED_META_nyt=' "$plugin" && pass "scaffolded file includes FEED_META block" \
                                   || fail "scaffolded file lacks FEED_META block"

# Sh-side loadability: source the file in a subshell and confirm the function
# is defined. Guards against template drift that Node parses fine but sh
# trips over.
sh -c ". \"$plugin\" && command -v feed_nyt" >/dev/null
assert_equals "$?" "0"                               "scaffolded plugin sources cleanly"

# Collision: a second --new-feed nyt must refuse.
out=$(CLAUDE_CONFIG_DIR="$scaffold_dir" node "$CLI" --new-feed nyt 2>&1)
status=$?
assert_equals "$status" "1"                          "--new-feed refuses to overwrite"
assert_contains "$out" "already exists"              "collision message explains why"

# Bad names: leading digit + hyphen.
out=$(CLAUDE_CONFIG_DIR="$scaffold_dir" node "$CLI" --new-feed 2fa 2>&1)
status=$?
assert_equals "$status" "2"                          "--new-feed rejects leading-digit name"
assert_contains "$out" "valid feed name"             "rejection message is clear"

out=$(CLAUDE_CONFIG_DIR="$scaffold_dir" node "$CLI" --new-feed my-feed 2>&1)
status=$?
assert_equals "$status" "2"                          "--new-feed rejects hyphenated name"

# Built-in collision: succeeds but warns.
out=$(CLAUDE_CONFIG_DIR="$scaffold_dir" node "$CLI" --new-feed hn 2>&1)
status=$?
assert_equals "$status" "0"                          "--new-feed <builtin-name> still succeeds"
assert_contains "$out" "OVERRIDE"                    "override warning surfaces"

rm -rf "$scaffold_dir"

}

section "FEED_API_VERSION gate: plugins declaring a future api are skipped" && {
# The sh-side runtime (load_user_feeds) and the installer (scanUserFeeds)
# must agree on what's loadable. A plugin declaring api > FEED_API_VERSION
# is skipped at both layers — runtime doesn't call it, installer doesn't
# surface it in --list-feeds or the wizard. Plugins with no api / non-
# numeric api get implicit v1 for backward compat with files written
# before this gate existed.
api_dir="$SANDBOX/cfg-api"
rm -rf "$api_dir"
mkdir -p "$api_dir/claude-newsline/feeds"

# Three shapes: future-api (skipped), explicit v1 (loaded), no api (loaded).
cat > "$api_dir/claude-newsline/feeds/future.sh" <<'SH'
FEED_META_future='description=Plugin from the year 3000
api=99
category=Future'
feed_future() { LABEL='F'; URL='https://x'; JQ='.'; }
SH
cat > "$api_dir/claude-newsline/feeds/present.sh" <<'SH'
FEED_META_present='description=Explicit v1
api=1'
feed_present() { LABEL='P'; URL='https://x'; JQ='.'; }
SH
cat > "$api_dir/claude-newsline/feeds/legacy.sh" <<'SH'
FEED_META_legacy='description=Pre-gate plugin, no api declared'
feed_legacy() { LABEL='L'; URL='https://x'; JQ='.'; }
SH
# Non-numeric api: installer treats as v1 per the "absent/non-numeric
# is implicit v1" rule. The sh-side loader has the same contract.
cat > "$api_dir/claude-newsline/feeds/sloppy.sh" <<'SH'
FEED_META_sloppy='description=Author typed "latest" instead of a number
api=latest'
feed_sloppy() { LABEL='S'; URL='https://x'; JQ='.'; }
SH
cat > "$api_dir/claude-newsline/feeds/broken.sh" <<'SH'
FEED_META_broken='description=Syntax-broken plugin'
feed_broken( {
SH
cat > "$api_dir/claude-newsline/feeds/nofunc.sh" <<'SH'
FEED_META_nofunc='description=Missing function plugin'
SH

# Installer-side (scanUserFeeds, via --list-feeds):
out=$(CLAUDE_CONFIG_DIR="$api_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "present"                     "explicit api=1 plugin is listed"
assert_contains "$out" "legacy"                      "no-api plugin is listed (implicit v1)"
assert_contains "$out" "sloppy"                      "non-numeric api falls back to v1"
# future-api plugin must NOT appear in the loadable "User feeds:" block —
# but it SHOULD appear in the separate Incompatible section so users see
# why their dropped-in plugin isn't loading. Structural check: split on
# the Incompatible header and assert future shows up only after it.
loadable_block=$(printf '%s\n' "$out" | awk '/^⚠ Incompatible/{exit} {print}')
case "$loadable_block" in
  *"future"*) fail "future-api plugin must not appear in loadable block" ;;
  *)          pass "loadable block excludes future-api plugin" ;;
esac
case "$loadable_block" in
  *"broken"*) fail "broken plugin must not appear in loadable block" ;;
  *)          pass "loadable block excludes syntax-broken plugin" ;;
esac
case "$loadable_block" in
  *"nofunc"*) fail "missing-function plugin must not appear in loadable block" ;;
  *)          pass "loadable block excludes missing-function plugin" ;;
esac
assert_contains "$out" "Incompatible plugins"        "Incompatible section surfaces future-api plugin"
assert_contains "$out" "declares api=99"             "Incompatible block shows declared api"
# Static parse: a syntax-broken file (`feed_broken( {` — no closing paren)
# fails the function-definition regex and lands in Incompatible with the
# same "not defined" reason a missing-function file would. The runtime
# still surfaces the actual syntax error in NEWSLINE_DEBUG output (sh-side
# section below); install-time we don't source the file so we can't
# distinguish "syntax error" from "no function defined" — both are
# "this file won't load."
assert_contains "$out" "broken"                      "Incompatible section surfaces syntax-broken plugin"
assert_contains "$out" "feed_broken() not defined"   "syntax-broken plugin reports as not-defined (static parse)"
assert_contains "$out" "nofunc"                      "Incompatible section surfaces missing-function plugin"
assert_contains "$out" "feed_nofunc() not defined"   "missing-function plugin reports as not-defined"

# Sh-side (load_user_feeds, via NEWSLINE_DEBUG=1):
out=$(NEWSLINE_FEEDS_DIR="$api_dir/claude-newsline/feeds" NEWSLINE_DEBUG=1 \
      bash "$STATUSLINE" </dev/null 2>&1)
# `feeds enabled:` line lists every ALL_FEEDS entry that passed the gate.
enabled_line=$(printf '%s\n' "$out" | grep '^feeds enabled:')
case "$enabled_line" in
  *present*)  pass "sh-side loads present (api=1)" ;;
  *)          fail "sh-side did not load present; got: $enabled_line" ;;
esac
case "$enabled_line" in
  *legacy*)   pass "sh-side loads legacy (no api → implicit v1)" ;;
  *)          fail "sh-side did not load legacy; got: $enabled_line" ;;
esac
case "$enabled_line" in
  *sloppy*)   pass "sh-side loads sloppy (non-numeric api → implicit v1)" ;;
  *)          fail "sh-side did not load sloppy; got: $enabled_line" ;;
esac
case "$enabled_line" in
  *future*)   fail "sh-side loaded future (api=99) but should have skipped" ;;
  *)          pass "sh-side skips future-api plugin" ;;
esac
case "$enabled_line" in
  *broken*)   fail "sh-side loaded broken plugin but should have skipped" ;;
  *)          pass "sh-side skips syntax-broken plugin" ;;
esac
case "$enabled_line" in
  *nofunc*)   fail "sh-side loaded nofunc plugin but should have skipped" ;;
  *)          pass "sh-side skips missing-function plugin" ;;
esac

rm -rf "$api_dir"

}

section "FEED_API_VERSION stays in sync between statusline.sh and claude-newsline.js" && {
# Same drift-prevention pattern as ALL_FEEDS / DEFAULT_ROTATION_SEC — the
# sh side is canonical, the JS side mirrors. A silent divergence would
# surface as "the runtime dropped my plugin but the installer said it
# was fine" (or vice versa).
sh_ver=$(grep -m1 '^FEED_API_VERSION=' "$STATUSLINE" | cut -d= -f2)
js_ver=$(node -e "console.log(require('$CLI').FEED_API_VERSION)")
assert_equals "$js_ver" "$sh_ver" "JS FEED_API_VERSION matches sh FEED_API_VERSION"

# pluginApiVersion: absent / empty / non-numeric → 1 (backward compat).
# Explicit numeric → the number.
out=$(node -e "
  const m = require('$CLI');
  const f = m.pluginApiVersion;
  console.log([f({}), f({api:''}), f({api:'latest'}), f({api:'1'}), f({api:'3'})].join(','));
")
assert_equals "$out" "1,1,1,1,3" "pluginApiVersion: absent/empty/non-numeric → 1; numeric passthrough"

}

section "--list-feeds surfaces api-incompatible plugins under an Incompatible section" && {
# Silent-skip on incompatibility is wrong UX — a user who drops a plugin
# needs visible feedback when the runtime won't load it. This test asserts
# both the plain and verbose paths render an "Incompatible" section when
# api-rejected plugins exist, and omit the section entirely when there are
# none (so the happy path stays quiet). Also asserts the wizard/loader
# filter (scanUserFeeds) continues to hide incompatibles — they're a
# reporting signal, not a loadable surface.
incompat_dir="$SANDBOX/cfg-incompat"
rm -rf "$incompat_dir"
mkdir -p "$incompat_dir/claude-newsline/feeds"

# Mixed set: one loadable, one explicitly incompatible, one non-numeric
# (should fall back to v1 and thus be loadable — guards against confusing
# "non-numeric" with "incompatible" in the renderer).
cat > "$incompat_dir/claude-newsline/feeds/good.sh" <<'SH'
FEED_META_good='description=Loadable
api=1
category=News'
feed_good() { LABEL='G'; URL='https://x'; JQ='.'; }
SH
cat > "$incompat_dir/claude-newsline/feeds/future.sh" <<'SH'
FEED_META_future='description=From the year 3000
api=99
version=0.5.0'
feed_future() { LABEL='F'; URL='https://x'; JQ='.'; }
SH

# Plain --list-feeds: Incompatible section present, plugin listed with
# declared api and runtime-supported-max.
out=$(CLAUDE_CONFIG_DIR="$incompat_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "Incompatible plugins"       "plain list has Incompatible header"
assert_contains "$out" "future"                     "incompatible plugin name shown"
assert_contains "$out" "declares api=99"            "plain list reports declared api"
assert_contains "$out" "runtime supports up to 2"   "plain list reports runtime max"
# good.sh must still appear under User feeds (not poisoned by the
# incompatible sibling).
assert_contains "$out" "User feeds:"                "User feeds header present"
assert_contains "$out" "good"                       "loadable plugin still listed"

# Verbose --list-feeds: the Incompatible group header appears once, below
# all loadable category groups. Plugin rendered with reason + self-
# reported metadata (description/version) so user can identify the file.
out=$(CLAUDE_CONFIG_DIR="$incompat_dir" node "$CLI" --list-feeds -v 2>&1)
assert_contains "$out" "Incompatible"               "verbose list has Incompatible group"
assert_contains "$out" "From the year 3000"         "-v shows incompatible plugin's description"
assert_contains "$out" "0.5.0"                       "-v shows incompatible plugin's version"
assert_contains "$out" "reason"                      "-v shows reason line"

# No-incompat case: remove the future plugin and re-run. The Incompatible
# section must disappear entirely — rendering an empty header would
# confuse users who'd wonder what's being hidden.
rm "$incompat_dir/claude-newsline/feeds/future.sh"
out=$(CLAUDE_CONFIG_DIR="$incompat_dir" node "$CLI" --list-feeds 2>&1)
case "$out" in
  *"Incompatible"*) fail "plain list must not show Incompatible when empty" ;;
  *)                pass "plain list hides Incompatible section when empty" ;;
esac
out=$(CLAUDE_CONFIG_DIR="$incompat_dir" node "$CLI" --list-feeds -v 2>&1)
case "$out" in
  *"Incompatible"*) fail "verbose list must not show Incompatible when empty" ;;
  *)                pass "verbose list hides Incompatible section when empty" ;;
esac

# scanUserFeeds (loadable-only filter) must STILL exclude incompatibles.
# The Incompatible section is an inspection-time affordance; the wizard's
# feeds checkbox should never offer a plugin the runtime will reject.
cat > "$incompat_dir/claude-newsline/feeds/future.sh" <<'SH'
FEED_META_future='api=99'
feed_future() { LABEL='F'; URL='https://x'; JQ='.'; }
SH
out=$(node -e "
  const m = require('$CLI');
  const loadable = m.scanUserFeeds('$incompat_dir/claude-newsline/feeds').map(f=>f.name).join(',');
  const all      = m.scanAllUserFeeds('$incompat_dir/claude-newsline/feeds').map(f=>f.name+(f.compat.ok?'':':incompat')).join(',');
  console.log('loadable='+loadable);
  console.log('all='+all);
")
assert_contains "$out" "loadable=good"              "scanUserFeeds excludes api=99 plugins"
assert_contains "$out" "future:incompat"            "scanAllUserFeeds tags api=99 as incompat"
assert_contains "$out" "good"                       "scanAllUserFeeds also includes loadable plugins"

rm -rf "$incompat_dir"

}
section "--list-feeds surfaces unreadable plugin files" && {
# A file the scanner can't read (perms, dangling symlink) used to be
# silently dropped — neither the loadable list nor the Incompatible
# section mentioned it. The runtime's load_user_feeds would surface a
# source failure via NEWSLINE_DEBUG=1, so the installer side was the
# inconsistency. Now it lands in Incompatible with a chmod hint.
unreadable_dir="$SANDBOX/cfg-unreadable"
rm -rf "$unreadable_dir"
mkdir -p "$unreadable_dir/claude-newsline/feeds"
cat > "$unreadable_dir/claude-newsline/feeds/secret.sh" <<'SH'
feed_secret() { LABEL='S'; URL='https://x'; JQ='.'; }
SH
chmod 0 "$unreadable_dir/claude-newsline/feeds/secret.sh"
out=$(CLAUDE_CONFIG_DIR="$unreadable_dir" node "$CLI" --list-feeds 2>&1)
status=$?
assert_equals "$status" "0"                              "--list-feeds doesn't crash on unreadable plugin"
assert_contains "$out" "Incompatible plugins"            "unreadable plugin shows under Incompatible"
assert_contains "$out" "secret"                          "unreadable plugin name surfaces"
assert_contains "$out" "unreadable"                      "row carries the unreadable reason"
assert_contains "$out" "chmod a+r"                       "fix hint suggests chmod"

# scanAllUserFeeds tags the row; scanUserFeeds (the loadable filter) hides it.
# File is still 0 from above — keep it that way through the second node call.
out=$(CLAUDE_CONFIG_DIR="$unreadable_dir" node -e "
  const m = require('$CLI');
  const dir = '$unreadable_dir/claude-newsline/feeds';
  const all = m.scanAllUserFeeds(dir).map(f=>f.name+(f.compat.ok?'':':'+f.compat.reason)).join(',');
  const loadable = m.scanUserFeeds(dir).map(f=>f.name).join(',');
  console.log('all=' + all);
  console.log('loadable=' + loadable);
")
assert_contains "$out" "secret:unreadable"   "scanAllUserFeeds tags secret as unreadable"
assert_equals   "$(printf '%s\n' "$out" | grep '^loadable=' | cut -d= -f2)" \
  "" "scanUserFeeds hides unreadable plugin from the loadable list"

# Restore mode so rm -rf can clean up cleanly on EXIT trap.
chmod 0644 "$unreadable_dir/claude-newsline/feeds/secret.sh"
rm -rf "$unreadable_dir"

}
section "--list-feeds does not source plugin code (static parse)" && {
# Regression: an earlier impl spawned `sh -c '. plugin'` per file with a
# 2s timeout to verify feed_<name>() was defined. That executed arbitrary
# plugin code at install / --list-feeds / wizard-render time. A misbehaving
# plugin (sleep, infinite loop, side-effect at top level) could hang the
# installer or run code the user never asked for. Static parse of the file
# (regex for feed_<name>() definition) avoids the trust boundary entirely.
ss_dir="$SANDBOX/cfg-static-scan"
rm -rf "$ss_dir"
mkdir -p "$ss_dir/claude-newsline/feeds"

# A plugin whose top-level code WOULD fail / produce output if sourced.
# Static parse must accept the feed_<name> definition as valid without
# executing the offending lines above it.
cat > "$ss_dir/claude-newsline/feeds/loud.sh" <<'SH'
echo "PLUGIN SOURCED (should not see this)" >&2
exit 1
feed_loud() { LABEL='L'; URL='https://x'; JQ='.'; }
SH

# Run --list-feeds and capture both streams. The fingerprint string from
# the plugin must NOT appear (would mean sourcing happened). The plugin
# itself MUST appear in the user-feeds list (definition was detected).
out=$(CLAUDE_CONFIG_DIR="$ss_dir" node "$CLI" --list-feeds 2>&1)
case "$out" in
  *"PLUGIN SOURCED"*) fail "--list-feeds did not source plugin code" "fingerprint string leaked" ;;
  *)                  pass "--list-feeds did not source plugin code" ;;
esac
assert_contains "$out" "loud" "--list-feeds detected feed_loud() definition without sourcing"

# A file with no feed_<name>() definition is correctly tagged incompatible
# with a per-row fix hint (replaces the old "all incompat = api mismatch"
# footer that was wrong for this case).
cat > "$ss_dir/claude-newsline/feeds/empty.sh" <<'SH'
# author wrote a comment but no function
SH
out=$(CLAUDE_CONFIG_DIR="$ss_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "empty"                                       "missing-function plugin listed under Incompatible"
assert_contains "$out" "feed_empty() not defined in file"            "incompat row carries the specific reason"
assert_contains "$out" "fix: add a \`feed_empty() { … }\` definition" "missing-function row carries fix hint"

rm -rf "$ss_dir"

}
section "user feed override does not inherit built-in FEED_META" && {
# Regression: when a user file overrides a built-in (e.g. hn.sh) and
# doesn't set its own FEED_META_<name>, the built-in's metadata
# (description, category, source=built-in) used to remain in the
# environment. statusline.sh would then auto-attach `source=<user-path>`
# on top of it, producing mixed-provenance metadata in NEWSLINE_DEBUG.
# Fix: clear FEED_META_<name> before sourcing each user plugin.
ov_dir="$SANDBOX/cfg-override"
rm -rf "$ov_dir"
mkdir -p "$ov_dir/claude-newsline/feeds"
cat > "$ov_dir/claude-newsline/feeds/hn.sh" <<'SH'
# Bare override — no FEED_META declared.
feed_hn() { LABEL='HN-user'; URL='https://example.com/hn-user'; JQ='.[]|@tsv'; }
SH

dbg=$(CLAUDE_CONFIG_DIR="$ov_dir" NEWSLINE_DEBUG=1 NEWSLINE_FEEDS_DIR="$ov_dir/claude-newsline/feeds" \
        bash "$STATUSLINE" </dev/null 2>&1)

# Built-in description must NOT appear under feed `hn` since the user file
# overrode the function but provided no metadata of its own.
case "$dbg" in
  *"Hacker News front page"*) fail "user override does not inherit built-in description" "built-in description leaked into override row" ;;
  *)                          pass "user override does not inherit built-in description" ;;
esac

# The user-file source path SHOULD be auto-attached, since attribution is
# the one piece of metadata the runtime owns.
assert_contains "$dbg" "$ov_dir/claude-newsline/feeds/hn.sh" "user override carries auto-attached source path"

rm -rf "$ov_dir"

}
section "--list-feeds -v groups plugins by FEED_META category" && {
# With multiple categories present, -v renders a `[<Category>]` header
# above each group. Plugins with no category land in "Custom" (user) or
# "News" (built-in default). Suppresses the `category=` key from the
# per-plugin detail list since the group header already shows it.
cat_dir="$SANDBOX/cfg-category"
rm -rf "$cat_dir"
mkdir -p "$cat_dir/claude-newsline/feeds"

cat > "$cat_dir/claude-newsline/feeds/weather.sh" <<'SH'
FEED_META_weather='description=Local forecast
api=1
category=Weather'
feed_weather() { LABEL='W'; URL='https://x'; JQ='.'; }
SH
cat > "$cat_dir/claude-newsline/feeds/nocat.sh" <<'SH'
FEED_META_nocat='description=No category declared
api=1'
feed_nocat() { LABEL='N'; URL='https://x'; JQ='.'; }
SH

out=$(CLAUDE_CONFIG_DIR="$cat_dir" node "$CLI" --list-feeds -v 2>&1)
assert_contains "$out" "[News]"                      "built-ins group under [News]"
assert_contains "$out" "[Weather]"                   "declared category renders as header"
assert_contains "$out" "[Custom]"                    "missing category defaults to [Custom]"
# The `category=` line must not appear in the per-plugin details — the
# header already carries the category, and double-printing would be noise.
case "$out" in
  *"category     Weather"*) fail "category= key should be suppressed in details" ;;
  *)                        pass "category= key is elided from per-plugin details" ;;
esac

rm -rf "$cat_dir"

}

section "--list-feeds surfaces user feeds alongside built-ins" && {
# Plain list shows built-ins + user feeds; -v/--verbose adds FEED_META
# fields. A built-in shadowed by a same-named user file is flagged as
# overridden (matches the runtime's last-definition-wins semantics).
list_dir="$SANDBOX/cfg-list"
rm -rf "$list_dir"
mkdir -p "$list_dir/claude-newsline/feeds"

out=$(CLAUDE_CONFIG_DIR="$list_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "Built-in feeds:"             "plain list has built-in header"
assert_contains "$out" "hn"                          "hn listed"
assert_contains "$out" "reddit"                      "reddit listed"
assert_contains "$out" "lobsters"                    "lobsters listed"
assert_contains "$out" "No user feeds"               "empty-state hint shown"
assert_contains "$out" "--new-feed"                  "empty-state suggests --new-feed"

cat > "$list_dir/claude-newsline/feeds/nyt.sh" <<'SH'
FEED_META_nyt='description=New York Times top stories
version=0.2.0
author=alice
homepage=https://nyt.com'
feed_nyt() { LABEL='NYT'; URL='https://x'; JQ='.'; }
SH
cat > "$list_dir/claude-newsline/feeds/hn.sh" <<'SH'
FEED_META_hn='description=Custom HN override'
feed_hn() { LABEL='HN'; URL='https://y'; JQ='.'; }
SH
# Bad-name file — scanner must skip it (matches sh-side rules).
cat > "$list_dir/claude-newsline/feeds/2bad.sh" <<'SH'
feed_2bad() { :; }
SH

out=$(CLAUDE_CONFIG_DIR="$list_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "User feeds:"                 "user feeds section appears"
assert_contains "$out" "nyt"                         "user feed nyt listed"
assert_contains "$out" "overridden by user feed"     "built-in hn flagged as overridden"
case "$out" in
  *"2bad"*) fail "bad-name user feed should not appear in --list-feeds" ;;
  *)        pass "bad-name user feed is skipped" ;;
esac

# Verbose: description/version/author/homepage rendered.
out=$(CLAUDE_CONFIG_DIR="$list_dir" node "$CLI" --list-feeds -v 2>&1)
assert_contains "$out" "New York Times top stories"  "-v shows description"
assert_contains "$out" "0.2.0"                        "-v shows version"
assert_contains "$out" "alice"                        "-v shows author"
assert_contains "$out" "https://nyt.com"              "-v shows homepage"
assert_contains "$out" "Custom HN override"           "-v shows override description"
out=$(CLAUDE_CONFIG_DIR="$list_dir" node "$CLI" --list-feeds --verbose 2>&1)
assert_contains "$out" "New York Times top stories"   "--verbose long form works"

rm -rf "$list_dir"

}

section "FEED_META_<name> is surfaced in NEWSLINE_DEBUG=1 report" && {
# Metadata is parsed only at debug-time (no cost on the hot path), so the
# round-trip test lives here. Built-in metadata is declared next to the feed
# functions; the report must show description for each built-in, plus any
# user-plugin metadata + the auto-attached source=<path>.
out=$(NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null)
assert_contains "$out" "feed metadata:" "debug report has metadata section"
assert_contains "$out" "Hacker News front page" "hn description surfaces"
assert_contains "$out" "Lobsters hottest links" "lobsters description surfaces"
assert_contains "$out" "parameterized via NEWSLINE_REDDIT_SUBS" "reddit (parameterized) description surfaces"

# User feed metadata round-trip: author/version plus auto-attached source=.
user_feeds_dir="$SANDBOX/user-feeds-meta"
mkdir -p "$user_feeds_dir"
cat > "$user_feeds_dir/myplugin.sh" <<'SH'
FEED_META_myplugin='description=A friendly test feed
version=1.2.3
author=tester'
feed_myplugin() {
  LABEL='Test'
  URL='https://example.test/x'
  JQ='.[] | [$default, .title, .url] | @tsv'
}
SH
out=$(NEWSLINE_FEEDS_DIR="$user_feeds_dir" NEWSLINE_DEBUG=1 bash "$STATUSLINE" </dev/null)
assert_contains "$out" "A friendly test feed" "user plugin description surfaces"
assert_contains "$out" "1.2.3"                 "user plugin version surfaces"
assert_contains "$out" "tester"                "user plugin author surfaces"
assert_contains "$out" "$user_feeds_dir/myplugin.sh" "auto-attached source=<path> points at the user file"
rm -rf "$user_feeds_dir"

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
section "uninstall removes installed script, colors.sh, xml-to-json.js, and cache" && {
run_cli >/dev/null 2>&1
prime_cache "cache cleanup test" "https://example.com/cache"
run_uninstall >/dev/null 2>&1
assert_file_absent "$CLAUDE_CONFIG_DIR/claude-newsline.sh" "script deleted"
assert_file_absent "$CLAUDE_CONFIG_DIR/colors.sh"          "colors.sh deleted"
assert_file_absent "$CLAUDE_CONFIG_DIR/xml-to-json.js"     "xml-to-json.js deleted"
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
echo "=== regression fixes (v0.2.0 review pass) ==="

section "is_disabled tolerates whitespace in NEWSLINE_FEEDS_DISABLED" && {
# Repro for the silent miss: a user-friendly CSV like "reddit, lobsters"
# (note the leading space on the second entry) used to disable only the
# first entry — the substring match against ",reddit, lobsters," looked
# for ",lobsters," literally and found ",␣lobsters," instead.
prime_cache "HN" "Should Render" "https://example.com/x"
out=$(NEWSLINE_FEEDS_DISABLED="reddit, lobsters" \
      bash "$STATUSLINE" </dev/null 2>&1)
assert_contains "$out" "Should Render" "headline still rendered (sanity)"

# End-to-end: the only way to verify is_disabled is to drive a refresh and
# inspect which feeds got fetched. Mock curl logs every URL it sees; we
# assert that after disabling all three built-ins via spaced-CSV, no built-
# in URL was fetched. If is_disabled mis-handled whitespace, lobsters or
# reddit would slip through.
fetch_log="$SANDBOX/fetch.log"
: > "$fetch_log"
make_mock_bin disable_curl spacecsv_curl curl <<MOCK
#!/bin/sh
url=""
for arg in "\$@"; do case "\$arg" in https://*) url="\$arg" ;; esac; done
printf '%s\n' "\$url" >> "$fetch_log"
printf '{}'
MOCK
rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
NEWSLINE_FEEDS_DISABLED="hn, reddit, lobsters" \
  PATH="$disable_curl:$PATH" \
  bash "$STATUSLINE" </dev/null >/dev/null 2>&1
# Wait briefly for any backgrounded fetch to land.
sleep 0.5
hits=$(wc -l <"$fetch_log" | tr -d ' ')
assert_equals "$hits" "0" "spaced-CSV disables every named feed (no fetches)"
rm -f "$fetch_log" "$CACHE" "$CACHE.pending" "$CACHE.lock"

}
section "--disable normalizes whitespace before writing .env" && {
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
run_cli --disable "reddit, lobsters" >/dev/null 2>&1
written=$(jq -r '.env.NEWSLINE_FEEDS_DISABLED' "$SETTINGS")
assert_equals "$written" "reddit,lobsters" \
  "--disable strips per-entry whitespace (canonical comma-tight form)"

# Same for --only inversion (which routes through invertOnly() → join(',')).
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
run_cli --only "hn" >/dev/null 2>&1
written=$(jq -r '.env.NEWSLINE_FEEDS_DISABLED' "$SETTINGS")
case "$written" in
  *,*\ *|*\ *,*) fail "--only writes whitespace-tight CSV" "got: $written" ;;
  *)             pass "--only writes whitespace-tight CSV" ;;
esac

}
section "NEWSLINE_FEEDS_DIR override is honored by --new-feed and --list-feeds" && {
override_dir="$SANDBOX/dotfile-feeds"
rm -rf "$override_dir"
NEWSLINE_FEEDS_DIR="$override_dir" node "$CLI" --new-feed dotfile_demo </dev/null >/dev/null 2>&1
assert_file_exists "$override_dir/dotfile_demo.sh" \
  "--new-feed scaffolds into NEWSLINE_FEEDS_DIR override"
# The default location must NOT receive the file.
assert_file_absent "$CLAUDE_CONFIG_DIR/claude-newsline/feeds/dotfile_demo.sh" \
  "--new-feed does not stamp the default dir when override is set"

# --list-feeds scans the override dir.
out=$(NEWSLINE_FEEDS_DIR="$override_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "dotfile_demo" "--list-feeds shows plugins from NEWSLINE_FEEDS_DIR override"

rm -rf "$override_dir"

}
section "parseFeedMeta accepts double-quoted FEED_META blocks" && {
# Sh sources both quote styles; the static parser must too. A future-api
# plugin written with double quotes used to bypass the installer-side gate
# (treated as no-meta → implicit api=1 → "loadable") while the runtime
# correctly skipped it. Symptom: file shows in --list-feeds, never rotates.
dq_dir="$SANDBOX/cfg-double-quoted-meta"
rm -rf "$dq_dir"
mkdir -p "$dq_dir/claude-newsline/feeds"
cat > "$dq_dir/claude-newsline/feeds/dq.sh" <<'SH'
FEED_META_dq="description=Double-quoted metadata block
api=99
category=Future"
feed_dq() { LABEL='DQ'; URL='https://x'; JQ='.'; }
SH
out=$(CLAUDE_CONFIG_DIR="$dq_dir" node "$CLI" --list-feeds 2>&1)
assert_contains "$out" "Incompatible plugins" "double-quoted api=99 is detected as incompat"
assert_contains "$out" "declares api=99"      "declared api surfaced from double-quoted body"
# Also: double-quoted description is read out via parseFeedMeta in -v.
out=$(CLAUDE_CONFIG_DIR="$dq_dir" node "$CLI" --list-feeds -v 2>&1)
assert_contains "$out" "Double-quoted metadata block" "-v reads description from double quotes"

# Direct unit-level check — parseFeedMeta returns the same object shape for
# either quote style.
out=$(node -e "
  const m = require('$CLI');
  const sq = m.parseFeedMeta(\"FEED_META_x='api=2\\nrole=test'\\n\", 'x');
  const dq = m.parseFeedMeta('FEED_META_x=\"api=2\\nrole=test\"\\n', 'x');
  console.log(JSON.stringify(sq) + '|' + JSON.stringify(dq));
")
assert_equals "$out" '{"api":"2","role":"test"}|{"api":"2","role":"test"}' \
  "parseFeedMeta returns identical objects for single vs double quotes"

rm -rf "$dq_dir"

}
section "detectFeedFunction tolerates next-line-brace style" && {
# POSIX accepts feed_foo()<newline>{ … } — bash too. Pre-fix the static
# parser required the brace on the same line as the parens, so a plugin
# in the canonical-but-not-dominant style landed in Incompatible with a
# misleading "feed_X() not defined" error pointing at code that IS defined.
nlb_dir="$SANDBOX/cfg-next-line-brace"
rm -rf "$nlb_dir"
mkdir -p "$nlb_dir/claude-newsline/feeds"
cat > "$nlb_dir/claude-newsline/feeds/nlb.sh" <<'SH'
FEED_META_nlb='description=Next-line-brace style
api=1'
feed_nlb()
{
  LABEL='NLB'
  URL='https://x'
  JQ='.'
}
SH
out=$(CLAUDE_CONFIG_DIR="$nlb_dir" node "$CLI" --list-feeds 2>&1)
case "$out" in
  *"Incompatible"*nlb*) fail "next-line-brace plugin must NOT land in Incompatible" ;;
  *)                    pass "next-line-brace plugin is recognized as loadable" ;;
esac
assert_contains "$out" "nlb"             "next-line-brace plugin appears in user feeds"

# Direct unit check on detectFeedFunction (via scanAllUserFeeds compat flag).
out=$(node -e "
  const m = require('$CLI');
  const f = m.scanAllUserFeeds('$nlb_dir/claude-newsline/feeds').find(x => x.name === 'nlb');
  console.log(f && f.compat && f.compat.ok ? 'loadable' : 'rejected');
")
assert_equals "$out" "loadable" "scanAllUserFeeds tags next-line-brace plugin loadable"

rm -rf "$nlb_dir"

}
section "writeSettings errors loudly on a broken symlink" && {
# Pre-fix: lstat saw the link, realpath threw ENOENT, the catch swallowed
# it, and the subsequent renameSync replaced the link with a regular file —
# silently destroying the dotfiles intent. Now: an explicit error.
broken_dir="$SANDBOX/broken-link"
mkdir -p "$broken_dir"
ln -s "$broken_dir/does-not-exist.json" "$broken_dir/settings.json"
out=$(CLAUDE_CONFIG_DIR="$broken_dir" node "$CLI" --yes </dev/null 2>&1)
status=$?
if [ "$status" -eq 0 ]; then
  fail "broken-symlink install exits non-zero" "exited 0; symlink may have been replaced"
else
  pass "broken-symlink install exits non-zero"
fi
assert_contains "$out" "symlink to a missing target" "error message identifies the symlink failure"
# Critical: the symlink must STILL be a symlink.
if [ -L "$broken_dir/settings.json" ]; then
  pass "broken symlink is preserved (not replaced with regular file)"
else
  fail "broken symlink is preserved (not replaced with regular file)" "link replaced"
fi
rm -rf "$broken_dir"

}
section "--color at runtime default elides the .env write" && {
# Symmetric with the existing rotation/reddit elision rules. A user
# explicitly picking dim_yellow (the runtime default) should clear any
# stale prior override, not pin the value forever.
sh_color=$(grep -E 'NEWSLINE_COLOR_FEED:-' "$SCRIPT_DIR/bin/statusline.sh" | head -1 | \
  sed -E 's/.*:-([^}]+)\}.*/\1/')
cat > "$SETTINGS" <<JSON
{"env":{"NEWSLINE_COLOR_FEED":"sky"}}
JSON
run_cli --color "$sh_color" >/dev/null 2>&1
assert_env_gone NEWSLINE_COLOR_FEED "explicit runtime-default color clears stale override"

# A non-default color still writes through.
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
run_cli --color sky >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_COLOR_FEED' "$SETTINGS")" "sky" \
  "non-default color still written"

}
section "--separator at runtime default elides the .env write" && {
sh_sep=$(grep -E 'NEWSLINE_LABEL_SEP:-' "$SCRIPT_DIR/bin/statusline.sh" | head -1 | \
  sed -E 's/.*:-([^}]+)\}.*/\1/')
cat > "$SETTINGS" <<'JSON'
{"env":{"NEWSLINE_LABEL_SEP":" | "}}
JSON
# Pass the runtime default verbatim.
run_cli --separator "$sh_sep" >/dev/null 2>&1
assert_env_gone NEWSLINE_LABEL_SEP "explicit runtime-default separator clears stale override"

# A non-default separator still writes through.
cat > "$SETTINGS" <<'JSON'
{"model":"claude-opus-4-7"}
JSON
run_cli --separator " | " >/dev/null 2>&1
assert_equals "$(jq -r '.env.NEWSLINE_LABEL_SEP' "$SETTINGS")" " | " \
  "non-default separator still written"

}
section "wizard option lists include the runtime default even when curated" && {
# Drift guard: a future statusline.sh default change shouldn't make fresh-
# install users unable to see the actual default in the wizard's picker.
# wizardInitialValues is the fall-back; the option list construction is in
# runWizard, which we can't drive non-interactively. So we assert the
# JS-side helpers expose runtime defaults that match sh, and that
# isAcceptedColor accepts the default — the building blocks the wizard uses.
js_color=$(node -e "
  // Re-derive the loadShDefault parse the way the installer does.
  const fs = require('fs'), path = require('path');
  const src = fs.readFileSync(path.join(path.dirname('$CLI'), 'statusline.sh'), 'utf8');
  const m = src.match(/\"\\\$\\{NEWSLINE_COLOR_FEED(?::-|-)([^}]*)\\}\"/m);
  console.log(m ? m[1] : 'unknown');
")
sh_color=$(grep -E 'NEWSLINE_COLOR_FEED:-' "$SCRIPT_DIR/bin/statusline.sh" | head -1 | \
  sed -E 's/.*:-([^}]+)\}.*/\1/')
assert_equals "$js_color" "$sh_color" "JS reads NEWSLINE_COLOR_FEED default same as sh"

}
section "stale .new.* tape files are reaped on cache-stale ticks" && {
# refresh_all_feeds writes the merged tape to $CACHE_FILE.new.$$ before
# mv'ing it to .pending or the live cache. A SIGKILL between awk completion
# and the mv leaves $CACHE_FILE.new.<pid> on disk forever — disk waste,
# AND uninstall's `rmdir cache/` then fails with ENOTEMPTY, leaving the
# cache directory behind after `--uninstall`.
#
# Plant a clearly-orphaned .new.* file with a far-past mtime, drive a tick
# that triggers the refresh branch (cache stale or absent), and assert the
# reaper picked it up. The reaper mirrors the existing buckets reaper —
# same STALE_REAP_SEC budget, same gating on entering the refresh branch.
ensure_fakedate
mkdir -p "$(dirname "$CACHE")"
rm -f "$CACHE" "$CACHE.pending" "$CACHE.new."*
rm -rf "$CACHE.lock" "$CACHE.buckets."*
# Plant the orphan with epoch-0 mtime so any positive FAKE_NOW is well past
# STALE_REAP_SEC=60. perl utime is the portable way to reach mtime=0.
touch "$CACHE.new.99999"
perl -e 'utime 0, 0, $ARGV[0]' "$CACHE.new.99999"

# Cache is empty → tick enters refresh branch and runs reapers. We don't
# need the refresh itself to succeed; the reaper runs unconditionally
# inside the branch. Mock curl as a no-op so the foreground returns fast.
make_mock_bin newreap_curl newreap_curl curl <<'SH'
#!/bin/sh
exit 1
SH
FAKE_NOW=600 NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
  PATH="$fakedate_dir:$newreap_curl:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1 || true

if [ ! -e "$CACHE.new.99999" ]; then
  pass "stale .new.<pid> orphan reaped on cache-stale tick"
else
  fail "stale .new.<pid> orphan reaped on cache-stale tick" "$CACHE.new.99999 still present"
fi

# Sibling guard: a freshly-written .new.* file must NOT be reaped (would
# clobber an in-flight refresh on a slow-disk box where the awk finished
# but the mv hasn't fired yet). STALE_REAP_SEC=60, FAKE_NOW=10 → fresh.
rm -f "$CACHE.new."*
touch "$CACHE.new.88888"   # mtime = now (real wall clock, but ≪ FAKE_NOW)
FAKE_NOW=10 NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
  PATH="$fakedate_dir:$newreap_curl:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1 || true
if [ -e "$CACHE.new.88888" ]; then
  pass "fresh .new.<pid> file is NOT reaped (in-flight refresh safe)"
else
  fail "fresh .new.<pid> file is NOT reaped (in-flight refresh safe)" \
    "reaper aged out a fresh staging file"
fi
rm -f "$CACHE.new."*

}
section "_pipe_strip_c1 drops bare C1 control bytes from feed bodies" && {
# Defense-in-depth check: an attacker-controlled feed could in theory smuggle
# bare 0x9B (C1 CSI) bytes that aren't valid UTF-8 continuations. The
# tr -d C0 strip doesn't touch 0x80-0x9F, so iconv -f UTF-8 -t UTF-8 -c
# was wired in to drop bare C1 bytes while preserving valid multi-byte UTF-8.
#
# Skip this test on hosts without iconv — the script's _HAVE_ICONV gate
# already degrades to cat in that case, and asserting iconv-specific
# behavior would just mark the host as failing.
if ! iconv -f UTF-8 -t UTF-8 -c </dev/null >/dev/null 2>&1; then
  pass "iconv unavailable on host — skipping C1 strip assertion"
else
  c1_dir="$SANDBOX/c1-strip"
  mkdir -p "$c1_dir"
  cat > "$c1_dir/c1feed.sh" <<'SH'
feed_c1feed() {
  LABEL='C1'
  URL='https://example.test/c1.json'
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
SH
  # Mock curl returns a JSON title containing a bare 0x9B byte. After C0
  # strip 0x9B survives; iconv drops it because it isn't part of a valid
  # UTF-8 sequence. The cleaned title should not contain the byte.
  make_mock_bin c1_curl c1_fetch curl <<'MOCK'
#!/bin/sh
printf '{"items":[{"title":"safe\x9bHIJACK","url":"https://example.test/c1"}]}\n'
MOCK
  rm -f "$CACHE" "$CACHE.pending" "$CACHE.lock"
  NEWSLINE_FEEDS_DIR="$c1_dir" NEWSLINE_FEEDS_DISABLED="hn,reddit,lobsters" \
    PATH="$c1_curl:$PATH" bash "$STATUSLINE" </dev/null >/dev/null 2>&1
  wait_for_cache
  if grep -q $'\x9b' "$CACHE" 2>/dev/null; then
    fail "bare C1 byte (0x9B) stripped from cache" "byte survived through pipeline"
  else
    pass "bare C1 byte (0x9B) stripped from cache"
  fi
  # Surrounding bytes ('safe' + 'HIJACK') survive — the strip targets only
  # the malformed byte, not the legitimate text around it.
  assert_contains "$(cat "$CACHE")" "safe" "legitimate text before C1 byte preserved"
  assert_contains "$(cat "$CACHE")" "HIJACK" "legitimate text after C1 byte preserved"
  rm -rf "$c1_dir"
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

# Paths with literal apostrophes survive shellQuote (POSIX '\'' escape) and
# must round-trip through stripSuffix. Pre-fix, QUOTED_PATH disallowed any
# `'` inside the path, so a user with `~/jane's home/.claude/...` would see
# their suffix unrecognised — re-installs would double-append, uninstall
# would leave the suffix in place.
out=$(node -e "
  const m = require('$CLI');
  const p = \"/Users/jane's home/.claude/claude-newsline.sh\";
  const cmd = \"keep-me ; bash \" + m.shellQuote(p);
  console.log(m.stripSuffix(cmd));
")
assert_equals "$out" "keep-me" "stripSuffix handles path with apostrophe via shellQuote"

# Standalone (no preceding command) with apostrophe path — same regex, just
# without the leading chain.
out=$(node -e "
  const m = require('$CLI');
  const p = \"/Users/jane's home/.claude/claude-newsline.sh\";
  console.log('[' + m.stripSuffix(\"bash \" + m.shellQuote(p)) + ']');
")
assert_equals "$out" "[]" "stripSuffix blanks standalone apostrophe-path command"

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

# escapeRegex must escape every regex meta-char it claims to handle. The
# earlier inline form ([.*+?^${}()|[\\]\\\\]) had a misplaced ] that closed
# the class early, making escape a no-op for normal bases — `settings.json`
# was embedded with an unescaped `.`, so a look-alike file like
# `settingsXjson.bak.123` would be mis-identified as our backup and pruned.
out=$(node -e "
  const m = require('$CLI');
  console.log(m.escapeRegex('a.b*c+d?e^f\$g{h}i(j)k|l[m]n\\\\o'));
")
assert_equals "$out" 'a\.b\*c\+d\?e\^f\$g\{h\}i\(j\)k\|l\[m\]n\\o' "escapeRegex escapes the full meta-char set"

# Round-trip: listBackups must NOT match a similarly-named non-backup file.
# Set up a sandbox dir, drop our real backup AND a look-alike, and confirm
# only the real one comes back.
backup_dir=$(mktemp -d -t feedstatus-bak-XXXXXX)
touch "$backup_dir/settings.json"
touch "$backup_dir/settings.json.bak.100"        # real
touch "$backup_dir/settings.json.bak.200"        # real
touch "$backup_dir/settingsXjson.bak.300"        # look-alike with X in `.` slot
touch "$backup_dir/SETTINGS.JSON.bak.400"        # case-different, must not match
touch "$backup_dir/settings.json.bak.notnum"     # non-numeric ts, must not match
out=$(node -e "
  const m = require('$CLI');
  const baks = m.listBackups('$backup_dir/settings.json');
  console.log(baks.join(','));
")
assert_equals "$out" "settings.json.bak.100,settings.json.bak.200" \
  "listBackups returns only real backups, not look-alike filenames"
rm -rf "$backup_dir"

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

# Hand-edited NEWSLINE_COLOR_FEED that's a raw SGR sequence — must survive a
# wizard reconfigure. Pre-fix this returned 'amber' because the helper only
# checked NAMED_COLORS; raw SGR slipped through validation but failed the
# pre-fill, so a user with NEWSLINE_COLOR_FEED='38;5;208' lost their setting.
out=$(node -e "
  const m = require('$CLI');
  const r = m.wizardInitialValues(
    { NEWSLINE_COLOR_FEED: '38;5;208' },
    [10, 20], [' \u2022 '],
  );
  console.log(r.color);
")
assert_equals "$out" "38;5;208" "wizard preserves a raw-SGR NEWSLINE_COLOR_FEED hand-edit"

# Same class of bug for NEWSLINE_LABEL_SEP. The helper trusts the caller's
# separatorOptions list — runWizard injects the env value when it isn't in
# the curated four — so when the caller does inject, the helper round-trips.
# Regression: pass the env separator in the options and assert it survives.
out=$(node -e "
  const m = require('$CLI');
  const env = { NEWSLINE_LABEL_SEP: ' :: ' };
  // Mirror what runWizard does today: append envSep when not in defaults.
  const opts = [' \u2022 ', ' \u203a ', ' :: '];
  const r = m.wizardInitialValues(env, [20], opts);
  console.log(r.separator);
")
assert_equals "$out" " :: " "wizard preserves an injected hand-edited separator"

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
