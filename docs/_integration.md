# Publishing these docs with Starlight

(Files starting with `_` are ignored by Astro, so this note is not a page.)

`docs/` is laid out as a Starlight content directory: every page is Markdown
with `title`/`description` front matter, and links are site-root paths
(`/guides/graph/`), which is what Starlight serves. To publish:

1. Create a Starlight project (`npm create astro@latest -- --template starlight`).
2. Copy or symlink this `docs/` directory to `src/content/docs/`.
3. Sidebar, in `astro.config.mjs`:

```js
starlight({
  title: 'Fire Engine',
  sidebar: [
    { label: 'Guides', autogenerate: { directory: 'guides' } },
    { label: 'Reference', autogenerate: { directory: 'reference' } },
    { label: 'Design', autogenerate: { directory: 'design' } },
  ],
})
```

`docs/reference/` is generated from doc comments by `scripts/docs.sh`; don't edit
it by hand. CI runs `scripts/docs.sh --check` and fails if it is stale. Pages
for Windows-only packages are generated on Windows (`odin doc` cannot target
Windows from another OS).
