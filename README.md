# claude-newsline

[![npm](https://img.shields.io/npm/v/@sitapix/claude-newsline?color=cb3837&logo=npm)](https://www.npmjs.com/package/@sitapix/claude-newsline)
[![test](https://github.com/sitapix/claude-newsline/actions/workflows/test.yml/badge.svg)](https://github.com/sitapix/claude-newsline/actions/workflows/test.yml)
[![node](https://img.shields.io/node/v/@sitapix/claude-newsline)](https://nodejs.org)
[![license](https://img.shields.io/npm/l/@sitapix/claude-newsline)](LICENSE)
[![for Claude Code](https://img.shields.io/badge/for%20Claude%20Code-D97757?logo=claude&logoColor=white)](https://claude.com/claude-code)

<a href="demo/demo.gif"><img src="demo/demo.gif" alt="claude-newsline rotating through Hacker News, Lobsters, and r/programming headlines in the Claude Code status line"></a>

A rotating news ticker for your [Claude Code](https://claude.com/claude-code) status line. Hacker News, r/programming, and Lobsters are on by default. Point it at anything else with a few lines of shell. Your existing `statusLine` stays put and this runs after it. Cmd-click (or Ctrl-click) any headline to open the story.

## Install

```bash
npx @sitapix/claude-newsline
```

Shows what it'll change in `~/.claude/settings.json`, asks once, writes. Re-running is idempotent. On a TTY with no flags, you get a wizard (which feeds, color, rotation speed); everything it asks is also a flag.

```bash
npx @sitapix/claude-newsline --only hn               # keep just one feed
npx @sitapix/claude-newsline --disable reddit        # drop one
npx @sitapix/claude-newsline --color bold_magenta    # name, raw SGR, or "none"
npx @sitapix/claude-newsline --rotation 30           # seconds per headline (default 20)
npx @sitapix/claude-newsline --motion static         # just switch, no scroll (also: slide, quick)
npx @sitapix/claude-newsline --yes                   # skip the prompt (CI)
npx @sitapix/claude-newsline --uninstall
```

`CLAUDE_CONFIG_DIR` is honored if set.

Reddit rate-limits anonymous JSON. When a refresh tick gets a 429, that feed sits out until the next one and the last good cache line keeps showing. More subs in `--reddit-subs` means more requests per refresh, which is why the 15-entry cap exists.

## Add your own feed

Drop a `<name>.sh` file in `~/.claude/claude-newsline/feeds/` and it joins the rotation. The runtime globs the directory on every refresh, so new plugins show up on the next tick without a rebuild or a reinstall. Filename maps to function name: `nyt.sh` must define `feed_nyt()`.

> **Trust boundary.** Plugins in this directory are sourced as shell code every refresh — same trust model as a dotfile or a `~/.zshrc` include. Audit third-party plugins before dropping them in, and don't chmod the directory world-writable. If a plugin fails to load, `NEWSLINE_DEBUG=1` reports it under `user feeds skipped:` with the source error.

Minimal JSON feed:

```sh
# ~/.claude/claude-newsline/feeds/nyt.sh
FEED_META_nyt='description=New York Times top stories
version=0.1.0
author=you'
feed_nyt() {
  LABEL='NYT'
  URL='https://example.com/nyt-feed.json'
  # jq emits one <label><TAB><title><TAB><url> row per headline.
  # $default is bound to LABEL — use it as-is or promote based on the title.
  # URLs MUST be http:// or https:// — other schemes render without OSC 8.
  JQ='.articles[] | [$default, .title, .url] | @tsv'
}
```

`FEED_META_<name>` is optional. When present, `NEWSLINE_DEBUG=1` prints each declared key (`description`, `version`, `author`, `homepage`) plus an auto-attached `source=<path>` line so you can audit what's loaded and from where.

A user file named the same as a built-in (`hn.sh`, `reddit.sh`, `lobsters.sh`) replaces that feed's function — last definition wins. That's the escape hatch when you want to tweak a built-in without forking.

Restart Claude Code (or let the cache expire) and the new source rotates in alongside the built-ins. Override the feeds directory with `NEWSLINE_FEEDS_DIR` if you want to keep plugins in a dotfiles repo.

### RSS/Atom feeds

Most news sites, blogs, GitHub release Atoms, and status pages only publish XML. Set `FEED_PARSER=xml` and the bundled helper (`xml-to-json.js`, zero-dep Node) transforms the body into a JSON array of `{title, link, description}` before your `JQ` runs. Same jq expressiveness as a JSON feed.

```sh
# ~/.claude/claude-newsline/feeds/bbc.sh
FEED_META_bbc='description=BBC News top stories
api=2
category=News'
feed_bbc() {
  LABEL='BBC'
  URL='http://feeds.bbci.co.uk/news/rss.xml'
  FEED_PARSER=xml
}
```

With no `JQ` declared, a default filter (`.[] | [$default, .title, .link] | @tsv`) is used. Override it the same way you would for a JSON feed — e.g. skip items whose description contains "sponsored":

```sh
JQ='.[] | select(.description | test("sponsored"; "i") | not) | [$default, .title, .link] | @tsv'
```

`xml-to-json` picks `<link>url</link>` (RSS) or the `href` attribute of `<link .../>` (Atom) automatically, decodes HTML entities (`&amp;` → `&`, `&#8217;` → `'`), and unwraps CDATA. RSS `<description>` and Atom `<summary>` are unified under the `description` key. Declare `api=2` in `FEED_META` so older runtimes skip the plugin cleanly instead of calling a branch they don't understand.

### Test a feed before you trust it

`claude-newsline --test-feed <name>` runs one fetch cycle for a single feed. You get the URL, the HTTP code, how many rows jq emitted, a sample of the output, and a warning if any row emits a non-`http(s)` URL. The scheme guard would drop those at render time anyway, but it's easier to fix the jq than to wonder why a headline isn't clickable:

```
$ claude-newsline --test-feed nyt
Testing feed: nyt

  URL:      https://example.com/nyt-feed.json
  HTTP:     200  (0.142s, 4827 bytes)
  jq:       12 rows
  Sample:
    NYT • White House announces new policy → https://www.nytimes.com/…
    NYT • Markets open higher on earnings  → https://www.nytimes.com/…

✓ OK.
```

For parameterized feeds (Reddit, or any plugin using `FEED_PARAMS`), the command iterates each CSV entry and reports per-entry:

```
$ claude-newsline --test-feed reddit
Testing feed: reddit (parameterized via REDDIT_SUBS="rust,golang")

[1/2] r/rust
  URL:      https://www.reddit.com/r/rust/top.json?t=day&limit=30
  HTTP:     200  (0.612s, 41028 bytes)
  jq:       27 rows
  ...

✓ All 2 entries OK.
```

The `env` block from `settings.json` is merged into the test run, so parameterized feeds resolve against the same config your installed status line uses. Override ad-hoc: `NEWSLINE_REDDIT_SUBS=rust claude-newsline --test-feed reddit`.

### Parameterized feeds (one plugin, N fetches)

Same shape as the built-in Reddit feed: declare `FEED_PARAMS_<name>` pointing at an env var, and the dispatch loop splits that CSV and calls your feed once per entry.

```sh
# ~/.claude/claude-newsline/feeds/jira.sh
feed_jira() {
  _project=$1
  case "$_project" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  LABEL="JIRA/$_project"
  URL="https://company.atlassian.net/rest/api/2/search?jql=project=$_project"
  JQ='.issues[] | [$default, .fields.summary, "https://company.atlassian.net/browse/\(.key)"] | @tsv'
}
# Resolve the user-facing env var to the internal name FEED_PARAMS points at.
# Without this line, NEWSLINE_JIRA_PROJECTS in your settings.json is ignored —
# the dispatch loop reads $JIRA_PROJECTS, not $NEWSLINE_JIRA_PROJECTS.
JIRA_PROJECTS="${NEWSLINE_JIRA_PROJECTS:-}"
FEED_PARAMS_jira='JIRA_PROJECTS'
```

Then set `NEWSLINE_JIRA_PROJECTS=ENG,INFRA` in Claude Code's `settings.json` under `"env"` (or export it in your shell). Each entry becomes one HTTP request per refresh — keep the list small, same reasoning as the Reddit cap.

### Debugging

`NEWSLINE_DEBUG=1 bash ~/.claude/claude-newsline.sh` prints the loaded-feeds map, each feed's metadata, and the source file each came from:

```
feeds enabled: hn reddit lobsters nyt jira

feed metadata:
  hn
    description  Hacker News front page (top 30)
    source       built-in
  nyt
    description  New York Times top stories
    version      0.1.0
    author       you
    source       /Users/you/.claude/claude-newsline/feeds/nyt.sh

user feeds dir:   /Users/you/.claude/claude-newsline/feeds
  nyt          ← /Users/you/.claude/claude-newsline/feeds/nyt.sh
  jira         ← /Users/you/.claude/claude-newsline/feeds/jira.sh
```

Files that fail to source, don't define the expected `feed_<name>` function, or have a filename that isn't a legal shell identifier (leading digit, hyphen) are skipped silently. The rest of the rotation keeps working. Filename validation is `[A-Za-z_][A-Za-z0-9_]*`.

The jq filter is sandboxed by jq itself (no filesystem, no network). The shell function runs inline with `statusline.sh` and has the same trust level as anything else in `~/.claude/` — don't source `.sh` files you haven't read. URLs that come out of the jq filter are validated at render time: anything that isn't `http://` or `https://` still rotates into view but does not get a clickable OSC 8 hyperlink (defense against terminal URL-handler argument injection, e.g. CVE-2023-46321).

## Tuning

Override any of these via env (shell profile or `settings.json` under `"env"`). All user-facing env vars are namespaced with `NEWSLINE_` so they can't collide with host-shell vars (`PREFIX`, `CACHE_FILE`, and `SCROLL` are generic enough to belong to other tools):

| Variable | Default | Effect |
| --- | --- | --- |
| `NEWSLINE_FEEDS_DISABLED` | (none) | Comma-separated feeds to skip |
| `NEWSLINE_REDDIT_SUBS` | `programming` | Comma-separated reddit entries. See `--reddit-subs` for the three accepted shapes. Capped at 15. |
| `NEWSLINE_CACHE_CHUNK` | `1` | Lines per feed per round-robin pass when building the cache. Default `1` strictly alternates sources (HN, Reddit, Lobsters, HN, …); higher values cluster same-source entries together. |
| `NEWSLINE_ROTATION_SEC` | `20` | Seconds per headline |
| `NEWSLINE_SCROLL` | `1` | Set to `0` to disable the scroll transition |
| `NEWSLINE_SCROLL_SEC` | `5` | Scroll duration in frames (Claude Code refreshes at 1 FPS, so the scroll is always a stepped slide: N discrete frames, not a smooth glide) |
| `NEWSLINE_REFRESH_SEC` | `600` | How often feeds are re-fetched |
| `NEWSLINE_MAX_TITLE` | `80` | Truncation point (bytes). ASCII = 1 byte/col, CJK ≈ 3 bytes/2 cols, so this is ≈80 cols for English and ≈48 cols for Japanese. |
| `NEWSLINE_COLOR_FEED` | `dim_yellow` | Color name, raw SGR (`38;5;208`), or `none` |
| `NEWSLINE_PREFIX` | `Ξ ` | Brand glyph rendered to the left of every headline (set `""` to disable) |
| `NEWSLINE_COLOR_PREFIX` | `dim` | Color for the prefix glyph |
| `NEWSLINE_SHOW_LABELS` | `1` | Set to `0` to hide the source label (just the title) |
| `NEWSLINE_LABEL_SEP` | ` • ` | Separator between label and title |
| `NEWSLINE_HYPERLINKS` | `auto` | `always` / `never` / `auto` |

Scroll smoothness is capped by `statusLine.refreshInterval`. Claude Code's minimum is 1 second (1 FPS). The installer sets it to `1` unless you already have one. At 1 FPS a 5s scroll is 5 discrete frames, which reads as a stepped slide rather than a smooth glide.

### Precedence

Config is resolved in the standard dotenv order, highest to lowest:

1. Shell environment (anything exported in `~/.zshrc`, `~/.bashrc`, your CI runner, etc.)
2. `settings.json` under `"env"` (what the installer writes)
3. Script default (the fallback baked into `statusline.sh`)

Shell env wins on the theory that the deploy environment knows more than the app does. Same ordering as [motdotla/dotenv](https://github.com/motdotla/dotenv) and Docker Compose. If something isn't applying the way you expect, run `NEWSLINE_DEBUG=1 bash ~/.claude/claude-newsline.sh` to see every knob's resolved value and where it came from.

## Terminals

Titles are wrapped in OSC 8 hyperlinks. Support is tracked at [Alhadis/OSC8-Adoption](https://github.com/Alhadis/OSC8-Adoption/) if you want the current compatibility matrix. macOS Terminal.app prints the escapes as literal text, so the runtime detects it and skips them there. Force with `NEWSLINE_HYPERLINKS=always` or `never`.

[`NO_COLOR`](https://no-color.org), [`FORCE_COLOR`](https://force-color.org), and Claude Code's `FORCE_HYPERLINK` are all honored. `NO_COLOR=1` suppresses every ANSI color escape (including the reset). `FORCE_HYPERLINK=0`/`1` trumps our `NEWSLINE_HYPERLINKS` knob.

## Requirements

Node 18+, plus `jq`, `curl`, and `bash 3.2+`. Default on macOS and most Linux distros.

## Contributing a built-in feed

> Just want a feed for yourself? [Add your own feed](#add-your-own-feed) covers the no-fork path. This section is for upstreaming a new built-in.

Adding a built-in is a one-file change. Each feed is a shell function in `bin/statusline.sh` that sets three vars:

- `LABEL`: short tag shown before the title (`HN`, `Lobsters`).
- `URL`: a JSON endpoint, or an RSS/Atom feed paired with `FEED_PARSER=xml`.
- `JQ`: a jq filter emitting one line per headline as `label<TAB>title<TAB>url`. For XML feeds, it runs over `xml-to-json`'s `[{title, link, description}, …]` output instead of the raw body.

Every `REFRESH_SEC` (default 600), the runtime runs, per feed:

```sh
curl -fsS --max-time 5 "$URL" | jq -r --arg default "$LABEL" "$JQ"
```

The jq filter is the parser. There's no schema detection — open the endpoint once, see what you're working with, write the jq. `$default` is bound to `LABEL`; a filter can pass it through unchanged or rewrite it per-item (`feed_hn` promotes `Show HN:` / `Ask HN:` prefixes into their own labels at refresh time).

Lobsters is the simplest. Top-level array, title and URL already present:

```sh
feed_lobsters() {
  LABEL='Lobsters'
  URL='https://lobste.rs/hottest.json'
  JQ='.[] | select(.title != null) | [$default, .title, .short_id_url] | @tsv'
}
```

HN's Algolia API nests under `.hits[]` and you build the URL yourself:

```sh
feed_hn() {
  LABEL='HN'
  URL='https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30'
  JQ='.hits[] | [$default, .title, "https://news.ycombinator.com/item?id=\(.objectID)"] | @tsv'
}
```

The real `feed_hn` in `bin/statusline.sh` captures titles starting with `Show HN:` / `Ask HN:` / `Tell HN:` and promotes the prefix into its own label (so you see `Show HN` as the tag, not `HN`). The snippet above is the teaching version.

To add your own:

1. `curl <url> | jq .` and find the array of items.
2. Write a jq filter that extracts one tab-separated row (`label`, `title`, `url`) per item.
3. Dry-run it before touching the codebase:
   ```sh
   curl -fsS 'https://your-api.example/feed.json' \
     | jq -r --arg default 'MyFeed' '.items[] | [$default, .title, .url] | @tsv'
   ```
   If you see `MyFeed<TAB>title<TAB>url` lines, the feed will work.
4. Drop the `feed_<name>()` function into `bin/statusline.sh` and append `<name>` to the `ALL_FEEDS='...'` line at the top of the same file. The installer parses that line at load (`loadAllFeeds` in `bin/claude-newsline.js`), so JS stays in sync. Add a matching `FEED_META_<name>='description=…\nsource=built-in'` block next to the function so `NEWSLINE_DEBUG=1` can describe your feed. `--only <name>` and `--disable <name>` work straight away. The interactive wizard has a hardcoded feed picker in `runWizard` (`bin/claude-newsline.js`, look for the `multiselect({ message: 'Which feeds should rotate?' })` block), so if you want the new feed to show up there too, add a `{ label, value, hint }` entry.

### Parameterized built-ins

If your feed takes a user-supplied list (like Reddit does with subreddits), declare it next to the function:

```sh
feed_myfeed() {
  _entry=$1                                # one list entry, e.g. "rust"
  case "$_entry" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;        # reject bad entries
  esac
  LABEL="my/$_entry"
  URL="https://api.example/$_entry.json"
  JQ='.items[] | [$default, .title, .url] | @tsv'
}
# User-facing env var → internal name FEED_PARAMS points at. Required for
# the CSV to propagate: the dispatch loop reads $MYFEED_ENTRIES, not
# $NEWSLINE_MYFEED_ENTRIES. Built-ins do this in statusline.sh's CONFIG
# block (see REDDIT_SUBS); user plugins declare it in the plugin file.
MYFEED_ENTRIES="${NEWSLINE_MYFEED_ENTRIES:-}"
FEED_PARAMS_myfeed='MYFEED_ENTRIES'
```

The dispatch loop in `refresh_all_feeds` sees `FEED_PARAMS_myfeed`, splits `$MYFEED_ENTRIES` on `,`, and calls `feed_myfeed` once per entry. Return non-zero to skip a bad entry without aborting the rest. See `feed_reddit` in `bin/statusline.sh` for the reference implementation.

Built-ins declare the `NEWSLINE_*`-to-internal binding in the CONFIG block at the top of `bin/statusline.sh` (e.g. `REDDIT_SUBS="${NEWSLINE_REDDIT_SUBS:-programming}"`) — put new built-in bindings there, not in the feed function, so they run before any refresh.

## Testing

```bash
./test.sh                             # full suite, no network
RUN_ONLY=reddit ./test.sh             # only sections matching an ERE
RUN_ONLY='install|uninstall' ./test.sh
```

Tests run under a fresh `mktemp -d`, so your real `~/.claude/` is never touched. CI runs the same script on every push ([workflow](.github/workflows/test.yml)).

A few sections piggyback on state set up earlier (primed cache, mocked `bin/`). A narrow `RUN_ONLY` that works on its own can fail here — widen the pattern until setup is included.

## Contributing

PRs and bug reports both welcome. Thanks for reading this far.

1. Fork, branch from `main`.
2. `./test.sh` stays green.
3. If you're adding a built-in feed, the pattern lives in [Contributing a built-in feed](#contributing-a-built-in-feed). If the feed is just for you, [Add your own feed](#add-your-own-feed) skips the fork.
4. Open the PR. CI takes it from there.

`statusline.sh` runs every second. A handful of things in there look wrong at first glance and are deliberate; the comments above each one say why.

## License

MIT.
