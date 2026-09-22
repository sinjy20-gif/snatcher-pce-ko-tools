-- POC_SAVELOAD_CAVE_FF v2
--
-- Runtime-only proof for the KO 0.3.1 save -> title -> load corruption.
-- Unlike v1, this does not infer whether the Bank 69 helper is active.  It
-- arms replacement only when the original decompressor executes its
-- LDA ($12),Y at $7171 and the source pointer is inside $BCD2-$BFFF.
-- The immediately following memory read is returned as $FF.

local mapped = emu.memType.pceMemory
local cpu = emu.memType.cpu

local READ_PC = 0x7171
local AFTER_READ_PC = 0x7173
local CAVE_LO, CAVE_HI = 0xBCD2, 0xBFFF

local armed = false
local hits = 0
local firstAddress = nil
local lastAddress = nil
local frame = 0
local lastHitFrame = -1000
local reportedHits = 0

emu.addMemoryCallback(function()
  local lo = emu.read(0x12, mapped)
  local hi = emu.read(0x13, mapped)
  local source = lo + hi * 0x100
  armed = source >= CAVE_LO and source <= CAVE_HI
end, emu.callbackType.exec, READ_PC, READ_PC, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  -- Also clears a stale arm if an interrupt or unexpected path prevented the
  -- source read.  On the normal path the read callback already cleared it.
  armed = false
end, emu.callbackType.exec, AFTER_READ_PC, AFTER_READ_PC, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address, value)
  if not armed then return value end
  armed = false
  hits = hits + 1
  lastHitFrame = frame
  if firstAddress == nil then firstAddress = address end
  lastAddress = address
  return 0xFF
end, emu.callbackType.read, CAVE_LO, CAVE_HI, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  if hits > 0 and hits ~= reportedHits and frame - lastHitFrame >= 3 then
    reportedHits = hits
    emu.log(string.format(
      "CAVE FF v2: %d decompressor reads replaced, $%04X-$%04X",
      hits, firstAddress or 0, lastAddress or 0))
  end
  if hits > 0 then
    emu.selectDrawSurface(emu.drawSurface.consoleScreen)
    emu.drawString(4, 4, string.format(
      "CAVE FF v2: %d  $%04X-$%04X",
      hits, firstAddress or 0, lastAddress or 0), 0xFFFFFFFF, 0xC0000000)
  end
end, emu.eventType.endFrame)

emu.log("CAVE FF v2 armed at decompressor $7171")
