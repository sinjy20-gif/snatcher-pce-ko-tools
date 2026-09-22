-- SUB 0.5.65 -- BIOS 0.4.6.42 preload 측정 전용
-- 메모리/레지스터를 읽고 로그만 남긴다. 게임/BIOS/AC 상태를 쓰지 않는다.
-- 이 스크립트를 먼저 로드한 뒤 Power Cycle 한다.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                     emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/preload_0_5_65_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')

local PC = {
  boot = 0xFF10, preload = 0xFF5F, loop = 0xFF65,
  loadOne = 0xFF8B, loadBlob = 0xBE64,
  returned = 0xFF9D, afterCmp = 0xFFA0,
  publish = 0xFF75, restore = 0xFF80,
}

local frame = 0
local n = { boot=0, preload=0, loop=0, loadOne=0, loadBlob=0,
            returned=0, afterCmp=0, publish=0, restore=0 }
local currentPass, currentRow = 0, -1
local lastSummary = ''

local function rb(at, kind) return emu.read(at, kind or MEM) or 0 end
local function hex(at, count, kind)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', rb(at + i, kind))
  end
  return table.concat(t, '')
end
local function state()
  local ok, s = pcall(emu.getState)
  return ok and type(s) == 'table' and s or nil
end
local function reg(s, names)
  for _, key in ipairs(names) do
    if type(s and s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end
local function hx(v, digits)
  return v < 0 and string.rep('?', digits) or string.format('%0' .. digits .. 'X', v)
end
local function regs()
  local s = state()
  return reg(s, {'cpu.a','a'}), reg(s, {'cpu.x','x'}),
         reg(s, {'cpu.y','y'}), reg(s, {'cpu.ps','cpu.p','p'}),
         reg(s, {'cpu.sp','sp'})
end
local function emit(event, detail)
  local a, x, y, p, sp = regs()
  local line = string.format('%d\t%s\t%d\t%d\tA=%s X=%s Y=%s P=%s SP=%s\t%s',
    frame, event, currentPass, currentRow, hx(a,2), hx(x,2), hx(y,2),
    hx(p,2), hx(sp,4), detail or '')
  emu.log('SUB 0.5.65 ' .. line:gsub('\t', ' · '))
  if out then out:write(line .. '\n'); out:flush() end
end
local function hook(name, address, fn)
  emu.addMemoryCallback(function()
    n[name] = n[name] + 1
    fn()
  end, emu.callbackType.exec, address, address, CPU, MEM)
end

hook('boot', PC.boot, function()
  if n.boot <= 12 then emit('BOOT', 'stateAC=' .. hex(0x010000, 6, AC)) end
end)
hook('preload', PC.preload, function()
  currentPass, currentRow = currentPass + 1, -1
  emit('PRELOAD_BEGIN', 'stateAC=' .. hex(0x010000, 6, AC))
end)
hook('loop', PC.loop, function()
  local _, _, y = regs()
  currentRow = y >= 0 and (y // 8) + 1 or -1
  emit('ROW_BEGIN', 'vars=' .. hex(0xBFE0, 8, MEM))
end)
hook('loadOne', PC.loadOne, function()
  if n.loadOne <= 20 then emit('LOAD_ONE', '') end
end)
hook('loadBlob', PC.loadBlob, function()
  if n.loadBlob <= 20 then emit('LOAD_BLOB_IN', 'vars=' .. hex(0xBFE0, 8, MEM)) end
end)
hook('returned', PC.returned, function()
  emit('LOAD_BLOB_OUT', 'before PLY')
end)
hook('afterCmp', PC.afterCmp, function()
  emit('LOAD_RESULT', 'after PLY+CMP; next RTS')
end)
hook('publish', PC.publish, function()
  if n.publish <= 8 then emit('PUBLISH', 'stateAC=' .. hex(0x010000, 6, AC)) end
end)
hook('restore', PC.restore, function()
  emit('RESTORE', 'publishHits=' .. n.publish .. ' stateAC=' .. hex(0x010000, 6, AC))
end)

local function summary(tag)
  local text = string.format(
    '%s boot=%d preload=%d rows=%d blobIn=%d blobOut=%d result=%d publish=%d restore=%d stateAC=%s bundleHead=%s',
    tag, n.boot, n.preload, n.loop, n.loadBlob, n.returned, n.afterCmp,
    n.publish, n.restore, hex(0x010000, 6, AC), hex(0x1F2800, 6, AC))
  if text ~= lastSummary then
    emu.log('SUB 0.5.65 ★ ' .. text)
    if out then out:write('# ' .. text .. '\n'); out:flush() end
    lastSummary = text
  end
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 120 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  summary('END')
  if out then out:close() end
end, emu.eventType.scriptEnded)

if out then
  out:write('frame\tevent\tpass\trow\tregisters\tdetail\n')
else
  emu.log('SUB 0.5.65 WARNING cannot open ' .. OUT)
end
emu.log('SUB 0.5.65 loaded -- BIOS 0.4.6.42 preload read-only measurement')
emu.log('  이 스크립트를 켠 상태에서 Power Cycle · 키 입력 불필요')
emu.log('  측정: 5개 row, $BE64 반환 A/P/Y, publish, preload 반복 횟수')
emu.log('  결과: ' .. OUT)
