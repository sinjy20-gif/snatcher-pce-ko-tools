-- LOAD_SUBTITLE_PACK_AC 0.1.0 -- 네이티브 자막 2단계의 첫 조각.
-- subtitle_pack.bin을 AC $1C0000에 한 번 적재하고 전 바이트를 되읽어 검증한다.
-- 화면/RAM/VRAM에는 쓰지 않는다. AC 자막 예약구역(192KB)만 쓴다.

local AC = emu.memType.pceArcadeCardRam
local PACK_AT, PACK_MAX = 0x1C0000, 192 * 1024
local PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local f = assert(io.open(PATH, 'rb'), 'subtitle pack not found: ' .. PATH)
local data = f:read('*a')
f:close()
assert(#data > 64, 'subtitle pack is too small')
assert(#data <= PACK_MAX, string.format('subtitle pack %d > reserve %d', #data, PACK_MAX))
assert(data:sub(1, 4) == 'SNSB', 'subtitle pack magic is not SNSB')

for i = 1, #data do
  emu.write(PACK_AT + i - 1, data:byte(i), AC)
end

local bad = nil
for i = 1, #data do
  local got = emu.read(PACK_AT + i - 1, AC) or -1
  if got ~= data:byte(i) then bad = i - 1; break end
end
assert(not bad, string.format('AC readback differs at +%X', bad or 0))

local version = data:byte(5) | (data:byte(6) << 8)
emu.log(string.format('SUBTITLE PACK AC LOAD PASS: %d B -> AC $%06X  (SNSB v%d)',
                      #data, PACK_AT, version))
emu.log('  Verified every byte. Load this once before a native-engine POC; it does not draw subtitles.')
