# Branding sources

Everything visual in the image is generated from this folder by
`just branding`. Never hand-edit the generated PNGs under `files/system`.

The same renderer serves every edition. An edition keeps its own
`branding/brand.env` (a copy of this one with the edition block changed)
and, if it has launcher icons of its own, `branding/icons/*.glyph`; fonts,
the logo and the wallpaper generator always come from this folder. From a
checkout of this repository:

```bash
scripts/render-branding.sh /path/to/edition-repo
```

## Required inputs

| File | What it is |
|---|---|
| `brand.env` | Colors, fonts, wordmark text, edition name, colour and image name |
| `icons/*.glyph` | SVG elements of a launcher icon's glyph, drawn on the dark tile (file name = icon name) |
| `source/logo.svg` | Full-color logo mark (square-ish, transparent background) |
| `source/logo-symbolic.svg` | Single-color white version for the top-bar menu |
| `source/fonts/*.ttf` | Lato and Cinzel, the files named by the `BRAND_*_FILE` values |
| `wallpapers/generate.py` | The four alternative wallpapers |

## Generated outputs

| Output | Used by |
|---|---|
| `usr/share/backgrounds/shatteredvales/wallpaper.png` | Desktop and lock background |
| `usr/share/shatteredvales/lockscreen-header.png` | Logo + two-line name above the lock clock (on a tall transparent canvas; see `shell-overrides.css.in`) |
| `usr/share/shatteredvales/avatar.png` | Default account picture for everyday accounts, gold (first login) |
| `usr/share/shatteredvales/avatar-admin.png` | Default account picture for administrators, red foil (`BRAND_ADMIN_FOIL_STOPS`) |
| `usr/share/pixmaps/fedora_logo_med.png`, `fedora_whitelogo_med.png` | Settings > About lockup with the edition line in the edition colour (light and dark mode) |
| `usr/share/icons/hicolor/scalable/apps/<glyph name>.svg` | Launcher icons, one per `icons/*.glyph` (Core: System Update) |
| `usr/share/shatteredvales/grub-theme/*` | Boot menu theme |
| `usr/share/shatteredvales/fastfetch/logo.txt` | Terminal logo for `fastfetch` |
| `usr/share/plymouth/themes/shatteredvales/watermark.png` | Boot splash |
| `usr/share/pixmaps/shatteredvales-gdm-logo.png` | Login screen logo (mark, OS name, edition) |
| `usr/share/pixmaps/shatteredvales-logo-symbolic.svg` | Logo Menu button |
| `usr/share/icons/hicolor/*/apps/shatteredvales-logo.*` | Settings > About, notifications |
| `usr/share/shatteredvales/brand.env` | Build scripts inside the image |
