# Deploy to GitHub Pages (the indie default)

The site is plain static files — no build step — so GitHub Pages is the cheapest, fastest host. Free, free HTTPS, custom domain supported, deploys on git push.

## Path A — Project site (recommended)

Lives at `https://<user>.github.io/<repo>/`.

1. **Initialise the repo and push:**
   ```bash
   cd my-app-website
   git init
   git add . && git commit -m "feat(site): initial one-pager"
   git branch -M main
   git remote add origin git@github.com:<user>/<repo>.git
   git push -u origin main
   ```

2. **Enable Pages** on GitHub: **Settings → Pages → Source → Deploy from branch → `main` → `/ (root)` → Save.**

3. **First deploy in ~1 minute.** GitHub serves from a CDN, HTTPS is automatic via Let's Encrypt.

## Path B — User/Org site

Lives at `https://<user>.github.io/`. Same workflow, but the repo **must be named** `<user>.github.io`. Only one per user/org.

## Path C — GitHub Actions deploy (if you ever add a build step)

You don't need this for a SwiftUI-For-Web site (no build), but if you later add a bundler or pre-render step, drop this into `.github/workflows/pages.yml`:

```yaml
name: Deploy to GitHub Pages
on:
  push: { branches: [main] }
permissions: { contents: read, pages: write, id-token: write }
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: "${{ steps.deployment.outputs.page_url }}"
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
      - uses: actions/configure-pages@983d7736d9b0ae728b81ab479565c72886d7745b # v5
      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa # v3
        with: { path: . }
      - id: deployment
        uses: actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e # v4
```

Then in **Settings → Pages → Source**, switch from "Deploy from branch" to "GitHub Actions".

## Custom domain (`yourapp.com` / `yourapp.dev`)

1. **Buy the domain** anywhere — Namecheap, Cloudflare Registrar (cheapest, no markup), Porkbun. Avoid GoDaddy.

2. **Add a `CNAME` file at the repo root** with the bare domain (one line, no protocol, no trailing slash):
   ```
   notesjournal.app
   ```
   Commit and push. GitHub picks it up; you can also set it via **Settings → Pages → Custom domain** which writes the same file.

3. **Set DNS records** at your registrar. For an **apex domain** like `notesjournal.app`, add four A records pointing at GitHub's Pages IPs:
   ```
   A    @    185.199.108.153
   A    @    185.199.109.153
   A    @    185.199.110.153
   A    @    185.199.111.153
   AAAA @    2606:50c0:8000::153
   AAAA @    2606:50c0:8001::153
   AAAA @    2606:50c0:8002::153
   AAAA @    2606:50c0:8003::153
   ```
   And a `www` CNAME so `www.notesjournal.app` resolves too:
   ```
   CNAME www  <user>.github.io
   ```

   For a **subdomain only** (e.g. `app.notesjournal.dev`), skip the A records — just one CNAME:
   ```
   CNAME app  <user>.github.io
   ```

4. **Wait for DNS propagation.** Usually 5–30 minutes; can take up to 24h. Check with:
   ```bash
   dig +short notesjournal.app
   ```
   It should return GitHub's IPs.

5. **Enable HTTPS** on the Pages settings page. GitHub provisions a Let's Encrypt cert automatically once DNS resolves. Tick **"Enforce HTTPS"** — required for the View Transitions API and other modern features.

## Deploy gotchas

| Symptom | Cause | Fix |
|---------|-------|-----|
| 404 on every asset | Project site URL is `/<repo>/` but `index.html` references `/main.js` | Use relative paths (`./main.js`) or set `<base href="/<repo>/">` |
| "Domain's DNS record could not be retrieved" on GitHub | DNS not propagated yet, or wrong record type | `dig` and verify; wait |
| HTTPS toggle is grayed out | DNS not pointing at GitHub yet | Fix DNS first, then HTTPS option unlocks |
| Page works on first load, broken on refresh of `/about` | SPA-style routes don't exist on GH Pages | This template is a one-pager; if you add routes, use hash-based (`#about`) or a `404.html` redirect |
| Custom domain reverts after push | You set it via UI but `CNAME` file isn't in the repo | Commit the `CNAME` file — UI changes write it but pushes can overwrite |

## Alternative hosts (one-line comparison)

GitHub Pages is the default — but if the developer asks:

- **Cloudflare Pages** — same workflow, faster global CDN, free tier more generous, custom domain DNS lives in the same dashboard. Recommend if they already use Cloudflare.
- **Netlify / Vercel** — same workflow with auto-deploy from push. Edge functions if you ever need them. Free tier fine for indie sites.
- **Your own VPS** — overkill for a one-pager. Don't recommend unless they explicitly want it.

## References

- [GitHub Pages docs](https://docs.github.com/en/pages)
- [Configuring a custom domain](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site)
