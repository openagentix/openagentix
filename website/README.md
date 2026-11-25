# Documentation site

Docusaurus site. Content comes from `docs/` (the diary, guide and features from `docs/diary/`, decision records from `docs/decisions/`, the roadmap and the contributing page from `docs/`). The `docs` workflow (`.github/workflows/docs.yml`) builds it and deploys it to GitHub Pages on every push to `main` that touches `docs/`, `website/` or the workflow.

## Build and check locally

```sh
cd website
npm ci
npm run build          # fails on any broken link or anchor
npm run serve          # http://localhost:3000/openagentix/
npm run check:mermaid  # parses every Mermaid diagram under docs/
```

The social card `static/img/social-card.png` is made from `static/img/social-card.svg` with `npm run social-card`.
Console screenshots in `docs/assets/console/` are made with `console/scripts/capture-screenshots.mjs` (the steps are at the top of that file).

## Site address

The address is set at build time. The defaults give the GitHub Pages address, so nothing changes until the variables below are set.

| Variable | Default | Meaning |
|---|---|---|
| `DOCS_URL` | `https://openagentix.github.io` | Site origin, used for canonical links, `sitemap.xml` and `robots.txt` |
| `DOCS_BASE_URL` | `/openagentix/` | Path the site is served under (`/` on a custom domain) |
| `DOCS_CNAME` | unset | If set, the build writes `static/CNAME` with this host name |

`static/CNAME` and `static/robots.txt` are written by the build and are not committed. The workflow reads the three values from repository variables (`vars.DOCS_URL`, `vars.DOCS_BASE_URL`, `vars.DOCS_CNAME`).

## Switch to `docs.openagentix.org`

Do these in order. The old address keeps working until step 4, and GitHub Pages redirects it to the new one afterwards.

1. **DNS.** At the DNS host for `openagentix.org`, create one record: `docs` as a CNAME pointing to `openagentix.github.io`. Do not add an A record. Check it with `dig +short CNAME docs.openagentix.org`; it should print `openagentix.github.io.`.
2. **Set the three repository variables** (needs admin rights on the repository):

   ```sh
   gh variable set DOCS_URL --repo openagentix/openagentix --body "https://docs.openagentix.org"
   gh variable set DOCS_BASE_URL --repo openagentix/openagentix --body "/"
   gh variable set DOCS_CNAME --repo openagentix/openagentix --body "docs.openagentix.org"
   ```

3. **Build and deploy with the new settings.**

   ```sh
   gh workflow run docs.yml --repo openagentix/openagentix
   gh run watch --repo openagentix/openagentix
   ```

4. **Set the custom domain on GitHub Pages.**

   ```sh
   gh api -X PUT repos/openagentix/openagentix/pages -f cname=docs.openagentix.org
   ```

   GitHub then checks the DNS record and issues a certificate. This can take from a few minutes to an hour.
5. **Enforce HTTPS** once the certificate is ready (the `https_certificate` state is `approved`):

   ```sh
   gh api repos/openagentix/openagentix/pages --jq '.https_certificate.state, .cname'
   gh api -X PUT repos/openagentix/openagentix/pages -F https_enforced=true
   ```

6. **Check.**

   ```sh
   curl -sI https://docs.openagentix.org/ | head -1                  # HTTP/2 200
   curl -s https://docs.openagentix.org/sitemap.xml | head -c 300     # URLs start with https://docs.openagentix.org/
   curl -s https://docs.openagentix.org/robots.txt                    # Sitemap line uses the new address
   curl -sI https://openagentix.github.io/openagentix/ | head -3      # redirects to the new address
   ```

7. **Update the "Docs site" link in `README.md`** to `https://docs.openagentix.org/` (the one canonical link there).

To go back: delete the three variables (`gh variable delete DOCS_URL --repo openagentix/openagentix`, and the same for the other two), remove the custom domain under Settings, Pages, then re-run the workflow.
