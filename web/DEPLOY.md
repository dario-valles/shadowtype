# Shadowtype Website — Deploy

The Shadowtype site is a **static** marketing + SEO site. There is no backend, no
licensing, no payments, and **no secrets** — the Cloudflare Worker in `web/worker`
only serves the files in `web/worker/public` (plus a `www` → apex redirect and a few
security headers). You can deploy it to Cloudflare Workers, Cloudflare Pages, GitHub
Pages, or any static host.

## Option A — Cloudflare Worker (current setup)

The Worker (`web/worker/src/index.ts`) serves `./public` via Workers Assets.

```sh
cd web/worker
bun install
bun run deploy        # wrangler deploy
```

`wrangler.toml` already contains everything needed:

- `name`, `main`, `compatibility_date`
- `[[routes]]` for the apex + `www` custom domains
- `[assets]` pointing at `./public`
- one non-secret var, `SITE_ORIGIN`, used by the `www` → apex redirect

No `wrangler secret put` is required.

Local preview:

```sh
cd web/worker
bun run dev           # wrangler dev — serves public/ locally
```

## Option B — Cloudflare Pages / GitHub Pages

The `web/worker/public` directory is a plain static bundle. Point any static host at it:

- **Cloudflare Pages:** create a Pages project with the build output set to
  `web/worker/public` (no build command needed).
- **GitHub Pages:** publish `web/worker/public` as the site root.

If you drop the Worker, the only behavior you lose is the in-Worker `www` → apex
301 redirect and the security headers; configure those at the host/CDN level instead.

## Open Graph images

The per-page social cards under `public/assets/og-*.png` are generated from SVGs by
the scripts in `web/worker/scripts`. To regenerate after editing headlines:

```sh
cd web/worker
bun run og            # gen-og.ts (needs rsvg-convert) + inject-og.ts
```

## Tests

```sh
cd web/worker
bun test
```
