-- SUB 0.4.57-controller-only -- 전체 키 controller 단독 분리시험
--
-- 포함: pack/631 B engine, 902키 lookup, mini index, selector, Lua timer, gate
-- 제외: allocator, record-Y callback, stage 재무장, fragment/end wipe,
--       MISS legacy suppression
-- 고정 VRAM $1600. Power Cycle 뒤 이 파일 하나만 실행할 것.

_G.SUB_ALLOCATOR_ARM_MATCHED = nil
SUB_VOICE_KEY_VERSION = '0.4.57-controller-only'
SUB_VOICE_ENGINE_PATH = rawget(_G, 'SUB_CONTROLLER_ENGINE_PATH') or
                        'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'
SUB_VOICE_ENGINE_BYTES = 631
SUB_VOICE_SELECTOR = 345
SUB_VOICE_MINI_INDEX = 0x1EF000
SUB_VOICE_MINI_COUNT = 11
SUB_VOICE_LUA_TIMER = true
SUB_VOICE_READY_OFFSET = 343
SUB_VOICE_NO_NEXT_SELECTOR = true
SUB_VOICE_AUDIT = true
SUB_VOICE_SUPPRESS_LEGACY_GATE = false
SUB_VOICE_FORCE_ENGINE_UPLOAD = rawget(_G, 'SUB_CONTROLLER_FORCE_ENGINE_UPLOAD') == true

dofile('C:/snatcher/lua/SUB/0.4.31.lua')

SUB_VOICE_KEY_VERSION = nil
SUB_VOICE_ENGINE_PATH = nil
SUB_VOICE_ENGINE_BYTES = nil
SUB_VOICE_SELECTOR = nil
SUB_VOICE_MINI_INDEX = nil
SUB_VOICE_MINI_COUNT = nil
SUB_VOICE_LUA_TIMER = nil
SUB_VOICE_READY_OFFSET = nil
SUB_VOICE_NO_NEXT_SELECTOR = nil
SUB_VOICE_AUDIT = nil
SUB_VOICE_SUPPRESS_LEGACY_GATE = nil
SUB_VOICE_FORCE_ENGINE_UPLOAD = nil

emu.log('SUB 0.4.57-controller-only armed -- NO allocator / NO wipe')
emu.log('  fixed VRAM $1600 · KEY 성공 단계별 MATCH/ENGINE/MINI/SELECTOR/GATE 로그')
emu.log('  첫 6800 음성의 자막 출력·진행 여부 확인')
