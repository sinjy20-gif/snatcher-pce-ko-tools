-- PROBE_SAT_EXTEND 0.1.1  --  오버레이 지문을 확인하고 쓴다
--
-- 0.1.0 이 무엇을 잘못했나
-- ----------------------
-- 0.1.0 은 "$6072 가 우리 패치가 아니면 덮어쓴다" 로만 판단했다.  $6000-$7FFF 는
-- 장면마다 갈리는 CD-RAM 오버레이다.  다른 오버레이가 올라오면 그 자리는 전혀
-- 다른 코드인데, 0.1.0 은 거기에도 JMP $5C20 을 3 바이트 박았다.
--
--   probe_sat_extend_0_1_0_20260823_020613:  설치 4 · 푸시 0
--     -> 스텁은 한 번도 안 불렸는데 패치는 네 번 했다.  남의 코드를 네 번 뭉갰다.
--   probe_sat_extend_0_1_0_20260823_020606:  설치가 2 -> 5 -> 7 로 기어오름
--     -> 오버레이가 갈릴 때마다 덮어썼고, 스텁은 딴 오버레이의 $6463 을 JSR 했다.
--
-- 화면 전체가 깨진 이유다.  0.1.0 의 성과 자체는 진짜였다:
--
--   [프레임 2~1200] 슬롯 16  F4 00 84 00 C8 03 80 00  ★ 생존 871 회 연속
--   길리언 얼굴 멀쩡 -- 빼앗지 않고 늘리는 것은 성립한다.
--
-- 0.1.1 이 고친 것
-- --------------
--  1  오버레이 지문 4 개를 다 맞춰야만 패치한다.  하나라도 어긋나면 아무것도 안 쓴다.
--       $6072 = 4C BE 43   (원본 JMP $43BE)   또는 우리 패치
--       $601E = A9 3F 85 17 (LDA #$3F / STA $17)
--       $6500 = 82 B5 00    (CLX / LDA $00,X)
--       $6463 = C2          (CLY)
--  2  스텁 자신도 $6500 == $82 를 확인한 뒤에만 JSR $6463 한다.
--     패치가 살아남았는데 오버레이만 갈린 경우를 막는다.
--  3  PHP/SEI ... PLP 로 MAWR 을 든 구간을 감싼다.
--     0.2.13 의 MAWR 가드는 끊긴 PC 가 $6000-$65FF 일 때만 건너뛴다.
--     스텁은 $5C20 이라 가드 밖이다 -- IRQ 엔진이 우리 MAWR 을 뺏을 수 있었다.
--  4  지문이 어긋난 프레임의 $6072 실제 바이트를 찍는다.  다른 오버레이가
--     무엇인지 알아야 다음 판을 짤 수 있다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_extend_0_1_1_<날짜>.tsv  (300 프레임마다)

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"

local STUB, LIST = 0x5C20, 0x5C80
local HOOK, JSR_AT = 0x6072, 0x5C69
local SATB_BYTE = 0x2000

local CODE = {
  0x08, 0x78, 0xAD, 0x00, 0x65, 0xC9, 0x82, 0xD0,
  0x47, 0xA5, 0x17, 0x30, 0x43, 0xA9, 0x3F, 0x38,
  0xE5, 0x17, 0x0A, 0x0A, 0xAA, 0x9C, 0x00, 0x00,
  0x8E, 0x02, 0x00, 0xA9, 0x10, 0x8D, 0x03, 0x00,
  0xA9, 0x02, 0x8D, 0x00, 0x00, 0xA9, 0xF4, 0x85,
  0x08, 0xA9, 0x00, 0x85, 0x09, 0xA9, 0x84, 0x85,
  0x0A, 0xA9, 0x00, 0x85, 0x0B, 0x64, 0x0C, 0x64,
  0x0D, 0x64, 0x0E, 0x64, 0x0F, 0xA9, 0x80, 0x85,
  0x10, 0xA9, 0x5C, 0x85, 0x11, 0xA9, 0x01, 0x85,
  0x16, 0x20, 0x63, 0x64, 0x28, 0x4C, 0xBE, 0x43,
  0x28, 0x4C, 0xBE, 0x43,
}
-- 레코드 1 개: 패턴 워드 $7900 -> SAT word2 $03C8 -> [3]=$C8, [4]=$B0
local RECORD = { 0x00, 0x00, 0x00, 0xC8, 0xB0 }
local ORIG   = { 0x4C, 0xBE, 0x43 }
local PATCH  = { 0x4C, STUB & 0xFF, STUB >> 8 }

-- 스프라이트 오버레이 지문.  전부 맞아야 한다.
local SIG = {
  { 0x601E, { 0xA9, 0x3F, 0x85, 0x17 } },   -- $17 = 전역 슬롯 예산 63
  { 0x6463, { 0xC2 } },                     -- 엔트리 파서 머리 CLY
  { 0x6500, { 0x82, 0xB5, 0x00 } },         -- 푸시 루프 CLX / LDA $00,X
}

local loaded, tries, frames = false, 0, 0
local installs, pushes, alive, dead = 0, 0, 0, 0
local live, absent = 0, 0
local slot_seen, logged, stranger = -1, 0, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function match(addr, want)
  for i = 1, #want do
    if emu.read(addr + i - 1, MEM) ~= want[i] then return false end
  end
  return true
end

local function fingerprint()
  for _, s in ipairs(SIG) do
    if not match(s[1], s[2]) then return false end
  end
  return true
end

local function flush()
  local name = string.format('C:/snatcher/dump/probe_sat_extend_0_1_1_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
    emu.log('-> ' .. name)
  end
end

local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다: ' .. PATH) return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

local function consider()
  -- 지문이 어긋나면 절대 쓰지 않는다
  if not fingerprint() then
    absent = absent + 1
    if stranger < 5 and not match(HOOK, PATCH) and not match(HOOK, ORIG) then
      stranger = stranger + 1
      local b = {}
      for i = 0, 5 do b[#b+1] = string.format('%02X', emu.read(HOOK + i, MEM) or 0) end
      say(string.format('[프레임 %d] 다른 오버레이 -- 건드리지 않는다.  $6072 = %s',
                        frames, table.concat(b, ' ')))
    end
    return
  end

  live = live + 1
  if match(HOOK, PATCH) then return end          -- 이미 우리 것
  if not match(HOOK, ORIG) then                  -- 지문은 맞는데 $6072 가 낯설다
    if stranger < 5 then
      stranger = stranger + 1
      local b = {}
      for i = 0, 5 do b[#b+1] = string.format('%02X', emu.read(HOOK + i, MEM) or 0) end
      say(string.format('[프레임 %d] ★ 지문은 맞는데 $6072 가 원본이 아니다: %s',
                        frames, table.concat(b, ' ')))
    end
    return
  end

  for i = 1, #CODE   do emu.write(STUB + i - 1, CODE[i],   MEM) end
  for i = 1, #RECORD do emu.write(LIST + i - 1, RECORD[i], MEM) end
  for i = 1, #PATCH  do emu.write(HOOK + i - 1, PATCH[i],  MEM) end
  installs = installs + 1
  if installs <= 5 then
    say(string.format('[프레임 %d] 지문 일치 -- 스텁 설치 %d 회째', frames, installs))
  end
end

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
      say(string.format('AC 적재 완료 (%d 프레임째)', tries))
    elseif tries >= 300 then
      loaded = true; say('★ AC 적재 실패')
    end
  end

  consider()

  if slot_seen >= 0 then
    local base = SATB_BYTE + slot_seen * 8
    local ok = emu.read(base, VRAM) == 0xF4 and emu.read(base + 2, VRAM) == 0x84
                 and emu.read(base + 4, VRAM) == 0xC8
    if ok then alive = alive + 1 else dead = dead + 1 end
    if logged < 5 then
      logged = logged + 1
      local b = {}
      for i = 0, 7 do b[#b+1] = string.format('%02X', emu.read(base + i, VRAM) or 0) end
      say(string.format('[프레임 %d] 슬롯 %d  %s  %s',
                        frames, slot_seen, table.concat(b, ' '),
                        ok and '★ 생존' or '지워짐'))
    end
    slot_seen = -1
  end

  if frames % 300 == 0 then
    say(string.format('--- %d --- 설치 %d · 푸시 %d · 생존 %d · 지워짐 %d · 오버레이 있음 %d / 없음 %d',
                      frames, installs, pushes, alive, dead, live, absent))
    flush()
  end
end, emu.eventType.startFrame)

emu.addMemoryCallback(function()
  pushes = pushes + 1
  slot_seen = 0x3F - (emu.read(0x2017, MEM) or 0x3F)
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  say(string.format('--- 정리 --- %d 프레임 · 설치 %d · 푸시 %d · 생존 %d · 지워짐 %d · 오버레이 있음 %d / 없음 %d',
                    frames, installs, pushes, alive, dead, live, absent))
  if installs == 0 then say('★ 지문이 한 번도 안 맞았다 -- 그 장면은 다른 오버레이다') end
  flush()
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_EXTEND 0.1.1 loaded  --  지문 확인 후에만 패치한다')
