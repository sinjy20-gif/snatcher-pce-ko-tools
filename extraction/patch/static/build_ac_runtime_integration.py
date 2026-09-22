#!/usr/bin/env python3
"""Replace only the 0.3.0-uitest SRT4 CD sector loader with an AC loader.

The renderer preloader, hash/probe/signature logic, cache layout, text data,
font data and renderer hooks are copied unchanged from 0.3.0-uitest.
For this first integrated build, Mesen Lua preloads the generated 2MB image.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402


BASE = ROOT / "build" / "patch" / "0.3.0-uitest"
VERSION = "ac_0.1.1"
OUT = ROOT / "build" / "patch" / VERSION
SECTOR_LOADER = 0x7F88
SECTOR_LO = 0x7FEF
SECTOR_MID = 0x7FF0
CACHE_BASE = 0x5B80
DIRECT_RELATIVE = 33973
LOADER_BYTES = 100


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def build_ac_loader() -> bytes:
    """Load the requested SRT4 slot from preloaded AC RAM into $5B80."""
    a = common.Assembler(SECTOR_LOADER)

    # Existing preloader passes direct_relative + slot in SECTOR_LO/MID.
    a.emit(0x38)  # SEC
    a.abs(0xAD, SECTOR_LO)
    a.emit(0xE9, DIRECT_RELATIVE & 0xFF, 0x85, 0xF8)
    a.abs(0xAD, SECTOR_MID)
    a.emit(0xE9, DIRECT_RELATIVE >> 8, 0x85, 0xF9)

    # Four-byte map entry address = slot << 2.
    a.emit(0x06, 0xF8, 0x26, 0xF9, 0x06, 0xF8, 0x26, 0xF9)
    a.emit(0xA5, 0xF8); a.abs(0x8D, 0x1A02)
    a.emit(0xA5, 0xF9); a.abs(0x8D, 0x1A03)
    a.abs(0x9C, 0x1A04)
    a.emit(0xA9, 0x01); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)

    # Read the 21-bit record address and its fixed marker. Without a completed
    # preload this must return miss instead of copying uninitialized AC RAM.
    a.abs(0xAD, 0x1A00); a.emit(0x85, 0xF8)
    a.abs(0xAD, 0x1A00); a.emit(0x85, 0xF9)
    a.abs(0xAD, 0x1A00); a.emit(0x85, 0xFA)
    a.abs(0xAD, 0x1A00)
    a.emit(0xC9, 0xA5)
    a.branch(0xD0, "miss")

    # Point the same auto-incrementing port at the unchanged 704-byte record.
    a.emit(0xA5, 0xF8); a.abs(0x8D, 0x1A02)
    a.emit(0xA5, 0xF9); a.abs(0x8D, 0x1A03)
    a.emit(0xA5, 0xFA); a.abs(0x8D, 0x1A04)
    a.emit(0xF3)  # TAI: alternating $1A00/$1A01 -> incrementing destination
    a.word(0x1A00); a.word(CACHE_BASE); a.word(704)
    a.emit(0xA9, 0x00, 0x60)
    a.label("miss")
    a.emit(0xA9, 0x01, 0x60)
    code = a.finish()
    code += bytes((0xEA,)) * (LOADER_BYTES - len(code))
    if len(code) != LOADER_BYTES:
        raise RuntimeError(f"AC loader must exactly replace 100 bytes, got {len(code)}")
    return code


def stage_cue() -> None:
    source_cue = next(BASE.glob("*.cue"))
    pattern = re.compile(r'^FILE "([^"]+)" BINARY$')
    lines: list[str] = []
    for line in source_cue.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if not match:
            lines.append(line)
            continue
        source = BASE / match.group(1)
        if "Track 02" in source.name:
            target = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {VERSION}].bin"
        else:
            target = OUT / source.name.replace("0.3.0-uitest", VERSION)
            if target.exists():
                lines.append(f'FILE "{target.name}" BINARY')
                continue
            try:
                target.hardlink_to(source)
            except OSError:
                shutil.copy2(source, target)
        lines.append(f'FILE "{target.name}" BINARY')
    (OUT / f"Snatcher CD-ROMantic (Japan) [KO {VERSION}].cue").write_text(
        "\n".join(lines) + "\n", encoding="ascii"
    )


def main() -> None:
    if OUT.exists():
        old_manifest = OUT / "manifest.json"
        if old_manifest.exists() and json.loads(old_manifest.read_text(encoding="utf-8")).get("version") != VERSION:
            raise SystemExit(f"refusing to update unrelated output: {OUT}")
    else:
        OUT.mkdir(parents=True)
    source02 = next(BASE.glob("*Track 02*uitest*.bin"))
    old_loader = proof.read_user_bytes(source02, common.bank6a_iso(SECTOR_LOADER), LOADER_BYTES)
    expected = bytes.fromhex(next(
        row.split("\t")[5] for row in (BASE / "track02_patches.tsv").read_text(
            encoding="utf-8-sig"
        ).splitlines()[1:] if row.startswith("sector_loader\t")
    ))
    if old_loader != expected:
        raise RuntimeError("0.3.0-uitest sector loader preflight mismatch")
    new_loader = build_ac_loader()
    target02 = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {VERSION}].bin"
    proof.apply_patches_streaming(source02, target02, [
        common.Patch("ac_sector_loader", common.bank6a_iso(SECTOR_LOADER), old_loader, new_loader, SECTOR_LOADER)
    ])
    stage_cue()
    for name in ("direct_records.tsv", "assets.tsv", "runtime_layout.json"):
        shutil.copy2(BASE / name, OUT / name)
    shutil.copytree(BASE / "ac_backing_store", OUT / "ac_backing_store", dirs_exist_ok=True)
    preload_lua = "AC_BACKING_STORE_PRELOAD_EMBEDDED.lua"
    shutil.copy2(BASE / "ac_backing_store" / preload_lua, OUT / preload_lua)
    manifest = {
        "version": VERSION,
        "base_build": str(BASE),
        "change": "replace only $7F88 100-byte CD SRT4 loader with AC SRT4 loader",
        "preload": "Mesen Lua for this integration build",
        "patched_track02_sha256": sha256_file(target02),
        "ac_loader_bytes": len(new_loader),
        "preserved": ["$5E40 preloader", "$66E5 BODY/UI hook", "$7F50 font wrapper", "704-byte SRT4 records"],
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        f"{VERSION}\n\n"
        f"1. Load and power-cycle: {OUT / f'Snatcher CD-ROMantic (Japan) [KO {VERSION}].cue'}\n"
        "2. Pause the game.\n"
        f"3. Load Lua from the same folder: {OUT / preload_lua}\n"
        "4. Wait for: AC backing store embedded preload complete: 787840 bytes\n"
        "5. Resume without another power-cycle.\n",
        encoding="utf-8-sig",
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
