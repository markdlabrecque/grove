# V2 Forest Green — visual redesign spec

Concept approved 2026-05-16. Source: `mockup.html` (live) / `mockup.png` (rendered).

This doc is the single source of truth for the forest-green refresh — palette,
typography, components. Anything not pinned here is implementer's judgment.

---

## 1. Palette

Light mode is the primary canvas (warm paper). Dark mode values are paired so
the same semantic name resolves correctly via the Asset Catalog.

| Semantic name      | Light (#)   | Dark (#)    | Notes                                       |
|--------------------|-------------|-------------|---------------------------------------------|
| `forest500`        | `#3F6E54`   | `#6F9275`   | Primary — buttons, active tab, accent       |
| `forest700`        | `#284938`   | `#3F6E54`   | Pressed/hover, button gradient bottom       |
| `forest800`        | `#1E382A`   | `#284938`   | Deep — text on sage, gradient end           |
| `forest900`        | `#14271D`   | `#0F1D16`   | Headlines, ink on paper                     |
| `moss400`          | `#6F9275`   | `#88A878`   | Secondary accent, success states            |
| `sage300`          | `#A4C3A0`   | `#4A6B4F`   | Lighter accent                              |
| `sage200`          | `#C9DBC0`   | `#34503C`   | Tonal chip background                       |
| `amber`            | `#C8A35A`   | `#D8B872`   | Warnings, "draft", informational            |
| `amberSoft`        | `#E8D5A8`   | `#5C4A22`   | Amber chip background                       |
| `paper`            | `#F4EFE3`   | `#171915`   | App background                              |
| `paperWarm`        | `#EFE8D6`   | `#1F221C`   | Sub-surface                                 |
| `card`             | `#FFFFFF`   | `#222621`   | Card/surface                                |
| `cardTint`         | `#FBF8EF`   | `#262A24`   | Card variant                                |
| `ink900`           | `#16221A`   | `#E8E3D4`   | Primary text                                |
| `ink700`           | `#2F3D33`   | `#C2BFB1`   | Body text                                   |
| `ink500`           | `#5A6A5F`   | `#8E9388`   | Secondary text                              |
| `ink300`           | `#94A097`   | `#5E6359`   | Tertiary, inactive tab                      |
| `hairline`         | `#D9D1BE`   | `#33372F`   | 1pt borders, dividers                       |
| `destructive`      | `#8B3A2E`   | `#C56C5C`   | Destructive actions                         |

**Replace** the existing single `AccentColor` (currently `#2D6A3F`) with `forest500`
as the new app-wide tint. Keep `AccentColor` as an alias for compatibility.

### Asset Catalog JSON (drop-in)

For each color above, create `ios/Grove/Grove/Assets.xcassets/<Name>.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "idiom" : "universal",
      "appearances" : [{ "appearance" : "luminosity", "value" : "light" }],
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "red" : "0x3F", "green" : "0x6E", "blue" : "0x54" }
      }
    },
    {
      "idiom" : "universal",
      "appearances" : [{ "appearance" : "luminosity", "value" : "dark" }],
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "red" : "0x6F", "green" : "0x92", "blue" : "0x75" }
      }
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

### SwiftUI Color extension (drop into `GroveCore` or `Theme.swift`)

```swift
import SwiftUI

extension Color {
  static let forest500   = Color("forest500")
  static let forest700   = Color("forest700")
  static let forest800   = Color("forest800")
  static let forest900   = Color("forest900")
  static let moss400     = Color("moss400")
  static let sage300     = Color("sage300")
  static let sage200     = Color("sage200")
  static let amber       = Color("amber")
  static let amberSoft   = Color("amberSoft")
  static let paper       = Color("paper")
  static let paperWarm   = Color("paperWarm")
  static let card        = Color("card")
  static let cardTint    = Color("cardTint")
  static let ink900      = Color("ink900")
  static let ink700      = Color("ink700")
  static let ink500      = Color("ink500")
  static let ink300      = Color("ink300")
  static let hairline    = Color("hairline")
  static let destructive = Color("destructive")
}
```

> **Important — no `Color+Theme.swift` in the source tree.**
> The extension above is the *design reference* only. The project deliberately
> omits a hand-written `Color+Theme.swift` because Xcode auto-generates
> identical `SwiftUI.Color` static accessors from the Asset Catalog at build
> time via `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`
> (set in both Debug and Release build configurations in the pbxproj, lines 495
> and 558). A manual file alongside the generated one triggers
> "invalid redeclaration" compile errors.
>
> If you add a new colorset, copy a colorset to a second target, or create a
> new Xcode scheme, verify that the setting is `YES` in the new configuration.
> If it is absent or `NO`, every `Color.forest500` (etc.) call becomes a compile
> error with no obvious explanation.

---

## 2. Typography

Stick with the system stack — no custom font files needed for V2.

| Role             | Font                            | Size | Weight    | Tracking |
|------------------|---------------------------------|------|-----------|----------|
| Large title      | SF Pro Display                  | 34pt | bold      | -0.022em |
| Section header   | SF Pro Text (uppercase)         | 11pt | semibold  | 0.14em   |
| Body             | SF Pro Text                     | 15pt | regular   | normal   |
| Body emphasis    | SF Pro Text                     | 15pt | medium    | normal   |
| Caption / meta   | SF Pro Text                     | 11pt | semibold  | normal   |
| Chip / pill      | SF Pro Text                     | 13pt | semibold  | normal   |
| Monospace (URL/token) | ui-monospace (SF Mono)     | 12pt | medium    | normal   |
| Answer card body | SF Pro Text (consider New York) | 15pt | regular   | normal   |

The answer-card body is the one place a serif (New York) could be experimented
with for a "reading" feel. Not required for V2 — implementer's call.

---

## 3. Component specs

### 3.1 Tab bar
- Background: `paper` at 86% alpha + `backdrop saturation 180% blur 20pt`
  (use `.background(.regularMaterial)` + `.tint(.forest500)` on `TabView`).
- Top border: 1pt `hairline`.
- Active tint: `forest500`. Inactive: `ink300`.
- Icons remain SF Symbols (`square.and.pencil`, `magnifyingglass`, `gearshape`).

### 3.2 Large title bar
- 34pt bold `forest900` left-aligned. To the right, an 11pt uppercase
  semibold "GROVE" wordmark in `forest500` with `0.12em` tracking
  (use `letterSpacing(1.3)` in SwiftUI). On Settings tab the wordmark is
  replaced with the build version string in the same style.

### 3.3 Save — editor card
- `card` surface, `hairline` border 1pt, 18pt corner radius, 18pt padding.
- Subtle drop shadow: `0 8 24 rgba(20,39,29,0.07)` + `0 1 2 rgba(...,0.05)`.
- Small `leaf.fill` SF Symbol in `sage300` at the top-right (22pt, 65% alpha).
- TextEditor inherits parent background (no nested chrome).

### 3.4 Chips
- Three styles in use:
  - **Outline** (`card` bg, `hairline` border, `ink700` text) — neutral facts (char count, language).
  - **Tonal sage** (`sage200` bg, no border, `forest800` text) — active/positive state.
  - **Tonal amber** (`amberSoft` bg, no border, dark amber text) — draft / warning.
- 13pt semibold text, 9pt vertical / 12pt horizontal padding, pill radius (999pt).
- Status dot (when present): 6×6pt circle `moss400`, 6pt gap.

### 3.5 Toggle row
- `card` surface, 16pt radius, 14×16pt padding, 1pt `hairline` border.
- Label: 15pt medium `ink900`. Sub: 12pt regular `ink500`, 3pt gap.
- Native iOS Toggle tinted `forest500`.

### 3.6 Primary button
- Height 52pt, 16pt corner radius.
- Background: linear gradient top→bottom `forest500 → forest700`.
- Foreground: `paper` (warm cream rather than white).
- 17pt semibold, leading SF Symbol 18pt at 10pt gap.
- Shadow: `0 8 24 -8 rgba(40,73,56,0.55)` (only in light mode; remove in dark).

### 3.7 Ask — search bar
- Same surface treatment as cards (50pt height, 14pt radius).
- Leading `magnifyingglass` in `forest500`, trailing `mic.fill` in `forest500`
  (mic only when the device supports dictation — current code already conditional).

### 3.8 Ask — answer card
- `card` surface + 18pt radius + standard shadow.
- A 3pt full-height vertical gradient bar on the leading edge:
  `forest500 → moss400`, top→bottom, with `0/3/3/0` corner radius.
- Header strip: 11pt uppercase semibold `forest500`, 0.14em tracking, with a small
  `leaf.fill` SF Symbol prefix.
- Body: 15pt regular `ink900` on `card`.
- Citation badges (`[1]`, `[2]`): `sage200` background, `forest800` text,
  10pt bold, 3×6pt padding, 4pt radius, baseline raised 1pt.

### 3.9 Ask — source card
- Standard `card` surface.
- **Score pill**: leaf-shaped tonal badge — `sage200` bg, `forest800` text,
  4×8pt padding, pill radius, with a 10pt `leaf.fill` SF Symbol leading.
- Meta line continues in 11pt semibold `ink500` after the pill.
- Snippet body: 14pt regular `ink900`, max 3 lines collapsed.
- Footer: 12pt medium `forest500` "View detail" + chevron in `ink300`.
- Expanded state (existing #295 behavior preserved): the inline `NavigationLink`
  with full `View detail / Delete` label sits below `Divider()`.

### 3.10 Recent-queries strip
- 8pt gap between chips, horizontal scroll, 16pt leading padding.
- **Lead chip** (first / most-recent): `forest700` bg, `paper` text.
- Other chips: outline style above.

### 3.11 Settings rows
- Grouped table style preserved (existing pattern in `SettingsView`).
- Row left: 28pt rounded-square icon badge (`forest500` bg / `paper` glyph,
  8pt radius, soft shadow). Alternates allowed: `moss400`, `forest800`, `amber`,
  `destructive` (matching row semantic).
- Row right: secondary text + chevron, or value, or native Toggle (tinted `forest500`).
- Section labels: 11pt uppercase semibold `forest700`, 0.14em tracking.

---

## 4. App icon

V2 redesign keeps scope tight: a new `AppIcon.appiconset` using `forest500` as
ground with the existing wordmark mark in `paper`. Implementer's discretion on
specifics — file a follow-up ticket if it needs a separate design pass.

---

## 5. Icons

All glyphs in the mockup map to SF Symbols. No custom raster assets required for V2.

| Mockup glyph        | SF Symbol                          |
|---------------------|------------------------------------|
| Leaf accent / score | `leaf.fill`                        |
| Save tab            | `square.and.pencil`                |
| Ask tab             | `magnifyingglass`                  |
| Settings tab        | `gearshape.fill`                   |
| Save button         | `arrow.up.circle.fill` (or keep `square.and.arrow.up`) |
| Mic                 | `mic.fill`                         |
| Server URL          | `network`                          |
| Bearer token        | `lock.fill`                        |
| Last sync           | `clock.fill`                       |
| Strip filler words  | `text.alignleft`                   |
| Language hint       | `globe`                            |
| Force resync        | `arrow.triangle.2.circlepath`      |
| Clear local cache   | `trash.fill`                       |

---

## 6. Out of scope for V2

- Custom fonts (system stack only).
- Animations / motion (existing transitions stay).
- Onboarding screens.
- Dark mode polish beyond the palette mapping above — a second pass after light
  mode is solid.
- App icon redesign beyond the simple recolor in §4.

---

## 7. Acceptance reference

The rendered mockup (`mockup.png`) is the visual ground-truth for V2.
`mockup.html` is the editable source — re-open it in a browser to inspect
exact CSS values for any component not pinned above.
