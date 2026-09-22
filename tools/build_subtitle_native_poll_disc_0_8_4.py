#!/usr/bin/env python3
"""0.8.4 완전 native POC: resident Track02 + 자막 AC payload Track24."""
from __future__ import annotations

import hashlib
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parent))
import build_disc_subtitle_hook as hook

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'build'/'patch'/'0.4.5.6'
SOURCE02=BASE/'Snatcher CD-ROMantic (Japan) (Track 02) [KO 0.4.5.6].bin'
SOURCE24=BASE/'Snatcher CD-ROMantic (Japan) (Track 24) [KO 0.4.5.6].bin'
RESIDENT=ROOT/'build'/'cutscene_subs'/'resident_controller_native_poll_0_8_4.bin'
APPEND=ROOT/'build'/'cutscene_subs'/'subtitle_track24_append_0_8_4.raw'
OUT=ROOT/'build'/'patch'/'subtitle_native_poll_0_8_4'
NAME02='Snatcher CD-ROMantic (Japan) (Track 02) [KO subtitle native 0.8.4].bin'
NAME24='Snatcher CD-ROMantic (Japan) (Track 24) [KO subtitle native 0.8.4].bin'
HELPER_HEAD=bytes.fromhex('a900' '2032bf' 'ad001a' 'c9ac' 'd035')
HELPER_CPU,HELPER_CODE_BYTES,RESIDENT_CPU,RAW=0x7CD2,631,0x7F49,2352


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1<<20),b''): h.update(chunk)
    return h.hexdigest().upper()


def patch_track02():
    data=bytearray(SOURCE02.read_bytes()); code=RESIDENT.read_bytes()
    if len(code)!=151: raise SystemExit('resident != 151 B')
    for cpu,want in hook.SIGNATURE:
        if hook.read_cpu(data,cpu,len(want))!=want: raise SystemExit(f'overlay signature ${cpu:04X}')
    at=data.find(HELPER_HEAD)
    if at<0 or data.find(HELPER_HEAD,at+1)>=0: raise SystemExit('helper fingerprint')
    free=at+HELPER_CODE_BYTES
    if data[free:free+151]!=b'\xFF'*151: raise SystemExit('helper tail not blank')
    data[free:free+151]=code; touched={free//RAW}
    new=bytes((0x20,RESIDENT_CPU&0xFF,RESIDENT_CPU>>8,0xEA))
    touched|=hook.apply(data,hook.Edit(label='native poll preload',cpu=hook.HOOK_CPU,
                                       old=hook.HOOK_OLD,new=new))
    for sector in sorted(touched):
        start=sector*RAW; raw=bytearray(data[start:start+RAW]); hook.rebuild_mode1_sector(raw)
        data[start:start+RAW]=raw
    target=OUT/NAME02; target.write_bytes(data); return target,sorted(touched)


def stage_cue(target02,target24):
    source_cue=next(BASE.glob('*.cue')); pattern=re.compile(r'^FILE "([^"]+)" BINARY$')
    lines=[]
    for line in source_cue.read_text(encoding='ascii').splitlines():
        m=pattern.match(line)
        if not m: lines.append(line); continue
        source=BASE/m.group(1)
        if 'Track 02' in source.name: target=target02
        elif 'Track 24' in source.name: target=target24
        else:
            target=OUT/source.name
            if not target.exists(): target.hardlink_to(source)
        lines.append(f'FILE "{target.name}" BINARY')
    cue=OUT/'Snatcher CD-ROMantic (Japan) [KO subtitle native 0.8.4].cue'
    cue.write_text('\n'.join(lines)+'\n',encoding='ascii'); return cue


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    target02,touched=patch_track02()
    target24=OUT/NAME24; shutil.copyfile(SOURCE24,target24)
    with target24.open('ab') as out,APPEND.open('rb') as src:
        shutil.copyfileobj(src,out,1<<20)
    cue=stage_cue(target02,target24)
    bins=list(OUT.glob('*.bin'))
    if len(bins)!=24: raise SystemExit(f'CUE tracks {len(bins)} != 24')
    expected24=SOURCE24.stat().st_size+APPEND.stat().st_size
    if target24.stat().st_size!=expected24: raise SystemExit('Track24 append size mismatch')
    print(f'Track02 EDC/ECC sectors {touched} · {target02.stat().st_size:,} B')
    print(f'Track24 +{APPEND.stat().st_size:,} B -> {target24.stat().st_size:,} B')
    print('resident sha256',sha(RESIDENT)); print('Track02 sha256',sha(target02)); print('Track24 sha256',sha(target24))
    print('24 tracks ·',cue)


if __name__=='__main__': main()
