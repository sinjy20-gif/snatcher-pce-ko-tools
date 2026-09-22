-- SUB 0.4.78 -- 0.4.77에서 발견한 FRAME_1 재변경의 타일 번호를 가른다.
--
-- 각 16x16 타일(64 word) 19개의 지문을 GLYPH_DONE과 FRAME_1에 비교하고,
-- FRAME_2 SATB가 실제 표시한 타일인지 used=Y/N까지 함께 남긴다.
-- 추가 게임/AC/VRAM/Sprite RAM write 0 B.

dofile('C:/snatcher/lua/SUB/0.4.73-controller-stage-pingpong.lua')

local VERSION = '0.4.78-pingpong-cell-diff'
local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 118
local GLYPH_DONE = ENGINE + 289
local SELECTOR = ENGINE + 345
local VRAM_LO, VRAM_HI = 144, 146
local CELLS, CELL_WORDS = 19, 0x40
local SATB = 0x1000

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_78_cell_diff_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('id\tkey\tbase\tcell\tdone_hash\tframe1_hash\tchanged\tused_frame2\n')

local function rb(address, kind)
  local ok, value = pcall(emu.read, address, kind)
  return ok and type(value) == 'number' and value or 0
end

local function rw(wordAt)
  local at = wordAt * 2
  return rb(at, VRAM) | (rb(at + 1, VRAM) << 8)
end

local function keyHex()
  local t = {}
  for i = 0, 5 do t[#t + 1] = string.format('%02X', rb(SELECTOR + i, MEM)) end
  return table.concat(t)
end

local function hashCell(base, cell)
  local h = 2166136261
  for at = base + cell * CELL_WORDS, base + (cell + 1) * CELL_WORDS - 1 do
    local v = rw(at)
    h = ((h ~ (v & 0xFF)) * 16777619) & 0xFFFFFFFF
    h = ((h ~ ((v >> 8) & 0xFF)) * 16777619) & 0xFFFFFFFF
  end
  return string.format('%08X', h)
end

local function usedCells(base)
  local used = {}
  for slot = 0, 63 do
    local at = SATB + slot * 4
    local pattern, attr = rw(at + 2), rw(at + 3)
    local first = (pattern & 0x07FF) << 5
    local width = (attr & 0x0100) ~= 0 and 2 or 1
    local hcode = (attr >> 12) & 0x03
    local height = hcode == 0 and 1 or (hcode == 1 and 2 or 4)
    for n = 0, width * height - 1 do
      local cell = ((first + n * CELL_WORDS) - base) // CELL_WORDS
      if cell >= 0 and cell < CELLS then used[cell] = true end
    end
  end
  return used
end

local frame, nextId, active = 0, 0, nil

emu.addMemoryCallback(function()
  nextId = nextId + 1
  active = {
    id = nextId,
    key = keyHex(),
    base = rb(ENGINE + VRAM_LO, MEM) | (rb(ENGINE + VRAM_HI, MEM) << 8),
    born = frame,
    done = nil,
    frame1 = nil,
  }
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addMemoryCallback(function()
  if not active then return end
  local hashes = {}
  for cell = 0, CELLS - 1 do hashes[cell] = hashCell(active.base, cell) end
  active.done = hashes
end, emu.callbackType.exec, GLYPH_DONE, GLYPH_DONE, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if not active or not active.done then return end
  local age = frame - active.born
  if age == 1 then
    local hashes = {}
    for cell = 0, CELLS - 1 do hashes[cell] = hashCell(active.base, cell) end
    active.frame1 = hashes
  elseif age == 2 and active.frame1 then
    local used = usedCells(active.base)
    local changed, relevant = {}, 0
    for cell = 0, CELLS - 1 do
      local didChange = active.done[cell] ~= active.frame1[cell]
      if didChange then
        changed[#changed + 1] = string.format('%d%s', cell, used[cell] and '*' or '')
        if used[cell] then relevant = relevant + 1 end
      end
      out:write(string.format('%d\t%s\t%04X\t%d\t%s\t%s\t%s\t%s\n',
        active.id, active.key, active.base, cell, active.done[cell], active.frame1[cell],
        didChange and 'Y' or 'N', used[cell] and 'Y' or 'N'))
    end
    out:flush()
    if active.id <= 8 then
      emu.log(string.format('SUB %s #%d base=$%04X FRAME_1 changed=[%s] · displayed=%d',
        VERSION, active.id, active.base, table.concat(changed, ','), relevant))
      emu.log('  * 표시는 FRAME_2 SATB가 실제 표시한 타일')
    end
    active = nil
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  emu.log('SUB ' .. VERSION .. ' 끝 -- ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB ' .. VERSION .. ' loaded -- tile-level READ ONLY')
emu.log('  Power Cycle 뒤 이 파일 하나만 실행 · changed 목록의 *가 실제 표시 타일')
emu.log('  output: ' .. OUT)
