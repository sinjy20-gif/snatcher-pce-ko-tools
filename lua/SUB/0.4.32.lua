-- SUB 0.4.32 -- 0.4.31의 미측정 ZP $18/$19 사용 제거판
-- 검색 카운터는 렌더러가 원래 작업용으로 쓰던 $15/$16만 사용한다.
SUB_VOICE_KEY_VERSION = '0.4.32'
dofile('C:/snatcher/lua/SUB/0.4.31.lua')
SUB_VOICE_KEY_VERSION = nil
