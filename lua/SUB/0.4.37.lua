-- SUB 0.4.37 -- 16-bit 도달/초과 타이머 + 동적 BAT/SATB allocator
--
-- 0.4.36은 elapsed == start.low인 호출에서만 다음 조각으로 넘어갔다.
-- 엔진 호출이 그 값을 건너뛰면 2/3번째 조각이 영원히 나오지 않았다.
-- 이 판은 16-bit elapsed >= start로 판정하고, 새 엔진의 이동된 오프셋을
-- allocator에 명시적으로 넘긴다.

SUB_VOICE_KEY_VERSION = '0.4.37'
SUB_VOICE_ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_lua_mini.bin'
SUB_VOICE_ENGINE_BYTES = 672
SUB_VOICE_SELECTOR = 386
SUB_VOICE_NEXT_SELECTOR = 466
SUB_VOICE_MINI_INDEX = 0x1EF000
SUB_VOICE_MINI_COUNT = 5
SUB_VOICE_COUNT_OK = 159
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
local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 159
local RECORD_Y = ENGINE + 481 + 3

emu.addMemoryCallback(function()
  local before = emu.read(RECORD_Y, MEM) or 0
  if before ~= 122 then emu.write(RECORD_Y, 122, MEM) end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

SUB_ALLOCATOR_VERSION = '0.4.37-dynamic'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = false
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
SUB_ALLOCATOR_ENGINE = ENGINE
SUB_ALLOCATOR_REBUILD_OFFSET = 58
SUB_ALLOCATOR_COUNT_OK_OFFSET = 159
SUB_ALLOCATOR_VRAM_LO_OFFSET = 185
SUB_ALLOCATOR_VRAM_HI_OFFSET = 187
SUB_ALLOCATOR_PAT_LO_OFFSET = 296
SUB_ALLOCATOR_ATTR_OFFSET = 301
dofile('C:/snatcher/lua/SUB/0.3.42-wide.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil
SUB_ALLOCATOR_ENGINE = nil
SUB_ALLOCATOR_REBUILD_OFFSET = nil
SUB_ALLOCATOR_COUNT_OK_OFFSET = nil
SUB_ALLOCATOR_VRAM_LO_OFFSET = nil
SUB_ALLOCATOR_VRAM_HI_OFFSET = nil
SUB_ALLOCATOR_PAT_LO_OFFSET = nil
SUB_ALLOCATOR_ATTR_OFFSET = nil

emu.log('SUB 0.4.37 armed -- 16-bit >= fragment timer + dynamic BAT/SATB allocator')
