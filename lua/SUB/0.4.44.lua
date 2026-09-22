-- SUB 0.4.44 -- 0.4.43 의 빠진 절반을 메운다: AC RAM 의 **팩**도 확인한다
--
-- 0.4.43 은 엔진만 강제로 다시 올렸다.  그런데 어긋날 수 있는 짝은 셋이다:
--
--     (1) 팩 파일      <-> 엔진 파일        0.4.43 가드 1 이 봄
--     (2) 엔진 파일    <-> AC RAM 의 엔진   0.4.43 가드 2 가 봄
--     (3) 팩 파일      <-> AC RAM 의 팩     ★ 아무도 안 봤다
--
-- (3) 이 왜 새는가.  0.4.31 의 ensureInstalled() 는 팩을 이렇게만 검사한다:
--
--     packV6 = AC[PACK+4] == 6 and AC[PACK+5] == 0
--
-- 버전 바이트 하나뿐이라, 옛 팩도 v6 이면 그대로 통과하고 새 팩을 안 올린다.
-- 엔진은 팩의 record_off/glyph_off 를 상수로 박고 있으므로, AC 에 옛 팩이 남으면
-- 새 엔진이 엉뚱한 자리를 읽는다.  증상은 팩만 새것일 때와 똑같다 -- 레코드의
-- count 가 쓰레기가 되고 push 루프가 SATB 를 통째로 뭉갠다.
--
-- 이 판은 AC 의 팩 헤더를 파일과 대조하고, 다르면 팩 전체를 다시 올린다.
-- 183 KB 쓰기라 몇 초 걸리지만 로드 때 한 번뿐이고, 조용히 틀리는 것보다 낫다.
--
-- 실행 조합은 0.4.43 과 같다.  0.4.43 대신 이것을 쓴다.

dofile('C:/snatcher/lua/SUB/0.4.43.lua')

local AC = emu.memType.pceArcadeCardRam
local PACK_AT = 0x1C0000
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local f = assert(io.open(PACK_PATH, 'rb'), 'cannot open ' .. PACK_PATH)
local pack = f:read('*a'); f:close()

-- 헤더에서 레이아웃을 결정하는 자리만 본다.  이 넷이 같으면 같은 팩이다.
--   8  글리프 수 u16      10 glyph_off  u32
--   14 ADPCM 수 u16       16 adpcm_off  u32
--   20 CD-DA 수 u16       22 cdda_off   u32
--   26 record_off u32     30 total      u32
local FIELDS = { 8, 10, 14, 16, 20, 22, 26, 30 }

local function u32at(s, at) -- 0-based
  return s:byte(at + 1) | (s:byte(at + 2) << 8) |
         (s:byte(at + 3) << 16) | (s:byte(at + 4) << 24)
end

local function acU32(at)
  return (emu.read(PACK_AT + at, AC) or 0) |
         ((emu.read(PACK_AT + at + 1, AC) or 0) << 8) |
         ((emu.read(PACK_AT + at + 2, AC) or 0) << 16) |
         ((emu.read(PACK_AT + at + 3, AC) or 0) << 24)
end

local diff = {}
for _, at in ipairs(FIELDS) do
  local want, got = u32at(pack, at), acU32(at)
  if want ~= got then
    diff[#diff + 1] = string.format('hdr+%02d  AC %08X != 파일 %08X', at, got, want)
  end
end

if #diff == 0 then
  emu.log(string.format('SUB 0.4.44 -- AC 의 팩이 파일과 같다 (%d B).  다시 올리지 않는다', #pack))
else
  emu.log(string.format('SUB 0.4.44 ★ AC 에 다른 팩이 있었다 -- %d B 를 다시 올린다', #pack))
  for _, line in ipairs(diff) do emu.log('    ' .. line) end
  local t0 = os.clock()
  for i = 1, #pack do
    emu.write(PACK_AT + i - 1, pack:byte(i), AC)
  end
  emu.log(string.format('    완료 (%.1f초).  이제 AC 의 팩과 엔진이 같은 세대다',
                        os.clock() - t0))
end

emu.log('SUB 0.4.44 armed -- 팩/엔진 · 파일/AC 네 방향이 모두 맞춰졌다')
