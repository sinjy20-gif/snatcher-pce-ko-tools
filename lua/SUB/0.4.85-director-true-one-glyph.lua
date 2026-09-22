-- SUB 0.4.85 -- 국장실 떨림 대조: 실제 업로드도 정확히 첫 글리프 1회만.
--
-- 0.4.84는 push count만 1이어서 표시만 한 글자일 수 있었다. 이 판은
-- glyph_loop 끝의 `BEQ done / JMP glyph_loop` 중 BEQ를 BRA로 바꿔 첫 전송 뒤
-- 무조건 glyph_done으로 간다. count도 1로 맞춰 SATB push 역시 한 칸이다.
--
-- 진단 전용. Power Cycle 뒤 이 파일 하나만 실행한다.

dofile('C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua')

local VERSION = '0.4.85-director-true-one-glyph'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local ENGINE = 0x5B80
local GLYPH_LOOP = ENGINE + 149
local COUNT = ENGINE + 344
local LOOP_EXIT_BRANCH = ENGINE + 0x118  -- F0 03 (BEQ glyph_done)
local BRA = 0x80                          -- 65C02/HuC6280 BRA, 같은 +03 상대값 유지
local SELECTOR = ENGINE + 345

local calls = 0
local function keyHex()
  local t = {}
  for i = 0, 5 do t[#t + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0) end
  return table.concat(t)
end

emu.addMemoryCallback(function()
  -- 이 시점은 첫 glyph_loop 진입 직전이다. 이후 첫 64B/128B 전송을 끝내면
  -- $5C98의 BRA가 곧바로 glyph_done으로 보내므로 두 번째 전송은 일어나지 않는다.
  emu.write(COUNT, 1, MEM)
  local op = emu.read(LOOP_EXIT_BRANCH, MEM) or 0
  if op == 0xF0 or op == BRA then emu.write(LOOP_EXIT_BRANCH, BRA, MEM) end
  calls = calls + 1
  if calls <= 12 then
    emu.log(string.format('SUB %s ★ TRUE ONE GLYPH #%d %s branch=%02X',
      VERSION, calls, keyHex(), op))
  end
end, emu.callbackType.exec, GLYPH_LOOP, GLYPH_LOOP, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 114, string.format('0.4.85 TRUE ONE GLYPH %d', calls),
                 0x80FFFF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB ' .. VERSION .. ' armed -- one AC/VDC glyph transfer per subtitle')
emu.log('  첫 글자 한 칸만 표시되는 것이 정상 · 0.4.84는 사용하지 말 것')
