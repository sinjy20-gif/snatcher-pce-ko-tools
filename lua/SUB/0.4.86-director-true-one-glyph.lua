-- SUB 0.4.86 -- 0.4.85의 branch 위치 +1 보정판.
--
-- engine+119 = F0 03 (BEQ glyph_done). 0.4.85는 engine+118의 operand($15)를
-- 바꿔 루프를 끊지 못했다. 이 판은 opcode F0를 BRA(80)로 바꾼다.
-- 첫 글리프 전송 뒤 즉시 glyph_done -> 1 x AC 64B + 1 x VDC 128B만 실행.

dofile('C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua')

local VERSION = '0.4.86-director-true-one-glyph'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local ENGINE = 0x5B80
local GLYPH_LOOP = ENGINE + 149
local COUNT = ENGINE + 344
local LOOP_EXIT_BRANCH = ENGINE + 0x119  -- F0 03
local BRA = 0x80
local SELECTOR = ENGINE + 345

local calls = 0
local function keyHex()
  local t = {}
  for i = 0, 5 do t[#t + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0) end
  return table.concat(t)
end

emu.addMemoryCallback(function()
  emu.write(COUNT, 1, MEM)
  local op = emu.read(LOOP_EXIT_BRANCH, MEM) or 0
  assert(op == 0xF0 or op == BRA, string.format('unexpected loop branch $%02X', op))
  emu.write(LOOP_EXIT_BRANCH, BRA, MEM)
  calls = calls + 1
  if calls <= 12 then
    emu.log(string.format('SUB %s ★ TRUE ONE GLYPH #%d %s branch=%02X->80',
      VERSION, calls, keyHex(), op))
  end
end, emu.callbackType.exec, GLYPH_LOOP, GLYPH_LOOP, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 114, string.format('0.4.86 TRUE ONE GLYPH %d', calls),
                 0x80FFFF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB ' .. VERSION .. ' armed -- exact one AC/VDC glyph transfer')
emu.log('  로그 branch=F0->80 뒤 조각당 TRUE ONE GLYPH 한 번이면 실험 성립')
