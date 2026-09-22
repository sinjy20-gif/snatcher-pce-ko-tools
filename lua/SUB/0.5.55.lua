-- SUB 0.5.55 -- BIOS 0.4.6.31 native 실패 기준선 자동 측정
-- 로드 시 0.5.51 정적 데이터만 올린다. 이후 게임 메모리는 쓰지 않는다.

dofile('C:/snatcher/lua/SUB/0.5.51.lua')

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                     emu.cpuType.pce
local SLOT, MINI, SELECTOR_AC = 0x1F2700, 0x1EF000, 0x1F206F
local STATE, ENGINE, SELECTOR_CPU = 0x7FDF, 0x5B80, 0x5B80 + 367
local TARGET = 0x003083
local FEC4, FEC7, LEGACY_ARM, LEGACY_RTS = 0xFEC4, 0xFEC7, 0xFEF1, 0xFEF9
local BRIDGE, DISPATCH = 0xFFD4, 0xF0EA

local stamp = os.date('%Y%m%d_%H%M%S')
local path = 'C:/snatcher/dump/sub/native_031_trace_' .. stamp .. '.tsv'
local out = assert(io.open(path, 'w'), 'cannot open ' .. path)

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, k in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[k]) == 'number' then return math.floor(s[k]) & 0xFFFF end
  end
  return -1
end

local frame = 0
local counts = { fec4=0, fec7=0, bridge=0, dispatch=0, legacy=0, engine=0, state=0 }
local lastStatus, lastLba = -1, -1
local perLba = {}
local targetA1, targetA2 = false, false

local function emit(kind, detail)
  local line = string.format('%d\t%s\t%02X\t%06X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s',
    frame, kind, rb(SLOT, AC), lba(), rb(STATE, MEM), rb(0x22A6, MEM),
    rb(0x22A7, MEM), rb(0x22AA, MEM), rb(0x180D, MEM), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log('SUB 0.5.55 ' .. line:gsub('\t', ' '))
end

local function snapshot(label)
  emit(label, 'key=' .. hex(SLOT + 4, 6, AC) ..
    ' mini=' .. hex(MINI, 13, AC) ..
    ' selAC=' .. hex(SELECTOR_AC, 9, AC) ..
    ' selCPU=' .. hex(SELECTOR_CPU, 9, MEM) ..
    ' magic=' .. hex(ENGINE, 3, MEM))
end

local function traceThisLba(now)
  local n = perLba[string.format('%06X', now)] or 0
  return n <= (now == TARGET and 24 or 2)
end

emu.addMemoryCallback(function()
  counts.fec4 = counts.fec4 + 1
  local k = string.format('%06X', lba())
  perLba[k] = (perLba[k] or 0) + 1
  if traceThisLba(lba()) then emit('FEC4', 'pc=FEC4') end
end, emu.callbackType.exec, FEC4, FEC4, CPU, MEM)

emu.addMemoryCallback(function()
  counts.fec7 = counts.fec7 + 1
  if traceThisLba(lba()) then
    emit('FEC7', 'bridge-return')
  end
end, emu.callbackType.exec, FEC7, FEC7, CPU, MEM)

emu.addMemoryCallback(function()
  counts.bridge = counts.bridge + 1
end, emu.callbackType.exec, BRIDGE, BRIDGE, CPU, MEM)

emu.addMemoryCallback(function()
  counts.dispatch = counts.dispatch + 1
end, emu.callbackType.exec, DISPATCH, DISPATCH, CPU, MEM)

emu.addMemoryCallback(function()
  counts.legacy = counts.legacy + 1
  emit('LEGACY_ARM', 'old-$22A7=$68 gate accepted')
end, emu.callbackType.exec, LEGACY_ARM, LEGACY_ARM, CPU, MEM)

emu.addMemoryCallback(function()
  if lba() == TARGET then emit('LEGACY_RTS', 'after-state1/consume') end
end, emu.callbackType.exec, LEGACY_RTS, LEGACY_RTS, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  counts.state = counts.state + 1
  emit('STATE_WRITE', string.format('value=%02X pc=%04X', value or 0, pcNow()))
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function()
  counts.engine = counts.engine + 1
  if counts.engine <= 8 or lba() == TARGET then
    emit('ENGINE', 'magic=' .. hex(ENGINE, 3, MEM) ..
      ' selector=' .. hex(SELECTOR_CPU, 9, MEM))
  end
end, emu.callbackType.exec, ENGINE, ENGINE, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local status, nowLba = rb(SLOT, AC), lba()
  if status ~= lastStatus or nowLba ~= lastLba then
    emit('SLOT', 'transition')
    lastStatus, lastLba = status, nowLba
  end
  if nowLba == TARGET and status == 0xA1 and not targetA1 then
    targetA1 = true; snapshot('D000_BEFORE')
  elseif nowLba == TARGET and status == 0xA2 and not targetA2 then
    targetA2 = true; snapshot('D000_AFTER')
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# counts fec4=%d fec7=%d bridge=%d dispatch=%d legacy=%d engine=%d state=%d\n',
    counts.fec4, counts.fec7, counts.bridge, counts.dispatch,
    counts.legacy, counts.engine, counts.state))
  out:close()
  emu.log('SUB 0.5.55 trace saved -> ' .. path)
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tslot\tlba\tstate\t22A6\t22A7\t22AA\t180D\tdetail\n')
out:flush()
emu.log('SUB 0.5.55 baseline probe loaded -- BIOS 0.4.6.31 only')
emu.log('  static upload + read-only runtime trace · key input unnecessary')
emu.log('  output: ' .. path)
