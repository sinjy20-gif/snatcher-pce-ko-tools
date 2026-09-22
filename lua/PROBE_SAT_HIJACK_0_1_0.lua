-- PROBE_SAT_HIJACK 0.1.0  --  게임 손을 빌린다
--
-- 발상
-- ----
-- 지금까지는 게임이 다 쓴 뒤에 우리 엔트리를 끼워 넣으려 했고, 매번 지워졌다.
--
--   PROBE_SAT_SURVIVE 0.1.0:  $6527 쓰기 2068 회 · 프레임끝 생존 1 · 지워짐 359
--
-- 게임은 매 프레임 SATB 64 칸을 전부 자기 것으로 다시 쓴다.  빈 슬롯을 빌리는
-- 접근은 구조적으로 성립하지 않는다.
--
-- 그래서 방향을 튼다.  디스어셈블에 조립 지점이 있다:
--
--   64FF  PHX
--   6500  CLX              <- 엔트리 하나당 한 번
--   6501  LDA $00,X        <- 제로페이지 $00-$07 에 조립된 엔트리를
--   6503  STA $0002           VWR 로 밀어 넣는다
--   650D  CPX #$08
--   650F  BNE $6501
--
-- $6500 에서 zp $00-$07 을 우리 값으로 바꿔치기하면, **게임이 자기 손으로**
-- 우리 스프라이트를 밀어 넣는다.  게임이 쓴 것이므로 지워지지 않는다.
--
-- PCE 제로페이지는 $2000-$20FF 이므로 zp $00 = CPU $2000 이다.
--
-- 무엇을 바꾸나
--   프레임마다 N 번째 엔트리 하나만 우리 것으로 바꾼다.  그 자리에 있던 게임
--   스프라이트는 그 프레임 동안 안 보인다 -- **개념 증명이므로 감수한다.**
--   글자가 뜨는지만 확인하면 된다.
--
-- 전제: 펌웨어 SUBTITEL_0.2.13.pce (패턴이 VRAM $7900 에 올라가야 한다).
--       AC 적재는 이 스크립트가 같이 한다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_hijack_0_1_0_<날짜>.tsv

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH = "C:/snatcher/SUBTITEL/0.2.13.bin"

local ZP = 0x2000                       -- zp $00
local TARGET = 5                        -- 프레임 내 N 번째 엔트리를 가로챈다
-- y=180+64, x=100+32, pat=$7900 -> $03C8, attr=$0080
local ENTRY = { 0xF4, 0x00, 0x84, 0x00, 0xC8, 0x03, 0x80, 0x00 }

local loaded, tries, frames = false, 0, 0
local seen, hijacked, logged = 0, 0, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다') return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

emu.addEventCallback(function()
  frames = frames + 1
  seen = 0                                        -- 프레임마다 카운터 초기화
  if not loaded then
    tries = tries + 1
    for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end
    local bad = 0
    for i = 1, #data do
      if emu.read(AC_ENGINE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
    end
    if bad == 0 then
      for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, MAGIC[i], AC) end
      loaded = true
      emu.log(string.format('AC 적재 완료 (%d 프레임째).  %d 번째 엔트리를 가로챈다',
              tries, TARGET))
    elseif tries >= 300 then loaded = true; emu.log('★ AC 적재 실패') end
  end
end, emu.eventType.startFrame)

emu.addMemoryCallback(function()
  seen = seen + 1
  if seen ~= TARGET then return end

  if logged < 3 then
    logged = logged + 1
    local was = {}
    for i = 0, 7 do was[#was+1] = string.format('%02X', emu.read(ZP + i, MEM) or 0) end
    say(string.format('[프레임 %d] %d 번째 엔트리 가로챔', frames, TARGET))
    say(string.format('  원래값  %s', table.concat(was, ' ')))
    say(string.format('  우리값  F4 00 84 00 C8 03 80 00'))
  end

  for i = 1, #ENTRY do emu.write(ZP + i - 1, ENTRY[i], MEM) end
  hijacked = hijacked + 1
end, emu.callbackType.exec, 0x6500, 0x6500, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  say(string.format('--- 정리 --- 가로챔 %d 회 / %d 프레임', hijacked, frames))
  if hijacked == 0 then
    say('★ $6500 에 안 걸렸거나 엔트리가 %d 개 미만이다 -- TARGET 을 줄여볼 것' )
  end
  local name = string.format('C:/snatcher/dump/probe_sat_hijack_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
    emu.log('-> ' .. name)
  end
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_HIJACK 0.1.0 loaded')
emu.log('  음성 대사 장면으로.  게임 스프라이트 하나가 우리 글자로 바뀌면 성공')
