# ChowSA marketing site

Static site for ChowSA — landing page, privacy policy, terms, account deletion.
Designed to deploy on GitHub Pages with zero build step.

## Files

```
site/
├── index.html           ← main landing page
├── privacy.html         ← privacy policy (POPIA + Google Data Safety)
├── terms.html           ← terms of service
├── delete-account.html  ← in-app + email deletion instructions
└── assets/
    └── img/             ← screenshots
```

## Deploying to GitHub Pages

### One-time setup

1. Create a new public repo on GitHub: **`chowsa-site`** (anything is fine; name affects the URL).
2. From a terminal in this folder:

   ```bash
   cd "G:/Claude/ChowSA/marketing/site"
   git init
   git add -A
   git commit -m "Initial ChowSA marketing site"
   git branch -M main
   git remote add origin https://github.com/SumaraiJack/chowsa-site.git
   git push -u origin main
   ```

3. On GitHub: **repo → Settings → Pages**.
   - Source: **Deploy from a branch**
   - Branch: **main** · folder: **/ (root)**
   - Save. First build takes ~1 minute.

4. Site URL will be: **`https://sumaraijack.github.io/chowsa-site/`**

### Updating later

```bash
cd "G:/Claude/ChowSA/marketing/site"
git add -A
git commit -m "tweak: <what changed>"
git push
```

GitHub rebuilds within ~60s.

## Custom domain (optional, later)

When you're ready to point a real domain (e.g. `chowsa.co.za`) at this:

1. Buy the domain (Domains.co.za, ~R150/year).
2. Add DNS records pointing at GitHub Pages:
   - `A` records → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   - `CNAME` for `www` → `sumaraijack.github.io`
3. In repo → Settings → Pages, enter the custom domain. GitHub creates a `CNAME` file in the repo.
4. Tick **Enforce HTTPS** once the cert provisions (15–60 min).

## URLs the Play Console listing will reference

- **Privacy Policy** → `https://sumaraijack.github.io/chowsa-site/privacy.html`
- **Account Deletion** → `https://sumaraijack.github.io/chowsa-site/delete-account.html`
- **Marketing site** → `https://sumaraijack.github.io/chowsa-site/`

Wire these into Play Console → Store Listing + App Content.

## Updating the screenshots

All images live in `assets/img/`. Replace any file with the same filename and the
site updates on next push. Recommended max width 1080px (Android phone width).

## Local preview

Just open `index.html` in a browser. No build tool, no dependencies, no Node.
Everything is self-contained except Google Fonts (loaded over the network).
