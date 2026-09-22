-- PROBE_SAT_EXTEND 0.1.3  --  패치를 프레임 밖으로 안 내보낸다
--
-- 0.1.2 가 무엇을 남겼나
-- --------------------
-- 0.1.2 의 푸시는 완벽했다 (생존 1187 · 지워짐 1).  지문 게이트도 일했다.
--
--   [프레임 555]  $606F = 62 20 1B E0 C9 00   -> 디스크 섹터 255 에 실재.
--                 오버레이 B 를 정확히 알아보고 안 건드렸다.
--   [프레임 1585] $606F = E6 20 20 5C 4C BE   -> ★ 디스크 어디에도 없다.
--                 20 20 5C 는 우리 패치다.  오버레이가 갈렸는데 남아 있었다.
--
-- 남의 오버레이가 그 JSR 을 실행하면 우리 스텁으로 들어오고, $6500 지문이
-- 안 맞아 JMP $60A6 로 빠지는데 그 오버레이의 $60A6 은 전혀 다른 코드다.
-- **UI 복귀 실패의 정체다.**  지문 게이트는 "쓰기 전"만 막았지
-- "이미 쓴 것"은 못 거뒀다.
--
-- 0.1.3 이 고친 것
-- --------------
-- 패치 수명을 SATB 조립 한 번으로 줄인다.
--
--   601E  LDA #$3F    조립 시작 -- 여기서 지문 확인하고 패치를 심는다
--         ... 객체 루프 ...
--   606F  JSR $5C20   우리 스텁
--   6072  JMP $43BE   ★ 여기서 즉시 원본 20 A6 60 으로 되돌린다
--
-- $601E 에서 $6072 까지는 CD 접근이 없는 게임 자기 직선 코드다.  그 사이에
-- 오버레이가 갈릴 수 없다.  프레임 경계를 넘어 패치가 남는 일이 사라진다.
-- $6072 는 예산 소진 조기 탈출($6034/$6066 BMI)로도 반드시 지나므로
-- 스텁이 안 불린 경우까지 전부 회수된다.
--
-- 스텁은 0.1.2 와 같다: VDC 접근 0 회, MAWR 무접촉.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_extend_0_1_3_<날짜>.tsv  (300 프레임마다)

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"

local STUB, LIST = 0x5C20, 0x5C80
local HOOK  = 0x606F          -- JSR $60A6 자리.  0 채우기 직전
local ARM   = 0x601E          -- LDA #$3F.  조립 시작 -- 여기서 심는다
local DISARM= 0x6072          -- JMP $43BE.  반드시 지난다 -- 여기서 거둔다
local SATB_BYTE = 0x2000

local JSR_AT = 0x5C51
local CODE = {
  0x08, 0x78, 0xAD, 0x00, 0x65, 0xC9, 0x82, 0xD0,
  0x2B, 0xA5, 0x17, 0x30, 0x27, 0xA9, 0xF4, 0x85,
  0x08, 0xA9, 0x00, 0x85, 0x09, 0xA9, 0x84, 0x85,
  0x0A, 0xA9, 0x00, 0x85, 0x0B, 0x64, 0x0C, 0x64,
  0x0D, 0x64, 0x0E, 0x64, 0x0F, 0xA9, 0x80, 0x85,
  0x10, 0xA9, 0x5C, 0x85, 0x11, 0xA9, 0x01, 0x85,
  0x16, 0x20, 0x63, 0x64, 0x28, 0x4C, 0xA6, 0x60,
}
local RECORD = { 0x00, 0x00, 0x00, 0xC8, 0xB0 }
local ORIG   = { 0x20, 0xA6, 0x60 }              -- JSR $60A6
local PATCH  = { 0x20, STUB & 0xFF, STUB >> 8 }  -- JSR $5C20

local SIG = {
  { 0x601E, { 0xA9, 0x3F, 0x85, 0x17 } },
  { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } },
  { 0x60A6, { 0xA6, 0x17 } },
  { 0x6072, { 0x4C, 0xBE, 0x43 } },
}

