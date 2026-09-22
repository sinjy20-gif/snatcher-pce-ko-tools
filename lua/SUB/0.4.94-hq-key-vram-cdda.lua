-- SUB 0.4.94 -- HQ ADPCM 자막 + CD-DA 트랙 자막 통합 진입점.
--
-- 일반 ADPCM은 0.4.93의 key별 VRAM A-base 체인을 그대로 쓴다.
-- CD-DA는 CDDA_SUBTITLE_RUNTIME의 track 단위 원고와 verified 안전 위치만 쓴다.
-- 둘 다 필요한 CPU RAM을 쓸 때 CD-DA 쪽이 반드시 백업·복원하므로 한 파일만 로드한다.
--
-- 사용:
--   Power Cycle -> 이 파일 하나만 로드
--   CD-DA 번역을 넣고 cdda_safe_positions.tsv의 해당 track을 verified로 바꾼 뒤 재생

dofile('C:/snatcher/lua/SUB/0.4.93-hq-key-vram.lua')

_G.SUB_CDDA_INTEGRATED = true
dofile('C:/snatcher/lua/CD-DA/CDDA_SUBTITLE_POC_0.1.3.lua')
_G.SUB_CDDA_INTEGRATED = nil

emu.log('SUB 0.4.94 HQ+CDDA armed -- ADPCM key map + CD-DA verified-safe tracks')
