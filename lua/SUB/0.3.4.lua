-- SUB 0.3.4 -- keyed POC와 같은 E6800_0E 한 음성에서 allocator 검증
--
-- 현재 native BIOS는 아직 end=$6800/rate=$0E만 자막 엔진을 시작시킨다.
-- allocator도 같은 음성에만 맞춰 자막 표시 + VRAM 무충돌을 먼저 검증한다.

SUB_ALLOCATOR_VERSION = '0.3.4'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = 0x6800
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
