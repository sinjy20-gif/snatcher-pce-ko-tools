# Non-dialogue Korean localization plan

This document fixes the production strategy for text that is not part of the
normal white narrative dialogue.

## Decision

Do not route every kind of text through the normal-dialogue hook.

The Korean font/code table and Track 24 payload are shared, but runtime
dispatch is split by rendering context:

1. normal narrative dialogue
2. colored speaker names
3. command menus and other UI text
4. static title/opening/graphic text

This separation is required because dialogue, speaker-name, and menu jobs have
different source/segment handling even though they can share lower-level font
machinery. The stray dots previously observed in dialogue and Japanese menus
were traced to glyph placement/bottom-pixel data, not to proof of a global
font-hook or VRAM-lifetime collision.

Production code still prefers verified context-specific callers. This is an
isolation and maintainability rule, not a conclusion drawn from the old dot
artifact.

Current working model, supported by the live font tests:

- narrative text, colored speaker names, and menus use the same underlying
  glyph/font path;
- text color belongs to palette/render state;
- position and spacing belong to each screen's layout/cursor state;
- only source-string selection and segment control need context-specific
  handling.

## Confirmed source layout

### Colored speaker names

- The speaker-name table is plain CP932/Shift-JIS on Track 02.
- Its first known entry is at ISO user-data offset `0x80548`
  (sector 256, track-relative LBA 31).
- Entries are terminated by `0xFF` and include a one-byte style/control prefix.
- Confirmed entries include `ギリアン`, `受付嬢`, `ミカ`, `局長`, `ハリー`,
  `<원문 5자>`, `<원문 5자>`, and `<원문 5자>`.
- At runtime the name is copied through the reusable `$3619` text buffer and
  is rendered with the game's existing color/layout state.
- The reproducible extractor currently emits 55 non-empty labels to
  `translation/speaker_name_standard.tsv`.

### Menus and UI

- Menu/action vocabulary is also plain CP932/Shift-JIS on Track 02.
- It is repeated in scene-local vocabulary blocks rather than stored only once.
- Confirmed examples include:
  - `見る`
  - `調べる`
  - `場所移動`
  - `<원문 5자>`
  - `<원문 5자>`
  - `<원문 7자>`
- One confirmed cluster begins around ISO offset `0x1172E5`.
- Menu text reaches the common low-level font machinery through a route that
  is different from the normal narrative `$66E5` route.
- The first conservative static inventory contains 58 unique UI candidates
  and 704 on-disc occurrences in `translation/ui_text.tsv`.
- `<원문 7자>` and `<원문 5자>` were each found in five scene/system
  blocks, confirming that at least part of the first-screen UI is ordinary
  text rather than a baked graphic.

### First/title/opening screens

Treat the first screens as two possible asset classes:

- selectable words such as `<원문 7자>`: UI text, handled by the menu
  path;
- logos, large captions, decorative lettering, or text baked into an image:
  tile graphics/BAT data, replaced offline as a graphic asset.

No static graphic is to be forced through the dialogue renderer.

## Production implementation

### 1. Normal narrative dialogue

Status: working.

- Translator source: `translation/snatcher_ko_master.tsv`
- Match the completed decoded Japanese source.
- Redirect only a matching narrative segment.
- Fall back to the original Japanese buffer on every miss.

### 2. Colored speaker names

Use a dedicated name lookup table, but keep the original name renderer.

- Match the complete original speaker-name segment.
- Redirect that segment to a Korean name string.
- Do not alter the palette, cursor, coordinates, or name/body sequencing.
- Require name-context/segment validation in addition to the source bytes so a
  word that also occurs in dialogue is not recolored as a speaker name.
- Reuse the already proven Korean glyph provider.

This preserves yellow, green, and other original name colors automatically.
The color belongs to the game's renderer state, not to the encoded name.

Directly rewriting the disc name table is retained only as a fallback for
same-length experiments. It is not the production design because shorter or
longer Korean names would otherwise require padding or relocation.

### 3. Menus and UI

Use a dedicated UI inventory and reuse the shared Korean glyph provider.

- Extract and deduplicate all plain menu strings with every disc occurrence.
- Assign a stable `ui_id` to each semantic command.
- Match the selected source string in the menu rendering context.
- Redirect to Korean while leaving menu palette, cursor, selection box, and
  spacing logic under game control.
- Do not build a second menu font. The shared lower-level Korean glyph path is
  the default design.
- Add a menu-specific text-selection hook only if the normal completed-buffer
  matcher cannot see menu strings.
- Preserve every original non-Hangul path and run dialogue/menu/title
  regression tests.
- Repeated copies of the same Japanese command share one Korean translation.

One short live trace will still be required to identify the active
menu-specific caller. After that, the remaining menu inventory and patching
are offline/automatic.

### 4. Static title/opening/graphic text

Use an offline graphics pipeline:

1. capture the visible VRAM tiles and BAT references for the screen;
2. correlate the loaded block with Track 02/scene data;
3. render the Korean replacement with the selected font;
4. encode PCE tiles and patch/repoint the asset;
5. preserve the original palette and tilemap placement.

Large logos that do not need translation remain untouched.

## Translator-facing files

The files are intentionally separate so editing normal dialogue cannot break
menus or names.

| File | Purpose |
| --- | --- |
| `translation/snatcher_ko_master.tsv` | normal narrative dialogue |
| `translation/speaker_name_standard.tsv` | colored speaker-name labels |
| `translation/ui_text.tsv` | menus, choices, save/load, system UI |
| `translation/graphic_text_manifest.tsv` | title/opening text baked into graphics |

The name and initial UI candidate inventories have now been populated
automatically. They are separate review queues; the translator may continue
editing only the normal-dialogue master until the non-dialogue runtime hooks
are ready.

## Shared build products

All four sources feed one compiler:

```text
dialogue table
speaker-name table
UI table
graphic asset manifest
        |
        +--> used-character set
        +--> Korean code table
        +--> Galmuri11 glyph pack
        +--> Track 24 SKO1 payload sections
```

Suggested Track 24 sections:

- `DLOG`: normal dialogue records
- `NAME`: speaker-name records
- `UITX`: menu/UI records
- `GFXT`: translated graphic assets
- `FONT`: generated glyph data
- `VSUB`: reserved for future voice-only subtitles

## Implementation order

- [x] Prove normal dialogue replacement and Korean glyph rendering.
- [x] Confirm the speaker-name table and plain menu strings on disc.
- [x] Extract the complete speaker-name inventory (55 non-empty records).
- [ ] Add name-context matching and test one colored Korean name.
- [x] Extract/deduplicate the initial menu/UI inventory
  (58 candidates / 704 occurrences; screen-context review remains).
- [ ] Confirm whether menu strings reach the existing completed-buffer matcher;
  identify only the missing text-selection caller if they do not.
- [ ] Test one Korean command menu without changing dialogue or other menus.
- [ ] Inventory the first/title/opening screens as UI text versus graphics.
- [ ] Test one static graphic-text replacement.
- [ ] Merge `NAME`, `UITX`, and `GFXT` into the production Track 24 payload.

## Acceptance gates

Each path must pass independently:

- original Japanese fallback remains intact;
- speaker colors and positions do not change;
- menu cursor, boxes, and selection behavior do not change;
- no stray pixels appear after closing dialogue or opening a menu;
- save/load and continue screens remain functional;
- title/opening timing and palette remain unchanged;
- any shared font routine preserves the original path for every non-Hangul
  code and passes cross-screen regression tests.
