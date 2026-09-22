-- PROBE CDDA native contract 0.2.0 -- read-only, run alone after map collection.
-- Confirms the current build's $60E4/$26F9 and $6119->$20A0 contracts.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local OUT = 'C:/snatcher/dump/probe_cdda_native_contract_0_2_0.tsv'
local file = assert(io.open(OUT, 'w'))
file:write('kind\tframe\tpc\ttrack_raw\ttrack_play\tmpr3\tsubq_20a0_20a9\n')

local frame, rows = 0, 0
local function rb(a) return emu.read(a, MEM) or 0 end
local function match(a, bytes)
  for i = 1, #bytes do if rb(a + i - 1) ~= bytes[i] then return false end end
  return true
end
local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or {}
end
local function mpr3(s)
  return s['memoryManager.mpr[3]'] or s['mpr[3]'] or 0
end
local function row(kind, pc, subq)
  local s = state()
  local raw = rb(0x26F9)
  rows = rows + 1
  file:write(string.format('%s\t%d\t%04X\t%02X\t%02d\t%02X\t%s\n',
    kind, frame, pc, raw, (raw & 0x7F) + 1, mpr3(s), subq or ''))
  file:flush()
end

-- Fingerprints prevent false hits when another overlay occupies the same CPU window.
emu.addMemoryCallback(function()
  if match(0x60D7, {0xAD,0xF9,0x26}) and match(0x60E4, {0x20,0x12,0xE0}) then
    row('CD_PLAY', 0x60E4, '')
  end
end, emu.callbackType.exec, 0x60E4, 0x60E4, CPU, MEM)

emu.addMemoryCallback(function()
  if match(0x6111, {0xA9,0xA0,0x85,0xFA,0xA9,0x20,0x85,0xFB,0x20,0x1E,0xE0}) then
    local t = {}
    for i = 0, 9 do t[#t + 1] = string.format('%02X', rb(0x20A0 + i)) end
    row('CD_SUBQ_RETURN', 0x611C, table.concat(t, ' '))
  end
end, emu.callbackType.exec, 0x611C, 0x611C, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function()
  file:write(string.format('-- frames=%d rows=%d\n', frame, rows))
  file:close()
  emu.log(string.format('PROBE CDDA native contract end -- %d rows', rows))
end, emu.eventType.scriptEnded)

emu.log('PROBE CDDA native contract 0.2.0 loaded -- read-only')
emu.log('  run alone after VRAM-map collection; play one CD-DA scene, then Stop')
emu.log('  output: ' .. OUT)
