-- SUB 0.4.89-controller -- 재무장 엔진용 controller.  0.4.57 을 건드리지 않는다.
--
-- 왜 따로 만드나
-- ---------------------------------------------------------------------------
-- 재무장 코드가 글리프 루프 안으로 들어가면서 엔진이 631 B -> 653 B 가 됐고,
-- `ready` / `selector` / `stage` 오프셋이 전부 뒤로 밀렸다.  그런데 0.4.57 은
-- 631 · 345 · 343 을 하드코딩한다.  거기를 고치면 **지금 유일하게 잘 도는
-- 경로를 잃는다.**  그래서 0.4.57 은 그대로 두고, 빌더가 내보낸 오프셋 표를
-- 읽는 판을 따로 둔다.
--
--     tools/build_subtitle_engine_vdc_rearm.py
--       -> build/cutscene_subs/engine_ac_lua_frame_rearm.bin
--       -> build/cutscene_subs/engine_ac_lua_frame_rearm.lua   ← 이 파일이 읽는 표
--
-- 표를 읽으므로 엔진을 다시 구워 크기가 또 바뀌어도 이 파일은 안 고쳐도 된다.
-- 0.4.57 과 나머지 설정(mini index · Lua timer · audit)은 같다.

-- base 를 바꿔 구운 판(예: --pat-vram 0x7900)을 시험할 때 이 전역으로 표를 바꾼다.
local INFO_PATH = rawget(_G, 'SUB_REARM_INFO_PATH') or
                  'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.lua'
local info = assert(dofile(INFO_PATH), 'cannot read engine offset table: ' .. INFO_PATH)
local off = info.offsets

for _, need in ipairs({'entry', 'count_ok', 'ready', 'selector', 'stage'}) do
  assert(off[need], 'offset table missing: ' .. need)
end

-- 다른 체인이 남겨둔 전역이 섞이지 않게 한다 (0.4.57 과 같은 조치).
_G.SUB_ALLOCATOR_ARM_MATCHED = nil

SUB_VOICE_KEY_VERSION = '0.4.89-vdc-rearm'
SUB_VOICE_ENGINE_PATH = info.path
SUB_VOICE_ENGINE_BYTES = info.engine_bytes
SUB_VOICE_SELECTOR = off.selector
SUB_VOICE_READY_OFFSET = off.ready
SUB_VOICE_MINI_INDEX = info.mini_index
SUB_VOICE_MINI_COUNT = info.mini_count
SUB_VOICE_LUA_TIMER = true
SUB_VOICE_NO_NEXT_SELECTOR = true
SUB_VOICE_AUDIT = true
SUB_VOICE_SUPPRESS_LEGACY_GATE = false
-- 첫 적재만 강제한다.  이후에는 0.4.31 의 전량 비교가 디스크 선적재의 되돌림을
-- 매 음성 gate 에서 잡는다 ($1F1F00 은 디스크 상주 렌더러 슬롯이다).
SUB_VOICE_FORCE_ENGINE_UPLOAD = true

dofile('C:/snatcher/lua/SUB/0.4.31.lua')

SUB_VOICE_KEY_VERSION = nil
SUB_VOICE_ENGINE_PATH = nil
SUB_VOICE_ENGINE_BYTES = nil
SUB_VOICE_SELECTOR = nil
SUB_VOICE_READY_OFFSET = nil
SUB_VOICE_MINI_INDEX = nil
SUB_VOICE_MINI_COUNT = nil
SUB_VOICE_LUA_TIMER = nil
SUB_VOICE_NO_NEXT_SELECTOR = nil
SUB_VOICE_AUDIT = nil
SUB_VOICE_SUPPRESS_LEGACY_GATE = nil
SUB_VOICE_FORCE_ENGINE_UPLOAD = nil

-- 뒤따르는 0.4.89-stage / 0.4.89-marker 가 같은 표를 다시 읽지 않도록 넘긴다.
_G.SUB_REARM_INFO = info

emu.log(string.format('SUB 0.4.89-controller armed -- engine %d B · rearm 판',
                      info.engine_bytes))
emu.log(string.format('  ready +%d ($%04X) · selector +%d · stage +%d ($%04X)',
                      off.ready, info.engine_lo + off.ready, off.selector,
                      off.stage, info.engine_lo + off.stage))
