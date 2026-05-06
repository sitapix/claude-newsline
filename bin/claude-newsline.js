#!/usr/bin/env node
// claude-newsline — appends a rotating headline to your Claude Code status line.
// https://github.com/sitapix/claude-newsline
//
// Install/uninstall driver. The hot path is statusline.sh (installed alongside
// this file into ~/.claude/). This installer is responsible for:
//   - copying statusline.sh + colors.sh into $CLAUDE_CONFIG_DIR
//   - editing settings.json to append "; bash '<path>/claude-newsline.sh'" to
//     the user's existing .statusLine.command (preserving anything they had)
//   - cleaning up on --uninstall, stripping only our suffix
//
// All writes to settings.json are atomic (tmp-file + rename) and preceded by
// a timestamped backup taken only after a successful parse.

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

// SGR-code-named colors, mirroring colors.sh's set_ansi(). Used by the
// --color flag and wizard preview. Empty strings mean "no SGR" (none/off).
const ANSI_BY_NAME = {
  none: '', off: '',
  black: '30', red: '31', green: '32', yellow: '33',
  blue: '34', magenta: '35', cyan: '36', white: '37',
  bright_black: '90', bright_red: '91', bright_green: '92', bright_yellow: '93',
  bright_blue: '94', bright_magenta: '95', bright_cyan: '96', bright_white: '97',
  bold: '1',
  bold_red: '1;31', bold_green: '1;32', bold_yellow: '1;33', bold_blue: '1;34',
  bold_magenta: '1;35', bold_cyan: '1;36', bold_white: '1;37',
  dim: '2',
  dim_red: '2;31', dim_green: '2;32', dim_yellow: '2;33', dim_blue: '2;34',
  dim_magenta: '2;35', dim_cyan: '2;36', dim_white: '2;37',
};

// Truecolor-anchored palette. Names describe the outcome, not the SGR code,
// so "amber" stays amber even on terminals that collapse 3X/9X codes. Each
// entry renders at the best depth the user's terminal supports, falling back
// to 256-color then to a raw 16-color SGR sequence.
//
// Derived from colors.sh's _palette cases so there's only one source of
// truth; a test round-trips the names to catch drift. c16 is the raw SGR
// string exactly as sh emits it ("1;33", "92") — renderPalette returns it
// verbatim, same as what set_ansi produces at depth 4.
//
// Parse line shape: `  name)    _palette _v R G B C256 "SGR" ;;`
function loadPalette() {
  const FALLBACK = {
    amber:    { rgb: [255, 193, 7],   c256: 214, c16: '1;33' },
    coral:    { rgb: [255, 127, 80],  c256: 209, c16: '1;31' },
    pink:     { rgb: [255, 105, 180], c256: 213, c16: '1;35' },
    mint:     { rgb: [0, 255, 135],   c256: 48,  c16: '92'   },
    sky:      { rgb: [135, 206, 235], c256: 117, c16: '96'   },
    lavender: { rgb: [177, 156, 217], c256: 183, c16: '95'   },
    lime:     { rgb: [198, 255, 0],   c256: 154, c16: '92'   },
  };
  try {
    const src = fs.readFileSync(path.join(__dirname, 'colors.sh'), 'utf8');
    const re = /^\s*(\w+)\)\s+_palette\s+_v\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"([^"]+)"/gm;
    const out = {};
    let m;
    while ((m = re.exec(src)) !== null) {
      out[m[1]] = {
        rgb: [Number(m[2]), Number(m[3]), Number(m[4])],
        c256: Number(m[5]),
        c16: m[6],
      };
    }
    return Object.keys(out).length ? out : FALLBACK;
  } catch (_) {
    return FALLBACK;
  }
}
const PALETTE = loadPalette();

// Terminal color depth. Mirrors colors.sh's detection byte-for-byte so the
// wizard preview and the installed hot path can't disagree on depth for the
// same env. Node's getColorDepth() was deliberately not used — it considers
// signals sh can't (Windows CI, IDE terminals) and would drift. Parity is
// enforced by the env-matrix test in test.sh; change both sides or neither.
// Depth: 0 = none, 4/8/24 = ANSI/256/truecolor.
function colorDepth() {
  if (process.env.NO_COLOR) return 0;
  const fc = process.env.FORCE_COLOR;
  if (fc === '0' || fc === 'false' || fc === 'no') return 0;
  if (fc === '3') return 24;
  if (fc === '2') return 8;
  if (fc === '1' || fc === 'true' || fc === 'yes') return 4;
  const ct = process.env.COLORTERM;
  if (ct === 'truecolor' || ct === '24bit') return 24;
  const term = process.env.TERM;
  if (term === 'dumb') return 0;
  if (!term) return 4;
  return 8;
}

// Render a palette entry → SGR parameter string at the given depth.
// spec.c16 is already a raw SGR sequence (same format sh emits), so we
// hand it back verbatim at the 16-color fallback depth.
function renderPalette(spec, depth) {
  if (depth <= 0) return '';
  if (depth >= 24) return `38;2;${spec.rgb.join(';')}`;
  if (depth >= 8)  return `38;5;${spec.c256}`;
  return spec.c16 || '';
}

function colorize(text, name, depth) {
  const d = depth ?? colorDepth();
  if (d <= 0) return text;
  // Match set_ansi's lookup order: palette, named SGR, then raw SGR
  // fallback (the `*)` case in colors.sh).
  let sgr;
  if (PALETTE[name]) sgr = renderPalette(PALETTE[name], d);
  else if (ANSI_BY_NAME[name] !== undefined) sgr = ANSI_BY_NAME[name];
  else if (name && RAW_SGR_REGEX.test(name)) sgr = name;
  if (!sgr) return text;
  return `\x1b[${sgr}m${text}\x1b[0m`;
}

// Validation list — derived from the maps so adding a color is a one-place
// change. Installer also accepts raw SGR sequences (below) so typos still
// fail loudly instead of silently emitting ESC[<garbage>m.
const NAMED_COLORS = [...Object.keys(PALETTE), ...Object.keys(ANSI_BY_NAME)];
// Raw ANSI SGR params: digits separated by semicolons, e.g. "38;5;208".
const RAW_SGR_REGEX = /^[0-9]+(?:;[0-9]+)*$/;

// Parse a value out of statusline.sh exactly once and cache the src text.
// Multiple readers (ALL_FEEDS, defaults, future extractors) should go
// through here so we read the file once per process, not once per knob.
let _statuslineSrc = null;
function readStatuslineSrc() {
  if (_statuslineSrc !== null) return _statuslineSrc;
  try {
    _statuslineSrc = fs.readFileSync(path.join(__dirname, 'statusline.sh'), 'utf8');
  } catch (_) {
    _statuslineSrc = '';
  }
  return _statuslineSrc;
}

// ALL_FEEDS is derived from statusline.sh's ALL_FEEDS='…' line so the JS
// side never drifts from the shell side (a test verifies the derivation
// round-trips). If the sh file isn't readable (odd install layout, tests
// loading the module from a weird CWD), fall back to a conservative default
// — real drift is still caught by the test-suite assertion.
function loadAllFeeds() {
  const m = readStatuslineSrc().match(/^ALL_FEEDS='([^']+)'/m);
  if (m) return m[1].split(/\s+/).filter(Boolean);
  return ['hn', 'reddit', 'lobsters'];
}
const ALL_FEEDS = loadAllFeeds();

// Extract a runtime default from statusline.sh's config block. Takes the
// external env-var name (what the user sets, e.g. `NEWSLINE_SCROLL`) — the
// internal shell variable that holds the resolved value (`SCROLL`) is not
// what we're looking up here. Accepts both `${VAR:-default}` and `${VAR-default}`
// (the latter is used for `NEWSLINE_PREFIX` so an explicit empty string
// survives without collapsing to the default glyph).
//
// Same drift-prevention pattern as ALL_FEEDS: the sh side is canonical (it's
// what users actually get at runtime) and JS defers to it. A test round-trips
// each default so a silent change in one side fails loudly.
function loadShDefault(externalName, fallback) {
  const re = new RegExp(`"\\$\\{${externalName}(?::-|-)([^}]*)\\}"`, 'm');
  const m = readStatuslineSrc().match(re);
  return m ? m[1] : fallback;
}

// POSIX function-name rule, shared by load_user_feeds (sh) and the Node side
// so filename validation stays in lockstep. A file the installer would accept
// that sh would reject is a user-visible drift.
const FEED_NAME_REGEX = /^[A-Za-z_][A-Za-z0-9_]*$/;

// Plugin-contract version. Mirrors `FEED_API_VERSION=<N>` in statusline.sh —
// a test asserts the two stay in lockstep. The sh side is canonical (it
// gates loading at runtime), the JS side mirrors so the installer doesn't
// surface plugins the runtime would then silently skip. Absent / non-
// numeric `api` in a plugin's FEED_META is treated as 1 (backward compat
// with plugins written before this gate existed).
function loadFeedApiVersion() {
  const m = readStatuslineSrc().match(/^FEED_API_VERSION=(\d+)/m);
  return m ? Number(m[1]) : 1;
}
const FEED_API_VERSION = loadFeedApiVersion();

// Parse `api=<N>` out of a parsed FEED_META object. Returns the integer
// api version, or 1 when absent/non-numeric (implicit v1). Kept separate
// from parseFeedMeta so callers that don't care about gating don't pay
// the parse cost, and so the "absent means 1" convention has one home.
function pluginApiVersion(meta) {
  const raw = meta && meta.api;
  if (typeof raw !== 'string' || raw === '') return 1;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : 1;
}

// Statically detect whether a plugin file declares `feed_<name>()`. We don't
// source the file: that would execute arbitrary plugin code at install /
// `--list-feeds` / wizard-render time, and a misbehaving plugin (infinite
// loop, network call, fork bomb) could hang the installer. The runtime is
// the authoritative gate — it sources lazily on the first refresh, captures
// stderr, and reports failures via NEWSLINE_DEBUG=1. The installer's job
// here is the cheaper "does the file LOOK like a plugin?" check.
//
// Matches the canonical POSIX function declaration with optional leading
// whitespace and an optional `function` keyword. A trailing brace on the
// SAME LINE is required (POSIX function definitions allow brace on next
// line, and most shells accept it; we rely on the dominant inline-brace
// shape and let the runtime catch the rare exotic format). False negatives
// here cost a "feed not loaded — file present" surface in --list-feeds;
// false positives cost the same plus a runtime error that the user sees in
// NEWSLINE_DEBUG=1. Both are recoverable.
function detectFeedFunction(src, name) {
  // The brace may sit on the same line OR on the next line (POSIX accepts
  // both; bash accepts both). Allowing `[ \\t\\r\\n]*\\{` covers the
  // next-line-brace style without changing behavior for the inline shape.
  const re = new RegExp(
    `(?:^|\\n)[ \\t]*(?:function[ \\t]+)?feed_${name}[ \\t]*\\([ \\t]*\\)[ \\t\\r\\n]*\\{`,
    'm'
  );
  return re.test(src);
}

