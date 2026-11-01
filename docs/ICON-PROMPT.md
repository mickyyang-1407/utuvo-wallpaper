# UTUVO Wallpaper Icon

- Date: 2026-10-31
- Mode: built-in image_gen (one generation; no API/CLI fallback, no credentials read)
- Generated size: 1254 x 1254 PNG, alpha present.
- Delivered PNG: ../Assets/AppIcon.png, 1024 x 1024 RGBA, proportional system sips size conversion only.
- Delivered ICNS: ../Assets/AppIcon.icns, standard 16/32/128/256/512 point representations at 1x and 2x; packaged by iconutil.
- Alpha check: range 0..255; all four corner alpha values are 0. Visible tile bounds at alpha >= 16: (96, 108, 925, 917) on the 1024 canvas. Very faint generated alpha pixels extend to (27, 38, 1021, 1024); no background removal or artwork editing was performed.
- Visual inspection: view_image once on the copied generated image. One warm cream rounded tile, an inset paper landscape, ochre sun, terracotta/sage/forest hills; no text, letters, sparkles, headphones or existing product mark.
- Temporary iconset: created only for sips/iconutil packaging and removed immediately after packaging.
- Scope: original product icon only; no Swift or build integration was changed.

## Exact generation prompt

```text
Use case: logo-brand
Asset type: an original native macOS app icon for a wallpaper application named UTUVO Wallpaper, but DO NOT write the name or any text.
Primary request: create exactly one polished, simple, memorable app icon: a warm ivory rounded-square tile containing a crisp inset picture-frame emblem, a golden sun and two or three broad overlapping paper-cut rolling hills.
Style/medium: sophisticated tactile cut-paper relief, restrained shallow depth, very subtle fine paper texture. Calm and friendly. Precisely composed geometric silhouette, readable at 32 pixels.
Color palette: warm cream, terracotta, sage green, a muted ochre sun, deep muted forest for the nearest hill. Strong clean separation between the few large color shapes.
Composition/framing: square 1024x1024 PNG canvas. Tile centered and front-facing, edges approximately 64 pixels from canvas edges (about 896x896 tile). Use macOS-appropriate rounded corners. The picture-frame emblem is a single clear large landscape scene; generous breathing room inside the tile. No detached decorative elements.
Lighting: soft natural diffuse light, only a restrained tiny shadow within the paper layers.
Transparency: the canvas OUTSIDE the rounded-square tile must be truly transparent with alpha, including all four outer corners; not white and not a checkerboard. Keep all icon content inside the rounded tile.
Constraints: completely original product identity. No letters, typography, logo, wordmark, watermark, sparkles, magic wand, stars, neon, glow, gradients with futuristic technology styling, device silhouette, headphones, ear, soundwaves, or recognizably borrowed existing icon. Do not imitate or redraw any UTUVO Listener icon.
Return one icon only, no mockup, no multiple variants, no labels.
```

