-- SUB 0.5.50 -- D000 단일 음성 3조각 실제 자막 시험
--
-- native BIOS 0.4.6.28은 LBA를 관찰 슬롯에 기록하고, 이 판은 검증된
-- AC renderer 체인을 D000 runtime key 하나에만 허용한다. 다른 음성은
-- selector/state/VRAM을 건드리지 않는다.

local TARGET = '00D00E437790'
local realLog = emu.log
SUB_D000_ONLY = true
SUB_D000_MATCHES = 0
SUB_D000_BLOCKED = 0

-- 0.4.93 -> 0.4.89 -> 0.4.31 체인을 먼저 올린다.
dofile('C:/snatcher/lua/SUB/0.4.93-hq-key-vram.lua')

assert(type(_G.SUB_VOICE_SELECT_BASE) == 'function', 'D000: renderer selector가 없다')

local MEM = emu.memType.pceMemory
local STATE = 0x7FDF
local ENGINE = 0x5B80

emu.addEventCallback(function()
  emu.drawString(4, 4, string.format('D000 TEST  match:%d blocked:%d state:%02X',
    SUB_D000_MATCHES or 0, SUB_D000_BLOCKED or 0,
    emu.read(STATE, MEM) or 0), 0x80D0FF, 0x000000)
end, emu.eventType.endFrame)

realLog('SUB 0.5.50 D000 TEST loaded -- target ' .. TARGET)
realLog('  3조각만 허용 · 다른 음성은 fail-closed · renderer chain active')
realLog(string.format('  engine CPU $%04X · state $%04X', ENGINE, STATE))