// Scan EVERY *.sh in the user-feeds directory that passes the filename
// rule — loadable AND incompatible alike — tagged with a compat status.
// Returns `[{name, path, meta, compat}]` sorted by name, where `compat` is
// `{ok:true}` for loadable plugins or `{ok:false, reason, ...}` for ones
// the runtime would skip. Incompatible plugins are INCLUDED so --list-feeds
// can render an "Incompatible" section — a silent-skip would leave users
// with no signal about why their dropped-in plugin isn't running. Most
// callers want only loadable plugins; use `scanUserFeeds` (filter wrapper)
// for that.
//
// Skip paths mirror sh-side load_user_feeds:
//   1. Filename fails the POSIX rule — we skip entirely here (not surfaced)
//      because sh would silently reject too and the file isn't a plugin
//      the author intended us to run. Different class of problem from
//      "api too new."
//   2. Unreadable file — skipped entirely for the same reason (author bug,
//      not a compat signal).
//   3. Missing feed_<name>() definition — INCLUDED, tagged incompatible.
//      Static detection catches the dominant shape; weird formats slip
//      through to the runtime gate, which still skips them safely.
//   4. `api=` declaration > FEED_API_VERSION — INCLUDED, tagged
//      `{ok:false, reason:'api', declaredApi, runtimeApi}` so callers can
//      render the "drop-in-but-wont-load" state.
function scanAllUserFeeds(userFeedsDir) {
  let entries;
  try {
    entries = fs.readdirSync(userFeedsDir);
  } catch (e) {
    if (e.code === 'ENOENT' || e.code === 'ENOTDIR') return [];
    throw e;
  }
  const out = [];
  for (const entry of entries) {
    if (!entry.endsWith('.sh')) continue;
    const name = entry.slice(0, -3);
    if (!FEED_NAME_REGEX.test(name)) continue;
    const p = path.join(userFeedsDir, entry);
    let src;
    try { src = fs.readFileSync(p, 'utf8'); }
    catch (e) {
      // Unreadable file (perms, dangling symlink, etc.). The runtime would
      // also fail to source it and surface the error via NEWSLINE_DEBUG=1
      // — mirror that visibility here so --list-feeds doesn't silently
      // hide a file the user dropped in.
      out.push({
        name, path: p, meta: {},
        compat: { ok: false, reason: `unreadable (${e.code || e.message})` },
      });
      continue;
    }
    const meta = parseFeedMeta(src, name);
    if (!detectFeedFunction(src, name)) {
      out.push({
        name, path: p, meta,
        compat: { ok: false, reason: `feed_${name}() not defined in file` },
      });
      continue;
    }
    const declaredApi = pluginApiVersion(meta);
    const compat = declaredApi > FEED_API_VERSION
      ? { ok: false, reason: 'api', declaredApi, runtimeApi: FEED_API_VERSION }
      : { ok: true };
    out.push({ name, path: p, meta, compat });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

// Loadable plugins only — the filter wrapper existing callers (wizard
// multiselect, built-in-override detection, --new-feed collision check)
// expect. Keeping the two functions distinct means "scan" everywhere
// implicitly means "only things we can actually run" except in the one
// place that explicitly needs to see rejects.
function scanUserFeeds(userFeedsDir) {
  return scanAllUserFeeds(userFeedsDir).filter(f => f.compat.ok);
}

// Parse a FEED_META_<name>='k=v\nk=v' block out of a plugin file into a flat
// object. Matches the line-oriented parser in statusline.sh's debug branch
// so the metadata shown by --list-feeds -v can't drift from what
// NEWSLINE_DEBUG=1 reports. Unknown keys are preserved; the first `=` is the
// separator (values can contain `=`). Only the `description`/`version`/
// `author`/`homepage` keys have rendering hooks elsewhere — the rest are
// just surfaced verbatim.
function parseFeedMeta(src, feedName) {
  // Accept single OR double quotes — POSIX sh accepts both, the runtime
  // sources either form just fine, so the static parser must too. A plugin
  // written with `FEED_META_x="api=99\n…"` would otherwise look like
  // "no metadata declared" to the installer (implicit api=1, listed as
  // loadable) while the runtime reads the real `api=99` and silently
  // skips. The two alternations are mutually exclusive (different quote
  // chars) so capture group order doesn't matter.
  const re = new RegExp(
    `^FEED_META_${feedName}\\s*=\\s*(?:'([^']*)'|"([^"]*)")`,
    'm'
  );
  const m = src.match(re);
  if (!m) return {};
  const body = m[1] !== undefined ? m[1] : m[2];
  const out = {};
  for (const line of body.split('\n')) {
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const k = line.slice(0, eq);
    const v = line.slice(eq + 1);
    if (k) out[k] = v;
  }
  return out;
}

// Template stamped by --new-feed. Keeping this adjacent to USER_FEEDS_README
// so the template and the doc stay in visual lockstep — a user who reads the
// README will recognize the scaffolded file exactly. The leading `# <name>.sh`
// header mirrors the README's minimal-feed example.
function newFeedTemplate(name) {
  return `# ${name}.sh — a claude-newsline feed plugin.
# https://github.com/sitapix/claude-newsline#custom-feeds
#
# The function name MUST be feed_${name} to match this file's name.
# It sets three globals the dispatch loop reads back: LABEL, URL, JQ.
#
# Optional metadata block — shown by \`claude-newsline --list-feeds -v\`
# and \`NEWSLINE_DEBUG=1\`. \`source=\` is auto-attached at load time.
#   api       — plugin-contract version (current: ${FEED_API_VERSION}). Absent = 1.
#               The runtime skips plugins declaring api > the version it
#               supports, so keep this set to the version you tested on.
#   category  — free-form label used to group feeds in --list-feeds -v.
FEED_META_${name}='description=TODO: one-line description
api=${FEED_API_VERSION}
category=Custom
version=0.1.0
author=TODO'

feed_${name}() {
  LABEL='TODO'
  URL='https://example.com/feed.json'
  # jq emits three tab-separated fields: <label>\\t<title>\\t<url>.
  # $default is LABEL above — use it, or promote a title-based label.
  # URL must be http(s); other schemes render but drop the OSC 8 link.
  # shellcheck disable=SC2016
  JQ='.items[] | [$default, .title, .url] | @tsv'
}

# Uncomment for a parameterized feed — feed_${name} is called once per
# comma-separated entry in $NEWSLINE_${name.toUpperCase()}_SRCS, with the entry
# as $1. Remember to re-validate $1 inside the function (defense against a
# hand-edited .env injecting into URLs), and return 1 to skip a bad entry.
#
# ${name.toUpperCase()}_SRCS="\${NEWSLINE_${name.toUpperCase()}_SRCS:-default-entry}"
# FEED_PARAMS_${name}='${name.toUpperCase()}_SRCS'

# Test:   claude-newsline --test-feed ${name}
# Offline: claude-newsline --test-feed ${name} --fixture sample.json
`;
}

// Matches our appended/standalone segment. We deliberately require:
//   - the path to be absolute (leading / or '/)
//   - the preceding separator to be exactly `;` — that's the only form we
//     ever write, so it's the only form we strip. If a user hand-edited
//     their command to use `&&`, `&`, `||`, or a pipe, that's their
//     config; we leave it alone rather than guessing what they meant.
//   - the basename to be exactly /claude-newsline.sh (so a user-owned file
//     named my-claude-newsline.sh is not mis-matched)
//   - no shell metacharacters inside the path
//
// Two forms are recognized — we only write the quoted form today, but the
// unquoted form gets stripped too so a hand-copied example from the README
// or a user tweak still cleans up on uninstall:
//   unquoted: bash /abs/path/claude-newsline.sh
//   quoted:   bash '/abs/path/claude-newsline.sh'  (spaces-safe)
//
// One regex with a leading alternation: either our segment sits at the
// start of the string (standalone) or it's preceded by a `;` separator
// (chained suffix). The QUOTED_PATH alternation also recognises the POSIX
// `'\''` escape sequence shellQuote emits when $HOME contains a literal
// apostrophe — without that, an `~/jane's home/...` install would leak its
// suffix on uninstall and double-append on re-install.
//
// Ownership marker: `CLAUDE_NEWSLINE=<ver> bash '<path>'`. Per-command env
// prefix (scoped to the bash invocation, not exported) so it's a pure tag.
// MARKER_PREFIX is optional in the regex so pre-marker installs still strip
// cleanly on upgrade. Bump MARKER_VALUE to let a future installer recognize
// its own previous shape.
const MARKER_VAR = 'CLAUDE_NEWSLINE';
const MARKER_VALUE = 'v1';
const MARKER_PREFIX = `(?:${MARKER_VAR}=[A-Za-z0-9._-]+\\s+)?`;
// Body: any non-quote/non-newline char, OR the four-char POSIX escape '\''.
const QUOTED_PATH = "'(?:[^'\\n]|'\\\\'')*/claude-newsline\\.sh'";
const UNQUOTED_PATH = "/[^\\s;&|'\"`$]*/claude-newsline\\.sh";
const CMD_TAIL = `${MARKER_PREFIX}bash\\s+(?:${QUOTED_PATH}|${UNQUOTED_PATH})`;
// End-of-chain (our canonical install shape: `… ; bash '<path>'`). Also
// handles the "bare standalone" case via the `^\s*` alternation.
const SUFFIX_REGEX = new RegExp(`(?:^\\s*|\\s*;\\s*)${CMD_TAIL}\\s*$`);
// Mid-chain: user appended another `; cmd` after our suffix before re-
// running install. Consume the leading `;` + whitespace; the trailing `;`
// stays behind the lookahead and re-joins the halves cleanly.
const MIDCHAIN_SUFFIX_REGEX = new RegExp(`\\s*;\\s*${CMD_TAIL}(?=\\s*;)`, 'g');
// Start-of-chain: our suffix leads the command, followed by the user's
// commands. Consume our segment AND the trailing `;`.
const STARTCHAIN_SUFFIX_REGEX = new RegExp(`^\\s*${CMD_TAIL}\\s*;\\s*`);

// Env keys claude-newsline writes. buildEnvUpdates() is the single place
// that materializes these from opts — if you add a new knob, add it to this
// list AND to buildEnvUpdates in the same commit.
const OWNED_ENV_KEYS = [
  'NEWSLINE_FEEDS_DISABLED', 'NEWSLINE_COLOR_FEED', 'NEWSLINE_SHOW_LABELS',
  'NEWSLINE_LABEL_SEP', 'NEWSLINE_REDDIT_SUBS', 'NEWSLINE_ROTATION_SEC',
  'NEWSLINE_SCROLL', 'NEWSLINE_SCROLL_SEC',
];

// Default rotation derived from statusline.sh — buildEnvUpdates elides
// ROTATION_SEC from .env when the user picks the same value the runtime
// would default to anyway (same pattern as REDDIT_SUBS).
const DEFAULT_ROTATION_SEC = Number(loadShDefault('NEWSLINE_ROTATION_SEC', '20'));
// Upper bound is arbitrary but bounded — a rotation > 1 hour is almost
// certainly a typo (10000 vs 10), and validateRotation should catch it early
// rather than silently writing nonsense into .env.
const MAX_ROTATION_SEC = 3600;

// Motion presets — a user-facing abstraction over SCROLL + SCROLL_SEC. We
// expose three named options because raw knob pairs ("SCROLL=0" / "SCROLL=1
// with SCROLL_SEC=3") are fiddly to reason about and invite invalid combos
// (SCROLL=0 with SCROLL_SEC=5 is meaningless). buildEnvUpdates is the single
// place that translates motion → env, so adding a preset is one entry here
// plus one branch there.
//
// DEFAULT_SCROLL_SEC is loaded from sh so the "smooth" preset truly matches
// runtime defaults (no .env writes) — keeping this in sync with statusline.sh
// is the same drift-prevention pattern as DEFAULT_ROTATION_SEC.
const DEFAULT_SCROLL_SEC = Number(loadShDefault('NEWSLINE_SCROLL_SEC', '5'));
const QUICK_SCROLL_SEC = 3;
// Naming honesty: Claude Code's minimum refreshInterval is 1s = 1 FPS, so
// the scroll is always a stepped slide — N discrete frames, not a smooth
// glide. We deliberately don't call any preset "smooth" because there's no
// knob in Claude Code that would make it so.
const MOTION_OPTIONS = ['static', 'slide', 'quick'];

// A REDDIT_SUBS entry is one of:
//   - a single subreddit:    "programming"        → /r/programming/top.json
//   - an anonymous multi:    "rust+golang+linux"  → /r/rust+golang+linux/top.json
//   - a user-owned multi:    "mawburn/techsubs"   → /user/mawburn/m/techsubs/top.json
// Keep the tiers in sync with the dispatch in statusline.sh's refresh_all_feeds —
// both sides must agree or an entry that passes installer validation will be
// silently skipped at refresh time.
const SUBREDDIT_REGEX = /^[A-Za-z0-9_]+(?:\+[A-Za-z0-9_]+)*$/;
const USER_MULTI_REGEX = /^[A-Za-z0-9_-]+\/[A-Za-z0-9_]+$/;
// Users copy-pasting from the URL bar often paste shapes like "r/programming",
// "/r/programming", "m/rust+golang", or "/m/rust+golang" — all of which would
// otherwise collide with the named-multi syntax (<user>/<multi>) if taken
// literally. Reddit serves anonymous combined feeds under both /r/a+b/ and
// /m/a+b/, so they're functionally interchangeable at the listing layer;
// we normalize both prefixes to the bare form. The r/ or m/ strip is gated
// on "no further slash" — "m/user/multi" stays ambiguous and falls through
// to normal validation, which rejects it (we don't infer user-owned multis
// from a stray "m/" prefix).
function normalizeRedditEntry(entry) {
  // Lookahead (?=[rm]\/) prevents "/bar" from being silently accepted as
  // "bar" — only "/r/foo" and "/m/foo" are real copy-paste shapes.
  let e = entry.replace(/^\/(?=[rm]\/)/, '');
  if (/^[rm]\//.test(e) && !e.slice(2).includes('/')) {
    e = e.slice(2);
  }
  return e;
}
function isValidRedditEntry(entry) {
  const e = normalizeRedditEntry(entry);
  return SUBREDDIT_REGEX.test(e) || USER_MULTI_REGEX.test(e);
}
const DEFAULT_REDDIT_SUB = loadShDefault('NEWSLINE_REDDIT_SUBS', 'programming');
// Runtime defaults for the two cosmetic knobs. Pulled from statusline.sh so
// the elision rule ("user picks the runtime default → drop the override") works
// for color and separator the same way it does for rotation and reddit-subs.
// A future statusline.sh default change updates the elision threshold without
// any JS edits — same drift-prevention pattern as DEFAULT_ROTATION_SEC.
const DEFAULT_COLOR_FEED = loadShDefault('NEWSLINE_COLOR_FEED', 'dim_yellow');
const DEFAULT_LABEL_SEP  = loadShDefault('NEWSLINE_LABEL_SEP', ' \u2022 ');
// Cap keeps a configured-too-enthusiastically user from issuing N sequential
// curls on every REFRESH_SEC tick; also bounds worst-case refresh time
// against the 120s stale-lock reaper so refreshes can't race themselves.
const MAX_REDDIT_SUBS = 15;
function parseCsv(csv) {
  return String(csv || '').split(',').map(s => s.trim()).filter(Boolean);
}
function validateRedditSubs(csv) {
  if (!csv) return;
  const subs = parseCsv(csv);
  if (subs.length > MAX_REDDIT_SUBS) {
    throw new Error(
      `Too many subreddits (${subs.length} > ${MAX_REDDIT_SUBS}).\n` +
      `Each sub adds one HTTP request per refresh — pick your favorites.`
    );
  }
  for (const sub of subs) {
    if (!isValidRedditEntry(sub)) {
      throw new Error(
        `Invalid subreddit entry: "${sub}"\n` +
        `Accepted forms:\n` +
        `  - single sub:      "programming"\n` +
        `  - combined feed:   "rust+golang+linux"\n` +
        `  - user multi:      "mawburn/techsubs"`
      );
    }
  }
}
function normalizeRedditSubs(csv) {
  return parseCsv(csv).map(normalizeRedditEntry).join(',');
}

// Drop interior whitespace and re-emit the canonical comma-tight form.
// is_disabled() in statusline.sh historically did a literal ",$x," substring
// match against the haystack, so a user-friendly "reddit, lobsters" left a
// leading space on the second entry and silently failed to disable it.
// Both the installer (here) and the runtime (now) trim per-entry; this
// keeps the on-disk shape canonical so a hand-written `.env` that sneaks
// past the installer still works at runtime via the sh-side normalizer.
function normalizeFeedsDisabled(csv) {
  return parseCsv(csv).join(',');
}

function configDir() {
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

// POSIX single-quote so shell metacharacters (space, $, `, ;) are inert.
// Embedded ' becomes '\'' (close-quote, literal-quote, reopen-quote).
function shellQuote(s) {
  return "'" + String(s).replace(/'/g, `'\\''`) + "'";
}

// Sibling tmp path for atomic write-then-rename. `pid + epoch-ms` avoids
// collisions between concurrent installs and between the two tmp files a
// single install stages. Used by writeSettings and applyPlan; keep the
// naming convention here so any future cleanup glob has one shape to match.
function tmpSibling(p) {
  return `${p}.tmp.${process.pid}.${Date.now()}`;
}

// Table-driven flag parser. VALUE_FLAGS carry a value (--flag val or
// --flag=val); SWITCHES are zero-arg booleans. Any parse failure (unknown
// flag, missing value, value that looks like a flag) sets opts.error —
// main() prints it and exits 2. A typo like --colur fails CI loudly rather
// than falling through to the help text.
function parseArgs(argv) {
  // null means "flag not passed"; '' means "flag passed with an empty value"
  // (user intent: clear the owned .env key back to runtime default). Keeping
  // the two distinct lets buildEnvUpdates emit an `undefined` delete sentinel
  // only on explicit clears, without dragging in a separate "passed flags" set.
  const opts = {
    disable: null,
    only: null,
    color: null,
    separator: null,
    showLabels: null,
    redditSubs: null,
    rotation: null,
    motion: null,
    testFeed: null,
    fixture: null,
    newFeed: null,
    uninstall: false,
    yes: false,
    listFeeds: false,
    listFeedsVerbose: false,
    help: false,
    error: null,
  };

  const VALUE_FLAGS = {
    '--disable':     'disable',
    '--only':        'only',
    '--color':       'color',
    '--separator':   'separator',
    '--reddit-subs': 'redditSubs',
    '--rotation':    'rotation',
    '--motion':      'motion',
    '--test-feed':   'testFeed',
    '--fixture':     'fixture',
    '--new-feed':    'newFeed',
  };
  const SWITCHES = {
    '--no-labels':       o => { o.showLabels = false; },
    '--labels':          o => { o.showLabels = true; },
    '--uninstall':       o => { o.uninstall = true; },
    '--yes':             o => { o.yes = true; },
    '-y':                o => { o.yes = true; },
    '--non-interactive': o => { o.yes = true; },
    '--list-feeds':      o => { o.listFeeds = true; },
    // -v pairs with --list-feeds to print metadata (description/author/homepage)
    // — a minimal subset of what --debug would show. Orthogonal to --help/-h so
    // bare `-v` on its own is a no-op (there's no "verbose install").
    '-v':                o => { o.listFeedsVerbose = true; },
    '--verbose':         o => { o.listFeedsVerbose = true; },
    '--help':            o => { o.help = true; },
    '-h':                o => { o.help = true; },
  };

  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (SWITCHES[a]) { SWITCHES[a](opts); continue; }

    let matched = false;
    for (const [flag, key] of Object.entries(VALUE_FLAGS)) {
      let v;
      if (a === flag) {
        v = args[++i];
      } else if (a.startsWith(flag + '=')) {
        v = a.slice(flag.length + 1);
      } else {
        continue;
      }
      // `--color` with no arg or `--color --yes` would otherwise swallow the
      // next flag or silently no-op. Reject both. An explicit empty value
      // (`--color ""` or `--color=""`) is allowed — it's the "clear this env
      // key back to the runtime default" shape, handled by buildEnvUpdates.
      if (v === undefined) {
        opts.error = `${flag} requires a value (got nothing)`;
      } else if (v.startsWith('--')) {
        opts.error = `${flag} requires a value (got ${JSON.stringify(v)})`;
      } else {
        opts[key] = v;
      }
      matched = true; break;
    }
    if (matched) continue;

    opts.error = `Unknown argument: ${a}`;
    break;
  }
  return opts;
}

// Any of these flags means the user is driving config explicitly and doesn't
// want the interactive wizard, even on a TTY. `!== null` (rather than falsy)
// is deliberate: passing `--disable ""` to clear a prior FEEDS_DISABLED is an
// explicit config action — it must skip the wizard, same as `--disable rust`.
function hasExplicitConfig(opts) {
  return !!(opts.disable !== null || opts.only !== null || opts.color !== null ||
            opts.separator !== null || opts.showLabels !== null ||
            opts.redditSubs !== null || opts.rotation !== null ||
            opts.motion !== null);
}

function usage() {
  console.log(`claude-newsline — appends a rotating headline to your Claude Code status line

Usage:
  npx @sitapix/claude-newsline [options]

Options:
  --disable <csv>    Comma-separated feeds to skip (${ALL_FEEDS.join(', ')})
  --only <csv>       Enable only these feeds; disable everything else
  --color <name>     Headline accent color (default: amber)
                     Palette (depth-adaptive): ${Object.keys(PALETTE).join(', ')}
                     Or a named SGR (red, bold_green, dim_cyan), a raw SGR
                     sequence (38;5;208), or "none" to disable color.
  --separator <str>  Separator between label and title (default: " • ")
                     e.g. " | ", " › ", " · "
  --rotation <sec>   Seconds per headline before advancing (default: ${DEFAULT_ROTATION_SEC}, max ${MAX_ROTATION_SEC})
  --motion <preset>  Transition between headlines (default: slide)
                       static   no animation — each rotation just switches
                       slide    ${DEFAULT_SCROLL_SEC}-frame stepped slide (runtime default)
                       quick    ${QUICK_SCROLL_SEC}-frame stepped slide — snappier
                     Claude Code refreshes at 1 FPS, so all transitions are
                     stepped (N discrete frames), not truly smooth.
  --no-labels        Hide the source label prefix ("HN • …" → just the title)
  --labels           Force-on the source label (default; useful to override .env)
  --reddit-subs <csv> Comma-separated reddit entries (default: programming).
                     Each entry is one of:
                       "programming"         single subreddit  → r/programming
                       "rust+golang+linux"   combined feed     → r/rust+golang+linux
                       "mawburn/techsubs"    user-owned multi  → /user/mawburn/m/techsubs
                     Capped at ${MAX_REDDIT_SUBS}; each entry is one HTTP request per refresh.
                     Reddit rate-limits anonymous JSON requests. A 429 skips
                     that tick and the last good headline keeps showing.
  --test-feed <name> Run one fetch cycle for a single feed and print
                     diagnostics (URL, HTTP code, jq row count, sample
                     rows, URL-scheme warning). Works on built-ins and
                     user feeds in ~/.claude/claude-newsline/feeds/.
                     For parameterized feeds (e.g. reddit), iterates each
                     CSV entry. Exits 0 on success, non-zero on failure.
  --fixture <path>   Use with --test-feed to skip the network and pipe
                     a saved JSON file into your jq filter instead. Lets
                     you iterate on a feed's jq offline.
  --new-feed <name>  Scaffold a starter feed_<name> plugin in your user
                     feeds directory (~/.claude/claude-newsline/feeds/)
                     and exit. Refuses to overwrite an existing file.
  --uninstall        Remove claude-newsline from settings.json
  --yes, -y          Skip confirmation prompt (required on non-TTY stdin)
  --list-feeds       List available feeds (built-in + user) and exit
                     Pair with -v / --verbose for per-feed metadata.
  --help, -h         Show this help

Running with no flags on an interactive terminal opens a setup wizard.
Any explicit config flag (--disable/--only/--color/--separator/--rotation/--motion/--no-labels)
or --yes skips the wizard and takes the quiet flag-driven path.
`);
}

function readSettings(p) {
  if (!fs.existsSync(p)) return {};
  const raw = fs.readFileSync(p, 'utf8');
  // A zero- or whitespace-byte settings.json almost always means a prior
  // writer was killed mid-flush. Treating it as {} and re-writing would
  // silently wipe whatever state was there. Force the user to make a
  // deliberate call instead — `rm settings.json` re-enters fresh-install.
  if (!raw.trim()) {
    throw new Error(
      `${p} is empty — possibly truncated from an interrupted write.\n` +
      `If a fresh config is intended, remove the file first:\n` +
      `  rm '${p}'`
    );
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`Failed to parse ${p}: ${e.message}`);
  }
}

// Write atomically: serialize to a sibling tempfile, then rename over the
// destination. A crash mid-write never leaves settings.json truncated.
//
// If the destination is a symlink (common dotfiles pattern — users symlink
// ~/.claude/settings.json to a git-tracked repo), resolve the realpath and
// write there so `rename()` doesn't replace the link with a regular file.
// The tmp file lives next to the real target so rename stays atomic on the
// same filesystem.
//
// Permissions: settings.json's `env` block frequently holds API keys and
// other secrets. A naive writeFileSync inherits the umask (typically 0o644),
// which would silently widen a security-conscious user's `chmod 600`. Stat
// the existing file (or symlink target) first and reapply its mode to the
// tmp before rename. First install (no prior file) defaults to 0o600 — same
// reasoning, applied to the conservative case.
const NEW_SETTINGS_MODE = 0o600;
function writeSettings(p, obj) {
  let target = p;
  let preservedMode = null;
  try {
    if (fs.lstatSync(p).isSymbolicLink()) {
      try {
        target = fs.realpathSync(p);
      } catch (e) {
        // Broken symlink: lstat reports a link but the target is missing.
        // Replacing the link with a regular file would silently destroy
        // the dotfiles intent. Surface a clear error so the user can fix
        // the link before re-running install.
        if (e.code === 'ENOENT') {
          throw new Error(
            `${p} is a symlink to a missing target.\n` +
            `Fix the link before re-running install.`
          );
        }
        throw e;
      }
    }
    // Stat AFTER symlink resolution so we read the real file's mode, not
    // the link's (which on most platforms is meaningless / fixed).
    try {
      preservedMode = fs.statSync(target).mode & 0o777;
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
  const tmp = tmpSibling(target);
  const data = JSON.stringify(obj, null, 2) + '\n';
  // Mode passed to writeFileSync only takes effect on file creation, so
  // write to tmp WITH the chosen mode and let rename carry it over. An
  // umask narrower than the chosen mode (rare but possible — e.g. 0o077)
  // would still cap us; chmod after open closes that gap deterministically.
  const mode = preservedMode != null ? preservedMode : NEW_SETTINGS_MODE;
  try {
    fs.writeFileSync(tmp, data, { mode });
    try { fs.chmodSync(tmp, mode); } catch (_) { /* best-effort across umask */ }
    fs.renameSync(tmp, target);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
    throw e;
  }
}

// Keep at most this many .bak.* files per settings path. Dedup (below)
// already prevents byte-identical redundant backups, but a user who edits
// settings.json over years of installs could still accumulate an unbounded
// series of legitimately-distinct backups. Pruning the tail keeps the
// directory sane while preserving enough history to recover from a few
// generations of mistakes. Bumpable; 10 is arbitrary but roomy.
const MAX_BACKUPS = 10;

// List all existing .bak.* files for a settings path, sorted oldest-first by
// (timestamp, collision counter). Lex sort would put `.bak.<ts>.10` before
// `.bak.<ts>.2` because '1' < '2' — and our retry loop creates up to .999
// collision counters, so a high-collision second would prune the wrong file
// at MAX_BACKUPS time. Pulling the numbers out and sorting numerically keeps
// chronological order honest.
// Escape every regex meta-character. The earlier inline form was buggy:
// `[.*+?^${}()|[\\]\\\\]` looked like a 14-char class but the `]` after `\\`
// closed the class early, so `.replace(...)` was a no-op for normal bases.
// Result: `settings.json` got embedded with an unescaped `.`, allowing
// look-alike filenames (`settingsXjson.bak.123`) to be matched and pruned.
// Spelled out via a named constant so a reader can verify the set without
// re-counting brackets.
const REGEX_META_RE = /[.*+?^${}()|[\]\\]/g;
function escapeRegex(s) { return String(s).replace(REGEX_META_RE, '\\$&'); }

function listBackups(settingsPath) {
  const dir = path.dirname(settingsPath);
  const base = path.basename(settingsPath);
  // Match `<base>.bak.<ts>` or `<base>.bak.<ts>.<n>`. Files that don't fit
  // the shape (some other tool's `.bak.<word>`) are skipped — we only own
  // and prune our own naming scheme.
  const re = new RegExp(
    `^${escapeRegex(base)}\\.bak\\.(\\d+)(?:\\.(\\d+))?$`
  );
  try {
    return fs.readdirSync(dir)
      .map(f => {
        const m = f.match(re);
        if (!m) return null;
        return { name: f, ts: Number(m[1]), seq: Number(m[2] || 0) };
      })
      .filter(Boolean)
      .sort((a, b) => a.ts - b.ts || a.seq - b.seq)
      .map(x => x.name);
  } catch (_) {
    return [];
  }
}

// Copy settings.json to a timestamped .bak. COPYFILE_EXCL closes the TOCTOU
// window between the existence check and the copy; bounded retry so a second
// install within the same second doesn't clobber the first backup.
function backup(settingsPath) {
  if (!fs.existsSync(settingsPath)) return null;

  // Skip the copy when the most recent .bak.* is byte-identical to the
  // current settings.json. Repeated no-op install/uninstall cycles would
  // otherwise pile up redundant backups.
  //
  // NB: when settingsPath is a symlink, `path.dirname` resolves the visible
  // path's directory, not the realpath's. That's intentional — .bak files
  // sit next to the path the user sees, and `fs.copyFileSync` follows the
  // link for content. The side effect is that two symlinks in different
  // directories pointing at the same real file each grow their own .bak
  // series; that's acceptable (each "view" has its own history).
  const dir = path.dirname(settingsPath);
  try {
    const baks = listBackups(settingsPath);
    if (baks.length > 0) {
      const mostRecent = path.join(dir, baks[baks.length - 1]);
      const current = fs.readFileSync(settingsPath);
      const prior = fs.readFileSync(mostRecent);
      if (current.equals(prior)) return mostRecent;
    }
  } catch (_) { /* fall through to fresh backup */ }

  const ts = Math.floor(Date.now() / 1000);
  let bak = `${settingsPath}.bak.${ts}`;
  let i = 1;
  let created = null;
  for (let attempts = 0; attempts < 1000; attempts++) {
    try {
      fs.copyFileSync(settingsPath, bak, fs.constants.COPYFILE_EXCL);
      created = bak;
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      bak = `${settingsPath}.bak.${ts}.${i++}`;
    }
  }
  if (!created) {
    throw new Error(`Unable to create backup for ${settingsPath}: too many collisions`);
  }

  // Prune older backups beyond MAX_BACKUPS (counting the one we just made).
  // Unlink failures are non-fatal — the backup just took succeeded; stale
  // .bak files sticking around is cosmetic, not a correctness issue.
  // listBackups already swallows readdir errors and returns []; slice and
  // arithmetic don't throw; unlink is guarded per-file.
  const baks = listBackups(settingsPath);
  if (baks.length > MAX_BACKUPS) {
    for (const name of baks.slice(0, baks.length - MAX_BACKUPS)) {
      try { fs.unlinkSync(path.join(dir, name)); } catch (_) { /* ignore */ }
    }
  }

  return created;
}

function stripSuffix(cmd) {
  if (!cmd) return '';
  // Apply in order: mid-chain (global) first, then start-chain, then end-
  // chain. Each pass is a no-op if its anchor doesn't match, so unrelated
  // commands survive. `||`/`&&`/`&`/pipe separators block every regex
  // (CMD_TAIL only follows `;` or ^), so hand-edited alternate-separator
  // chains are left alone — consistent with the original contract.
  let r = cmd;
  r = r.replace(MIDCHAIN_SUFFIX_REGEX, '');
  r = r.replace(STARTCHAIN_SUFFIX_REGEX, '');
  r = r.replace(SUFFIX_REGEX, '');
  return r.trim();
}

function validateFeeds(csv) {
  if (!csv) return;
  for (const name of parseCsv(csv)) {
    if (!ALL_FEEDS.includes(name)) {
      throw new Error(`Unknown feed: ${name}\nAvailable: ${ALL_FEEDS.join(', ')}`);
    }
  }
}

function invertOnly(only) {
  const keep = new Set(parseCsv(only));
  return ALL_FEEDS.filter(f => !keep.has(f)).join(',');
}

// Returns the normalized rotation value (number), or null if unset. Callers
// should write the result back to opts so downstream consumers don't each
// re-parse (CLI gives strings, wizard gives numbers; this is the one coercion).
function validateRotation(v) {
  if (v === null || v === undefined || v === '') return null;
  // Reject anything that isn't a clean positive integer. Floats, negatives,
  // and alpha garbage all land here; statusline.sh's guard_num would fall
  // back silently, but at install time we'd rather fail loud.
  if (!/^\d+$/.test(String(v))) {
    throw new Error(`--rotation must be a positive integer (seconds), got: ${v}`);
  }
  const n = Number(v);
  if (n < 1 || n > MAX_ROTATION_SEC) {
    throw new Error(`--rotation out of range (1..${MAX_ROTATION_SEC}), got: ${v}`);
  }
  return n;
}

// Normalize a motion flag value. '' is the explicit-clear sentinel; treat it
// like "smooth" at validate time (both clear the owned keys to runtime
// defaults) so --motion "" behaves consistently with the other `FLAG ""`
// shapes. null means "flag not passed".
function validateMotion(v) {
  if (v === null || v === undefined) return null;
  if (v === '') return '';
  if (!MOTION_OPTIONS.includes(v)) {
    throw new Error(`--motion must be one of: ${MOTION_OPTIONS.join(', ')} (got ${v})`);
  }
  return v;
}

function validateColor(c) {
  if (!c) return;
  if (NAMED_COLORS.includes(c)) return;
  if (RAW_SGR_REGEX.test(c)) return;
  throw new Error(
    `Unknown color: ${c}\n` +
    `Named colors: ${NAMED_COLORS.join(', ')}\n` +
    `Or raw ANSI SGR params (digits separated by semicolons), e.g. "38;5;208".`
  );
}

// Map a single flag value onto an owned env key. Centralizes the three
// shapes every owned key has to handle:
//   opt === null              → flag not passed; leave the patch alone
//   opt === ''                → explicit clear (`--FLAG ""`); emit delete sentinel
//   transform(opt) === default → user picked the runtime default; emit delete
//                                sentinel so a stale prior override clears
//   otherwise                 → write transform(opt)
//
// The "matches default → clear" rule fixes a stale-key bug: with
// `.env.NEWSLINE_ROTATION_SEC=30` already in place, running
// `--rotation 20` (the runtime default) used to silently leave the 30
// behind because the patch elided the write. The user reasonably expected
// the explicit choice of the default to take effect; collapsing it to the
// delete sentinel makes that work.
//
// transform default is String; defaultValue is the post-transform string
// (caller's responsibility to pre-stringify numeric defaults so equality
// is by value, not type).
function setOrClear(env, key, opt, { transform = String, defaultValue } = {}) {
  if (opt === null) return;
  if (opt === '') { env[key] = undefined; return; }
  const value = transform(opt);
  if (defaultValue !== undefined && value === defaultValue) {
    env[key] = undefined;
    return;
  }
  env[key] = value;
}

// Map wizard/flag opts → env patch. Keys returned MUST be in OWNED_ENV_KEYS.
// This is the single source of truth for "what env does install() write" —
// describePlan prints from this map, applyPlan routes it through reconcileEnv.
//
// Invariant: a value of `undefined` in the returned patch means "delete this
// key from .env" (revert to the runtime default in statusline.sh). Produced
// by `--FLAG ""` (explicit clear), `--FLAG <runtime-default>` (matches default),
// and the `--labels` switch (undo a prior `--no-labels`). reconcileEnv is the
// ONLY correct way to apply this patch — a naive `Object.assign` would write
// the string "undefined" into .env on JSON.stringify.
//
// `null` in opts means "flag not passed" → no key in the patch at all; `''`
// means "flag passed with empty value" → undefined sentinel → delete.
function buildEnvUpdates(opts) {
  const env = {};

  // --only and --disable both target FEEDS_DISABLED. --only wins when both
  // are passed (more specific: "these feeds only"). `--only ""` is meaningless
  // (can't enable zero feeds), so it converges to the same clear as
  // `--disable ""`. Inverting a full --only list also yields an empty
  // disabled string; setOrClear's clear-on-empty-string rule routes both
  // through the same delete sentinel.
  let feedsDisabled = null;
  if (opts.only !== null) {
    feedsDisabled = opts.only === '' ? '' : invertOnly(opts.only);
  } else if (opts.disable !== null) {
    feedsDisabled = opts.disable;
  }
  setOrClear(env, 'NEWSLINE_FEEDS_DISABLED', feedsDisabled, {
    transform: normalizeFeedsDisabled,
  });

  setOrClear(env, 'NEWSLINE_COLOR_FEED', opts.color, {
    defaultValue: DEFAULT_COLOR_FEED,
  });
  setOrClear(env, 'NEWSLINE_LABEL_SEP', opts.separator, {
    defaultValue: DEFAULT_LABEL_SEP,
  });

  // --no-labels writes '0'. --labels uses the `undefined` sentinel so
  // reconcileEnv clears any existing key and the runtime default (labels on)
  // takes over. Two-state boolean doesn't fit setOrClear's three-state shape,
  // so it stays inline.
  if (opts.showLabels === false)      env.NEWSLINE_SHOW_LABELS = '0';
  else if (opts.showLabels === true)  env.NEWSLINE_SHOW_LABELS = undefined;

  setOrClear(env, 'NEWSLINE_REDDIT_SUBS', opts.redditSubs, {
    transform: normalizeRedditSubs,
    defaultValue: DEFAULT_REDDIT_SUB,
  });

  // opts.rotation is number|''|null by the time install() called us.
  // String(20) === String(DEFAULT_ROTATION_SEC) collapses the explicit-default
  // case to the delete sentinel.
  setOrClear(env, 'NEWSLINE_ROTATION_SEC', opts.rotation, {
    defaultValue: String(DEFAULT_ROTATION_SEC),
  });

  // Motion is a multi-key fan-out (one preset → two env keys), so it doesn't
  // fit setOrClear's single-key shape. '' and 'slide' both clear both keys
  // (runtime slide at SCROLL_SEC=5 is the default). 'static' sets SCROLL=0
  // and clears SCROLL_SEC (meaningless when scroll is off — leaving a stray
  // value would only confuse a user reading their settings.json). 'quick'
  // clears SCROLL (runtime → 1) and writes SCROLL_SEC=3. null means no motion
  // flag was passed — leave both keys alone so a non-wizard re-install with
  // other flags doesn't silently wipe a user's hand-edited SCROLL_SEC.
  if (opts.motion !== null) {
    if (opts.motion === '' || opts.motion === 'slide') {
      env.NEWSLINE_SCROLL = undefined;
      env.NEWSLINE_SCROLL_SEC = undefined;
    } else if (opts.motion === 'static') {
      env.NEWSLINE_SCROLL = '0';
      env.NEWSLINE_SCROLL_SEC = undefined;
    } else if (opts.motion === 'quick') {
      env.NEWSLINE_SCROLL = undefined;
      env.NEWSLINE_SCROLL_SEC = String(QUICK_SCROLL_SEC);
    }
  }
  return env;
}

// Compute the wizard's initial selections from the user's current .env so
// re-running the wizard reads as a reconfigure, not a reset. Unlike raw
// currentEnv lookups at the prompt site, this collapses "missing" / "empty"
// / "unknown option" into a single fallback path so the wizard never hands
// clack an initialValue that isn't in its option list (which would render
// as no-highlight and confuse the user). `availableFeeds` is the union of
// built-ins and user-plugin names the wizard will render as checkboxes —
// defaults to ALL_FEEDS for callers (and tests) that don't need to see
// user feeds.
// Predicate mirror of validateColor — returns true for any color string the
// installer would accept (palette, named SGR, raw SGR). Lets the wizard keep
// a hand-edited NEWSLINE_COLOR_FEED across a reconfigure even when the
// user's choice (e.g. "38;5;208") isn't in the curated colorChoices list.
function isAcceptedColor(name) {
  if (!name) return false;
  return NAMED_COLORS.includes(name) || RAW_SGR_REGEX.test(name);
}

function wizardInitialValues(currentEnv, rotationOptions, separatorOptions, availableFeeds) {
  const env = currentEnv || {};
  const feeds = availableFeeds && availableFeeds.length ? availableFeeds : ALL_FEEDS;
  const disabled = new Set(parseCsv(env.NEWSLINE_FEEDS_DISABLED || ''));
  const initialFeeds = feeds.filter(f => !disabled.has(f));
  const rotationN = Number(env.NEWSLINE_ROTATION_SEC);
  const rotationKnown = Number.isFinite(rotationN) && rotationOptions.includes(rotationN);
  // Infer motion from the two underlying env keys. NEWSLINE_SCROLL=0 (any
  // zero-ish) → static, regardless of SCROLL_SEC. Otherwise, SCROLL_SEC
  // below the runtime default means the user previously picked "quick" (or
  // hand-edited to an even shorter value — we still pre-select quick, close
  // enough). Everything else collapses to "slide", which is also the
  // fallback when the keys are unset.
  let motion = 'slide';
  const scrollRaw = env.NEWSLINE_SCROLL;
  if (scrollRaw === '0' || scrollRaw === 'false' || scrollRaw === 'no') {
    motion = 'static';
  } else {
    const scrollSecN = Number(env.NEWSLINE_SCROLL_SEC);
    if (Number.isFinite(scrollSecN) && scrollSecN > 0 && scrollSecN < DEFAULT_SCROLL_SEC) {
      motion = 'quick';
    }
  }
  return {
    feeds: initialFeeds.length ? initialFeeds : feeds,
    redditSubs: env.NEWSLINE_REDDIT_SUBS || DEFAULT_REDDIT_SUB,
    // Accept any color validateColor would accept — palette, named SGR, raw
    // SGR. The runWizard caller injects whatever value comes back here into
    // colorChoices when not already there, so a hand-edited "38;5;208" pre-
    // selects correctly instead of silently reverting to amber.
    color: isAcceptedColor(env.NEWSLINE_COLOR_FEED) ? env.NEWSLINE_COLOR_FEED : 'amber',
    showLabels: env.NEWSLINE_SHOW_LABELS !== '0',
    separator: separatorOptions.includes(env.NEWSLINE_LABEL_SEP) ? env.NEWSLINE_LABEL_SEP : ' \u2022 ',
    rotation: rotationKnown ? rotationN : DEFAULT_ROTATION_SEC,
    motion,
  };
}

// First-run interactive wizard. Mutates `opts` in place and returns
// `{ ran, clack }` — `ran: true` lets the caller skip the trailing
// confirm() (the wizard IS the confirmation), and `clack` is the loaded
// module so install()/describePlan()/applyPlan() can reuse the same UI
// (log.*, outro) without re-importing. Dynamic import because
// @clack/prompts is ESM-only; --help / --yes / non-TTY paths never reach
// here. `currentEnv` is the existing settings.env so a re-run pre-fills
// answers. Cancel exits 0 (user-initiated, not an error — matches clack's
// own documented pattern). The import is try/wrapped because source
// checkouts (`git clone && node bin/claude-newsline.js`) haven't run `npm
// install`; rather than crash with a stack trace, fall back to flag-driven
// install with a one-line hint. npx / global installs always resolve the
// dep, so this path is only hit in dev.
async function runWizard(opts, currentEnv = {}) {
  let clack;
  try {
    clack = await import('@clack/prompts');
  } catch (_) {
    console.error('Warning: @clack/prompts not available; skipping wizard.');
    console.error('Re-run with explicit flags (--disable / --color / --separator / --no-labels) or `npm install` to restore the wizard.');
    return { ran: false, clack: null };
  }
  const { intro, multiselect, select, text, note, cancel, group, log } = clack;

  const SAMPLE_TITLE = 'New Rust release lands async closures';
  // Custom rotation values the user may have hand-edited survive a reconfigure
  // by getting injected into the option list for the current run. Without this,
  // `wizardInitialValues` would silently normalize a `NEWSLINE_ROTATION_SEC=45`
  // back to the default 20 the moment a user Enter-through the wizard to change
  // an unrelated setting. Build the option set AFTER reading env.
  const BASE_ROTATION_OPTIONS = [10, DEFAULT_ROTATION_SEC, 30, 60, 120];
  const envRotation = Number(currentEnv && currentEnv.NEWSLINE_ROTATION_SEC);
  const ROTATION_OPTIONS = Number.isFinite(envRotation) && envRotation > 0 && !BASE_ROTATION_OPTIONS.includes(envRotation)
    ? [...BASE_ROTATION_OPTIONS, envRotation].sort((a, b) => a - b)
    : BASE_ROTATION_OPTIONS;
  // Separator + color injection mirrors the rotation pattern: a hand-edited
  // NEWSLINE_LABEL_SEP / NEWSLINE_COLOR_FEED that's a non-default value gets
  // appended to the option list so Enter-throughs preserve the user's choice
  // instead of silently rewriting it back to a curated default.
  const BASE_SEPARATOR_OPTIONS = [' \u2022 ', ' \u203a ', ' \u00b7 ', ' \u2014 '];
  // Inject the runtime default if it isn't already in the curated list — a
  // future statusline.sh default change shouldn't make fresh-install users
  // unable to see the actual default in the picker.
  const baseSeparatorWithRuntime = BASE_SEPARATOR_OPTIONS.includes(DEFAULT_LABEL_SEP)
    ? BASE_SEPARATOR_OPTIONS
    : [DEFAULT_LABEL_SEP, ...BASE_SEPARATOR_OPTIONS];
  const envSep = currentEnv && typeof currentEnv.NEWSLINE_LABEL_SEP === 'string'
    ? currentEnv.NEWSLINE_LABEL_SEP : null;
  const SEPARATOR_OPTIONS = envSep && !baseSeparatorWithRuntime.includes(envSep)
    ? [...baseSeparatorWithRuntime, envSep]
    : baseSeparatorWithRuntime;

  // User plugins dropped into the feeds dir appear in the wizard checkbox
  // alongside built-ins. scanUserFeeds() silently skips files whose names
  // would fail the sh-side loader — what shows up here is exactly what
  // load_user_feeds would also accept. Reads metadata lazily (only when we
  // need it for the hint), so a large feeds dir doesn't slow the wizard.
  const paths = installPaths();
  const userFeedEntries = scanUserFeeds(paths.userFeedsDir);
  // A user feed with the same name as a built-in overrides at load time —
  // the rotation slot stays singular (load_user_feeds dedupes ALL_FEEDS),
  // so the checkbox should do the same. User version wins visually.
  const builtinNames = new Set(ALL_FEEDS);
  const overridingUserNames = new Set(
    userFeedEntries.filter(f => builtinNames.has(f.name)).map(f => f.name)
  );
  const availableFeedNames = [
    ...ALL_FEEDS,
    ...userFeedEntries.filter(f => !builtinNames.has(f.name)).map(f => f.name),
  ];
  const initial = wizardInitialValues(currentEnv, ROTATION_OPTIONS, SEPARATOR_OPTIONS, availableFeedNames);
  // A "fresh" install (no prior config) gets a one-line explainer. Reconfigures
  // skip it — the returning user already knows what the tool is.
  const isFreshInstall = !currentEnv || Object.keys(currentEnv).length === 0;

  // Reuse the runtime's prefix glyph (Ξ) and accent palette so the wizard
  // header visually ties to the installed headline. `amber` is the default
  // feed color in PALETTE — bold keeps the tag readable on dark backgrounds
  // where depth-reduced palette entries wash out.
  intro(colorize('\u039e claude-newsline', 'amber') + colorize(' setup', 'dim'));
  if (isFreshInstall) {
    note(
      'Rotating news headlines in your Claude Code status line.\n' +
      'Cmd/Ctrl-click a headline to open the story.',
      'What this does',
    );
  } else {
    // Reconfigure flow: returning user sees prefilled answers. One-line
    // orientation beats a second `note()` — scan it once and move on.
    log.info('Reconfiguring — press Enter to keep existing answers.');
  }

  // Palette entries are derived from PALETTE (i.e. from colors.sh) so adding
  // a color to the sh side automatically appears here. The appended non-
  // palette rows are a curated picks of ANSI_BY_NAME names + "none". A hand-
  // edited NEWSLINE_COLOR_FEED that isn't already represented (e.g. a raw
  // SGR like "38;5;208" or a named SGR not in our curated extras) gets a
  // "Current setting" row prepended so it pre-selects and survives Enter-
  // through — same intent as the SEPARATOR_OPTIONS injection above.
  const titleCase = s => s.charAt(0).toUpperCase() + s.slice(1);
  const curatedColorChoices = [
    ...Object.keys(PALETTE).map(k => [titleCase(k), k]),
    ['Bold white',  'bold_white'],
    ['Dim yellow',  'dim_yellow'],
    ['Dim (faded)', 'dim'],
    ['No color',    'none'],
  ];
  // Same drift-prevention as the separator list: if a future runtime default
  // isn't in the curated picks, prepend it labeled "Runtime default" so
  // fresh-install users see the actual default.
  const curatedColorValues = new Set(curatedColorChoices.map(([, v]) => v));
  const baseColorChoices = curatedColorValues.has(DEFAULT_COLOR_FEED)
    ? curatedColorChoices
    : [[`Runtime default (${DEFAULT_COLOR_FEED})`, DEFAULT_COLOR_FEED], ...curatedColorChoices];
  const envColor = currentEnv && currentEnv.NEWSLINE_COLOR_FEED;
  const baseColorValues = new Set(baseColorChoices.map(([, v]) => v));
  const colorChoices = isAcceptedColor(envColor) && !baseColorValues.has(envColor)
    ? [[`Current setting (${envColor})`, envColor], ...baseColorChoices]
    : baseColorChoices;

  // One combined step for "what does each headline look like?" — the prior
  // two-step flow (show-label? then separator?) made the user answer a config
  // question before they'd seen the result. Here each option is the whole
  // rendered shape, so the hint *is* the answer.
  //
  // The sentinel `__bare__` means "no label" (same as showLabels=false). Any
  // other value is the separator string itself. This lets one select carry
  // both decisions without smuggling a second form field through clack. Built
  // from SEPARATOR_OPTIONS so a hand-edited separator (injected above) shows
  // up here verbatim.
  const HEADLINE_FORMAT_OPTIONS = [
    { label: 'Just the title', value: '__bare__' },
    ...SEPARATOR_OPTIONS.map(s => ({ label: `HN${s}Title`, value: s })),
  ];
  const initialFormat = initial.showLabels ? initial.separator : '__bare__';

  // Concrete rates instead of vibes ("chill" / "balanced" told the user
  // nothing they couldn't read off the seconds number). Rounded frequencies
  // give a tangible "how often do I see a new headline" number.
  const perMin = (sec) => {
    if (sec >= 60) {
      const mins = sec / 60;
      return mins === 1 ? '1 headline / minute' : `1 headline / ${mins} min`;
    }
    return `~${Math.round(60 / sec)} headlines / minute`;
  };

  // Build motion preview frames. Inlined so the motion step can reuse the
  // SAMPLE_A/tape values (final preview below rebuilds from final answers).
  // At 1 FPS (Claude Code's refresh floor) the scroll is a stepped slide —
  // we can't animate inside a hint, so each scroll option shows TWO frame
  // slices joined by `→` to imply motion. Slide and quick differ by stride:
  // quick's two frames span further apart on the tape, so the arrow visibly
  // bridges more distance — a visual proxy for "fewer frames in the same
  // total motion."
  const buildMotionDemo = (showLabels, separator) => {
    const labelForSample = showLabels ? `HN${separator}` : '';
    const SAMPLE_A = `${labelForSample}${SAMPLE_TITLE}`;
    const SAMPLE_B = `${showLabels ? `Lobsters${separator}` : ''}Postgres 18 adds lateral joins`;
    const SAMPLE_SEP = '  |  ';
    const tape = SAMPLE_A + SAMPLE_SEP + SAMPLE_B;
    const SLIDE_WIDTH = 26;
    const sliceTape = (offset) => tape.slice(offset, offset + SLIDE_WIDTH);
    const mid = SAMPLE_A.length;
    const slideFrameA = sliceTape(Math.max(0, mid - SLIDE_WIDTH + 6));
    const slideFrameB = sliceTape(Math.max(0, mid - 6));
    const quickFrameA = sliceTape(Math.max(0, mid - SLIDE_WIDTH + 12));
    const quickFrameB = sliceTape(Math.max(0, mid + 2));
    return {
      SAMPLE_A,
      slideFrameB,
      quickFrameB,
      slideDemo: `${slideFrameA} \u2192 ${slideFrameB}`,
      quickDemo: `${quickFrameA} \u2192 ${quickFrameB}`,
    };
  };

  // group() runs the prompts sequentially, passes prior answers via
  // { results }, and centralizes cancel handling in onCancel — replacing
  // the hand-rolled bail() wrapper on every prompt.
  const answers = await group(
    {
      feeds: () => multiselect({
        message: 'Which feeds should rotate?',
        required: true,
        initialValues: initial.feeds,
        options: (() => {
          const builtinOpts = [
            { label: 'Hacker News', value: 'hn',       hint: overridingUserNames.has('hn')       ? 'overridden by your user feed' : 'front page top 30' },
            { label: 'Reddit',      value: 'reddit',   hint: overridingUserNames.has('reddit')   ? 'overridden by your user feed' : `pick subreddits next — max ${MAX_REDDIT_SUBS}` },
            { label: 'Lobsters',    value: 'lobsters', hint: overridingUserNames.has('lobsters') ? 'overridden by your user feed' : 'hottest links (programming & security)' },
          ].filter(o => ALL_FEEDS.includes(o.value));
          // User-plugin rows use the FEED_META `description` when present
          // (matches --list-feeds semantics) and fall back to a generic
          // "user feed" tag — the source path is too long for the hint
          // column and already visible via --list-feeds.
          const userOpts = userFeedEntries
            .filter(f => !builtinNames.has(f.name))
            .map(f => ({
              label: f.name,
              value: f.name,
              hint: (f.meta && f.meta.description) || 'user feed',
            }));
          return [...builtinOpts, ...userOpts];
        })(),
      }),

      // Conditional prompt: non-prompt return values are fine with group().
      // When Reddit isn't selected we short-circuit to `null`; downstream
      // code treats null as "leave REDDIT_SUBS alone". Validation mirrors
      // the CLI flag (format + count cap) so the user sees the same errors
      // here rather than hitting them post-wizard in install().
      redditSubs: ({ results }) => {
        if (!results.feeds.includes('reddit')) return null;
        // Skip the formats lesson for returning users who already have
        // valid subs — they've seen it before and it's noise on a
        // reconfigure. Only fresh installs (or invalid subs) get it.
        const existingSubs = currentEnv && currentEnv.NEWSLINE_REDDIT_SUBS;
        const existingValid = existingSubs &&
          parseCsv(existingSubs).every(isValidRedditEntry);
        if (!existingValid) {
          note(
            'single sub      programming\n' +
            'combined feed   rust+golang+linux\n' +
            'user multi      mawburn/techsubs\n' +
            '\n' +
            'Reddit rate-limits anonymous requests; a 429 just\n' +
            'skips that tick and the last good headline keeps showing.',
            'Subreddit formats',
          );
        }
        return text({
          message: `Subreddits (comma-separated, spaces ok, max ${MAX_REDDIT_SUBS}):`,
          placeholder: 'programming, rust+golang, mawburn/techsubs',
          initialValue: initial.redditSubs,
          validate: (v) => {
            const subs = parseCsv(v);
            if (subs.length === 0) return 'Enter at least one entry';
            if (subs.length > MAX_REDDIT_SUBS) {
              return `Too many (${subs.length} > ${MAX_REDDIT_SUBS}) — each is one HTTP request per refresh`;
            }
            for (const s of subs) {
              if (!isValidRedditEntry(s)) {
                return `Invalid entry "${s}" — use "name", "sub1+sub2", or "user/multi"`;
              }
            }
            return undefined;
          },
        });
      },

      color: () => select({
        message: 'Headline accent color?',
        initialValue: initial.color,
        options: colorChoices.map(([label, value]) => ({
          label,
          value,
          hint: colorize(`HN \u2022 ${SAMPLE_TITLE}`, value),
        })),
      }),

      headlineFormat: ({ results }) => select({
        message: 'Headline format?',
        initialValue: initialFormat,
        options: HEADLINE_FORMAT_OPTIONS.map(({ label, value }) => ({
          label,
          value,
          hint: value === '__bare__'
            ? colorize(SAMPLE_TITLE, results.color)
            : colorize(`HN${value}${SAMPLE_TITLE}`, results.color),
        })),
      }),

      // Drop "(default)" markers — clack's initialValue highlight already
      // signals the pre-selected option. Hand-edited values that aren't in
      // BASE_ROTATION_OPTIONS get injected upstream so Enter-through preserves them.
      rotation: () => select({
        message: 'How long should each headline stay on screen?',
        initialValue: initial.rotation,
        options: ROTATION_OPTIONS.map((sec) => ({
          label: `${sec}s`.padEnd(5),
          value: sec,
          hint: perMin(sec),
        })),
      }),

      // The hint for each option renders the motion visually (two frame
      // slices joined by an arrow) — that's the preview. We dropped the
      // prior `note('About motion', …)` explainer because it restated in
      // prose what the hints already showed; two notes in one group made
      // the UI feel noisy. The 1 FPS caveat now lives in the option labels
      // ("frames") and --help.
      motion: ({ results }) => {
        const showLabels = results.headlineFormat !== '__bare__';
        const separator = showLabels ? results.headlineFormat : null;
        const demo = buildMotionDemo(showLabels, separator);
        return select({
          message: 'How should headlines transition?',
          initialValue: initial.motion,
          options: [
            {
              label: 'Static \u2014 no animation',
              value: 'static',
              hint: colorize(demo.SAMPLE_A, results.color),
            },
            {
              label: `Slide  \u2014 ${DEFAULT_SCROLL_SEC} frames`,
              value: 'slide',
              hint: colorize(demo.slideDemo, results.color),
            },
            {
              label: `Quick  \u2014 ${QUICK_SCROLL_SEC} frames (snappier)`,
              value: 'quick',
              hint: colorize(demo.quickDemo, results.color),
            },
          ],
        });
      },
    },
    {
      onCancel() {
        cancel('Aborted.');
        process.exit(0);
      },
    }
  );

  const { feeds, color, headlineFormat, rotation, motion } = answers;
  const redditSubs = answers.redditSubs ? normalizeRedditSubs(answers.redditSubs) : null;
  const showLabels = headlineFormat !== '__bare__';
  const separator = showLabels ? headlineFormat : null;

  // Final preview. The product IS rotation + transition, so show it: render
  // the starting headline, optionally a mid-transition frame for scroll
  // motions, and the next headline labeled with when it arrives. The prefix
  // glyph renders dim (matches runtime NEWSLINE_COLOR_PREFIX default); the
  // headline renders in the chosen color.
  const demo = buildMotionDemo(showLabels, separator);
  const previewPrefix = colorize('\u039e ', 'dim');
  const headA = showLabels ? `HN${separator}${SAMPLE_TITLE}` : SAMPLE_TITLE;
  const headB = showLabels
    ? `Lobsters${separator}Postgres 18 adds lateral joins`
    : 'Postgres 18 adds lateral joins';
  const previewFrames = [];
  previewFrames.push(`${previewPrefix}${colorize(headA, color)}   ${colorize('now', 'dim')}`);
  if (motion !== 'static') {
    const previewScrollFrame = (motion === 'quick' ? demo.quickFrameB : demo.slideFrameB);
    previewFrames.push(`${previewPrefix}${colorize(previewScrollFrame, color)}   ${colorize('sliding', 'dim')}`);
  }
  previewFrames.push(`${previewPrefix}${colorize(headB, color)}   ${colorize(`in ${rotation}s`, 'dim')}`);
  const transitionSummary = motion === 'static'
    ? `switches every ${rotation}s`
    : `${motion === 'quick' ? QUICK_SCROLL_SEC : DEFAULT_SCROLL_SEC}-frame slide every ${rotation}s`;
  // Title doubles as the confirmation for the wizard path — there's no
  // trailing "Proceed?" prompt after this, so the title must read as
  // "this is what you're about to install", not just a passive preview.
  note(
    previewFrames.join('\n') + '\n\n' + transitionSummary,
    'Ready to install',
  );

  // Use opts.only (positive form) — buildEnvUpdates already inverts to
  // FEEDS_DISABLED. Avoids a double-negative where the wizard inverts once
  // and env building conceptually inverts again. opts.disable stays `null`
  // (not `''`) because `''` now means "explicit clear" — buildEnvUpdates
  // gives opts.only priority when both are set, so this only matters for
  // correctness if someone changes that precedence later.
  opts.only = feeds.join(',');
  opts.disable = null;
  opts.color = color;
  opts.showLabels = showLabels;
  opts.separator = separator;
  opts.redditSubs = redditSubs;
  opts.rotation = rotation;
  opts.motion = motion;
  // Defer outro() to install() so describePlan / applyPlan can render
  // inside the same clack flow (log.step, log.success) and outro is the
  // final visual — one continuous vertical-bar UI from intro to done.
  return { ran: true, clack };
}


// All filesystem paths install/uninstall touch. One place so the two
// functions can't disagree about "where does claude-newsline live".
function installPaths() {
  const cfgDir = configDir();
  const cacheFile = path.join(cfgDir, 'cache', 'feed-titles.txt');
  // User-feeds directory — statusline.sh resolves
  // ${NEWSLINE_FEEDS_DIR:-$CONFIG_DIR/claude-newsline/feeds} at runtime.
  // Honor the same override here so --new-feed scaffolds into the right
  // place, --list-feeds scans the right directory, and the wizard's
  // user-plugin checkbox sees what the runtime will actually load. Without
  // this the installer wrote files the runtime never reads.
  const userFeedsDir = process.env.NEWSLINE_FEEDS_DIR
    || path.join(cfgDir, 'claude-newsline', 'feeds');
  return {
    cfgDir,
    settingsPath:     path.join(cfgDir, 'settings.json'),
    scriptDest:       path.join(cfgDir, 'claude-newsline.sh'),
    colorsDest:       path.join(cfgDir, 'colors.sh'),
    // Filename identical on src and dest so statusline.sh's
    // `$_SCRIPT_DIR/xml-to-json.js` resolves the same way at dev (repo/bin/)
    // and installed ($CLAUDE_CONFIG_DIR/).
    xmlToJsonDest:    path.join(cfgDir, 'xml-to-json.js'),
    scriptSrc:        path.join(__dirname, 'statusline.sh'),
    colorsSrc:        path.join(__dirname, 'colors.sh'),
    xmlToJsonSrc:     path.join(__dirname, 'xml-to-json.js'),
    cacheDir:         path.join(cfgDir, 'cache'),
    cacheFile,
    userFeedsDir,
    userFeedsReadme:  path.join(userFeedsDir, 'README.md'),
    // .pending is the double-buffer slot; .lock is the refresh serialization
    // dir. Both are part of the runtime contract with statusline.sh — if the
    // suffixes drift, uninstall leaves orphans and re-install thinks a
    // refresh is in flight.
    cachePendingFile: `${cacheFile}.pending`,
    cacheLockDir:     `${cacheFile}.lock`,
  };
}

// README template dropped into paths.userFeedsReadme on first install.
// Never overwrites an existing file (see wx-flag write in applyPlan) so a
// user-edited README survives re-runs.
const USER_FEEDS_README = `# Custom feeds

Drop a \`<name>.sh\` file in this directory and it becomes a feed in your
claude-newsline rotation. Filename maps to function name:
\`nyt.sh\` defines \`feed_nyt()\`.

Fastest start — scaffold a template and test it offline:

\`\`\`sh
claude-newsline --new-feed nyt
# edit ~/.claude/claude-newsline/feeds/nyt.sh
claude-newsline --test-feed nyt --fixture sample.json
\`\`\`

## Share or browse community feeds

No central registry — but the project's GitHub Discussions are the place
to share a plugin you've written or grab one someone else has posted:

  https://github.com/sitapix/claude-newsline/discussions

Treat third-party plugins the same way you'd treat any shell script from
the internet — read the file before dropping it in this directory.

## The plugin contract

A feed plugin is one POSIX-sh file that defines:

1. **Required** \`feed_<name>()\` — a function setting three globals the
   dispatch loop reads back: \`LABEL\`, \`URL\`, \`JQ\`.
2. **Optional** \`FEED_PARAMS_<name>\` — the internal variable name your feed
   will be called for each CSV entry of (see "Parameterized feed" below).
3. **Optional** \`FEED_META_<name>\` — newline-separated \`key=value\` lines
   shown in \`NEWSLINE_DEBUG=1\` and \`--list-feeds -v\`. Recognized keys:
   - \`api\` — plugin-contract version (current: ${FEED_API_VERSION}). Declares which
     version of the plugin contract this file was written against. Plugins
     declaring a version newer than the runtime supports are skipped.
     Absent or non-numeric is treated as \`api=1\` (backward compat).
   - \`category\` — free-form group label used by \`--list-feeds -v\` to
     cluster related plugins. Defaults to \`Custom\` when absent.
   - \`description\`, \`version\`, \`author\`, \`homepage\` — informational only.
   - \`source\` — auto-attached at load time with the plugin's file path.

Filename rules (enforced at load time):

- Must match \`[A-Za-z_][A-Za-z0-9_]*\` before the \`.sh\` — POSIX shell
  function-name rules. \`2fa.sh\` (leading digit) and \`my-feed.sh\`
  (hyphen) are rejected.
- A file named the same as a built-in (e.g. \`hn.sh\`) OVERRIDES the
  built-in for this installation. No duplicate rotation slot — it simply
  takes over.

## Security

**User plugins are sourced into the statusline.sh shell process.** A
malicious file dropped here has the same privileges as your status line
runs with. Only install plugins you've read. \`NEWSLINE_DEBUG=1\` prints
the full path of every loaded plugin so you can audit at any time.

## Minimal feed

\`\`\`sh
# nyt.sh
FEED_META_nyt='description=New York Times top stories
api=${FEED_API_VERSION}
category=News
version=0.1.0
author=you'
feed_nyt() {
  LABEL='NYT'
  URL='https://example.com/nyt-feed.json'
  # jq emits three tab-separated fields: <label>\\t<title>\\t<url>
  # \$default is the LABEL above — use it, or promote a title-based label.
  JQ='.articles[] | [\$default, .title, .url] | @tsv'
}
\`\`\`

Restart Claude Code (or let the current cache expire) and the new feed
joins the rotation.

## Parameterized feed

Same shape as the built-in Reddit feed — declare \`FEED_PARAMS_<name>\` to
split a CSV env var and call your feed once per entry:

\`\`\`sh
# jira.sh
FEED_META_jira='description=JIRA project issues (parameterized)'
feed_jira() {
  _project=\$1
  case "\$_project" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  LABEL="JIRA/\$_project"
  URL="https://company.atlassian.net/rest/api/2/search?jql=project=\$_project"
  JQ='.issues[] | [\$default, .fields.summary, "https://company.atlassian.net/browse/\\(.key)"] | @tsv'
}
# Bind the user-facing env var (NEWSLINE_*) to the internal name FEED_PARAMS
# points at. The dispatch loop reads $JIRA_PROJECTS, not $NEWSLINE_JIRA_PROJECTS —
# without this line, nothing in your settings.json "env" reaches the feed.
JIRA_PROJECTS="\${NEWSLINE_JIRA_PROJECTS:-}"
FEED_PARAMS_jira='JIRA_PROJECTS'
# Then set NEWSLINE_JIRA_PROJECTS=ENG,INFRA via Claude Code settings.json "env".
\`\`\`

Contract for parameterized feeds:
- The function is called once per comma-separated entry in the resolved
  internal variable. \`$1\` is the entry.
- \`return 1\` rejects a single entry (it's skipped; other entries proceed).
  This is the right response to an invalid entry — the runtime treats it
  as belt-and-braces over any installer-side validation.
- The function must re-validate its input — a hand-edited \`.env\` must
  not be able to inject into URLs.
- You MUST include a \`YOUR_INTERNAL="\${NEWSLINE_YOUR_INTERNAL:-default}"\`
  line that binds the user-facing env var to the internal variable name
  \`FEED_PARAMS_<name>\` points at. Built-ins do this in statusline.sh's
  CONFIG block; user plugins declare it in the plugin file itself.

## Output contract

The jq filter must emit newline-separated records of three tab-separated
fields:

    <label>\\t<title>\\t<url>

- \`<label>\` — shown as the \`SOURCE • \` prefix. Can be the default passed
  in via \`--arg default "$LABEL"\`, or a per-item override (the built-in
  HN feed promotes \`Show HN\`/\`Ask HN\`/\`Tell HN\` prefixes into the label
  this way).
- \`<title>\` — the headline text. UTF-8 ok; byte-truncated to MAX_TITLE.
- \`<url>\` — **must be http(s)://**. Any other scheme drops the OSC 8
  hyperlink on render (defense against terminal URL-handler argument
  injection). The line still rotates into view, just unlinked.

Control bytes (C0/C1, ESC, CR) in any field are stripped after jq emits
them and before the cache is written. You can't accidentally break the
terminal by emitting a title that contains an escape sequence.

## Debugging

\`NEWSLINE_DEBUG=1\` in your environment prints:

- the resolved config,
- the loaded-feeds map,
- each feed's metadata block (description/version/author/source),
- the path each user feed came from.

A file with a syntax error or a missing \`feed_<name>\` function is
skipped silently; the rest of the rotation keeps working.

See https://github.com/sitapix/claude-newsline#custom-feeds for details.
`;

// Derive the intended install shape from an already-read settings object.
// The `settings` ref is live — applyPlan() mutates it, so `plan` is a
// staging area rather than an immutable snapshot. `wizardRan` means the
// wizard answers are authoritative, so stale owned-env keys get purged on
// re-run. Caller reads settings so install() can pre-fill the wizard from
// the same object without re-parsing the file.
function planInstall(opts, paths, settings, wizardRan = false) {
  // Claude Code's schema makes this a string, but nothing here validates the
  // settings.json shape — a hand-edited `"command": null` or `"command": 42`
  // would crash `stripSuffix`'s `.replace` call with a cryptic stack trace.
  // Coerce non-strings to empty so we overwrite cleanly instead of blowing up.
  const cmdField = settings.statusLine && settings.statusLine.command;
  const existingCmd = typeof cmdField === 'string' ? cmdField : '';
  const stripped = stripSuffix(existingCmd);
  const newslineCmd = `${MARKER_VAR}=${MARKER_VALUE} bash ${shellQuote(paths.scriptDest)}`;
  const newCmd = stripped ? `${stripped} ; ${newslineCmd}` : newslineCmd;
  const hadRefresh = !!(settings.statusLine && settings.statusLine.refreshInterval !== undefined);
  const envUpdates = buildEnvUpdates(opts);
  return { settings, existingCmd, newCmd, hadRefresh, envUpdates, clearStaleEnv: wizardRan };
}

// Apply env updates and — when the wizard ran — drop any owned keys that
// aren't in the update (so a re-run where the user re-enabled a feed purges
// the old FEEDS_DISABLED). Exported for unit testing.
function reconcileEnv(env, envUpdates, clearStale = false) {
  env = env || {};
  if (clearStale) {
    for (const k of OWNED_ENV_KEYS) {
      if (!(k in envUpdates)) delete env[k];
    }
  }
  // Iterate explicitly so `key: undefined` (emitted by buildEnvUpdates to
  // mean "revert to runtime default") deletes the key instead of round-
  // tripping the string "undefined" through JSON.stringify.
  for (const [k, v] of Object.entries(envUpdates)) {
    if (v === undefined) delete env[k];
    else env[k] = v;
  }
  return env;
}

// True when applyPlan would produce byte-identical settings.json. Used to
// reassure a reconfiguring user that Enter-through the wizard is safe — we
// still refresh the installed shell scripts (in case the package was bumped)
// but settings.json is untouched. Three conditions must all hold:
//   1. .statusLine.command already matches what we'd write
//   2. .statusLine.refreshInterval already exists (we won't add it)
//   3. every envUpdates entry is either a redundant write (same value) or
//      a delete of an already-absent key
function isSettingsNoop(plan) {
  if (plan.existingCmd !== plan.newCmd) return false;
  if (!plan.hadRefresh) return false;
  const existingEnv = (plan.settings && plan.settings.env) || {};
  for (const [k, v] of Object.entries(plan.envUpdates)) {
    if (v === undefined) {
      if (k in existingEnv) return false;
    } else {
      if (existingEnv[k] !== v) return false;
    }
  }
  // Wizard-run reconcile can drop owned keys that aren't in the patch — if
  // any of those are currently present, that's a change.
  if (plan.clearStaleEnv) {
    for (const k of OWNED_ENV_KEYS) {
      if (k in existingEnv && !(k in plan.envUpdates)) return false;
    }
  }
  return true;
}

// Single abstraction for installer output and prompts. Two backends:
//
//   - "wizard" mode (clack is loaded; the user came in via runWizard) renders
//     into clack's vertical-bar log.* / tasks() flow so describePlan,
//     applyPlan, and the proceed-confirm sit inside one continuous UI.
//   - "plain" mode (no clack) prints to console with minimal styling. Used
//     by flag-driven paths and the source-checkout fallback when
//     @clack/prompts isn't installed.
//
// confirm() lazy-loads clack on first call so flag-driven paths don't pay
// for the import unless they actually need to prompt; --yes / non-TTY
// paths short-circuit before reaching here. A failed lazy-load surfaces
// a clear "install --yes or npm install" message instead of crashing.
//
// confirm() returns a boolean; user-cancels (Ctrl-C / Esc) exit the
// process with status 0, matching clack's documented pattern (cancel is
// user-initiated, not an error, so no traceback or non-zero exit).
function createUILogger(initialClack) {
  let clack = initialClack || null;
  const isWizard = !!initialClack;

  // Resolve clack on demand for prompts (confirm). The wizard mode
  // already has it loaded; flag mode loads on first use.
  const ensureClack = async () => {
    if (clack) return clack;
    try {
      clack = await import('@clack/prompts');
      return clack;
    } catch (_) {
      return null;
    }
  };

  if (isWizard) {
    return {
      isWizard,
      warn:    (s) => clack.log.warn(s),
      step:    (s) => clack.log.step(s),
      success: (s) => clack.log.success(s),
      message: (s) => clack.log.message(s),
      tasks:   (list) => clack.tasks(list),
      cancel:  (s) => clack.cancel(s),
      outro:   (s) => clack.outro(s),
      async confirm(message) {
        const c = await ensureClack();
        const result = await c.confirm({
          message,
          active: 'Install',
          inactive: 'Cancel',
          initialValue: true,
        });
        if (c.isCancel(result)) { c.cancel('Aborted.'); process.exit(0); }
        return result;
      },
    };
  }

  return {
    isWizard,
    warn:    (s) => console.log(`\x1b[33m${s}\x1b[0m`),
    step:    (s) => console.log(s),
    success: (s) => console.log(`\u2713 ${s}`),
    message: (s) => console.log(s),
    cancel:  (s) => console.log(s),
    outro:   (s) => console.log(`\nDone. ${s}`),
    async confirm(message) {
      const c = await ensureClack();
      if (!c) {
        console.error('\nError: @clack/prompts not available; cannot prompt for confirmation.');
        console.error('Re-run with --yes (or -y) to skip the prompt, or `npm install` to restore it.');
        return false;
      }
      const result = await c.confirm({
        message,
        active: 'Install',
        inactive: 'Cancel',
        initialValue: true,
      });
      if (c.isCancel(result)) { c.cancel('Aborted.'); process.exit(0); }
      return result;
    },
  };
}

function describePlan(plan, ui) {
  ui = ui || createUILogger(null);
  // Fresh configs have no statusLine at all. Claude Code's built-in default
  // is minimal (no cwd/model/git/cost unless the user configured them), so
  // the user isn't "losing" a rich line — but they also aren't getting one.
  // Call this out so a first-time user knows they can combine the headline
  // with the richer statusLine examples in the Claude Code docs.
  if (!plan.existingCmd) {
    ui.warn(
      'No existing statusLine detected.\n' +
      'After install, your status line will be only the rotating headline.\n' +
      'For model / cwd / git / cost info alongside it, set up a base statusLine\n' +
      'first (see https://code.claude.com/docs/en/statusline) and re-run —\n' +
      'this installer chains the headline after whatever is already there.'
    );
  }
  if (isSettingsNoop(plan)) {
    ui.message('Configuration already matches — no changes to settings.json.\n(Installed scripts will still be refreshed.)');
    return;
  }
  // Collect into a single block so clack's log.step renders the whole
  // "Planned changes" as one ◇-prefixed event instead of many orphan
  // vertical bars. Plain logger joins on newlines — output is identical.
  const lines = ['Planned changes to settings.json:'];
  if (plan.existingCmd && plan.existingCmd !== plan.newCmd) {
    lines.push(`  .statusLine.command: ${JSON.stringify(plan.existingCmd)}`);
    lines.push(`                    \u2192 ${JSON.stringify(plan.newCmd)}`);
  } else if (!plan.existingCmd) {
    lines.push(`  .statusLine.command = ${JSON.stringify(plan.newCmd)}  (new)`);
  }
  if (!plan.hadRefresh) {
    lines.push('  .statusLine.refreshInterval = 1  (was unset) — enables scroll animation; ~60 shell invocations/minute');
  }
  const existingEnv = (plan.settings && plan.settings.env) || {};
  for (const [k, v] of Object.entries(plan.envUpdates)) {
    if (v === undefined) {
      if (k in existingEnv) lines.push(`  .env.${k}: cleared (revert to runtime default)`);
    } else if (existingEnv[k] !== v) {
      lines.push(`  .env.${k} = ${JSON.stringify(v)}`);
    }
  }
  ui.step(lines.join('\n'));
}

async function applyPlan(plan, paths, ui) {
  ui = ui || createUILogger(null);
  fs.mkdirSync(paths.cfgDir, { recursive: true });

  // Scaffold the user-feeds directory on first install. Idempotent and
  // non-transactional: failure here must not abort the main install (a
  // read-only $HOME or a perms glitch shouldn't block the status line).
  // `wx` flag writes only when the file doesn't exist, so a concurrent
  // re-install or a user-edited README can't be clobbered — `EEXIST`
  // falls through to the outer catch as a no-op. Avoids the existsSync
  // + writeFileSync TOCTOU window.
  try {
    fs.mkdirSync(paths.userFeedsDir, { recursive: true });
    fs.writeFileSync(paths.userFeedsReadme, USER_FEEDS_README, { flag: 'wx' });
  } catch (_) { /* non-fatal (includes EEXIST on re-install) — install proceeds */ }

  // Transactional: stage both scripts into sibling tmp files, rename them
  // into place, then patch settings.json LAST. rename(2) on the same
  // filesystem is atomic; copyFileSync is not, so writing directly to
  // scriptDest could leave a half-written file if we crash mid-copy.
  //
  // Ordering rationale: if settings.json were written FIRST and a rename
  // then failed, settings would reference a scriptDest that doesn't exist —
  // Claude Code would then log a "file not found" error on every status-
  // line refresh. Writing settings LAST means any failure before the final
  // settings write leaves the OLD state fully intact; the worst case is
  // stale-but-valid scripts on disk that the next install rewrites cleanly.
  //
  // The cleanup trap unlinks both tmps on any throw. Once `renameSync`
  // succeeds, the tmp path no longer exists, so `unlinkSync(tmp)` becomes
  // a no-op (ENOENT is swallowed). That means cleanup is safe to call even
  // after a partial advance — it only wipes what's still pending.
  // Staging table: [src, dest, mode]. Every runtime file ships as one row.
  // Adding a fourth file is one row, not three scattered edits.
  const staged = [
    [paths.scriptSrc,     paths.scriptDest,     0o755],
    [paths.colorsSrc,     paths.colorsDest,     null],
    [paths.xmlToJsonSrc,  paths.xmlToJsonDest,  0o755],
  ].map(([src, dest, mode]) => ({ src, dest, mode, tmp: tmpSibling(dest) }));
  const cleanup = () => {
    for (const { tmp } of staged) {
      try { fs.unlinkSync(tmp); } catch (_) { /* ignore ENOENT */ }
    }
  };

  // Factor each transactional step into a closure so the clack path (rendered
  // via tasks() with per-step spinners) and the plain path (flat log.success
  // lines) share the same ordering and side effects.
  const stepBackup = () => {
    const bak = backup(paths.settingsPath);
    return bak ? `Backed up \u2192 ${bak}` : 'No prior settings.json — nothing to back up';
  };
  const stepStage = () => {
    for (const { src, tmp, mode } of staged) {
      fs.copyFileSync(src, tmp);
      if (mode !== null) fs.chmodSync(tmp, mode);
    }
    return `Staged \u2192 ${paths.scriptDest}`;
  };
  const stepPatch = () => {
    // Install scripts first so settings.json never points at a file that
    // isn't on disk yet. If any rename fails we throw before writing
    // settings — old state survives intact.
    for (const { tmp, dest } of staged) fs.renameSync(tmp, dest);
    const settings = plan.settings;
    settings.statusLine = settings.statusLine || {};
    settings.statusLine.type = 'command';
    settings.statusLine.command = plan.newCmd;
    if (!plan.hadRefresh) settings.statusLine.refreshInterval = 1;
    settings.env = reconcileEnv(settings.env, plan.envUpdates, plan.clearStaleEnv);
    if (Object.keys(settings.env).length === 0) delete settings.env;
    writeSettings(paths.settingsPath, settings);
    return `Patched ${paths.settingsPath}`;
  };

  try {
    if (ui.tasks) {
      await ui.tasks([
        { title: 'Backing up existing settings', task: async () => stepBackup() },
        { title: 'Staging runtime scripts',      task: async () => stepStage()  },
        { title: 'Patching settings.json',       task: async () => stepPatch()  },
      ]);
    } else {
      ui.success(stepBackup());
      stepStage();
      ui.success(stepPatch());
      ui.success(`Installed script \u2192 ${paths.scriptDest}`);
    }
  } catch (e) {
    cleanup();
    throw e;
  }
}

async function install(opts) {
  const paths = installPaths();
  if (!fs.existsSync(paths.scriptSrc) || !fs.existsSync(paths.colorsSrc) ||
      !fs.existsSync(paths.xmlToJsonSrc)) {
    throw new Error('Installer files missing. Reinstall the package.');
  }

  // Interactive wizard on fresh TTY installs only. --yes, non-TTY, and any
  // explicit config flag keep the flag-driven path so scripts and CI never
  // hit a hung stdin waiting for input. runWizard returns the loaded
  // @clack/prompts module to wrap into a UI logger, so describePlan,
  // applyPlan, and the proceed-confirm all render inside the same vertical-
  // bar flow.
  let wizardRan = false;
  let wizardClack = null;
  // Read once. The wizard pre-fills from settings.env; planInstall consumes
  // the same object. A re-run is a reconfigure, not a reset.
  const settings = readSettings(paths.settingsPath);

  // CI environments often present a TTY (GitHub Actions does) but expect
  // non-interactive behavior. Matching create-vite / pnpm create / gh, we
  // treat CI=true as "never prompt", same as non-TTY.
  const ciEnv = !!process.env.CI;
  if (!opts.yes && process.stdin.isTTY && !ciEnv && !hasExplicitConfig(opts)) {
    const r = await runWizard(opts, settings.env || {});
    wizardRan = r.ran;
    wizardClack = r.clack;
  }

  validateFeeds(opts.disable);
  validateFeeds(opts.only);
  validateColor(opts.color);
  validateRedditSubs(opts.redditSubs);
  // `--rotation ""` / `--rotation=""` is the explicit-clear shape — skip
  // validation so the empty-string sentinel survives into buildEnvUpdates,
  // which translates it to `undefined` (delete the key). Everything else
  // (null = not passed, a number, a string of digits) goes through the
  // range check.
  if (opts.rotation !== '') opts.rotation = validateRotation(opts.rotation);
  opts.motion = validateMotion(opts.motion);

  const plan = planInstall(opts, paths, settings, wizardRan);
  const ui = createUILogger(wizardClack);
  describePlan(plan, ui);

  // Confirmation gate. Three paths:
  //   1. --yes            → skip entirely.
  //   2. flag path, TTY   → ui.confirm() lazy-loads clack and prompts.
  //   3. wizard path      → ui.confirm() reuses the wizard's clack module so
  //                         the prompt sits inside the same vertical-bar UI.
  //                         Skip when the plan is a no-op — nothing to
  //                         confirm and an extra Y/N beat reads as friction.
  // The non-TTY / CI branch only fires on flag-driven runs: a wizard can't
  // have happened without a TTY, so wizardRan implies it's safe to prompt.
  if (!opts.yes) {
    if (!wizardRan) {
      if (!process.stdin.isTTY || ciEnv) {
        const why = ciEnv ? 'CI=true is set' : 'stdin is not a TTY';
        console.error(`\nError: ${why}; refusing to auto-confirm.`);
        console.error('Re-run with --yes (or -y) to skip the confirmation prompt.');
        return 1;
      }
      const ok = await ui.confirm('Apply these changes?');
      // Pick-Cancel returns 0 to match Ctrl-C (which clack handles via its
      // own process.exit(0) in confirm()). Both are user-initiated declines;
      // returning different exit codes here used to make CI scripts that
      // pipe input flake based on which key the user happened to hit.
      if (!ok) { ui.cancel('Aborted.'); return 0; }
    } else if (!isSettingsNoop(plan)) {
      const ok = await ui.confirm('Apply these changes?');
      // Pick-Cancel returns 0 to match Ctrl-C (which clack handles via its
      // own process.exit(0) in confirm()). Both are user-initiated declines;
      // returning different exit codes here used to make CI scripts that
      // pipe input flake based on which key the user happened to hit.
      if (!ok) { ui.cancel('Aborted.'); return 0; }
    }
  }

  await applyPlan(plan, paths, ui);
  // On the wizard path, a terminal success line before outro gives the
  // vertical-bar UI a clear "done" beat separate from the reload hint —
  // outro collapses the gutter, so a success line inside the flow reads
  // better than stuffing both pieces of info into outro itself.
  const doneMsg = 'Restart Claude Code (or start a new session) to see the headline.';
  if (ui.isWizard) ui.success('Installed.');
  ui.outro(doneMsg);
  return 0;
}

async function uninstall() {
  const paths = installPaths();

  if (fs.existsSync(paths.settingsPath)) {
    // Parse BEFORE backup so malformed JSON doesn't orphan a .bak file.
    const settings = readSettings(paths.settingsPath);
    const bak = backup(paths.settingsPath);
    // Same non-string guard as planInstall — a malformed command field must
    // not crash uninstall; treat it as nothing-to-strip.
    const cmdField = settings.statusLine && settings.statusLine.command;
    const existingCmd = typeof cmdField === 'string' ? cmdField : '';
    const stripped = stripSuffix(existingCmd);

    if (!stripped) {
      delete settings.statusLine;
    } else if (settings.statusLine) {
      settings.statusLine.command = stripped;
      // Install only ever writes refreshInterval=1 (and only when it was
      // unset). Symmetric cleanup: drop it iff it still matches what we
      // wrote. A user who explicitly chose refreshInterval=1 loses it; any
      // other value is theirs and we don't touch it.
      if (settings.statusLine.refreshInterval === 1) {
        delete settings.statusLine.refreshInterval;
      }
    }

    if (settings.env) {
      settings.env = reconcileEnv(settings.env, {}, true);
      if (Object.keys(settings.env).length === 0) delete settings.env;
    }

    writeSettings(paths.settingsPath, settings);
    console.log(`✓ Removed claude-newsline from settings.json (backup: ${bak})`);
  }

  for (const p of [paths.scriptDest, paths.colorsDest, paths.xmlToJsonDest, paths.cacheFile, paths.cachePendingFile]) {
    // unlink → catch ENOENT instead of existsSync+unlink: collapses the
    // TOCTOU window and tolerates the file being removed underneath us.
    try {
      fs.unlinkSync(p);
      console.log(`✓ Removed ${p}`);
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
  }
  try {
    fs.rmdirSync(paths.cacheLockDir);
  } catch (e) {
    if (e.code !== 'ENOENT' && e.code !== 'ENOTEMPTY' && e.code !== 'ENOTDIR') throw e;
  }
  // Remove cache/ only if empty. ENOTEMPTY means the user put something there.
  try {
    fs.rmdirSync(paths.cacheDir);
    console.log(`✓ Removed ${paths.cacheDir}`);
  } catch (e) {
    if (e.code !== 'ENOENT' && e.code !== 'ENOTEMPTY') throw e;
  }
  console.log('Done.');
  return 0;
}

// --test-feed: spawn statusline.sh with NEWSLINE_TEST_FEED=<name> so the
// diagnostic branch runs. Prefers the *installed* script (same version the
// user actually sees at runtime) and falls back to the package's bin/
// copy when they haven't installed yet (so `npx ... --test-feed foo`
// works even on a fresh machine). Settings.json "env" is merged into the
// child env — Claude Code injects it at runtime, so merging it here keeps
// parameterized feeds (like reddit's NEWSLINE_REDDIT_SUBS) resolving to
// the same value the user sees in production. process.env wins so users
// can override ad hoc: `NEWSLINE_REDDIT_SUBS=rust npx ... --test-feed reddit`.
async function testFeed(opts) {
  const name = opts.testFeed;
  // Pre-filter before handing to the shell. POSIX function-name rules —
  // same check load_user_feeds does, mirrored here so a typo fails fast in
  // Node with a clear message instead of tripping the bash-side validator.
  if (!FEED_NAME_REGEX.test(name)) {
    console.error(`Error: --test-feed expects a valid feed name (got ${JSON.stringify(name)})`);
    console.error('Names must match [A-Za-z_][A-Za-z0-9_]* (POSIX function-name rules).');
    return 2;
  }

  // --fixture short-circuits the curl step so authors can iterate on a jq
  // filter without hitting the network. Validate early — an unreadable path
  // or a --fixture without --test-feed is a user error we should catch in
  // Node, not paper over with a bash-side empty read.
  let fixtureAbs = null;
  if (opts.fixture !== null) {
    try {
      const st = fs.statSync(opts.fixture);
      if (!st.isFile()) {
        console.error(`Error: --fixture expects a file (got ${JSON.stringify(opts.fixture)})`);
        return 2;
      }
      fixtureAbs = path.resolve(opts.fixture);
    } catch (e) {
      console.error(`Error: --fixture ${JSON.stringify(opts.fixture)}: ${e.message}`);
      return 2;
    }
  }

  const paths = installPaths();
  const scriptPath = fs.existsSync(paths.scriptDest) ? paths.scriptDest : paths.scriptSrc;
  if (!fs.existsSync(scriptPath)) {
    console.error(`Error: statusline.sh not found at ${scriptPath}`);
    return 1;
  }

  // Merge settings.env into the child's env (process.env wins). Skip if
  // settings.json is absent (fresh machine, nothing installed yet) — the
  // user's own env or the runtime defaults will carry. readSettings throws
  // on malformed JSON; surface that as a clean error rather than a stack.
  const childEnv = { ...process.env };
  if (fs.existsSync(paths.settingsPath)) {
    try {
      const settings = readSettings(paths.settingsPath);
      const settingsEnv = (settings && settings.env) || {};
      for (const [k, v] of Object.entries(settingsEnv)) {
        if (childEnv[k] === undefined) childEnv[k] = v;
      }
    } catch (e) {
      console.error(`Error: ${e.message}`);
      return 1;
    }
  }
  childEnv.NEWSLINE_TEST_FEED = name;
  if (fixtureAbs !== null) childEnv.NEWSLINE_TEST_FEED_FIXTURE = fixtureAbs;

  const { spawn } = require('child_process');
  return new Promise((resolve) => {
    const child = spawn('bash', [scriptPath], {
      stdio: ['ignore', 'inherit', 'inherit'],
      env: childEnv,
    });
    child.on('exit', (code, signal) => {
      if (signal) resolve(1);
      else resolve(code == null ? 1 : code);
    });
    child.on('error', (err) => {
      console.error(`Error: ${err.message}`);
      resolve(1);
    });
  });
}

// --new-feed: stamp a starter plugin file into $USER_FEEDS_DIR/<name>.sh and
// exit. Validation mirrors load_user_feeds's name rules so a file this creates
// is guaranteed loadable. Refuses to overwrite an existing file (an author
// iterating on their own plugin shouldn't lose work to a re-run of this
// command). Creates the feeds dir if it doesn't exist — first-time users who
// haven't run install yet still get a working scaffold.
function newFeed(opts) {
  const name = opts.newFeed;
  if (!FEED_NAME_REGEX.test(name)) {
    console.error(`Error: --new-feed expects a valid feed name (got ${JSON.stringify(name)})`);
    console.error('Names must match [A-Za-z_][A-Za-z0-9_]* (POSIX function-name rules).');
    console.error('Examples: nyt, github_trending, my_feed');
    return 2;
  }
  const paths = installPaths();
  const dest = path.join(paths.userFeedsDir, `${name}.sh`);
  if (fs.existsSync(dest)) {
    console.error(`Error: ${dest} already exists — refusing to overwrite.`);
    console.error(`Delete it first if you want a fresh template, or edit it in place.`);
    return 1;
  }
  // Name collision with a built-in isn't fatal (user-feed overrides are a
  // documented feature — statusline.sh's load_user_feeds dedupes), but it's
  // almost always a surprise, so warn and keep going.
  if (ALL_FEEDS.includes(name)) {
    console.error(`Warning: "${name}" is also a built-in feed — this plugin will OVERRIDE it at load time.`);
  }
  try {
    fs.mkdirSync(paths.userFeedsDir, { recursive: true });
    // wx = O_EXCL: fail if it somehow appeared between the existsSync check
    // and now (race is absurd in practice but the extra guard costs nothing).
    fs.writeFileSync(dest, newFeedTemplate(name), { flag: 'wx', mode: 0o644 });
  } catch (e) {
    console.error(`Error: ${e.message}`);
    return 1;
  }
  console.log(`Created ${dest}`);
  console.log('');
  console.log('Next steps:');
  console.log(`  1. Edit the file — set LABEL, URL, JQ (and FEED_META description).`);
  console.log(`  2. Test with a live fetch:   claude-newsline --test-feed ${name}`);
  console.log(`  3. Or test offline:          claude-newsline --test-feed ${name} --fixture sample.json`);
  console.log('');
  console.log(`Feed will join the rotation next refresh (or restart Claude Code).`);
  return 0;
}

// --list-feeds: show built-ins + user feeds, optionally with metadata.
// Read from statusline.sh source (built-ins) and scan the feeds dir (user).
// No sourcing needed — the metadata parser matches what sh reports at
// NEWSLINE_DEBUG=1, so what users see here is what they'd see at runtime.
function listFeeds(verbose) {
  const paths = installPaths();
  // scanAllUserFeeds returns both loadable and api-incompatible plugins so
  // --list-feeds can surface the "I dropped this file but it's not running"
  // case — silent-skip leaves users guessing. Partition into two groups:
  // loadable ones join the main list; incompatible ones get a separate
  // section so the user sees the file exists but knows why it's ignored.
  const allUserFeeds = scanAllUserFeeds(paths.userFeedsDir);
  const userFeeds = allUserFeeds.filter(f => f.compat.ok);
  const incompatFeeds = allUserFeeds.filter(f => !f.compat.ok);
  const userFeedNames = new Set(userFeeds.map(f => f.name));
  const shSrc = readStatuslineSrc();

  // Default category when a plugin didn't declare one. Built-ins set
  // `category=News` explicitly; user plugins without metadata land in
  // "Custom" — matches ccstatusline's convention for user-written widgets.
  const defaultCategory = (isBuiltin) => isBuiltin ? 'News' : 'Custom';
  const rows = [];
  for (const f of ALL_FEEDS) {
    const overridden = userFeedNames.has(f);
    const meta = parseFeedMeta(shSrc, f);
    rows.push({
      name: f,
      source: overridden ? 'built-in (overridden by user feed)' : 'built-in',
      meta,
      category: meta.category || defaultCategory(true),
      isBuiltin: true,
    });
  }
  for (const { name, path: p, meta: userMeta } of userFeeds) {
    // User-owned file that also has a built-in name — the rotation will use
    // the user version. Don't double-list; we already flagged the built-in
    // row as overridden. But still print the user version below, since the
    // user's metadata/description is what actually applies.
    const isOverride = ALL_FEEDS.includes(name);
    rows.push({
      name,
      source: isOverride ? `user override: ${p}` : `user: ${p}`,
      meta: userMeta || {},
      category: (userMeta && userMeta.category) || defaultCategory(false),
      isBuiltin: false,
    });
  }

  // One-liner reason per incompat row. Renders the specific cause inline so
  // the user doesn't have to map a generic footer back to each row's case.
  // Returns { line, hint } per row — hint is a short fix suggestion (or null
  // when nothing useful can be said).
  const renderIncompat = (f) => {
    if (f.compat.reason === 'api') {
      return {
        line: `  ${f.name}  (declares api=${f.compat.declaredApi}, runtime supports up to ${f.compat.runtimeApi})`,
        hint: `    fix: upgrade claude-newsline, or edit ${f.path} to declare api=${f.compat.runtimeApi} or lower`,
      };
    }
    if (/not defined in file/.test(f.compat.reason)) {
      return {
        line: `  ${f.name}  (${f.compat.reason})`,
        hint: `    fix: add a \`feed_${f.name}() { … }\` definition to ${f.path}`,
      };
    }
    if (/^unreadable/.test(f.compat.reason)) {
      return {
        line: `  ${f.name}  (${f.compat.reason})`,
        hint: `    fix: chmod a+r ${f.path} (or remove if it shouldn't be a plugin)`,
      };
    }
    return { line: `  ${f.name}  (${f.compat.reason})`, hint: null };
  };

  if (!verbose) {
    console.log('Built-in feeds:');
    for (const r of rows.filter(r => r.isBuiltin)) {
      const note = r.source.includes('overridden') ? '  (overridden by user feed)' : '';
      console.log(`  ${r.name}${note}`);
    }
    if (userFeeds.length) {
      console.log('');
      console.log('User feeds:');
      for (const { name } of userFeeds) console.log(`  ${name}`);
      console.log('');
      console.log(`(from ${paths.userFeedsDir})`);
    } else {
      console.log('');
      console.log(`No user feeds. Scaffold one with:  claude-newsline --new-feed <name>`);
      console.log(`(writes to ${paths.userFeedsDir})`);
    }
    // Incompat section only renders when there's something to say.
    // Placement: below user feeds (or the empty-state hint) so the happy-
    // path info isn't pushed down by rare failures, but still visible to
    // anyone scanning the full output. Prefix with "⚠" to catch the eye
    // without color escapes (which --list-feeds doesn't otherwise use).
    if (incompatFeeds.length) {
      console.log('');
      console.log('⚠ Incompatible plugins (not loaded):');
      for (const f of incompatFeeds) {
        const { line, hint } = renderIncompat(f);
        console.log(line);
        if (hint) console.log(hint);
      }
    }
    return 0;
  }

  // Verbose: group by category so a list of 10+ feeds scans at a glance.
  // Stable order — categories appear in first-seen order (built-ins before
  // user plugins, by scan order). Sorting alphabetically would re-home
  // built-ins below "Custom" on a default install; not what users expect.
  const byCategory = new Map();
  for (const r of rows) {
    if (!byCategory.has(r.category)) byCategory.set(r.category, []);
    byCategory.get(r.category).push(r);
  }
  // These keys get the two-column render; everything else ("license",
  // custom author-added keys) prints below verbatim. Kept as a single list
  // so adding a recognized key touches one place.
  const RECOGNIZED_KEYS = ['description', 'version', 'author', 'homepage', 'api'];
  for (const [category, catRows] of byCategory.entries()) {
    console.log(`[${category}]`);
    for (const r of catRows) {
      console.log(`  ${r.name}  [${r.source}]`);
      for (const k of RECOGNIZED_KEYS) {
        if (r.meta[k]) console.log(`    ${k.padEnd(12)} ${r.meta[k]}`);
      }
      // Surface uncommon keys the author included. The auto-attached
      // `source=` is suppressed (already in the header bracket) and
      // `category=` is suppressed (it's the group header).
      for (const k of Object.keys(r.meta)) {
        if (RECOGNIZED_KEYS.includes(k) || k === 'source' || k === 'category') continue;
        console.log(`    ${k.padEnd(12)} ${r.meta[k]}`);
      }
      console.log('');
    }
  }
  // Same incompat block as the non-verbose path, rendered under a trailing
  // group header so it sits after all loadable-category groups.
  if (incompatFeeds.length) {
    console.log('[⚠ Incompatible — not loaded]');
    for (const f of incompatFeeds) {
      console.log(`  ${f.name}  [user: ${f.path}]`);
      if (f.compat.reason === 'api') {
        console.log(`    reason       declares api=${f.compat.declaredApi}, runtime supports up to ${f.compat.runtimeApi}`);
        console.log(`    fix          upgrade claude-newsline, or edit the plugin to declare api=${f.compat.runtimeApi} or lower`);
      } else {
        console.log(`    reason       ${f.compat.reason}`);
        if (/not defined in file/.test(f.compat.reason)) {
          console.log(`    fix          add a feed_${f.name}() { … } definition`);
        }
      }
      // Still show the plugin's self-reported description/version so the
      // user can identify which file this is without opening it.
      if (f.meta.description) console.log(`    description  ${f.meta.description}`);
      if (f.meta.version)     console.log(`    version      ${f.meta.version}`);
      console.log('');
    }
  }
  return 0;
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.error) {
    console.error(`Error: ${opts.error}`);
    usage();
    return 2;
  }
  if (opts.help) { usage(); return 0; }
  // --fixture is only meaningful with --test-feed; a bare --fixture is a
  // user error we should surface rather than silently discard.
  if (opts.fixture !== null && opts.testFeed === null) {
    console.error('Error: --fixture requires --test-feed <name>');
    return 2;
  }
  if (opts.listFeeds) return listFeeds(opts.listFeedsVerbose);
  if (opts.newFeed !== null) return newFeed(opts);
  if (opts.testFeed !== null) return testFeed(opts);
  if (opts.uninstall) return uninstall();
  return install(opts);
}

// Exported for test.sh. Guarded so importing doesn't trigger main().
if (require.main === module) {
  main().then(code => process.exit(code || 0)).catch(err => {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  });
}

// Only things test.sh actually imports land here. Internal helpers are used
// only within this file and don't need to be exposed.
module.exports = {
  stripSuffix,
  invertOnly,
  shellQuote,
  validateColor,
  validateRotation,
  validateMotion,
  reconcileEnv,
  colorize,
  colorDepth,
  isValidRedditEntry,
  wizardInitialValues,
  scanUserFeeds,
  scanAllUserFeeds,
  parseFeedMeta,
  pluginApiVersion,
  newFeedTemplate,
  FEED_NAME_REGEX,
  FEED_API_VERSION,
  ALL_FEEDS,
  PALETTE,
  DEFAULT_ROTATION_SEC,
  DEFAULT_SCROLL_SEC,
  QUICK_SCROLL_SEC,
  MOTION_OPTIONS,
  DEFAULT_REDDIT_SUB,
  OWNED_ENV_KEYS,
  MARKER_VAR,
  MARKER_VALUE,
  MAX_BACKUPS,
  escapeRegex,
  listBackups,
};
