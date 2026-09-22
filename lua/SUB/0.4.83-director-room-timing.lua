-- SUB 0.4.83 -- 국장실 떨림 원인 측정: 0.4.82 고정경로 + 0.4.70 timing probe.
--
-- 자막 VRAM 충돌을 고치는 파일이 아니다. 업로드가 몇 스캔라인을 점유하는지,
-- 그리고 그때 이미 화면이 $1600을 참조하는지만 읽어 기록한다.
-- 추가 게임/AC/VRAM/Sprite RAM write 0 B.

SUB_WHEN_CHILD = 'C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua'
dofile('C:/snatcher/lua/SUB/0.4.70-when.lua')
SUB_WHEN_CHILD = nil

emu.log('SUB 0.4.83-director-room-timing loaded -- fixed $1600 + wipe timing audit')
emu.log('  국장실에서 떨림이 보이는 대사 1~2개만 재생 후 Stop')
emu.log('  upload 스캔라인 span / 산자리덮음 / game redraw을 TSV에 기록한다')
