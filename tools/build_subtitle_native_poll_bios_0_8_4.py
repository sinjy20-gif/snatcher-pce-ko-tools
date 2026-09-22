#!/usr/bin/env python3
"""0.8.4 BIOS poll + 기존 Track24 load_blob를 호출하는 one-shot preload."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
STATIC=ROOT/'extraction'/'patch'/'static'; sys.path.insert(0,str(STATIC))
from build_disc_patch import Assembler
import build_track24_loader_proof as track24
sys.path.insert(0,str(ROOT/'tools'))
import subtitle_layout as subtitle_mem

SOURCE=ROOT/'build'/'bios_font'/'Syscard3_galmuri.pce'
BASE24=ROOT/'build'/'patch'/'0.4.5.6'/'Snatcher CD-ROMantic (Japan) (Track 24) [KO 0.4.5.6].bin'
OUT=ROOT/'build'/'bios_font'/'Syscard3_galmuri_sub_native_poll_0_8_4.pce'
INFO=ROOT/'build'/'bios_font'/'subtitle_native_poll_0_8_4.json'
RAW_PAYLOAD=ROOT/'build'/'cutscene_subs'/'subtitle_track24_append_0_8_4.raw'
USER_PAYLOAD=ROOT/'build'/'cutscene_subs'/'subtitle_track24_append_0_8_4.user.bin'

ROM_CPU,CAVE,CAVE_BYTES,STATE=0xE000,0xFEC4,0x118,0x7FDF
LOAD_BLOB,VARS=0x7E64,0x7FE0
# Track24 CUE has INDEX 01 at 00:03:00: 225 raw sectors after file start.
# The earlier 234999 value assumed a 150-sector pregap and addressed every
# appended payload 75 sectors too late.
TRACK24_INDEX1_LBA,TRACK24_FILE_LBA=235149,234924
USER=2048
# 팩 base 는 2026-09-02 에 $1C0000 -> $160000 (단일 출처 tools/subtitle_layout.py)
PACK_AT,HELPER_AT,RENDERER_AT=0x160000,0x1F1C00,0x1F1F00


def pack_with_adpcm_master():
    """팩 preload 행 하나로 팩과 ADPCM LBA 마스터를 같이 싣는다."""
    build=ROOT/'build'/'cutscene_subs'
    pack=(build/'subtitle_pack.bin').read_bytes()
    master=(build/'adpcm_lba_master_index.bin').read_bytes()
    offset=subtitle_mem.AC_ADPCM_LBA_MASTER-PACK_AT
    if len(pack)>offset:
        raise SystemExit(
            f'subtitle pack {len(pack):,} B가 ADPCM master 자리 '
            f'${subtitle_mem.AC_ADPCM_LBA_MASTER:06X}를 침범한다')
    return pack+bytes((0xFF,))*(offset-len(pack))+master


def off(cpu): return cpu-ROM_CPU
def pad(blob): return blob+bytes((0xFF,))*(-len(blob)%USER)


def payloads():
    build=ROOT/'build'/'cutscene_subs'
    return [
      ('pack',pack_with_adpcm_master(),PACK_AT),
      ('helper',(build/'resident_helper_slot_native_poll_0_8_3.bin').read_bytes(),HELPER_AT),
      ('renderer',(build/'resident_renderer_slot_native_poll_0_8_3.bin').read_bytes(),RENDERER_AT),
    ]


def layout():
    if BASE24.stat().st_size%2352: raise SystemExit('Track24 raw size mismatch')
    next_lba=TRACK24_FILE_LBA+BASE24.stat().st_size//2352
    relative=next_lba-TRACK24_INDEX1_LBA
    rows=[]; cursor=relative; user=bytearray(); raw=bytearray(); abs_lba=next_lba
    for name,blob,dest in payloads():
        padded=pad(blob); full,rem=divmod(len(blob),0x2000); final=(rem+USER-1)//USER
        rows.append({'name':name,'relative_sector':cursor,'absolute_lba':abs_lba,
          'bytes':len(blob),'sectors':len(padded)//USER,'full_chunks':full,
          'final_sectors':final,'destination':dest})
        user.extend(padded)
        for at in range(0,len(padded),USER):
            sec=track24.make_mode1_sector(abs_lba,padded[at:at+USER])
            track24.verify_mode1_sector(sec,abs_lba); raw.extend(sec); abs_lba+=1; cursor+=1
    return rows,bytes(user),bytes(raw)


def build(rows):
    a=Assembler(CAVE)
    # state FF는 최초 preload, FE는 실패 정지. 그 외는 0.8.3 판정과 같다.
    a.abs(0xAD,STATE); a.emit(0xC9,0xFF); a.branch(0xF0,'preload')
    a.emit(0xC9,0xFE); a.branch(0xF0,'idle')
    a.emit(0xC9,0x02); a.branch(0xF0,'active')
    a.emit(0xC9,0x00); a.branch(0xD0,'ret')
    a.abs(0xAD,0x22A6); a.branch(0xD0,'idle')
    a.abs(0xAD,0x22A7); a.emit(0xC9,0x68); a.branch(0xD0,'idle')
    a.abs(0xAD,0x22AA); a.emit(0xC9,0x0E); a.branch(0xD0,'idle')
    a.abs(0xAD,0x180D); a.emit(0x29,0x20); a.branch(0xF0,'idle')
    a.emit(0xA9,1); a.abs(0x8D,STATE); a.emit(0x60)
    a.label('active'); a.abs(0xAD,0x180D); a.emit(0x29,0x20); a.branch(0xD0,'still')
    a.emit(0xA9,3); a.abs(0x8D,STATE); a.emit(0x60)
    a.label('still'); a.emit(0xA9,2,0x60)
    a.label('idle'); a.emit(0xA9,0)
    a.label('ret'); a.emit(0x60)

    a.label('preload'); a.emit(0xDA,0x5A)         # PHX / PHY
    for index in range(3):
        a.emit(0xA0,index*8); a.abs(0x20,'load_one'); a.branch(0xD0,'load_fail')
    a.emit(0x7A,0xFA); a.abs(0x9C,STATE); a.emit(0xA9,0,0x60)
    a.label('load_fail'); a.emit(0x7A,0xFA,0xA9,0xFE); a.abs(0x8D,STATE); a.emit(0xA9,0,0x60)
    a.label('load_one'); a.emit(0xA2,0)
    a.label('load_copy'); a.abs(0xB9,'load_table'); a.emit(0x9D); a.word(VARS)
    a.emit(0xC8,0xE8,0xE0,8); a.branch(0xD0,'load_copy')
    a.abs(0x20,LOAD_BLOB); a.emit(0x60)
    a.label('load_table')
    for row in rows:
        sector=row['relative_sector']; dest=row['destination']
        if sector>0xFFFF: raise SystemExit('relative sector exceeds 16 bit')
        a.emit(sector&0xFF,sector>>8,row['full_chunks'],row['final_sectors'],
               dest&0xFF,(dest>>8)&0xFF,(dest>>16)&0xFF,0)
    return a.finish()


def main():
    rows,user,raw=layout(); code=build(rows); source=SOURCE.read_bytes(); image=bytearray(source)
    if image[off(0xF61A):off(0xF61A)+3]!=bytes((0x8D,0x0D,0x18)) or \
       image[off(0xF6EF):off(0xF6EF)+3]!=bytes((0xAD,0x0C,0x18)):
        raise SystemExit('ADPCM hooks are not original')
    if image[off(CAVE):off(CAVE)+CAVE_BYTES]!=b'\xFF'*CAVE_BYTES: raise SystemExit('cave not FF')
    if len(code)>CAVE_BYTES: raise SystemExit(f'cave {len(code)}/{CAVE_BYTES}')
    image[off(CAVE):off(CAVE)+len(code)]=code; OUT.write_bytes(image)
    USER_PAYLOAD.write_bytes(user); RAW_PAYLOAD.write_bytes(raw)
    INFO.write_text(json.dumps({'output':str(OUT),'sha256':hashlib.sha256(bytes(image)).hexdigest(),
      'code_bytes':len(code),'bios_hooks':0,'load_blob_runtime':'7E64','vars':'7FE0-7FE7',
      'track24_base_bytes':BASE24.stat().st_size,'rows':rows,
      'user_payload_bytes':len(user),'raw_payload_bytes':len(raw)},ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'native poll preload BIOS {len(code)}/{CAVE_BYTES} B · hooks 0')
    for row in rows: print(f"  {row['name']}: rel {row['relative_sector']:04X} · {row['sectors']} sectors -> AC ${row['destination']:06X}")
    print(f'  append {len(raw)} raw B / {len(user)} user B')


if __name__=='__main__': main()
