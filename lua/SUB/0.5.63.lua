-- SUB 0.5.63 -- 0.4.6.38 D000 3조각 native scheduler 관찰판
-- frozen 데이터 설치 뒤 active state $02의 native part 상태만 읽는다.

dofile('C:/snatcher/lua/SUB/0.5.61.lua')

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local STATE, ELAPSED, PART, COUNT = 0x7FDF, 0x5E0D, 0x5E0F, 0x5E10
local SLOT = 0x1F2700
local frame, priorState, priorPart = 0, -1, -1

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function elapsed() return rb(ELAPSED, MEM) | (rb(ELAPSED + 1, MEM) << 8) end

emu.addEventCallback(function()
  frame = frame + 1
  local state, part, count = rb(STATE, MEM), rb(PART, MEM), rb(COUNT, MEM)
  local lba = (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
  if state == 2 and priorState ~= 2 and lba == 0x003083 then
    emu.log(string.format('SUB 0.5.63 ★ NATIVE ARM f%d · part 1/%d · elapsed %d',
      frame, count, elapsed()))
    priorPart = part
  elseif state == 2 and part ~= priorPart and lba == 0x003083 then
    emu.log(string.format('SUB 0.5.63 ★ NATIVE PART %d/%d f%d · elapsed %d',
      part + 1, count, frame, elapsed()))
    priorPart = part
  elseif priorState == 2 and state ~= 2 then
    emu.log(string.format('SUB 0.5.63 ★ NATIVE END f%d · final part %d/%d · elapsed %d',
      frame, priorPart + 1, count, elapsed()))
    priorPart = -1
  end
  priorState = state
end, emu.eventType.endFrame)

emu.log('SUB 0.5.63 loaded -- BIOS 0.4.6.38 D000 native 3-part scheduler')
emu.log('  active state $02 관찰 · 기대 전환 90f / 180f · 쓰기/키 입력 없음')
