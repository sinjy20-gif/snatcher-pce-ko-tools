-- SUB 0.5.62 -- 0.4.6.37 D000 3조각 native scheduler 관찰판
-- 데이터 설치는 검증된 frozen loader 0.5.61 그대로이며, 아래 callback은 읽기만 한다.

dofile('C:/snatcher/lua/SUB/0.5.61.lua')

local MEM = emu.memType.pceMemory
local STATE, ELAPSED, PART, COUNT = 0x7FDF, 0x5E0D, 0x5E0F, 0x5E10
local frame, priorState, priorPart = 0, 0, -1

local function rb(at) return emu.read(at, MEM) or 0 end
local function elapsed() return rb(ELAPSED) | (rb(ELAPSED + 1) << 8) end

emu.addEventCallback(function()
  frame = frame + 1
  local state, part, count = rb(STATE), rb(PART), rb(COUNT)
  if state == 1 and priorState ~= 1 then
    emu.log(string.format('SUB 0.5.62 ★ NATIVE ARM f%d · part 1/%d · elapsed %d',
      frame, count, elapsed()))
    priorPart = part
  elseif state == 1 and part ~= priorPart then
    emu.log(string.format('SUB 0.5.62 ★ NATIVE PART %d/%d f%d · elapsed %d',
      part + 1, count, frame, elapsed()))
    priorPart = part
  elseif priorState == 1 and state == 0 then
    emu.log(string.format('SUB 0.5.62 ★ NATIVE END f%d · final part %d/%d · elapsed %d',
      frame, priorPart + 1, count, elapsed()))
    priorPart = -1
  end
  priorState = state
end, emu.eventType.endFrame)

emu.log('SUB 0.5.62 loaded -- BIOS 0.4.6.37 D000 native 3-part scheduler')
emu.log('  관찰 callback은 read-only · 전환 기대값 90f / 180f · 키 입력 없음')
