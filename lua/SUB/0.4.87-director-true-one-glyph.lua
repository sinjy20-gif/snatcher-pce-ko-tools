-- SUB 0.4.87 -- 국장실 떨림 대조용: 별도 컴파일 엔진으로 진짜 한 글자만 전송.
--
-- 실행 전 tools/build_subtitle_engine_oneglyph.py가 만든 631 B 엔진을 쓴다.
-- 원본과 주소/길이는 같고, record.cells 읽기만 LDA #1로 바뀌었다.
-- 따라서 loop, SATB push 모두 처음부터 한 칸이며 런타임 코드 패치는 없다.

SUB_CONTROLLER_ENGINE_PATH =
  'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_oneglyph.bin'
SUB_CONTROLLER_FORCE_ENGINE_UPLOAD = true
dofile('C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua')
SUB_CONTROLLER_ENGINE_PATH = nil
SUB_CONTROLLER_FORCE_ENGINE_UPLOAD = nil

emu.log('SUB 0.4.87-director-true-one-glyph armed -- compiled one-glyph engine')
emu.log('  한 글자만 표시/업로드되는 것이 정상 · 0.4.84~0.4.86은 사용하지 말 것')
