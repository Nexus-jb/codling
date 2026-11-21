# Codling's website

The website lives in [`site/`](../site): one page of plain HTML and CSS, with
no scripts, cookies, fonts or images from anywhere else. The
[Website workflow](../.github/workflows/pages.yml) publishes it to GitHub
Pages whenever `site/` changes on `main`.

## Before the public beta

The site is not announced yet. Until the public beta:

- `site/index.html` carries `<meta name="robots" content="noindex, nofollow">`,
  so search engines leave it out of their results.
- Nothing links to it: not the README, not the package's `Homepage` field in
  `scripts/package-deb.sh`, and not the Nexus website.
- "Get Codling" says that Codling is not available yet, with no download
  button.

## Launch checklist

1. Remove the `robots` meta tag from `site/index.html`.
2. Replace the "Get Codling" text with how to install the public beta.
3. If the site moves to its own domain, add `site/CNAME` with the domain and
   set it under Settings, Pages.
4. Point `Homepage` in `scripts/package-deb.sh` and the README at the site.

## Rules for the site

- Every feature on the page works on a real device today. Planned features
  are not listed.
- Screenshots are real screenshots of Codling, not drawings of it.
- The colors match `App/Palette.swift`, in Light and Dark.
- No third-party requests and no tracking, as in the app.
