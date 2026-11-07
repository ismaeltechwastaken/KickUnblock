# KickUnblock brand basics

The app icon is a pixel-art K with slightly rounded cells and a play triangle, in seven
colour variants. The SVG sources are in `Resources/icons` and the installed PNGs are in
`App/Resources`. Edit the SVGs and re-export every size if the icon ever changes.

## Assets

| File | Use |
| --- | --- |
| `wordmark-dark.svg` / `wordmark-light.svg` | "KickUnblock" lettering alone, for dark / light backgrounds |
| `lockup-dark.svg` / `lockup-light.svg` | Icon tile + wordmark, for dark / light backgrounds |
| `../icons/<Variant>[-Dark\|-Tinted].svg` | App icon sources (Default, Dark, Tinted appearances) |
| In app | `KickUnblockWordmark` and `KickUnblockLogoView` (SwiftUI, same outlines) |

## Clear space

Keep empty space on every side equal to **one stem width**.

- Wordmark / lockup. The stem of the "K" in the lettering (132 units on a 700-unit cap
  height, so about **0.19 x the cap height**). At a 18 pt wordmark that is about 3.4 pt.
- Mark alone. The K stem of the icon (168 / 1024 of the tile, about **0.16 x the tile size**).

Nothing (text, edges, other logos, busy imagery) goes inside that zone.

## Minimum size

- Wordmark. **12 pt** cap height (12 px at 1x). Below that, use the mark alone.
- Mark / tile. 20 pt in UI. The icon is checked for legibility at 40 px and 29 pt.

## Colors

| Role | Hex | Notes |
| --- | --- | --- |
| Kick green (on dark) | `#53FC18` | Primary brand color, 13.3:1 on carbon |
| Kick green (on light) | `#178005` | Text/marks on white or off-white. 5.1:1 on white (WCAG AA text), 4.3:1 on `#ECECE8` |
| Carbon | `#111111` | Classic icon tile |
| OLED | `#000000` | OLED icon tile |
| Ink | `#0F0F0F` | "Unblock" on light backgrounds |
| White | `#FFFFFF` | "Unblock" and play triangle on dark backgrounds |

Bright `#53FC18` is for dark backgrounds only. On light backgrounds always switch to
`#178005` (the `-light` files do this).

## Do

- Use the provided SVGs or SwiftUI views. Scale proportionally.
- Use the `-dark` files on dark surfaces and the `-light` files on light ones.
- Keep the play triangle white (or the specified variant color) and separate from the K.
- Keep the icon flat. The system adds Liquid Glass depth, highlights and shadows on
  iOS 26/27.

## Don't

- Don't stretch, rotate or outline the lettering. Don't add glows, blurs, drop shadows or gradients to the
  lettering.
- Don't recolor "Kick" outside the two greens above (the in-app accent override is the
  only exception) or put bright green on white.
- Don't redraw the K. Don't merge the triangle into it. Don't change the 45 degree arms.
- Don't set the wordmark in a live font. It is outlined Space Grotesk Bold (SIL OFL 1.1).
- Don't imitate Kick's own logo or pixel-stepped K, and don't imply this is an
  official Kick product.
