-- Read-only companion probe for POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_2_0.lua.
-- Load AFTER the allocator POC. It observes both real rebuilds of its 2-fragment target.
local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local ENGINE, REBUILD, STATE = 0x5B80, 0x5BA6, 0x7FDF
local armed, seen, pending, frame = false, 0, nil, 0

local function bytesUsed(base)
  local n = 0
  for a = base * 2, (base + 1216) * 2 - 1 do
    if (emu.read(a, VRAM) or 0) ~= 0 then n = n + 1 end
  end
  return n
end
local function satRefs(base)
  local lo, n = (base >> 5) & 0xFFFF, 0
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8 + 4
    local pat = (emu.read(at, VRAM) or 0) | ((emu.read(at + 1, VRAM) or 0) << 8)
    if pat >= lo and pat < lo + 38 then n = n + 1 end
  end
  return n
end

emu.addMemoryCallback(function()
  local st = emu.getState()
  local endAddr = ((st['cdrom.adpcm.readAddress'] or 0) + (st['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if endAddr == 0x6800 and (st['cdrom.adpcm.playbackRate'] or -1) == 0x0E then
    armed, seen = true, 0
    emu.log('ALLOC MEASURE armed: target E6800_0E')
  end
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if not armed or seen >= 2 then return end
  seen = seen + 1
  local base = (emu.read(ENGINE + 167, MEM) or 0) << 8
  pending = {n = seen, base = base, elapsed = emu.read(ENGINE + 455, MEM) or 0, due = frame + 1}
end, emu.callbackType.exec, REBUILD, REBUILD, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if pending and frame >= pending.due then
    emu.log(string.format('ALLOC MEASURE #%d base=$%04X elapsed=%d VRAM=%d/2432 SATB=%d state=%02X',
      pending.n, pending.base, pending.elapsed, bytesUsed(pending.base), satRefs(pending.base),
      emu.read(STATE, MEM) or 0))
    pending = nil
  end
  if armed and seen == 2 and (emu.read(STATE, MEM) or 0) == 0 then
    emu.log('ALLOC MEASURE end: native cleanup entered')
    armed = false
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SUBTITLE_FRAGMENT_ALLOCATOR 0.1.0 loaded -- read-only')
