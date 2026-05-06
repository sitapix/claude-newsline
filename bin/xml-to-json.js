#!/usr/bin/env node
// xml-to-json — extract a JSON array of {title, link, description} objects
// from an RSS or Atom feed on stdin. Zero deps (Node 18+). Invoked from
// statusline.sh's _parse_body when a plugin declares FEED_PARSER=xml; the
// caller pipes the output into jq, which gets the same field access and
// filtering expressiveness it has for JSON feeds.
//
// Always emits valid JSON. Empty input / garbage input → `[]`, so the
// downstream jq never sees a malformed document. A compromised feed can't
// crash the refresh loop (would leave the cache stale) or smuggle control
// bytes: titles/links/descriptions are stripped of C0 bytes AND normalize
// runs of whitespace (including tab/newline) to a single space here, so
// the JSON carries fields that are safe to feed straight to `jq @tsv`.

'use strict';

let xml = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { xml += chunk; });
// EPIPE fires when downstream jq exits early (SIGPIPE). Swallow only that;
// other stdin errors shouldn't be silently hidden.
process.stdin.on('error', e => { if (e.code !== 'EPIPE') throw e; });
process.stdin.on('end', () => {
  // CDATA handling — placeholder substitution.
  //
  // Earlier impl did `unwrapCdata` once, top-level, before ITEM_RE / TITLE_RE
  // ran on the result. Two correctness defects fell out:
  //
  //   1. CDATA may legitimately contain `</item>` text. The regex parser
  //      can't see CDATA boundaries, so the non-greedy ITEM_RE stopped at
  //      the FIRST literal `</item>` — even one inside CDATA — and
  //      truncated parsing for the rest of the document. A single CDATA
  //      block could silently empty an entire feed.
  //
  //   2. Per XML spec, CDATA disables entity processing. The unwrap-then-
  //      decode order meant a literal `&amp;` inside CDATA decoded to `&`,
  //      which is wrong (the feed author wrote literal text and meant it).
  //
  // Both fall away if CDATA blocks never appear as XML markup to the regex
  // pipeline. Replace each `<![CDATA[...]]>` with a unique placeholder
  // before any regex runs; restore at field-emit time, marked verbatim so
  // entity decode skips that segment. Placeholders use Private-Use
  // Unicode (U+E000..) — ITEM_RE / TITLE_RE / LINK_RE can't match against
  // them, and clean()'s C0/C1 strip leaves PUA alone.
  const CDATA_OPEN = '\uE000';
  const CDATA_CLOSE = '\uE001';
  const cdataSlots = [];
  const xmlSafe = xml.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, (_, body) => {
    const i = cdataSlots.length;
    cdataSlots.push(body);
    return `${CDATA_OPEN}${i}${CDATA_CLOSE}`;
  });
  const PLACEHOLDER_RE = new RegExp(`${CDATA_OPEN}(\\d+)${CDATA_CLOSE}`, 'g');

  // Single-pass combined regex is what makes double-escape handling
  // correct: every `&...;` token must decode exactly once. .replace(/g)
  // scans left-to-right and does NOT re-scan replaced content — the
  // cursor advances past the matched region in the original string, so
  // a token produced by an earlier replacement (`&` from `&amp;`,
  // `&` from `&#38;`) cannot fuse with the trailing literal characters
  // into a second match.
  //
  // Splitting this into per-encoding `.replace()` calls (one for `&#NN;`,
  // one for `&#xHH;`, one for named) WOULD re-scan after each pass and
  // over-decode: `&amp;lt;` (correct: `&lt;`) survives because both halves
  // are named, but `&#38;lt;` would go numeric→`&lt;`→named→`<`. One
  // combined alternation matches numeric, hex, and named in the same pass.
  // Alternation order is irrelevant — the leading `&` and trailing `;` are
  // anchors and the inner alternations don't share prefixes.
  const NAMED = { lt: '<', gt: '>', quot: '"', apos: "'", amp: '&' };
  const decodeNumeric = v => v > 0x10FFFF ? '' : String.fromCodePoint(v);
  const ENTITY_RE = /&(?:#(\d+)|#x([0-9a-fA-F]+)|(lt|gt|quot|apos|amp));/g;
  const decode = s => s.replace(ENTITY_RE, (_, dec, hex, name) => {
    if (dec !== undefined) return decodeNumeric(parseInt(dec, 10));
    if (hex !== undefined) return decodeNumeric(parseInt(hex, 16));
    return NAMED[name];
  });

  // Restore CDATA placeholders to verbatim text. Entities inside CDATA
  // are NOT decoded — that's the spec. Walking matchAll lets us treat
  // verbatim segments as separate concatenation, so an `&amp;` inside
  // CDATA survives a subsequent decode() pass on the surrounding text.
  const expandWithVerbatim = (s) => {
    if (!cdataSlots.length) return decode(s);
    let out = '';
    let last = 0;
    for (const m of s.matchAll(PLACEHOLDER_RE)) {
      out += decode(s.slice(last, m.index));
      out += cdataSlots[Number(m[1])] || '';
      last = m.index + m[0].length;
    }
    out += decode(s.slice(last));
    return out;
  };

  // C0-strip after expand so `&#10;` (newline entity) gets squashed to
  // space here — jq @tsv downstream would otherwise split a title with
  // a literal \n across two cache records.
  const clean = s => expandWithVerbatim(s)
    .replace(/[\x00-\x1f\x7f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  // URLs go through a stricter cleaner: line-wrapped CDATA in <link> elements
  // (common in pretty-printed feeds) would otherwise leave a literal space
  // in the URL, which the OSC 8 hyperlink wrapper then ships to the terminal
  // verbatim — most terminals split on the space and the link silently
  // breaks. Strip whitespace + controls outright instead of collapsing.
  const cleanUrl = s => expandWithVerbatim(s)
    .replace(/[\x00-\x20\x7f]+/g, '')
    .trim();

  const ITEM_RE = /<(item|entry)\b[^>]*>([\s\S]*?)<\/\1\s*>/gi;
  const TITLE_RE = /<title\b[^>]*>([\s\S]*?)<\/title\s*>/i;
  const LINK_CONTENT_RE = /<link\b[^>]*>([\s\S]+?)<\/link\s*>/i;
  const LINK_TAG_RE = /<link\b[^>]*>/gi;
  // Pre-compiled per-attribute regexes. bestHref is the only caller and it
  // only ever asks for these two; constructing `new RegExp` per lookup (the
  // prior shape) compiled the same pattern once per <link> tag in the feed
  // — wasteful, and pretended to be more general than the code is.
  const HREF_RE = /\bhref\s*=\s*(["'])([^"']*)\1/i;
  const REL_RE  = /\brel\s*=\s*(["'])([^"']*)\1/i;
  // Two cleaners: href values use cleanUrl (no whitespace tolerance); rel
  // is a token attribute compared as text. matchAttrUrl applies cleanUrl;
  // matchAttr keeps the prose-friendly clean.
  const matchAttr = (tag, re) => {
    const m = tag.match(re);
    return m ? clean(m[2]) : '';
  };
  const matchAttrUrl = (tag, re) => {
    const m = tag.match(re);
    return m ? cleanUrl(m[2]) : '';
  };
  const bestHref = body => {
    let fallback = '';
    for (const m of body.matchAll(LINK_TAG_RE)) {
      const tag = m[0];
      const href = matchAttrUrl(tag, HREF_RE);
      if (!href) continue;
      const rel = matchAttr(tag, REL_RE).toLowerCase();
      if (rel === 'alternate' || rel === '') return href;
      if (!fallback) fallback = href;
    }
    return fallback;
  };
  // RSS <description> and Atom <summary> both mean "short blurb"; unify
  // under the `description` JSON key so a single jq filter handles either.
  const DESC_RE = /<(?:description|summary)\b[^>]*>([\s\S]*?)<\/(?:description|summary)\s*>/i;

  const items = [];
  // Walk the placeholder-substituted source so CDATA-internal markup (like a
  // literal `</item>`) can't truncate item bodies. Field-level extraction
  // below also runs against the substituted body; clean()/cleanUrl() restore
  // the verbatim CDATA text at the last possible step.
  for (const m of xmlSafe.matchAll(ITEM_RE)) {
    const body = m[2];
    const tMatch = body.match(TITLE_RE);
    const title = tMatch ? clean(tMatch[1]) : '';
    // Content-style <link>URL</link> (RSS, tolerant-Atom) first; fall
    // back to Atom href links. Prefer rel="alternate" / no rel over
    // rel="self", which usually points at the feed/API entry, not the story.
    let link = '';
    const lc = body.match(LINK_CONTENT_RE);
    if (lc) link = cleanUrl(lc[1]);
    if (!link) {
      link = bestHref(body);
    }
    if (!title || !link) continue;
    const dMatch = body.match(DESC_RE);
    const description = dMatch ? clean(dMatch[1]) : null;
    items.push({ title, link, description });
  }
  process.stdout.write(JSON.stringify(items) + '\n');
});
