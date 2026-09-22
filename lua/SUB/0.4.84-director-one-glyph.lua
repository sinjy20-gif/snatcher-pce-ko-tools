-- SUB 0.4.84 -- 국장실 떨림 대조: 자막 조각마다 첫 글리프 1개만 올린다.
--
-- 0.4.82의 고정 $1600 + controller/stage + wipe는 그대로 쓴다.
-- 엔진이 record.cells를 internal count/$15에 복사한 뒤 glyph_loop에 들어오는
-- 정확한 지점에서 둘을 1로 줄인다. 따라서 AC->stage 64B + stage->VDC 128B
-- 한 번만 실행되고, push도 스프라이트 한 칸만 한다.
--
-- 진단 전용: 모든 자막이 첫 글자 하나만 표시되는 것이 정상이다.
-- Power Cycle 뒤 이 파일 하나만 실행한다.

dofile('C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua')

local VERSION = '0.4.84-director-one-glyph'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local ENGINE = 0x5B80
local GLYPH_LOOP = ENGINE + 149
local COUNT = ENGINE + 344       -- push 루틴도 이 값을 다시 읽는다
local REMAINING = 0x0015         -- glyph_loop의 현재 남은 글리프 수
local SELECTOR = ENGINE + 345

local seen = 0
local function keyHex()
  local t = {}
  for i = 0, 5 do t[#t + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0) end
  return table.concat(t)
end

emu.addMemoryCallback(function()
  emu.write(COUNT, 1, MEM)
  emu.write(REMAINING, 1, MEM)
  seen = seen + 1
  if seen <= 12 then
    emu.log(string.format('SUB %s ★ ONE GLYPH #%d %s', VERSION, seen, keyHex()))
  end
end, emu.callbackType.exec, GLYPH_LOOP, GLYPH_LOOP, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 114, string.format('0.4.84 ONE GLYPH %d', seen),
                 0x80FFFF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB ' .. VERSION .. ' armed -- fixed $1600, first glyph only')
emu.log('  국장실 떨림 대조용 · 한 글자만 나오는 것이 정상 · allocator/ping-pong 없음')
