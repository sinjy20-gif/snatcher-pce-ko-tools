-- SUB 0.4.36 -- 전체 음성 키/미니 색인/동기 조각 + 동적 VRAM allocator
--
-- 0.4.35의 자막 수명 경로를 유지하고, 고정 $1600을 버린다.
-- 음성마다·조각마다 현재 BAT/SATB가 참조하지 않는 19셀 블록을 다시 고른다.

SUB_VOICE_KEY_VERSION = '0.4.36'
dofile('C:/snatcher/lua/SUB/0.4.35.lua')
SUB_VOICE_KEY_VERSION = nil

SUB_ALLOCATOR_VERSION = '0.4.36-dynamic'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = false
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
dofile('C:/snatcher/lua/SUB/0.3.42-wide.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil

emu.log('SUB 0.4.36 loaded -- mini index + synchronous fragments + dynamic BAT/SATB allocator')
emu.log('  fixed $1600 사용 안 함 · 음성/조각마다 참조되지 않는 VRAM 블록 재선정')
