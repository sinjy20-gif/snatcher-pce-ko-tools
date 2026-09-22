-- SUB 0.4.34 -- mini-index 유지 + CPU record Y 실측/보정
SUB_VOICE_KEY_VERSION = '0.4.34'
SUB_VOICE_ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_lua_mini.bin'
SUB_VOICE_ENGINE_BYTES = 652
SUB_VOICE_SELECTOR = 366
SUB_VOICE_NEXT_SELECTOR = 446
SUB_VOICE_MINI_INDEX = 0x1EF000
SUB_VOICE_MINI_COUNT = 5
dofile('C:/snatcher/lua/SUB/0.4.31.lua')
SUB_VOICE_KEY_VERSION = nil
SUB_VOICE_ENGINE_PATH = nil
SUB_VOICE_ENGINE_BYTES = nil
SUB_VOICE_SELECTOR = nil
SUB_VOICE_NEXT_SELECTOR = nil
SUB_VOICE_MINI_INDEX = nil
SUB_VOICE_MINI_COUNT = nil

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 139
local RECORD = ENGINE + 461
local seen = 0

-- 현재 keyed ADPCM 1,912행의 pos는 전부 공란, 즉 기본 '중간' Y=122다.
-- 팩에도 122가 들어 있다. 그리기 직전 CPU 복사본을 실측하고 다르면 보정한다.
emu.addMemoryCallback(function()
  seen = seen + 1
  local cells = emu.read(RECORD + 0, MEM) or 0
  local width = emu.read(RECORD + 1, MEM) or 0
  local flags = emu.read(RECORD + 2, MEM) or 0
  local before = emu.read(RECORD + 3, MEM) or 0
  local frames = (emu.read(RECORD + 4, MEM) or 0) |
                 ((emu.read(RECORD + 5, MEM) or 0) << 8)
  if before ~= 122 then emu.write(RECORD + 3, 122, MEM) end
  emu.log(string.format(
    'SUB 0.4.34 RECORD #%d cells=%d width=%d flags=%02X Y=%d->122 frames=%d',
    seen, cells, width, flags, before, frames))
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.log('SUB 0.4.34 Y audit armed at $5C0B · CPU record $5D4D · expected Y=122')
