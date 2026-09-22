-- SUB 0.4.35 -- 3조각 이상을 count_ok에서 동기 연결 + Y=122 보정
SUB_VOICE_KEY_VERSION = rawget(_G, 'SUB_VOICE_KEY_VERSION') or '0.4.35'
SUB_VOICE_ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_lua_mini.bin'
SUB_VOICE_ENGINE_BYTES = 652
SUB_VOICE_SELECTOR = 366
SUB_VOICE_NEXT_SELECTOR = 446
SUB_VOICE_MINI_INDEX = 0x1EF000
SUB_VOICE_MINI_COUNT = 5
SUB_VOICE_COUNT_OK = 139
dofile('C:/snatcher/lua/SUB/0.4.31.lua')
SUB_VOICE_KEY_VERSION = nil
SUB_VOICE_ENGINE_PATH = nil
SUB_VOICE_ENGINE_BYTES = nil
SUB_VOICE_SELECTOR = nil
SUB_VOICE_NEXT_SELECTOR = nil
SUB_VOICE_MINI_INDEX = nil
SUB_VOICE_MINI_COUNT = nil
SUB_VOICE_COUNT_OK = nil

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local COUNT_OK = 0x5B80 + 139
local RECORD_Y = 0x5B80 + 461 + 3

emu.addMemoryCallback(function()
  local before = emu.read(RECORD_Y, MEM) or 0
  if before ~= 122 then emu.write(RECORD_Y, 122, MEM) end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.log('SUB 0.4.35 armed -- mini index · synchronous 2->3->4->5 · Y=122')
