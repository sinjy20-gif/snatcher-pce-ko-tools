-- PROBE_SAT_AFTER_PUSH 0.1.0
--
-- 무엇을 증명하나
-- ----------------
-- "게임의 SAT 푸시 루프가 끝난 직후에 우리 엔트리를 쓰면 화면에 보이는가?"
--
-- 여기까지 확인된 것 (2026-08-23)
--   PROBE_SUBS_VERIFY 0.1.1
--     설치직후   SAT byte $2140 = F4 00 84 00 C8 03 80 00   우리 값이 정확히 도착
--     +30 프레임 SAT byte $2140 = 00 00 00 00 00 00 00 00   게임이 0 으로 지웠다
--     패턴(byte $F200)은 그대로 남아 있다
--
--   디스크 오버레이 정적 디스어셈블 ($6000 베이스, Track02 섹터 251+)
--     6500  CLX
--     6501  LDA $00,X        <- 제로페이지 $00-$07 에 엔트리를 조립해서
--     6503  STA $0002           VWR 로 하나씩 밀어 넣는다
--     650D  CPX #$08
--     650F  BNE $6501
--     6512  DEC $17          <- 남은 엔트리 수
--     6524  JMP $6463        <- 다음 엔트리
--     6527  RTS              <- ★ 루프 종료 지점
--
--   빈 슬롯을 0 으로 채우므로 "게임이 안 쓰는 슬롯" 이라는 것은 없다.
--   64 개 전부 게임이 매 패스 관리한다.
--
-- 그래서 이 프로브는
--   $6527 에 실행 콜백을 걸고, 거기서 VRAM SATB 에 우리 엔트리를 직접 쓴다.
--   게임이 막 전송을 마친 시점이라 MAWR 이 놀고 있고, 다음 패스 전까지 살아남는다.
--
-- ★ 이것은 엔진이 아니라 개념 증명이다.  Lua 가 직접 VRAM 을 쓴다.
--   보이면 -> 디스크 패치에서 $6527 을 훅해 같은 일을 하면 된다
--   안 보이면 -> SAT 값·팔레트·패턴 중 다른 문제가 남아 있다
--
-- 전제: SUBTITEL 0.2.13 으로 부팅해서 패턴이 이미 VRAM 에 올라가 있어야 한다.
--       (PROBE_SUBS_VERIFY 0.1.1 이 하던 AC 적재도 여기서 같이 한다)
--
-- 출력  로그.  게임 메모리는 안 건드리고 VRAM SATB 한 칸만 쓴다.

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH = "C:/snatcher/SUBTITEL/0.2.13.bin"

local SAT_BYTE = 0x2140                 -- VRAM 워드 $10A0 = 바이트 $2140 (슬롯 40)
local ENTRY = { 0xF4, 0x00, 0x84, 0x00, 0xC8, 0x03, 0x80, 0x00 }

-- ---------- AC 적재 (0.2.13 페이로드) ----------
local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다: ' .. PATH) return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

local loaded, tries, writes, frames = false, 0, 0, 0

emu.addEventCallback(function()
  frames = frames + 1
  if loaded then return end
  tries = tries + 1
  for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end
  local bad = 0
  for i = 1, #data do
    if emu.read(AC_ENGINE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
  end
  if bad == 0 then
    for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, MAGIC[i], AC) end
    loaded = true
    emu.log(string.format('AC 적재 완료 (%d 프레임째).  이제 $6527 을 기다린다', tries))
  elseif tries >= 300 then
    loaded = true
    emu.log('★ AC 적재 실패')
  end
end, emu.eventType.startFrame)

-- ---------- 게임의 SAT 푸시가 끝나는 지점 ----------
emu.addMemoryCallback(function()
  for i = 1, #ENTRY do emu.write(SAT_BYTE + i - 1, ENTRY[i], VRAM) end
  writes = writes + 1
  if writes == 1 or writes % 600 == 0 then
    emu.log(string.format('$6527 도달 %d 회 (프레임 %d) -- SAT 슬롯 40 을 다시 씀', writes, frames))
  end
end, emu.callbackType.exec, 0x6527, 0x6527, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  emu.log(string.format('--- 정리 --- $6527 도달 %d 회 / %d 프레임', writes, frames))
  if writes == 0 then
    emu.log('★ $6527 에 한 번도 안 걸렸다 -- 뱅크가 다르거나 그 루프가 아니다')
  end
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_AFTER_PUSH 0.1.0 loaded')
emu.log('  펌웨어는 SUBTITEL_0.2.13.pce 여야 한다 (패턴 업로드용)')
emu.log('  음성 대사 장면으로 가면 x=100 y=180 에 글자가 떠야 한다')
