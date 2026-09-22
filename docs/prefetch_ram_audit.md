# Track 24 prefetch RAM audit

## Immediate experiment

The current SRT4 asset cache is 704 bytes. Moving one synchronous Track 24
read earlier does not require an additional 8 KiB allocation: the existing
single-asset cache can be reused. The first feasibility check is the measured
time between completion of `$3619`/`$349A` and the first renderer entry at
`$66E5`.

If that interval is less than one frame, moving the same blocking read there
will not materially hide latency. A scene/menu-selection trigger or a true
next-record prefetch is then required.

## Multi-record cache

Each current direct asset occupies 704 bytes, including text and its local
font payload. An 8 KiB bank can therefore hold eleven raw assets at most;
allowing an index and safety metadata, ten entries is the practical target.

The ordinary 8 KiB WRAM window `$2000-$3FFF` is not a candidate. It contains
the game state, renderer pointers, `$3619` dialogue buffer, glyph work areas,
and other live structures. Existing dumps also show no unused 8 KiB run.

The current bank-68 cache at `$5B80-$5E3F` is not persistent storage either.
Runtime tracing already proved that the game overwrites part of this range;
cache-integrity validation was added for that reason. A scene prefetch cache
must therefore use a separately audited physical Card RAM bank, or store only
compact text/index data and copy the selected asset into the current cache at
use time.

Static zero/`FF` contents are only candidates, not proof of safety. A physical
bank is safe only after its MPR mappings, reads, writes, and executable use are
observed across representative gameplay and scene transitions.

The Track 02 load image was scanned bank-by-bank. Physical bank `$6C` is the
only 8 KiB image consisting entirely of zero bytes, so it is the leading
candidate. This does **not** yet authorize use: `AUDIT_CARD_RAM_6C.lua` must
remain quiet across representative gameplay, loads, saves, and scene changes.

## RETRACTED 2026-08-10 — bank `$6C` is not a candidate, and neither is any bank

The paragraph above is wrong in its premise, not just its conclusion. Two live
audits settled it; see `restart kit/logs/bank_census_2026-08-10.md` for the raw
logs.

`UI 0.1.42.lua`, run against a probe disc carrying `K6CPROBE` markers written
into the all-zero 8 KiB at Track 02 user offset `$083800`:

- the markers were **never** visible while bank `$6C` was mapped (`marks=0`),
  so `$083800` does not load into bank `$6C` at all;
- bank `$6C` is written across all 32 of its pages, starting at frame ~834 from
  BIOS PC `$EA9E`.

The mistake was treating "bank number" as if it addressed a fixed disc offset.
`bank $68 == user $07B800` holds only because the boot loader happens to load
that region there. Outside the loaded region there is no such correspondence,
so "this 8 KiB disc image is all zero" says nothing about any bank. The zero
block at `$083800` is simply disc space nothing ever reads.

`UI 0.1.43.lua` then surveyed every bank: **all 32 Card RAM banks `$68`-`$87`
get mapped during ordinary play.** No bank can be reserved.

Follow-on: banks `$74`-`$7F` are mapped sequentially into MPR4 from BIOS at
~3.2 frames each — 96 KiB in 0.58 s, i.e. 1x CD-ROM rate. The scene package the
game already loads is therefore ~96 KiB, far larger than the two 8 KiB pages
(script + text) previously measured. Placing the Korean glyph atlas inside that
already-paid-for load is the remaining approach that needs neither a reserved
bank nor an extra CD read.
