-- SUB 0.5.64 -- 0.4.6.39 AC-persistent D000 scheduler 관찰판

dofile('C:/snatcher/lua/SUB/0.5.61.lua')

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local STATE, SLOT, SCHED = 0x7FDF, 0x1F2700, 0x1F2710
local frame, priorPart, tracking = 0, -1, false

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function elapsed() return rb(SCHED, AC) | (rb(SCHED + 1, AC) << 8) end

emu.addEventCallback(function()
  frame = frame + 1
  local state, part, count = rb(STATE, MEM), rb(SCHED + 2, AC), rb(SCHED + 3, AC)
  if state == 2 and not tracking and lba() == 0x003083 then
    tracking = true
    emu.log(string.format('SUB 0.5.64 ★ NATIVE ARM f%d · part 1/%d · elapsed %d',
      frame, count, elapsed()))
    priorPart = part
  elseif tracking and state == 2 and part ~= priorPart then
    emu.log(string.format('SUB 0.5.64 ★ NATIVE PART %d/%d f%d · elapsed %d',
      part + 1, count, frame, elapsed()))
    priorPart = part
  elseif tracking and state ~= 2 then
    emu.log(string.format('SUB 0.5.64 ★ NATIVE END f%d · final part %d/%d · elapsed %d',
      frame, priorPart + 1, count, elapsed()))
    priorPart = -1
    tracking = false
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.64 loaded -- BIOS 0.4.6.39 D000 native 3-part scheduler')
emu.log('  scheduler state AC $1F2710 · 기대 1/3 -> 2/3@90 -> 3/3@180')
