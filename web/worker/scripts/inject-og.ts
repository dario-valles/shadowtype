/* Injects og:image + twitter image/title/description into the marketing-page
   heads. SEO pages get their own per-page card (assets/og-<slug>.png, built by
   gen-og.ts) and reuse their existing og:title/og:description for the twitter
   tags. Legal pages get a minimal block pointing at the generic homepage card.
   Idempotent: skips any page that already has an og:image. Run from web/worker:
     bun scripts/inject-og.ts */
import { readFileSync, writeFileSync } from "fs";

const BASE = "https://shadowtype.app/assets";
const grab = (h: string, re: RegExp) => (h.match(re) || [])[1] || "";

const SEO = [
  "shadowtype-vs-cotypist", "shadowtype-vs-cotabby", "shadowtype-vs-apple-intelligence",
  "cotypist-alternative", "cotabby-alternative", "apple-intelligence-alternative",
  "grammarly-alternative-mac", "local-ai-autocomplete-mac", "offline-text-prediction-macos",
  "private-autocomplete-mac", "ai-writing-assistant-mac",
];
const LEGAL = ["terms", "privacy"];

function injectSeo(slug: string) {
  const f = `public/${slug}.html`;
  let h = readFileSync(f, "utf8");
  if (/property="og:image"/.test(h)) { console.log(`skip  ${slug} (already has og:image)`); return; }
  const ogTitle = grab(h, /property="og:title" content="([^"]*)"/);
  const ogDesc = grab(h, /property="og:description" content="([^"]*)"/);
  const img = `${BASE}/og-${slug}.png`;
  const block =
`  <meta property="og:site_name" content="Shadowtype" />
  <meta property="og:locale" content="en_US" />
  <meta property="og:image" content="${img}" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:type" content="image/png" />
  <meta property="og:image:alt" content="${ogTitle} — 100% on-device, one-time, no subscription." />
  <meta name="twitter:title" content="${ogTitle}" />
  <meta name="twitter:description" content="${ogDesc}" />
  <meta name="twitter:image" content="${img}" />
  <meta name="twitter:image:alt" content="${ogTitle}" />`;
  const anchor = '<meta name="twitter:card" content="summary_large_image" />';
  if (!h.includes(anchor)) { console.error(`FAIL  ${slug}: no twitter:card anchor`); return; }
  h = h.replace(anchor, anchor + "\n" + block);
  writeFileSync(f, h);
  console.log(`ok    ${slug}  → og-${slug}.png`);
}

function injectLegal(slug: string) {
  const f = `public/${slug}.html`;
  let h = readFileSync(f, "utf8");
  if (/property="og:image"/.test(h)) { console.log(`skip  ${slug} (already has og:image)`); return; }
  const title = grab(h, /<title>([\s\S]*?)<\/title>/).trim();
  const desc = grab(h, /name="description" content="([^"]*)"/);
  const url = grab(h, /rel="canonical" href="([^"]*)"/);
  const img = `${BASE}/og.png`;
  const block =
`  <meta property="og:type" content="website" />
  <meta property="og:site_name" content="Shadowtype" />
  <meta property="og:title" content="${title}" />
  <meta property="og:description" content="${desc}" />
  <meta property="og:url" content="${url}" />
  <meta property="og:image" content="${img}" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:type" content="image/png" />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:image" content="${img}" />`;
  const anchor = '<link rel="stylesheet" href="/landing.css" />';
  if (!h.includes(anchor)) { console.error(`FAIL  ${slug}: no stylesheet anchor`); return; }
  h = h.replace(anchor, anchor + "\n" + block);
  writeFileSync(f, h);
  console.log(`ok    ${slug}  → og.png (generic)`);
}

SEO.forEach(injectSeo);
LEGAL.forEach(injectLegal);
console.log("\ndone.");