local loaded, tries, frames = false, 0, 0
local armed, arms, pushes, alive, dead = false, 0, 0, 0, 0
local refused, stranded = 0, 0
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
  local name = string.format('C:/snatcher/dump/probe_sat_extend_0_1_3_%s.tsv',
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

local function disarm(where)
  if not armed then return end
  if match(HOOK, PATCH) then
    for i = 1, #ORIG do emu.write(HOOK + i - 1, ORIG[i], MEM) end
  else
    stranded = stranded + 1                 -- 우리 패치가 아니게 됐다.  손대지 않는다
    if stranded <= 3 then
      local b = {}
      for i = 0, 5 do b[#b+1] = string.format('%02X', emu.read(HOOK + i, MEM) or 0) end
      say(string.format('[프레임 %d] ★ %s 에서 회수 실패 -- $606F = %s',
                        frames, where, table.concat(b, ' ')))
    end
  end
  armed = false
end

-- 조립 시작.  지문이 맞을 때만 심는다.
emu.addMemoryCallback(function()
  if armed then disarm('재무장') end
  if not fingerprint() then refused = refused + 1; return end
  if not match(HOOK, ORIG) then refused = refused + 1; return end
  for i = 1, #CODE   do emu.write(STUB + i - 1, CODE[i],   MEM) end
  for i = 1, #RECORD do emu.write(LIST + i - 1, RECORD[i], MEM) end
  for i = 1, #PATCH  do emu.write(HOOK + i - 1, PATCH[i],  MEM) end
  armed = true; arms = arms + 1
  if arms <= 3 then say(string.format('[프레임 %d] 지문 일치 -- 무장 %d 회째', frames, arms)) end
end, emu.callbackType.exec, ARM, ARM, emu.cpuType.pce, MEM)

-- 조립 끝.  반드시 지난다.  여기서 무조건 거둔다.
emu.addMemoryCallback(function()
  disarm('$6072')
end, emu.callbackType.exec, DISARM, DISARM, emu.cpuType.pce, MEM)

-- 스텁이 게임 루프를 부르는 순간
emu.addMemoryCallback(function()
  pushes = pushes + 1
  slot_seen = 0x3F - (emu.read(0x2017, MEM) or 0x3F)
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

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
      loaded = true; say(string.format('AC 적재 완료 (%d 프레임째)', tries))
    elseif tries >= 300 then loaded = true; say('★ AC 적재 실패') end
  end

  -- 프레임 경계에 패치가 남아 있으면 안 된다.  남았다면 설계가 틀린 것이다.
  if armed then
    stranger = stranger + 1
    if stranger <= 3 then
      say(string.format('[프레임 %d] ★ 프레임 경계에 무장이 남았다 -- $6072 를 안 지났다', frames))
    end
    disarm('프레임경계')
  end

  if slot_seen >= 0 then
    local base = SATB_BYTE + slot_seen * 8
    local ok = emu.read(base, VRAM) == 0xF4 and emu.read(base + 2, VRAM) == 0x84
                 and emu.read(base + 4, VRAM) == 0xC8
    if ok then alive = alive + 1 else dead = dead + 1 end
    if logged < 5 then
      logged = logged + 1
      local b = {}
      for i = 0, 7 do b[#b+1] = string.format('%02X', emu.read(base + i, VRAM) or 0) end
      say(string.format('[프레임 %d] 슬롯 %d  %s  %s', frames, slot_seen,
                        table.concat(b, ' '), ok and '★ 생존' or '지워짐'))
    end
    slot_seen = -1
  end

  if frames % 300 == 0 then
    say(string.format('--- %d --- 무장 %d · 거부 %d · 푸시 %d · 생존 %d · 지워짐 %d · 회수실패 %d · 경계잔류 %d',
                      frames, arms, refused, pushes, alive, dead, stranded, stranger))
    flush()
  end
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  disarm('종료')
  say(string.format('--- 정리 --- %d 프레임 · 무장 %d · 거부 %d · 푸시 %d · 생존 %d · 지워짐 %d · 회수실패 %d · 경계잔류 %d',
                    frames, arms, refused, pushes, alive, dead, stranded, stranger))
  flush()
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_EXTEND 0.1.3 loaded  --  $601E 무장 / $6072 회수')
