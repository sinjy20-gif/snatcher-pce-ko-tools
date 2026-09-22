-- SUB 0.4.50-allparts-hunt -- 전체 번역 대사 사냥용
--
-- 0.4.48의 조각 전환/종료 wipe 동작은 그대로 두고, 현재 팩의 실측 최대인
-- 11조각까지 mini index에 싣는다.  기준 디스크는 0.4.6.11이며 이 Lua 하나만
-- 실행한다.  독립 디스크 출하판은 아니다.

SUB_RUNTIME_MINI_COUNT = 11
dofile('C:/snatcher/lua/SUB/0.4.48-fragment-wipe.lua')
SUB_RUNTIME_MINI_COUNT = nil

emu.log('SUB 0.4.50-allparts-hunt loaded -- mini index 11조각 · 전체 번역 대사 사냥용')
emu.log('  기준 디스크 0.4.6.11 · Power Cycle 뒤 이 파일 하나만 실행')
