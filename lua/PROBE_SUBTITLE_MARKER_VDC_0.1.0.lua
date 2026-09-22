-- Passive VDC ordering probe for syscard3_subtitle_marker_test_v0_1_0.pce.
-- Records whether the copied renderer is really executing and whether game
-- VDC traffic follows it in the same frame (which would overwrite its SATB).

local OUT = "C:/snatcher/dump/probe_subtitle_marker_vdc_0_1_0.tsv"
local mem, cpu = emu.memType.pceMemory, emu.memType.cpu
local LO, HI = 0x5B80, 0x5C5F
local frame, engineSeen, ours, game, active = 0, false, 0, 0, false
local first = nil
local file = assert(io.open(OUT, "w"))
file:write("frame\tengine_vdc_writes\tgame_vdc_writes_after_engine\tengine_prefix\n")

local function pc()
  local s = emu.getState() or {}
  return s["cpu.pc"] or s["cpu.programCounter"] or s["pc"] or 0
end

local function matched()
  return (emu.read(0x22A6, mem) or 0) == 0
     and (emu.read(0x22A7, mem) or 0) == 0x68
     and (emu.read(0x22AA, mem) or 0) == 0x0E
end

emu.addMemoryCallback(function()
  if matched() then
    active, first = true, nil
    emu.log("marker VDC probe armed for E6800_0E")
  end
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  if not active or first then return end
  local b = {}
  for i = 0, 15 do b[#b + 1] = string.format("%02X", emu.read(LO + i, mem) or 0) end
  first = table.concat(b, " ")
  emu.log("marker engine prefix: " .. first)
end, emu.callbackType.exec, LO, LO, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  if not active then return end
  local p = pc()
  if p >= LO and p <= HI then
    engineSeen, ours = true, ours + 1
  elseif engineSeen then
    game = game + 1
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  if engineSeen then
    file:write(string.format("%d\t%d\t%d\t%s\n", frame, ours, game, first or ""))
    file:flush()
  end
  engineSeen, ours, game = false, 0, 0
  if active then
    local state = emu.getState() or {}
    if state["cdrom.adpcm.playing"] ~= true then active = false end
  end
end, emu.eventType.endFrame)
emu.addEventCallback(function() file:close() end, emu.eventType.scriptEnded)
emu.log("PROBE_SUBTITLE_MARKER_VDC 0.1.0 loaded (passive)")
emu.log("  run one marker voice; output: " .. OUT)
