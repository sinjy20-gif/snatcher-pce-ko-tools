-- SUB 0.4.75-pingpong-handoff-probe -- A/B 전환 순서 측정 전용
--
-- 0.4.73의 A/B 선택은 그대로 재현하되, 이 파일 자신은 게임/AC/VRAM/Sprite
-- RAM에 한 바이트도 쓰지 않는다.  다음 세 시점만 TSV로 남긴다.
--   COUNT_OK   새 base가 renderer에 들어간 직후
--   GLYPH_DONE 글리프 복사가 끝난 직후
--   FRAME +1/+2 실제 SATB가 어느 base를 가리키는지

dofile('C:/snatcher/lua/SUB/0.4.73-controller-stage-pingpong.lua')

local VERSION = '0.4.75-pingpong-handoff-probe'
local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local SPR = emu.memType.pceSpriteRam
local CPU = emu.cpuType.pce

local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 118
local GLYPH_DONE = ENGINE + 289
local VRAM_LO, VRAM_HI = 144, 146
local BLOCK_WORDS = 19 * 0x40
local SATB = 0x2000

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_75_handoff_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('id\tphase\tframe\tbase\tvram_satb\tsprite_ram\tcell1_words\tall_words\n')

local function rb(address, kind)
  local ok, value = pcall(emu.read, address, kind)
  return ok and type(value) == 'number' and value or 0
end

local function word(wordAt)
  local at = wordAt * 2
  return rb(at, VRAM) | (rb(at + 1, VRAM) << 8)
end

local function overlaps(base, pattern, attr)
  local first = (pattern & 0x07FF) << 5
  local width = (attr & 0x0100) ~= 0 and 2 or 1
  local hcode = (attr >> 12) & 0x03
  local height = hcode == 0 and 1 or (hcode == 1 and 2 or 4)
  local last = first + width * height * 0x40 - 1
  return last >= base and first < base + BLOCK_WORDS
end

local function refs(kind, origin, base)
  if not kind then return 0 end
  local n = 0
  for slot = 0, 63 do
    local at = origin + slot * 8
    local pattern = rb(at + 4, kind) | (rb(at + 5, kind) << 8)
    local attr = rb(at + 6, kind) | (rb(at + 7, kind) << 8)
    if overlaps(base, pattern, attr) then n = n + 1 end
  end
  return n
end

local function density(base, from, count)
  local n = 0
  for wordAt = base + from, base + from + count - 1 do
    if word(wordAt) ~= 0 then n = n + 1 end
  end
  return n
end

local frame, nextId, active = 0, 0, nil
local function record(phase, rec)
  local vramRefs = refs(VRAM, SATB, rec.base)
  local sprRefs = refs(SPR, 0, rec.base)
  local cell1 = density(rec.base, 0, 0x40)
  local whole = density(rec.base, 0, BLOCK_WORDS)
  out:write(string.format('%d\t%s\t%d\t%04X\t%d\t%d\t%d\t%d\n',
    rec.id, phase, frame, rec.base, vramRefs, sprRefs, cell1, whole))
  out:flush()
  if rec.id <= 8 then
    emu.log(string.format('SUB %s #%d %s base=$%04X SATB=%d/%d cell1=%d all=%d',
      VERSION, rec.id, phase, rec.base, vramRefs, sprRefs, cell1, whole))
  end
end

emu.addMemoryCallback(function()
  nextId = nextId + 1
  active = {
    id = nextId,
    base = (rb(ENGINE + VRAM_LO, MEM) | (rb(ENGINE + VRAM_HI, MEM) << 8)),
    born = frame,
    done = false,
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
  if active then
    local age = frame - active.born
    if age == 1 then record('FRAME_1', active)
    elseif age == 2 then
      record('FRAME_2', active)
      active = nil
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  emu.log('SUB ' .. VERSION .. ' 끝 -- ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB ' .. VERSION .. ' loaded -- handoff trace only (extra game writes 0 B)')
emu.log('  COUNT_OK -> GLYPH_DONE -> FRAME+1/+2; Power Cycle 뒤 이 파일 하나만 실행')
emu.log('  output: ' .. OUT)
