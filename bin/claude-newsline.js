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
const readline = require('readline');

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
// (chained suffix). Quoted paths that embedded a literal ' via the POSIX
// '\'' trick are NOT matched — those are exceedingly rare (a $HOME with an
// apostrophe) and would need manual cleanup on uninstall.
//
// Ownership marker: `CLAUDE_NEWSLINE=<ver> bash '<path>'`. Per-command env
// prefix (scoped to the bash invocation, not exported) so it's a pure tag.
// MARKER_PREFIX is optional in the regex so pre-marker installs still strip
// cleanly on upgrade. Bump MARKER_VALUE to let a future installer recognize
// its own previous shape.
const MARKER_VAR = 'CLAUDE_NEWSLINE';
const MARKER_VALUE = 'v1';
const MARKER_PREFIX = `(?:${MARKER_VAR}=[A-Za-z0-9._-]+\\s+)?`;
const QUOTED_PATH = "'[^'\\n]*/claude-newsline\\.sh'";
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
    uninstall: false,
    yes: false,
    listFeeds: false,
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
  };
  const SWITCHES = {
    '--no-labels':       o => { o.showLabels = false; },
    '--labels':          o => { o.showLabels = true; },
    '--uninstall':       o => { o.uninstall = true; },
    '--yes':             o => { o.yes = true; },
    '-y':                o => { o.yes = true; },
    '--non-interactive': o => { o.yes = true; },
    '--list-feeds':      o => { o.listFeeds = true; },
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
  --uninstall        Remove claude-newsline from settings.json
  --yes, -y          Skip confirmation prompt (required on non-TTY stdin)
  --list-feeds       List available feeds and exit
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
function writeSettings(p, obj) {
  let target = p;
  try {
    if (fs.lstatSync(p).isSymbolicLink()) {
      target = fs.realpathSync(p);
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
  const tmp = tmpSibling(target);
  const data = JSON.stringify(obj, null, 2) + '\n';
  try {
    fs.writeFileSync(tmp, data);
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

// List all existing .bak.* files for a settings path, sorted ascending by
// the filename. The suffix is a fixed-width Unix timestamp (with an
// optional collision-counter tail like `.bak.<ts>.1`), so lex sort
// coincides with chronological order — the last element is the newest.
function listBackups(settingsPath) {
  const dir = path.dirname(settingsPath);
  const base = path.basename(settingsPath);
  try {
    return fs.readdirSync(dir)
      .filter(f => f.startsWith(`${base}.bak.`))
      .sort();
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

// Map wizard/flag opts → env patch. Keys returned MUST be in OWNED_ENV_KEYS.
// This is the single source of truth for "what env does install() write" —
// describePlan prints from this map, applyPlan routes it through reconcileEnv.
//
// Invariant: a value of `undefined` in the returned patch means "delete this
// key from .env" (revert to the runtime default in statusline.sh). This is
// produced by `--FLAG ""` / `--FLAG=""` (explicit clear) and by the `--labels`
// switch (undo a prior `--no-labels`). reconcileEnv is the ONLY correct way
// to apply this patch — a naive `Object.assign` would write the string
// "undefined" into .env on JSON.stringify. REDDIT_SUBS/ROTATION_SEC at the
// runtime default are also elided so users who accept defaults don't end up
// with a redundant .env key.
//
// `null` in opts means "flag not passed" → no key in the patch at all; `''`
// means "flag passed with empty value" → undefined sentinel → delete.
function buildEnvUpdates(opts) {
  const env = {};
  // --only and --disable both target FEEDS_DISABLED. --only wins when both
  // are passed (more specific: "these feeds only"). Each handles the explicit-
  // clear case: `--only ""` is meaningless (can't enable zero feeds), so we
  // treat `--only ""` the same as `--disable ""` (clear the key). Inverting
  // a full --only list (e.g. every feed selected) also yields an empty
  // disabled set; the null→'' collapse at the end routes that to the delete
  // sentinel too, so wizard "select all" and flag "clear" converge.
  let feedsDisabled = null;
  if (opts.only !== null) {
    feedsDisabled = opts.only === '' ? '' : invertOnly(opts.only);
  } else if (opts.disable !== null) {
    feedsDisabled = opts.disable;
  }
  if (feedsDisabled !== null) {
    env.NEWSLINE_FEEDS_DISABLED = feedsDisabled === '' ? undefined : feedsDisabled;
  }
  if (opts.color !== null) {
    env.NEWSLINE_COLOR_FEED = opts.color === '' ? undefined : opts.color;
  }
  // --no-labels writes '0'. --labels uses the `undefined` sentinel so
  // reconcileEnv clears any existing key and the runtime default (labels on)
  // takes over. Without the sentinel, `--labels` couldn't undo a prior
  // `--no-labels` outside the wizard path.
  if (opts.showLabels === false)      env.NEWSLINE_SHOW_LABELS = '0';
  else if (opts.showLabels === true)  env.NEWSLINE_SHOW_LABELS = undefined;
  if (opts.separator !== null) {
    env.NEWSLINE_LABEL_SEP = opts.separator === '' ? undefined : opts.separator;
  }
  if (opts.redditSubs !== null) {
    if (opts.redditSubs === '') {
      env.NEWSLINE_REDDIT_SUBS = undefined;
    } else {
      const subs = normalizeRedditSubs(opts.redditSubs);
      if (subs && subs !== DEFAULT_REDDIT_SUB) env.NEWSLINE_REDDIT_SUBS = subs;
    }
  }
  // opts.rotation is normalized to number|''|null by install() — '' skips
  // validateRotation so the clear sentinel survives into the patch here.
  if (opts.rotation === '') {
    env.NEWSLINE_ROTATION_SEC = undefined;
  } else if (opts.rotation !== null && opts.rotation !== DEFAULT_ROTATION_SEC) {
    env.NEWSLINE_ROTATION_SEC = String(opts.rotation);
  }
  // Motion presets. '' and 'slide' both clear both keys (runtime slide at
  // SCROLL_SEC=5 is the default). 'static' sets SCROLL=0 and clears
  // SCROLL_SEC (meaningless when scroll is off — leaving a stray value would
  // only confuse a user reading their settings.json). 'quick' clears SCROLL
  // (runtime → 1) and writes SCROLL_SEC=3. null means no motion flag was
  // passed — leave both keys alone so a non-wizard re-install with other
  // flags doesn't silently wipe a user's hand-edited SCROLL_SEC.
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
// as no-highlight and confuse the user).
function wizardInitialValues(currentEnv, rotationOptions, separatorOptions) {
  const env = currentEnv || {};
  const disabled = new Set(parseCsv(env.NEWSLINE_FEEDS_DISABLED || ''));
  const initialFeeds = ALL_FEEDS.filter(f => !disabled.has(f));
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
    feeds: initialFeeds.length ? initialFeeds : ALL_FEEDS,
    redditSubs: env.NEWSLINE_REDDIT_SUBS || DEFAULT_REDDIT_SUB,
    color: NAMED_COLORS.includes(env.NEWSLINE_COLOR_FEED) ? env.NEWSLINE_COLOR_FEED : 'amber',
    showLabels: env.NEWSLINE_SHOW_LABELS !== '0',
    separator: separatorOptions.includes(env.NEWSLINE_LABEL_SEP) ? env.NEWSLINE_LABEL_SEP : ' \u2022 ',
    rotation: rotationKnown ? rotationN : DEFAULT_ROTATION_SEC,
    motion,
  };
}

// First-run interactive wizard. Mutates `opts` in place and returns true if
// it ran — caller uses the return to skip the trailing confirm() since the
// wizard itself is the confirmation. Dynamic import because @clack/prompts
// is ESM-only; --help / --yes / non-TTY paths never reach here.
// `currentEnv` is the existing settings.env so a re-run pre-fills answers.
async function runWizard(opts, currentEnv = {}) {
  let clack;
  try {
    clack = await import('@clack/prompts');
  } catch (_) {
    console.error('Warning: @clack/prompts not available; skipping wizard.');
    console.error('Re-run with explicit flags (--disable / --color / --separator / --no-labels) or install deps.');
    return false;
  }
  const { intro, outro, multiselect, select, text, note, cancel, isCancel } = clack;

  const bail = (result) => {
    if (isCancel(result)) {
      cancel('Aborted.');
      process.exit(1);
    }
    return result;
  };

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
  const SEPARATOR_OPTIONS = [' \u2022 ', ' \u203a ', ' \u00b7 ', ' \u2014 '];
  const initial = wizardInitialValues(currentEnv, ROTATION_OPTIONS, SEPARATOR_OPTIONS);
  // A "fresh" install (no prior config) gets a one-line explainer. Reconfigures
  // skip it — the returning user already knows what the tool is.
  const isFreshInstall = !currentEnv || Object.keys(currentEnv).length === 0;

  intro('\x1b[1mclaude-newsline setup\x1b[0m');
  if (isFreshInstall) {
    note(
      'Rotating news headlines in your Claude Code status line.\n' +
      'Cmd/Ctrl-click a headline to open the story.',
      'What this does',
    );
  }

  const feeds = bail(await multiselect({
    message: 'Which feeds should rotate?',
    required: true,
    initialValues: initial.feeds,
    options: [
      { label: 'Hacker News', value: 'hn',       hint: 'front page top 30' },
      { label: 'Reddit',      value: 'reddit',   hint: `pick subreddits next — max ${MAX_REDDIT_SUBS}` },
      { label: 'Lobsters',    value: 'lobsters', hint: 'hottest links (programming & security)' },
    ],
  }));

  // Subreddit input only shown when Reddit is enabled. Validation mirrors
  // the CLI flag (format + count cap) so the user sees the same errors
  // here rather than hitting them post-wizard in install().
  let redditSubs = null;
  if (feeds.includes('reddit')) {
    // Skip the formats lesson for returning users who already have valid
    // subs configured — they've seen it before and it's noise on a
    // reconfigure. Only fresh installs (or installs with invalid subs) get
    // the teaching block.
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
    const raw = bail(await text({
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
    }));
    redditSubs = normalizeRedditSubs(raw);
  }

  // Palette entries are derived from PALETTE (i.e. from colors.sh) so adding
  // a color to the sh side automatically appears here. The appended non-
  // palette rows are a curated picks of ANSI_BY_NAME names + "none".
  const titleCase = s => s.charAt(0).toUpperCase() + s.slice(1);
  const colorChoices = [
    ...Object.keys(PALETTE).map(k => [titleCase(k), k]),
    ['Bold white',  'bold_white'],
    ['Dim yellow',  'dim_yellow'],
    ['Dim (faded)', 'dim'],
    ['No color',    'none'],
  ];
  const color = bail(await select({
    message: 'Headline accent color?',
    initialValue: initial.color,
    options: colorChoices.map(([label, value]) => ({
      label,
      value,
      hint: colorize(`HN \u2022 ${SAMPLE_TITLE}`, value),
    })),
  }));

  // One combined step for "what does each headline look like?" — the prior
  // two-step flow (show-label? then separator?) made the user answer a config
  // question before they'd seen the result. Here each option is the whole
  // rendered shape, so the hint *is* the answer.
  //
  // The sentinel `__bare__` means "no label" (same as showLabels=false). Any
  // other value is the separator string itself. This lets one select carry
  // both decisions without smuggling a second form field through clack.
  const HEADLINE_FORMAT_OPTIONS = [
    { label: 'Just the title', value: '__bare__' },
    { label: `HN \u2022 Title`, value: ' \u2022 ' },
    { label: `HN \u203a Title`, value: ' \u203a ' },
    { label: `HN \u00b7 Title`, value: ' \u00b7 ' },
    { label: `HN \u2014 Title`, value: ' \u2014 ' },
  ];
  const initialFormat = initial.showLabels ? initial.separator : '__bare__';
  const headlineFormat = bail(await select({
    message: 'Headline format?',
    initialValue: initialFormat,
    options: HEADLINE_FORMAT_OPTIONS.map(({ label, value }) => ({
      label,
      value,
      hint: value === '__bare__'
        ? colorize(SAMPLE_TITLE, color)
        : colorize(`HN${value}${SAMPLE_TITLE}`, color),
    })),
  }));
  const showLabels = headlineFormat !== '__bare__';
  const separator = showLabels ? headlineFormat : null;

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
  const rotation = bail(await select({
    message: 'How long should each headline stay on screen?',
    initialValue: initial.rotation,
    // Drop "(default)" markers — clack's initialValue highlight already
    // signals the pre-selected option. Hand-edited values that aren't in
    // BASE_ROTATION_OPTIONS get injected upstream so Enter-through preserves them.
    options: ROTATION_OPTIONS.map((sec) => ({
      label: `${sec}s`.padEnd(5),
      value: sec,
      hint: perMin(sec),
    })),
  }));

  // Motion preview hints. At 1 FPS (Claude Code's refresh floor) the scroll
  // is a stepped slide — we can't animate inside a hint, so each scroll
  // option shows TWO frame slices joined by `→` to imply motion. Slide and
  // quick differ by stride: quick's two frames span further apart on the
  // tape, so the arrow visibly bridges more distance — a visual proxy for
  // "fewer frames in the same total motion."
  const labelForSample = showLabels ? `HN${separator}` : '';
  const SAMPLE_A = `${labelForSample}${SAMPLE_TITLE}`;
  const SAMPLE_B = `${showLabels ? `Lobsters${separator}` : ''}Postgres 18 adds lateral joins`;
  const SAMPLE_SEP = '  |  ';
  const tape = SAMPLE_A + SAMPLE_SEP + SAMPLE_B;
  const SLIDE_WIDTH = 26;
  const sliceTape = (offset) => tape.slice(offset, offset + SLIDE_WIDTH);
  // Slide: two frames near the middle of the transition (smaller stride).
  // Quick: two frames bracketing more of the tape (larger stride → reads as
  // "bigger jump per frame"). The numbers below are visual estimates tuned
  // to the 26-char window; they don't need to correspond to actual tick counts.
  const mid = SAMPLE_A.length;
  const slideFrameA = sliceTape(Math.max(0, mid - SLIDE_WIDTH + 6));
  const slideFrameB = sliceTape(Math.max(0, mid - 6));
  const quickFrameA = sliceTape(Math.max(0, mid - SLIDE_WIDTH + 12));
  const quickFrameB = sliceTape(Math.max(0, mid + 2));
  const slideDemo = `${slideFrameA} \u2192 ${slideFrameB}`;
  const quickDemo = `${quickFrameA} \u2192 ${quickFrameB}`;

  // The 1 FPS caveat is load-bearing context (explains why "smooth" isn't
  // a preset) but drags the select message out. Surface it as a short note
  // before the prompt instead — readers scan it once and move on.
  note(
    'Claude Code refreshes at 1 FPS, so the scroll is a stepped slide.\n' +
    'The preset picks how many 1s ticks the slide takes.',
    'About motion',
  );
  const motion = bail(await select({
    message: 'How should headlines transition?',
    initialValue: initial.motion,
    options: [
      {
        label: 'Static \u2014 no animation',
        value: 'static',
        hint: colorize(SAMPLE_A, color),
      },
      {
        label: `Slide  \u2014 ${DEFAULT_SCROLL_SEC} frames`,
        value: 'slide',
        hint: colorize(slideDemo, color),
      },
      {
        label: `Quick  \u2014 ${QUICK_SCROLL_SEC} frames (snappier)`,
        value: 'quick',
        hint: colorize(quickDemo, color),
      },
    ],
  }));

  // Final preview. The product IS rotation + transition, so show it: render
  // the starting headline, optionally a mid-transition frame for scroll
  // motions, and the next headline labeled with when it arrives. The prefix
  // glyph renders dim (matches runtime NEWSLINE_COLOR_PREFIX default); the
  // headline renders in the chosen color.
  const previewPrefix = colorize('\u039e ', 'dim');
  const headA = showLabels ? `HN${separator}${SAMPLE_TITLE}` : SAMPLE_TITLE;
  const headB = showLabels
    ? `Lobsters${separator}Postgres 18 adds lateral joins`
    : 'Postgres 18 adds lateral joins';
  const previewFrames = [];
  previewFrames.push(`${previewPrefix}${colorize(headA, color)}   ${colorize('now', 'dim')}`);
  if (motion !== 'static') {
    const previewScrollFrame = (motion === 'quick' ? quickFrameB : slideFrameB);
    previewFrames.push(`${previewPrefix}${colorize(previewScrollFrame, color)}   ${colorize('sliding', 'dim')}`);
  }
  previewFrames.push(`${previewPrefix}${colorize(headB, color)}   ${colorize(`in ${rotation}s`, 'dim')}`);
  const transitionSummary = motion === 'static'
    ? `switches every ${rotation}s`
    : `${motion === 'quick' ? QUICK_SCROLL_SEC : DEFAULT_SCROLL_SEC}-frame slide every ${rotation}s`;
  note(
    previewFrames.join('\n') + '\n\n' + transitionSummary,
    'Preview',
  );

  outro('Ready to install.');

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
  return true;
}

function confirm(question, defaultYes = true) {
  return new Promise(resolve => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const hint = defaultYes ? '[Y/n]' : '[y/N]';
    rl.question(`${question} ${hint} `, ans => {
      rl.close();
      const a = ans.trim().toLowerCase();
      if (a === '') return resolve(defaultYes);
      resolve(a.startsWith('y'));
    });
  });
}

// All filesystem paths install/uninstall touch. One place so the two
// functions can't disagree about "where does claude-newsline live".
function installPaths() {
  const cfgDir = configDir();
  return {
    cfgDir,
    settingsPath: path.join(cfgDir, 'settings.json'),
    scriptDest:   path.join(cfgDir, 'claude-newsline.sh'),
    colorsDest:   path.join(cfgDir, 'colors.sh'),
    scriptSrc:    path.join(__dirname, 'statusline.sh'),
    colorsSrc:    path.join(__dirname, 'colors.sh'),
    cacheDir:     path.join(cfgDir, 'cache'),
    cacheFile:    path.join(cfgDir, 'cache', 'feed-titles.txt'),
  };
}

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

function describePlan(plan) {
  // Fresh configs have no statusLine at all. Claude Code's built-in default
  // is minimal (no cwd/model/git/cost unless the user configured them), so
  // the user isn't "losing" a rich line — but they also aren't getting one.
  // Call this out so a first-time user knows they can combine the headline
  // with the richer statusLine examples in the Claude Code docs.
  if (!plan.existingCmd) {
    console.log('');
    console.log('\x1b[33m! No existing statusLine detected.\x1b[0m');
    console.log('  After install, your status line will be only the rotating headline.');
    console.log('  For model / cwd / git / cost info alongside it, set up a base statusLine');
    console.log('  first (see https://code.claude.com/docs/en/statusline) and re-run —');
    console.log('  this installer chains the headline after whatever is already there.');
    console.log('');
  }
  if (isSettingsNoop(plan)) {
    console.log('Configuration already matches — no changes to settings.json.');
    console.log('(Installed scripts will still be refreshed.)');
    return;
  }
  console.log('Planned changes to settings.json:');
  if (plan.existingCmd && plan.existingCmd !== plan.newCmd) {
    console.log(`  .statusLine.command: ${JSON.stringify(plan.existingCmd)}`);
    console.log(`                    → ${JSON.stringify(plan.newCmd)}`);
  } else if (!plan.existingCmd) {
    console.log(`  .statusLine.command = ${JSON.stringify(plan.newCmd)}  (new)`);
  }
  if (!plan.hadRefresh) {
    console.log('  .statusLine.refreshInterval = 1  (was unset) — enables scroll animation; ~60 shell invocations/minute');
  }
  const existingEnv = (plan.settings && plan.settings.env) || {};
  for (const [k, v] of Object.entries(plan.envUpdates)) {
    if (v === undefined) {
      if (k in existingEnv) console.log(`  .env.${k}: cleared (revert to runtime default)`);
    } else if (existingEnv[k] !== v) {
      console.log(`  .env.${k} = ${JSON.stringify(v)}`);
    }
  }
}

function applyPlan(plan, paths) {
  fs.mkdirSync(paths.cfgDir, { recursive: true });
  const bak = backup(paths.settingsPath);
  if (bak) console.log(`✓ Backed up → ${bak}`);

  // Transactional: stage both scripts into sibling tmp files, atomically
  // patch settings.json, then rename the tmps into place. rename(2) on the
  // same filesystem is atomic; copyFileSync is not, so writing directly to
  // scriptDest could leave a half-written file if we crash mid-copy.
  // settings.json goes first so any failure before this point leaves the
  // old state fully intact; failures after it leave stale scripts that the
  // next install rewrites cleanly. Tmp files are unlinked on any throw.
  const scriptTmp = tmpSibling(paths.scriptDest);
  const colorsTmp = tmpSibling(paths.colorsDest);
  const cleanup = () => {
    for (const p of [scriptTmp, colorsTmp]) {
      try { fs.unlinkSync(p); } catch (_) { /* ignore ENOENT */ }
    }
  };

  try {
    fs.copyFileSync(paths.scriptSrc, scriptTmp);
    fs.chmodSync(scriptTmp, 0o755);
    fs.copyFileSync(paths.colorsSrc, colorsTmp);

    const settings = plan.settings;
    settings.statusLine = settings.statusLine || {};
    settings.statusLine.type = 'command';
    settings.statusLine.command = plan.newCmd;
    if (!plan.hadRefresh) settings.statusLine.refreshInterval = 1;

    settings.env = reconcileEnv(settings.env, plan.envUpdates, plan.clearStaleEnv);
    if (Object.keys(settings.env).length === 0) delete settings.env;

    writeSettings(paths.settingsPath, settings);
    fs.renameSync(scriptTmp, paths.scriptDest);
    fs.renameSync(colorsTmp, paths.colorsDest);
  } catch (e) {
    cleanup();
    throw e;
  }

  console.log(`✓ Installed script → ${paths.scriptDest}`);
  console.log(`✓ Patched ${paths.settingsPath}`);
}

async function install(opts) {
  const paths = installPaths();
  if (!fs.existsSync(paths.scriptSrc) || !fs.existsSync(paths.colorsSrc)) {
    throw new Error('Installer files missing. Reinstall the package.');
  }

  // Interactive wizard on fresh TTY installs only. --yes, non-TTY, and any
  // explicit config flag keep the flag-driven path so scripts and CI
  // never hit a hung stdin waiting for input.
  let wizardRan = false;
  // Read once. The wizard pre-fills from settings.env; planInstall consumes
  // the same object. A re-run is a reconfigure, not a reset.
  const settings = readSettings(paths.settingsPath);

  if (!opts.yes && process.stdin.isTTY && !hasExplicitConfig(opts)) {
    wizardRan = await runWizard(opts, settings.env || {});
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
  describePlan(plan);

  // Wizard answers count as explicit confirmation — don't double-prompt.
  if (!opts.yes && !wizardRan) {
    if (!process.stdin.isTTY) {
      console.error('\nError: stdin is not a TTY; refusing to auto-confirm.');
      console.error('Re-run with --yes (or -y) to skip the confirmation prompt.');
      return 1;
    }
    const ok = await confirm('\nProceed?');
    if (!ok) { console.log('Aborted.'); return 1; }
  }

  applyPlan(plan, paths);
  console.log('\nDone. Restart Claude Code (or start a new session) to see the headline.');
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

  for (const p of [paths.scriptDest, paths.colorsDest, paths.cacheFile]) {
    // unlink → catch ENOENT instead of existsSync+unlink: collapses the
    // TOCTOU window and tolerates the file being removed underneath us.
    try {
      fs.unlinkSync(p);
      console.log(`✓ Removed ${p}`);
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
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

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.error) {
    console.error(`Error: ${opts.error}`);
    usage();
    return 2;
  }
  if (opts.help) { usage(); return 0; }
  if (opts.listFeeds) { console.log(`Available feeds: ${ALL_FEEDS.join(', ')}`); return 0; }
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
};
