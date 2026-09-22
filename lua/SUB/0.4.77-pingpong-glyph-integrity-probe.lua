-- SUB 0.4.77 -- 0.4.73 A/B ping-pong 글리프 내용 검증 전용
--
-- $65A0/$7920에 실제로 올라간 타일 word를 COUNT_OK~표시 뒤 8프레임까지
-- 해시한다.  SATB 포인터/팔레트가 정상이라는 0.4.76 결과 다음 단계다.
-- 이 파일이 추가로 쓰는 게임/AC/VRAM/Sprite RAM 바이트는 0이다.

dofile('C:/snatcher/lua/SUB/0.4.73-controller-stage-pingpong.lua')

local VERSION = '0.4.77-pingpong-glyph-integrity'
local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 118
local GLYPH_DONE = ENGINE + 289
local SELECTOR = ENGINE + 345
local VRAM_LO, VRAM_HI = 144, 146
local BLOCK_WORDS = 19 * 0x40
local WINDOW = 8

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_77_glyph_integrity_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('id\tkey\tphase\tframe\tbase\tblock_hash\tfirst_hash\tlast_hash\tchanged\n')

local function rb(address, kind)
  local ok, value = pcall(emu.read, address, kind)
  return ok and type(value) == 'number' and value or 0
end

local function keyHex()
  local t = {}
  for i = 0, 5 do t[#t + 1] = string.format('%02X', rb(SELECTOR + i, MEM)) end
  return table.concat(t)
end

local function word(wordAt)
  local at = wordAt * 2
  return rb(at, VRAM) | (rb(at + 1, VRAM) << 8)
end

-- FNV-1a를 32비트 범위에 계속 접어 넣는다.  타일 내용이 한 word라도 다르면
-- 달라지는 비교용 지문이며, 게임 상태에는 전혀 손대지 않는다.
local function hashWords(first, count)
  local h = 2166136261
  for at = first, first + count - 1 do
    local v = word(at)
    h = ((h ~ (v & 0xFF)) * 16777619) & 0xFFFFFFFF
    h = ((h ~ ((v >> 8) & 0xFF)) * 16777619) & 0xFFFFFFFF
  end
  return string.format('%08X', h)
end

local frame, nextId, active = 0, 0, nil
local function record(phase, rec)
  local whole = hashWords(rec.base, BLOCK_WORDS)
  local first = hashWords(rec.base, 0x40)
  local last = hashWords(rec.base + BLOCK_WORDS - 0x40, 0x40)
  local changed = rec.previous and (whole ~= rec.previous) and 'Y' or 'N'
  out:write(string.format('%d\t%s\t%s\t%d\t%04X\t%s\t%s\t%s\t%s\n',
    rec.id, rec.key, phase, frame, rec.base, whole, first, last, changed))
  out:flush()
  if rec.id <= 8 then
    emu.log(string.format('SUB %s #%d %s base=$%04X block=%s first=%s %s',
      VERSION, rec.id, phase, rec.base, whole, first, changed == 'Y' and '★ CHANGED' or ''))
  end
  rec.previous = whole
end

emu.addMemoryCallback(function()
  nextId = nextId + 1
  active = {
    id = nextId,
    key = keyHex(),
    base = rb(ENGINE + VRAM_LO, MEM) | (rb(ENGINE + VRAM_HI, MEM) << 8),
    born = frame,
    done = false,
    previous = nil,
  }
  record('COUNT_OK', active)
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addMemoryCallback(function()
  if not active then return end
  active.done = true
  record('GLYPH_DONE', active)
end, emu.callbackType.exec, GLYPH_DONE, GLYPH_DONE, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if not active then return end
  local age = frame - active.born
  if active.done and age >= 1 and age <= WINDOW then record('FRAME_' .. age, active) end
  if age > WINDOW then active = nil end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  emu.log('SUB ' .. VERSION .. ' 끝 -- ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB ' .. VERSION .. ' loaded -- A/B glyph contents READ ONLY')
emu.log('  Power Cycle 뒤 이 파일 하나만 실행 · GLYPH_DONE 뒤 hash가 바뀌면 ★ CHANGED')
emu.log('  output: ' .. OUT)
