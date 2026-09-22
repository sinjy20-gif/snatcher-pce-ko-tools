-- PROBE_SAT_SURVIVE 0.1.0  --  $6527 에서 쓰고, 프레임 끝에 살아남았는지 본다
--
-- 왜 이 판인가
-- ------------
-- Mesen 스크립트 창은 하나뿐이라 SAT_AFTER_PUSH 와 SATB_DUMP 를 같이 못 돌린다.
-- 그래서 둘을 합친다.  쓰기와 확인이 한 프레임 안에서 짝을 이뤄야 판정이 된다.
--
-- 지금까지 통과한 것 (2026-08-23)
--   패턴      VRAM byte $F200 도착.  poc_patterns 와 일치
--   SAT 값    byte $2140 에 정확히 도착
--   훅 자리    $6527 은 게임 SAT 루프의 끝.  15,600 회 걸림
--   엔트리 형식  게임 slot 12 가 attr $0080 · pal 0 · 16x16 · front 로 우리와 동일
--   패턴번호   게임 $028C>>1*64=$5180 / 우리 $03C8>>1*64=$7900.  공식 검증됨
--
-- 그런데도 안 보인다.  남은 질문은 하나다:
--   **우리 엔트리가 프레임 끝까지 살아 있는가?**
--
-- 팔레트 주의
--   게임 slot 12·13·14 도 팔레트 0 을 쓴다.  SUBTITEL 0.2.13 이 그 팔레트의
--   색 1·2 를 덮어쓰고 있었다.  이 프로브는 팔레트를 안 건드린다 -- 게임이
--   이미 쓰는 팔레트라면 색이 이미 들어 있을 것이고, 그러면 우리 글자도 보여야 한다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_survive_0_1_0_<날짜>.tsv

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH = "C:/snatcher/SUBTITEL/0.2.13.bin"

local SATB = 0x2000                     -- VDC 워드 $1000 = Mesen 바이트 $2000
local SLOT = 40
local ENTRY = { 0xF4, 0x00, 0x84, 0x00, 0xC8, 0x03, 0x80, 0x00 }
local OURS = SATB + SLOT * 8

local loaded, tries, frames = false, 0, 0
local writes, alive, dead, reported = 0, 0, 0, 0
local lines = {}

local function rb(a) return emu.read(a, VRAM) or 0 end
local function say(s) emu.log(s); lines[#lines+1] = s end

-- AC 적재
local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다') return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

emu.addEventCallback(function()
  frames = frames + 1
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
      emu.log(string.format('AC 적재 완료 (%d 프레임째)', tries))
    elseif tries >= 300 then loaded = true; emu.log('★ AC 적재 실패') end
  end
end, emu.eventType.startFrame)

-- 게임 SAT 푸시가 끝나는 지점마다 우리 엔트리를 쓴다
emu.addMemoryCallback(function()
  for i = 1, #ENTRY do emu.write(OURS + i - 1, ENTRY[i], VRAM) end
  writes = writes + 1
end, emu.callbackType.exec, 0x6527, 0x6527, emu.cpuType.pce, MEM)

-- 프레임 끝에 살아남았는지 확인
emu.addEventCallback(function()
  local ok = true
  for i = 1, #ENTRY do if rb(OURS + i - 1) ~= ENTRY[i] then ok = false end end
  if ok then alive = alive + 1 else dead = dead + 1 end

  if writes > 0 and reported < 3 and (alive + dead) % 120 == 0 then
    reported = reported + 1
    local cur = {}
    for i = 0, 7 do cur[#cur+1] = string.format('%02X', rb(OURS + i)) end
    say(string.format('[프레임 %d] $6527 쓰기 %d · 프레임끝 생존 %d · 지워짐 %d',
        frames, writes, alive, dead))
    say(string.format('  슬롯 %d 현재값  %s', SLOT, table.concat(cur, ' ')))
    say(string.format('  기대값          F4 00 84 00 C8 03 80 00'))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say(string.format('--- 정리 --- $6527 쓰기 %d 회 · 프레임끝 생존 %d · 지워짐 %d',
      writes, alive, dead))
  if writes == 0 then
    say('★ $6527 에 안 걸렸다')
  elseif alive == 0 then
    say('★ 한 번도 프레임 끝까지 못 살아남았다 -- 게임이 우리 뒤에 또 민다')
  elseif dead == 0 then
    say('★ 항상 살아남는다 -- 그런데도 안 보이면 값이 아니라 표시 조건 문제다')
  else
    say(string.format('★ 생존율 %.0f%% -- 깜빡이고 있을 것이다', 100 * alive / (alive + dead)))
  end
  local name = string.format('C:/snatcher/dump/probe_sat_survive_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
    emu.log('-> ' .. name)
  end
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_SURVIVE 0.1.0 loaded')
emu.log('  음성 대사 장면으로 가면 된다.  팔레트는 안 건드린다')
