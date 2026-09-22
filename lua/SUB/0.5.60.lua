-- SUB 0.5.60 -- D000 첫 조각 SATB/Sprite RAM 잔재 자동 진단
-- BIOS 0.4.6.36 + 정적 loader 0.5.51 전용. 관찰만 하며 게임 상태를 쓰지 않는다.

local VERSION = '0.5.60'
local OUT = 'C:/snatcher/dump/sub/adpcm_native_d000_satb_060.tsv'
local MEM, AC, VRAM, SPR = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                            emu.memType.pceVideoRam, emu.memType.pceSpriteRam
local CPU = emu.cpuType.pce
local SLOT, TARGET = 0x1F2700, 0x003083
local ENGINE, BASE = 0x5B80, 0x6600
local SATB, BLOCK_WORDS = 0x2000, 19 * 0x40

local info = assert(dofile('C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.lua'))
dofile('C:/snatcher/lua/SUB/0.5.51.lua')

local function rb(at, kind)
  local ok, value = pcall(emu.read, at, kind)
  return ok and type(value) == 'number' and value or 0
end

local function rw(at, kind)
  return rb(at, kind) | (rb(at + 1, kind) << 8)
end

local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end

local function hex(at, count, kind)
  local t = {}
  for i = 0, count - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end

local function pointsAtBase(pattern, attr)
  if (attr & 0x0F) ~= 0x0F then return false end
  local first = (pattern & 0x07FF) << 5
  local width = ((attr & 0x0100) ~= 0) and 2 or 1
  local hcode = (attr >> 12) & 0x03
  local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
  local last = first + width * height * 0x40 - 1
  return last >= BASE and first < BASE + BLOCK_WORDS
end

local rows = {'frame\tphase\ttable\tslot\ty\tx\tpattern\tattr\ttarget'}
local function scanTable(frame, phase, name, kind, origin)
  local active, target = 0, 0
  for slot = 0, 63 do
    local at = origin + slot * 8
    local y, x = rw(at, kind), rw(at + 2, kind)
    local pattern, attr = rw(at + 4, kind), rw(at + 6, kind)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      active = active + 1
      local ours = pointsAtBase(pattern, attr)
      if ours then target = target + 1 end
      rows[#rows + 1] = string.format('%d\t%s\t%s\t%d\t%04X\t%04X\t%04X\t%04X\t%d',
        frame, phase, name, slot, y, x, pattern, attr, ours and 1 or 0)
    end
  end
  return active, target
end

local frame, armedFrame, pushes, dumped = 0, nil, 0, false
local summaries = {}

local pushAt = ENGINE + info.offsets.push
emu.addMemoryCallback(function()
  if not armedFrame then return end
  pushes = pushes + 1
  local count = rb(ENGINE + info.offsets.count, MEM)
  local rec = hex(ENGINE + info.offsets.record, 48, MEM)
  local list = hex(ENGINE + info.offsets.list, math.min(count, 19) * 5, MEM)
  rows[#rows + 1] = string.format('# push=%d frame=%d zpY=%04X zpX=%04X count=%d record=%s list=%s',
    pushes, frame, rw(0x08, MEM), rw(0x0A, MEM), count, rec, list)
end, emu.callbackType.exec, pushAt, pushAt, CPU, MEM)

local function dump()
  local f, err = io.open(OUT, 'w')
  if not f then
    emu.log('SUB ' .. VERSION .. ' dump open FAIL: ' .. tostring(err))
    return
  end
  f:write(table.concat(rows, '\n'), '\n')
  f:close()
  emu.log(string.format('SUB %s ★ AUTO DUMP -> %s', VERSION, OUT))
  emu.log(string.format('  D000 pushes=%d · %s', pushes, table.concat(summaries, ' · ')))
end

emu.addEventCallback(function()
  frame = frame + 1
  if not armedFrame and lba() == TARGET and rb(SLOT, AC) == 0xA2 then
    armedFrame = frame
    local va, vt = scanTable(frame, 'ARM', 'VRAM', VRAM, SATB)
    local sa, st = scanTable(frame, 'ARM', 'SPR', SPR, 0)
    summaries[#summaries + 1] = string.format('ARM V%d/%d S%d/%d', vt, va, st, sa)
    emu.log(string.format('SUB %s D000 armed f%d · SATB 잔재 자동 추적 시작', VERSION, frame))
  end
  if not armedFrame or dumped then return end
  local age = frame - armedFrame
  if age >= 0 and age <= 12 then
    local va, vt = scanTable(frame, 'F' .. age, 'VRAM', VRAM, SATB)
    local sa, st = scanTable(frame, 'F' .. age, 'SPR', SPR, 0)
    if age == 0 or age == 1 or age == 5 or age == 12 then
      summaries[#summaries + 1] = string.format('F%d V%d/%d S%d/%d', age, vt, va, st, sa)
    end
  end
  if age >= 12 then dumped = true; dump() end
end, emu.eventType.endFrame)

emu.log('SUB ' .. VERSION .. ' loaded -- BIOS 0.4.6.36 D000 first-fragment residue probe')
emu.log('  관찰 전용 · 키 입력 없음 · 12프레임 뒤 자동 저장: ' .. OUT)
