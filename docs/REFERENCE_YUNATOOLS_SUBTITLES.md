# YunaTools PCE CD subtitle system: Snatcher feasibility study

> **2026-08-19 갱신.**  이 문서는 2026-07-26 의 타당성 검토다.  소스를 실제로
> 읽고 나온 실측치(스프라이트당 128 B 슬롯 · 2플레인 전송 · SAT 16 엔트리 ·
> 더블폭 스프라이트 · 고정폭 한글이면 시프트 합성기 불필요)와, 이번에 잡아둔
> AC/케이브 예약은 `handoff/SNATCHER_CUTSCENE_SUBS_2026-08-19.md` 에 있다.
> 아래 "32 subtitle sprites" 는 SAT 엔트리가 아니라 **패턴** 개수다.

Status: **feasible enough for a one-scene proof of concept, but separate from
the normal dialogue overlay.**

Snatcher contains voice-only passages with no Japanese on-screen text. The
existing Korean overlay runs only when the normal dialogue renderer consumes a
text buffer, so those voice-only passages need a second, timed subtitle
runtime.

## References reviewed

- Repository and build system:
  https://github.com/suppertails66/yunatools
- Common subtitle script definitions:
  https://github.com/suppertails66/yunatools/blob/master/yuna/asm/include/scene_common.inc
- Scene runtime:
  https://github.com/suppertails66/yunatools/blob/master/yuna/asm/overlay/scene.s
- Offline subtitle preview renderer:
  https://github.com/suppertails66/yunatools/blob/master/yuna/src/subrender.cpp
- Scene script example:
  https://github.com/suppertails66/yunatools/blob/master/yuna/asm/scene00.s

## What YunaTools actually does

This is not a tool that burns text into a movie stream. It injects a small
subtitle engine into each PCE CD scene overlay:

1. A patched VSync handler increments a frame counter and runs a compact
   subtitle command stream.
2. ADPCM playback entry points increment a separate audio-event counter and
   remember the exact frame at which each clip started.
3. Script commands wait for a frame or an ADPCM event, compose text, upload a
   limited number of patterns per VSync, swap subtitle buffers, and later hide
   them.
4. Subtitle graphics are rendered as sprites. The runtime reserves subtitle
   entries at the start of the SAT, refreshes them every VSync, and modifies
   the game's sprite clear/generation paths so normal scene sprites do not
   erase or overwrite them.
5. The implementation supports two composition lines, up to 16 sprites per
   line (32 subtitle sprites total), centered variable-width text, a dedicated
   palette, and a one-pixel outline/drop shadow.

The code deliberately throttles script actions, sprite-attribute transfers,
and pattern transfers per VSync. This matters because glyph composition and
outlining are too expensive to perform all at once without risking missed
VBlank work.

`subrender.cpp` is an offline 256x32 preview/image renderer. It parses `[br]`
and `[end]`, centers two 16-pixel-high lines, and adds a black one-pixel
outline. It is useful as a layout reference, but the actual in-game work is
performed by `scene.s`.

## Mapping to the Snatcher patch

Already reusable:

- the existing Galmuri-based Korean glyph generator and used-character
  inventory
- the translation/build pipeline
- the planned Track 24 appended payload archive
- the concept of two-line timed subtitle records
- frame-based and audio-event-based timing
- sprite composition and double-buffered show/hide scheduling

Not directly reusable:

- Yuna's absolute addresses, banks, overlay entry points, SAT ownership rules,
  and free RAM/VRAM
- its ADPCM playback hooks
- its scene-specific sprite offsets and palette choices
- the current Snatcher `$66E5` normal-dialogue hook, because voice-only scenes
  never enter that path

## Recommended Snatcher architecture

Keep two independent systems:

1. **Normal dialogue overlay**
   - exact decoded Japanese source lookup
   - Korean replacement string and font data
   - existing runtime path
2. **Voice-only subtitle overlay**
   - scene ID plus timed subtitle events
   - separate VSync-driven sprite renderer
   - activated only for known voice-only scenes

Suggested source format:

```text
scene_id	start_frame	end_frame	line1	line2	audio_event
```

The compiler can turn this into a compact command stream stored with the other
Korean assets in the appended Track 24 archive. A small resident scene hook
loads or pages only the current scene's events and glyphs.

## Main unknowns and risks

1. **Audio path**
   - Determine whether each target scene uses ADPCM, streamed ADPCM, or CD-DA.
   - ADPCM can be synchronized like Yuna by hooking the playback call.
   - CD-DA may need a scene-start/frame counter or CD audio sector/status
     timing instead.
2. **Scene hook**
   - Find a VSync or per-frame scene routine that remains mapped throughout
     the voice-only passage.
3. **Sprite budget**
   - Audit SAT/SATB use in one target scene. Yuna had to patch sprite clear
     and generation code, so a naive overlay may flicker or erase characters.
4. **VRAM and palette**
   - Reserve subtitle patterns and one palette without colliding with scene
     graphics or palette effects.
5. **Bank/RAM lifetime**
   - Identify a small code/state area that stays mapped during the scene.
6. **Timing authoring**
   - A playthrough or speech transcription can seed timings, but the final
     patch should synchronize against in-game frame/audio events.

## One-scene proof of concept

Choose a short voice-only scene and do only this:

1. Identify the exact audio-start call and the scene's stable VSync/per-frame
   hook.
2. Log the scene's SATB, palette, and VRAM usage.
3. Reserve four to eight subtitle sprites, not the full 32-sprite design.
4. Preload one short Korean line and its glyphs.
5. Show it at one timestamp and hide it at another.
6. Confirm that animation, audio, menus, and scene transitions remain intact.

If this succeeds, the remaining work becomes data authoring and scaling the
renderer. If it fails, the logs will distinguish timing, sprite, palette, and
bank-lifetime conflicts before a full subtitle engine is attempted.

## Feasibility conclusion

The method is technically compatible with Snatcher and is a much better fit
than modifying a video stream. The biggest uncertainty is not Korean font
rendering—the project has already solved that—but coexistence with each
voice-scene's sprite/SATB and memory layout. Overall feasibility is **high
enough to justify a one-scene POC**, not yet high enough to promise a universal
drop-in runtime without scene-specific testing.
