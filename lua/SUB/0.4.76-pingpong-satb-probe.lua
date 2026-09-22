-- SUB 0.4.76 -- 0.4.73 A/B ping-pong에서 자막 줄 SATB 항목만 읽는다.
-- 게임/AC/VRAM/Sprite RAM 추가 쓰기 0 B.

SUB_SATB_CHILD = 'C:/snatcher/lua/SUB/0.4.73-controller-stage-pingpong.lua'
dofile('C:/snatcher/lua/SUB/0.4.68-satb.lua')
SUB_SATB_CHILD = nil

emu.log('SUB 0.4.76-pingpong-satb-probe loaded -- A/B 경로의 SATB slot audit')
emu.log('  Power Cycle 뒤 이 파일 하나만 실행 · output은 satb_0_4_68_*.tsv')
