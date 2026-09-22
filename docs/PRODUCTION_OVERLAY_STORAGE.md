# Production Korean overlay storage

## Verified baseline

Build `0.1.5` was runtime-verified in Mesen on 2026-08-01.

- Track 24 appended-sector Korean payload loaded successfully without Lua.
- The original yellow speaker name remained intact.
- Korean and original Japanese renderer paths coexisted normally.
- Dialogue rendering and progression remained operational.

This makes `0.1.5` the production storage/loader baseline for subsequent
translation builds.

## Chosen layout

Use a two-tier design:

1. **Track 02 resident code cave (`$5C67-$5FFF`, 921 bytes)**
   - tiny renderer hook
   - overlay lookup/sector loader
   - page/cache bookkeeping
2. **Appended sectors at the end of Track 24**
   - `SKO1` header and version/checksum
   - lookup table
   - exact Japanese source pool
   - Korean string pool
   - generated Galmuri11 glyph pack
   - future voice-only subtitle timing/data

Track 24 is the final `MODE1/2352` track. Existing Track 24 bytes are never
overwritten; the patched copy is extended with newly generated raw Mode-1
sectors. Extending the last track preserves every existing track start LBA and
only moves the disc lead-out.

## Current measurements

- original Track 24: 80,433,696 raw bytes / 34,198 sectors
- Track 24 INDEX 01 begins after its 225-sector pregap
- total existing BIN sectors: 269,122
- first appended file-boundary sector: 269,122
- raw-sector MSF headers must include the normal +150 sector CD offset
- provisional reserve: 1,024 user sectors = 2 MiB user data
- provisional raw growth: 2,408,448 bytes

The current 81-entry AI preview payload is only 14,244 bytes. A 2 MiB reserve
comfortably covers the full dialogue corpus, generated font, metadata, and
later subtitle tables without changing existing LBAs.

## Runtime policy

Do not load the whole archive into WRAM. Read it in pages:

- keep a compact lookup/header resident in a verified work area
- compare the decoded Japanese source/signature
- fetch only the matched Korean string page
- cache/load only glyph pages needed by the active scene
- leave the game's original text path untouched when no overlay record matches

The exact RAM/Card-RAM cache addresses still require a usage audit before the
production loader is installed.

## Rejected primary options

- **Track 02 cave for all data:** only 921 bytes; already nearly full in 0.0.8.
- **overwrite apparent padding inside Track 24:** unsafe until every original
  sector reference is proven.
- **new Track 25:** possible, but extending the already-final data track avoids
  additional TOC/CUE compatibility assumptions.

## Required verification

1. generate valid MODE1/2352 sync, header, EDC, and P/Q ECC for appended sectors
2. patch a test loader with the exact appended absolute LBA
3. read and checksum a small marker block in Mesen
4. verify unchanged LBAs for Tracks 01-24
5. test original-hardware-compatible CUE/CHD conversion
6. load one Korean string from Track 24 before scaling to the full archive

## Live CD-base discovery (0.1.3)

The game keeps two valid data-track bases:

- first base: Track 02 INDEX 01, absolute LBA `0x00104E` (4174)
- second base: Track 24 INDEX 01, absolute LBA `0x03968D` (235149)

`CD_READ` receives a logical sector offset and tries the first valid base. A
payload appended only to Track 24 cannot be reached while the first base still
points at Track 02: the corresponding Track 02 sector is readable and returns
blank data before the fallback base is considered.

Build 0.1.4 attempted a reversible read sequence, but exposed an important
calling-convention detail. `CD_BASE` uses `BH` for the base-address type and
`CL` for the set mode. Supplying `BH=01`, `CL=01` made Mesen interpret `AL=03`
as Track 03 and normalize base 0 to `0x00962C` (Track 03 INDEX 01). The returned
31 bytes exactly matched Track 06 sector 6107, proving that the subsequent
relative read had used that wrong base.

Build 0.1.5 uses the corrected reversible sequence:

1. call `CD_BASE ($E006)` with `BH=00` (record address) and `CL=01`
   (set first base), selecting Track 24 INDEX 01
2. call `CD_READ ($E009)` with logical sector `0x0084B5`
3. restore Track 02 INDEX 01 with the same `BH=00`, `CL=01` convention

The first appended payload is absolute LBA 269122. The relative sector is
`269122 - 235149 = 33973` (`0x0084B5`). Existing Track 24 bytes remain
unchanged and all appended raw sectors have verified EDC/ECC.
