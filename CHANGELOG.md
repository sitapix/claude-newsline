# Changelog

All notable changes to claude-newsline. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows [SemVer](https://semver.org/) — under 1.0.0, behaviour changes still ship as patch
releases when they're bug fixes against the documented or specified intent.

## [0.2.1] — 2026-05-05

### Security

- **`writeSettings` now preserves the existing `settings.json` file mode and defaults to `0o600` on
  first install.** Previously, the atomic write-then-rename inherited the umask (typically `0o644`),
  which silently widened permissions for users who had `chmod 600 ~/.claude/settings.json` to
  protect API keys stored in the `env` block. If you'd hardened your settings.json before installing
  any prior version, run `chmod 600 ~/.claude/settings.json` once after upgrading; subsequent
  installs and uninstalls now keep whatever mode you set.

### Fixed

- **`bin/xml-to-json.js`: CDATA blocks no longer truncate item parsing.** A non-greedy `<item>...</item>`
  regex ran on raw XML, so a literal `</item>` inside CDATA stopped the match early — a single CDATA
  block could silently empty the rest of the feed. CDATA is now placeholder-substituted before any
  regex matches, restored verbatim at field-emit time.
- **`bin/xml-to-json.js`: entities inside CDATA are no longer decoded.** Per XML spec, CDATA disables
  entity processing; the previous unwrap-then-decode order incorrectly turned `<![CDATA[Tom &amp; Jerry]]>`
  into `Tom & Jerry`. Entities outside CDATA still decode normally.
- **`bin/claude-newsline.js`: `listBackups` regex escape was broken.** A misplaced `]` closed the
  character class early, making `escapeRegex` a no-op for normal filenames. `settings.json`'s `.`
  was therefore unescaped at lookup time, so a look-alike file (`settingsXjson.bak.123`) could
  match. Now uses a named `escapeRegex` helper covering the full meta-char set; both `escapeRegex`
  and `listBackups` are exported for unit testing.
- **`bin/statusline.sh`: stale `$CACHE_FILE.new.<pid>` orphans are now reaped.** A SIGKILL between
  awk completion and the final `mv` (to `.pending` or the live cache) used to leak the staging file
  forever, eventually tripping `uninstall`'s `rmdir cache/` with `ENOTEMPTY`. Reaper mirrors the
  existing `.buckets.*` reaper — same `STALE_REAP_SEC=60` budget, same gating on entry to the
  refresh branch.

### Internal

- Removed dead `[ "$dwell" -lt 0 ] && dwell=0` guard in `bin/statusline.sh`. The earlier
  `SCROLL_SEC` clamp and `guard_num ROTATION_SEC` already keep `dwell >= 1`; comment now spells
  out the invariants in place of the unreachable check.

## [0.2.0] — 2026 earlier

Adds support for FEED_PARSER=xml plugins (RSS/Atom via the bundled zero-dep
`bin/xml-to-json.js`), the per-frame-derived scroll viewport, the
`@clack/prompts` setup wizard, the user-feeds plugin directory, and
`--new-feed` / `--test-feed` / `--list-feeds` tooling. See the README for the
full feature surface.

## [0.1.1] — 2026 earlier

First public release: rotating headline appended to the user's existing
`statusLine.command`, HN + Reddit + Lobsters built-in feeds, install/uninstall
via `npx`.
