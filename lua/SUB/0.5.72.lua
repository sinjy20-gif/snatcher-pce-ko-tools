-- SUB 0.5.72 -- 0.4.6.42에서 CD-DA 후보 공간 충돌 측정 (read-only)
-- AC/CPU 메모리 쓰기 없음. 먼저 로드한 뒤 Power Cycle하고 ACT1 오프닝을 통과한다.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
  emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_space_0_5_72_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local frame, shown = 0, 0
local LIMIT = 160
local counts = {}
local ranges = {
  { name='HELPER', lo=0x1F1C00, hi=0x1F1DBF },
  { name='ACTIVE_ENGINE', lo=0x1F1F00, hi=0x1F219E },
  { name='CDDA_TEMPLATE', lo=0x1FD000, hi=0x1FD29E },
}

local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, key in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end
local function rangeName(at)
  for _, r in ipairs(ranges) do
    if at >= r.lo and at <= r.hi then return r.name end
  end
  return nil
end
local function emit(event, detail, force)
  local line = string.format('%d\t%s\tpc=%04X\ttrack=%02X\tpulse=%02X/%02X\t%s',
    frame, event, pcNow() & 0xFFFF, emu.read(0x26F9, MEM) or 0,
    emu.read(0x263C, MEM) or 0, emu.read(0x2638, MEM) or 0, detail or '')
  out:write(line .. '\n'); out:flush()
  if force or shown < LIMIT then
    shown = shown + 1
    emu.log('SUB 0.5.72 ' .. line:gsub('\t', ' · '))
  end
end
local function hit(key, event, detail)
  counts[key] = (counts[key] or 0) + 1
  if counts[key] <= 8 then emit(event, detail .. ' hit=' .. counts[key]) end
end

-- Mesen이 AC physical callback을 지원하면 실제 주소 접근을 직접 잡는다.
local directOk = true
for _, r in ipairs(ranges) do
  for _, spec in ipairs({ {'R', emu.callbackType.read}, {'W', emu.callbackType.write} }) do
    local name, lo, hi, rw, typ = r.name, r.lo, r.hi, spec[1], spec[2]
    local ok = pcall(function()
      emu.addMemoryCallback(function(address, value)
        hit('AC_' .. rw .. '_' .. name, 'AC_' .. rw,
          string.format('%s addr=%06X value=%02X', name, address,
            (value or 0) & 0xFF))
      end, typ, lo, hi, CPU, AC)
    end)
    if not ok then directOk = false end
  end
end

-- 포트 접근도 별도로 복원한다. direct callback 지원 여부와 무관한 증거다.
local ch = {
  [0]={ base=0, off=0, inc=0, ctl=0, known=0 },
  [1]={ base=0, off=0, inc=0, ctl=0, known=0 },
}
local function regWrite(address, value)
  local n = address >= 0x1A10 and 1 or 0
  local p, s = 0x1A00 + n * 0x10, ch[n]
  local o, v = address - p, (value or 0) & 0xFF
  if o >= 2 and o <= 4 then
    local shift = (o - 2) * 8
    s.base = (s.base & (~(0xFF << shift))) | (v << shift)
    s.known = s.known | (1 << (o - 2))
  elseif o == 5 then s.off = (s.off & 0xFF00) | v
  elseif o == 6 then s.off = (s.off & 0x00FF) | (v << 8)
  elseif o == 7 then s.inc = (s.inc & 0xFF00) | v
  elseif o == 8 then s.inc = (s.inc & 0x00FF) | (v << 8)
  elseif o == 9 then s.ctl = v end
end
emu.addMemoryCallback(regWrite, emu.callbackType.write,
  0x1A02, 0x1A09, CPU, MEM)
emu.addMemoryCallback(regWrite, emu.callbackType.write,
  0x1A12, 0x1A19, CPU, MEM)

local function portAccess(n, rw, address, value)
  local s = ch[n]
  local effective = (s.base + s.off) & 0x1FFFFF
  local name = rangeName(effective)
  if name then
    hit(string.format('PORT%d_%s_%s', n, rw, name), 'PORT_' .. rw,
      string.format('ch=%d %s addr=%06X value=%02X base=%06X off=%04X inc=%04X ctl=%02X',
        n, name, effective, (value or 0) & 0xFF, s.base, s.off, s.inc, s.ctl))
  end
  if (s.ctl & 0x10) ~= 0 then s.base = (s.base + s.inc) & 0xFFFFFF end
end
for n = 0, 1 do
  local p = 0x1A00 + n * 0x10
  emu.addMemoryCallback(function(a, v) portAccess(n, 'R', a, v) end,
    emu.callbackType.read, p, p + 1, CPU, MEM)
  emu.addMemoryCallback(function(a, v) portAccess(n, 'W', a, v) end,
    emu.callbackType.write, p, p + 1, CPU, MEM)
end

-- CPU 임시 엔진 영역은 오프닝에서 게임 자체가 쓰는지도 함께 본다.
for _, spec in ipairs({ {'R', emu.callbackType.read}, {'W', emu.callbackType.write},
                        {'X', emu.callbackType.exec} }) do
  local rw, typ = spec[1], spec[2]
  emu.addMemoryCallback(function(address, value)
    hit('CPU_' .. rw, 'CPU_' .. rw,
      string.format('addr=%04X value=%02X', address, (value or 0) & 0xFF))
  end, typ, 0x5B80, 0x5E1E, CPU, MEM)
end

local function total(prefix)
  local n = 0
  for k, v in pairs(counts) do if k:sub(1, #prefix) == prefix then n = n + v end end
  return n
end
local function summary(tag)
  local line = string.format(
    '%s directAC=%s helper=%d active=%d template=%d cpuR=%d cpuW=%d cpuX=%d',
    tag, directOk and 'ON' or 'UNSUPPORTED', total('AC_R_HELPER') + total('AC_W_HELPER') +
    total('PORT0_R_HELPER') + total('PORT0_W_HELPER') + total('PORT1_R_HELPER') +
    total('PORT1_W_HELPER'), total('AC_R_ACTIVE_ENGINE') + total('AC_W_ACTIVE_ENGINE') +
    total('PORT0_R_ACTIVE_ENGINE') + total('PORT0_W_ACTIVE_ENGINE') +
    total('PORT1_R_ACTIVE_ENGINE') + total('PORT1_W_ACTIVE_ENGINE'),
    total('AC_R_CDDA_TEMPLATE') + total('AC_W_CDDA_TEMPLATE') +
    total('PORT0_R_CDDA_TEMPLATE') + total('PORT0_W_CDDA_TEMPLATE') +
    total('PORT1_R_CDDA_TEMPLATE') + total('PORT1_W_CDDA_TEMPLATE'),
    counts.CPU_R or 0, counts.CPU_W or 0, counts.CPU_X or 0)
  out:write('# ' .. line .. '\n'); out:flush()
  emu.log('SUB 0.5.72 ★ ' .. line)
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  summary('END'); out:close()
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\ttrack\tpulse\tdetail\n'); out:flush()
emu.log('SUB 0.5.72 loaded -- 0.4.6.42 CD-DA candidate space read-only probe')
emu.log('  먼저 로드 후 Power Cycle · ACT1 오프닝 통과 · 키/메모리 쓰기 없음')
emu.log('  AC helper/active/CDDA-template + CPU $5B80-$5E1E 접근 자동 기록')
emu.log('  결과: ' .. OUT)
