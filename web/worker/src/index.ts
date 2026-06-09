// Shadowtype static site — a tiny Cloudflare Worker that serves the marketing + SEO pages in ./public.
// Shadowtype is free and open source; there is no backend (no licensing, payments, email, or admin). The
// Worker only (1) redirects the www host to the apex (canonical host, SEO) and (2) adds security headers,
// then falls through to the ASSETS binding which serves the static files. No secrets are required.

import { Hono } from "hono";

export interface Env {
  // Workers Assets — the static landing + SEO site (./public).
  ASSETS: Fetcher;
  // Canonical apex origin (e.g. https://shadowtype.app). Used by the www → apex redirect.
  SITE_ORIGIN: string;
}

const app = new Hono<{ Bindings: Env }>();

// www → apex 301 (canonical host, SEO). The www host is bound to this Worker via a custom_domain route
// in wrangler.toml; any request arriving on it is permanently redirected to SITE_ORIGIN with the path +
// query preserved, ahead of asset serving so nothing else sees the www host.
app.use("*", async (c, next) => {
  const host = (c.req.header("host") ?? "").toLowerCase();
  if (host.startsWith("www.")) {
    const target = new URL(c.env.SITE_ORIGIN);
    const url = new URL(c.req.url);
    url.protocol = target.protocol;
    url.host = target.host; // host includes any non-443 port; path + search untouched
    return c.redirect(url.toString(), 301);
  }
  await next();
});

// Security headers on every response (defense-in-depth for a static site).
app.use("*", async (c, next) => {
  await next();
  c.header("X-Content-Type-Options", "nosniff");
  c.header("Referrer-Policy", "strict-origin-when-cross-origin");
  c.header("X-Frame-Options", "DENY");
  c.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
});

// Everything → the static site (index.html, *.html, assets).
app.all("*", (c) => c.env.ASSETS.fetch(c.req.raw));

export default app;
