-- SUB return-path audit core (read-only); version/address may be supplied by wrapper.
-- Load this one file, Power Cycle, and do not skip the opening.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam, emu.memType.cpu
local AUDIT_VERSION = rawget(_G, 'SUB_AUDIT_VERSION') or '0.3.12'
local PRELOAD_ENTER = rawget(_G, 'SUB_PRELOAD_ENTER') or 0xFF9A
local BOOT_DONE = rawget(_G, 'SUB_BOOT_DONE') or 0xFF95
local frame, loadCalls, doneCalls = 0, 0, 0
local readyFrame, beforeZp, doneZp, restoreChecked = nil, nil, nil, false

local function byte(a) return emu.read(a, MEM) or 0 end
local function hexBytes(base, count)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = string.format('%02X', byte(base + i)) end
  return table.concat(out, ' ')
end
local function stateLine(tag)
  local ok, s = pcall(emu.getState); s = ok and s or {}
  local mpr = {}
  for i = 0, 7 do mpr[#mpr + 1] = string.format('%02X', s[string.format('memoryManager.mpr[%d]', i)] or 0) end
  emu.log(string.format('SUB %s %s f=%d PC=%04X SP=%02X P=%02X MPR=%s ZP[F8-FF]=%s',
    AUDIT_VERSION, tag, frame, s['cpu.pc'] or 0, s['cpu.sp'] or 0, s['cpu.ps'] or s['cpu.p'] or 0,
    table.concat(mpr, ' '), hexBytes(0x20F8, 8)))
  local sp = s['cpu.sp'] or 0
  emu.log('  stack=' .. hexBytes(0x2100 + ((sp + 1) % 256), 12))
end
local function ready()
  return (emu.read(0x10000, AC) or 0) == 0xAC
     and (emu.read(0x10001, AC) or 0) == 0x15
     and (emu.read(0x10002, AC) or 0) == 0x51
     and (emu.read(0x10003, AC) or 0) == 1
end

-- First load_one is immediately after the original game CD_READ returned,
-- but before our nested payload reads have changed BIOS work variables.
emu.addMemoryCallback(function()
  loadCalls = loadCalls + 1
  if loadCalls == 1 then
    beforeZp = hexBytes(0x20F8, 8)
    stateLine('PRELOAD_ENTER')
  end
end, emu.callbackType.exec, PRELOAD_ENTER, PRELOAD_ENTER, emu.cpuType.pce, MEM)

-- This is the common exit just before PLY/PLX/PLA/PLP/RTS.
emu.addMemoryCallback(function()
  doneCalls = doneCalls + 1
  doneZp = hexBytes(0x20F8, 8)
  stateLine('BOOT_DONE')
  if beforeZp and not restoreChecked then
    restoreChecked = true
    if beforeZp ~= doneZp then
      emu.log('SUB ' .. AUDIT_VERSION .. ' ★ BIOS WORK ZP CHANGED: ' .. beforeZp .. ' -> ' .. doneZp)
    else
      emu.log('SUB ' .. AUDIT_VERSION .. ' ★ BIOS WORK ZP RESTORE PASS')
    end
  end
end, emu.callbackType.exec, BOOT_DONE, BOOT_DONE, emu.cpuType.pce, MEM)

for _, h in ipairs({{0x73BD, 'TITLE_CHAIN'}, {0x7CEF, 'TITLE_CACHE'}, {0xBD13, 'DEMAND_INIT'}, {0x5E40, 'KOREAN_LOOKUP'}}) do
  local address, tag = h[1], h[2]
  emu.addMemoryCallback(function() stateLine(tag) end,
    emu.callbackType.exec, address, address, emu.cpuType.pce, MEM)
end

emu.addEventCallback(function()
  frame = frame + 1
  if not readyFrame and ready() then
    readyFrame = frame
    stateLine('AC_READY')
  elseif readyFrame and frame <= readyFrame + 600 and (frame - readyFrame) % 60 == 0 then
    stateLine('POST_READY+' .. (frame - readyFrame))
  end
end, emu.eventType.endFrame)

emu.log('SUB ' .. AUDIT_VERSION .. ' loaded -- BIOS preload return-path audit / read-only')
emu.log('  Power Cycle 후 노스킵 · READY 뒤 타이틀이 안 뜰 때 로그 전체를 보낼 것')
