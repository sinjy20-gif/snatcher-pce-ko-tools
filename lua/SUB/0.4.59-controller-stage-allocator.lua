-- SUB 0.4.59-controller-stage-allocator -- matched-only allocator 결합시험
--
-- 0.4.58의 정상 controller+stage에 allocator만 추가한다.
-- fragment/end wipe와 record-Y 보정은 아직 없다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

dofile('C:/snatcher/lua/SUB/0.4.58-controller-stage.lua')

SUB_ALLOCATOR_VERSION = '0.4.59-matched'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = false
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
SUB_ALLOCATOR_REQUIRE_MATCHED = true
SUB_ALLOCATOR_VERIFY_DETAIL = false
SUB_ALLOCATOR_ENGINE = 0x5B80
SUB_ALLOCATOR_REBUILD_OFFSET = 17
SUB_ALLOCATOR_COUNT_OK_OFFSET = 118
SUB_ALLOCATOR_VRAM_LO_OFFSET = 144
SUB_ALLOCATOR_VRAM_HI_OFFSET = 146
SUB_ALLOCATOR_PAT_LO_OFFSET = 255
SUB_ALLOCATOR_ATTR_OFFSET = 260

dofile('C:/snatcher/lua/SUB/0.3.43-defer.lua')

SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil
SUB_ALLOCATOR_REQUIRE_MATCHED = nil
SUB_ALLOCATOR_VERIFY_DETAIL = nil
SUB_ALLOCATOR_ENGINE = nil
SUB_ALLOCATOR_REBUILD_OFFSET = nil
SUB_ALLOCATOR_COUNT_OK_OFFSET = nil
SUB_ALLOCATOR_VRAM_LO_OFFSET = nil
SUB_ALLOCATOR_VRAM_HI_OFFSET = nil
SUB_ALLOCATOR_PAT_LO_OFFSET = nil
SUB_ALLOCATOR_ATTR_OFFSET = nil

emu.log('SUB 0.4.59 armed -- controller + stage + MATCHED-ONLY allocator')
emu.log('  MISS allocator 무장 0회 · KEY에서만 armed/PATCHED 예상')
emu.log('  NO fragment/end wipe · 미카 3조각과 이후 진행 확인')
