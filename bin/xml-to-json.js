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
  const unwrapCdata = s => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1');

  // Single-pass combined regex is what makes double-escape handling
  // correct: `&amp;lt;` must decode once to the literal 4-char `&lt;`, not
  // all the way to `<`. .replace(/g) scans left-to-right and does NOT
  // re-scan replaced content, so `&amp;` matches first, becomes `&`, the
  // cursor advances past the replacement, and `lt;` never matches. One
  // combined sweep does everything; splitting this into per-entity
  // `.replace()` calls would re-scan after `&amp;` → `&` and over-decode.
  // Alternation order inside the regex is irrelevant because the named
  // entities don't share prefixes.
  const NAMED = { lt: '<', gt: '>', quot: '"', apos: "'", amp: '&' };
  const decodeNumeric = v => v > 0x10FFFF ? '' : String.fromCodePoint(v);
  const decode = s => s
    .replace(/&#(\d+);/g,           (_, n) => decodeNumeric(parseInt(n, 10)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_, n) => decodeNumeric(parseInt(n, 16)))
    .replace(/&(lt|gt|quot|apos|amp);/g, (_, e) => NAMED[e]);

  // C0-strip after decode so `&#10;` (newline entity) gets squashed to
  // space here — jq @tsv downstream would otherwise split a title with
  // a literal \n across two cache records.
  const clean = s => decode(unwrapCdata(s))
    .replace(/[\x00-\x1f\x7f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  const ITEM_RE = /<(item|entry)\b[^>]*>([\s\S]*?)<\/\1\s*>/gi;
  const TITLE_RE = /<title\b[^>]*>([\s\S]*?)<\/title\s*>/i;
  const LINK_CONTENT_RE = /<link\b[^>]*>([\s\S]+?)<\/link\s*>/i;
  const LINK_TAG_RE = /<link\b[^>]*>/gi;
  const attr = (tag, name) => {
    const re = new RegExp(`\\b${name}\\s*=\\s*(["'])([^"']*)\\1`, 'i');
    const m = tag.match(re);
    return m ? clean(m[2]) : '';
  };
  const bestHref = body => {
    let fallback = '';
    for (const m of body.matchAll(LINK_TAG_RE)) {
      const tag = m[0];
      const href = attr(tag, 'href');
      if (!href) continue;
      const rel = attr(tag, 'rel').toLowerCase();
      if (rel === 'alternate' || rel === '') return href;
      if (!fallback) fallback = href;
    }
    return fallback;
  };
  // RSS <description> and Atom <summary> both mean "short blurb"; unify
  // under the `description` JSON key so a single jq filter handles either.
  const DESC_RE = /<(?:description|summary)\b[^>]*>([\s\S]*?)<\/(?:description|summary)\s*>/i;

  const items = [];
  for (const m of xml.matchAll(ITEM_RE)) {
    const body = m[2];
    const tMatch = body.match(TITLE_RE);
    const title = tMatch ? clean(tMatch[1]) : '';
    // Content-style <link>URL</link> (RSS, tolerant-Atom) first; fall
    // back to Atom href links. Prefer rel="alternate" / no rel over
    // rel="self", which usually points at the feed/API entry, not the story.
    let link = '';
    const lc = body.match(LINK_CONTENT_RE);
    if (lc) link = clean(lc[1]);
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
