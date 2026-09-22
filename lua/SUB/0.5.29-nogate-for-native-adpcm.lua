-- SUB 0.5.29 -- 0.4.6.26(네이티브 ADPCM 감지) 전용 실행판.  위조를 끈다
--
-- 왜 이게 따로 필요한가
-- ---------------------------------------------------------------------------
-- `0.4.31` 은 기존 네이티브 게이트가 **음성 하나(`$22A7 == $68`)만** 받기 때문에
-- 게이트를 열려고 `$22A6/$22A7/$22AA` 를 가짜 값으로 덮어썼다.
--
-- 0.4.6.26 은 그 게이트를 일반화했다.  이제 게임이 자연히 써 넣는 진짜 값으로
-- 열린다.  그러므로 **위조를 계속하면 안 된다.**
--
-- ★ 위험이 실재한다.  게임은 `$F5E7` 에서 `$22A7` 을 쓰고 `$F604` 에서 읽는다.
--   그 사이에 Lua 가 값을 바꾸면 **음성이 엉뚱한 주소에서 재생된다.**
--   (0.5.28 로 뜬 셋업 루틴 전문 기준 · baseline §9.1.1)
--
-- `SUB_VOICE_NO_GATE` 는 `0.4.31` 이 **로드 시점에** 읽는다
-- (`local NO_GATE = rawget(_G,'SUB_VOICE_NO_GATE') == true`).
-- 그래서 dofile 보다 **먼저** 세워야 한다.  이 파일이 하는 일이 그것뿐이다.
--
-- 무엇이 네이티브고 무엇이 아직 Lua 인가
-- ---------------------------------------------------------------------------
--     감지 (음성 시작)      네이티브 $FEC4      ← 이번 판
--     6 B 키 · 팩 조회 · mini index · selector   아직 Lua
--     CD-DA 전체            네이티브 (0.4.6.25 에서 실기 PASS)
--
-- 판정
--     음성 자막이 뜨면      게이트가 진짜 값으로 열렸다.  감지 이관 성공
--     안 뜨면               게이트가 안 열린다.  $180D / $22A7 를 다시 본다
--     CD-DA 가 깨지면       합치면서 CD-DA 분기를 건드렸다
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크/BIOS 는 0.4.6.26-dual-detect.

-- ★ 위조 금지.  dofile 보다 먼저 세운다.
SUB_VOICE_NO_GATE = true

-- ★ 화면 오버레이 차단.  동결본 0.4.93 / 0.4.31 이 HUD 를 그린다.
-- 그 파일들은 해시 등재본이라 한 바이트도 안 건드리고 함수만 무력화한다.
emu.drawString = function() end

dofile('C:/snatcher/lua/SUB/0.4.93-hq-key-vram.lua')

local MEM = emu.memType.pceMemory
local STATE = 0x7FDF

-- 네이티브 게이트가 실제로 열리는지만 조용히 센다.  게임 상태는 안 바꾼다.
local seen, arms, frame = -1, 0, 0
emu.addEventCallback(function()
  frame = frame + 1
  local s = emu.read(STATE, MEM) or -1
  if s ~= seen then
    seen = s
    if s == 1 then
      arms = arms + 1
      emu.log(string.format(
        'SUB 0.5.29 ★ 네이티브 게이트 ARM #%d · %df · $22A7=$%02X $22AA=$%02X $180D=$%02X',
        arms, frame,
        emu.read(0x22A7, MEM) or 0, emu.read(0x22AA, MEM) or 0,
        emu.read(0x180D, MEM) or 0))
    end
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.29-nogate-for-native-adpcm armed')
emu.log('  ★ SUB_VOICE_NO_GATE = true -- $22A6/$22A7/$22AA 위조를 하지 않는다')
emu.log('  디스크는 0.4.6.26-dual-detect 여야 한다 (게이트 일반화판)')
emu.log('  ARM 이 0 이면 네이티브 게이트가 안 열린 것이다')
