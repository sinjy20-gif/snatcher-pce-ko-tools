-- PROBE_SAT_EXTEND 0.1.2  --  MAWR 을 아예 안 만진다
--
-- 0.1.1 이 무엇을 잘못했나
-- ----------------------
-- 0.1.1 은 지문 게이트로 오버레이 오염은 막았고 푸시도 완벽했다:
--
--   설치 1 · 푸시 666 · 생존 666 · 지워짐 0 · 오버레이 있음 899 / 없음 1
--
-- 그런데 화면이 검고 대사 뒤 UI 가 안 돌아왔다.  스프라이트뷰·타일뷰는 정상.
-- VRAM 이 아니라 VDC 레지스터 문제라는 뜻이고, 스텁이 만지는 건 MAWR 뿐이었다.
--
-- $60A6 을 뜯으니 그것이 §2 가 말한 "안 쓰는 슬롯도 0 으로 채운다" 였다:
--
--   60A6  LDX $17                남은 예산
--   60AA  ST1 #$00 / ST2 #$00 x4 = 4 워드 = 슬롯 하나.  ★ MAWR 현재 위치에 쓴다
--   60BA  DEX / BPL $60AA        $17+1 칸
--   60BD  RTS
--
-- 그래서 실제 순서는
--
--   객체 루프        엔트리 N 개 푸시.  MAWR 자동 전진
--   606F JSR $60A6   남은 칸 0 채우기.  끝나면 MAWR = $1100 (SATB 밖)
--   6072 JMP $43BE   ★ 0.1.1 스텁이 붙은 자리
--
-- 0.1.1 은 0 채우기가 끝난 뒤에 MAWR 을 $1000+used*4 로 되돌리고 나갔다.
-- 게임이 남긴 $1100 이 아니라.  MAWR 은 쓰기 전용이라 복구가 안 된다 (§1.3).
-- **$6072 에서 MAWR 을 건드리는 설계 자체가 틀렸다.**
--
-- 0.1.2 가 고친 것
-- --------------
-- 후킹 지점을 $606F 로 옮긴다.  0 채우기 **직전**이다.
--
--   606F  JSR $60A6   ->   JSR $5C20
--   스텁: zp 원점만 세우고  JSR $6463  ->  JMP $60A6  ($60A6 의 RTS 가 $6072 로)
--
-- 여기서 MAWR 은 이미 다음 빈 슬롯에 정확히 서 있다 -- 원본 게임의 0 채우기가
-- 그 전제로 동작하니 보장된 사실이다.  우리가 한 칸 밀면 MAWR 이 4 워드 전진하고,
-- 같은 푸시가 $17 을 하나 깎으므로 $60A6 은 정확히 한 칸 덜 채운다.  저절로 맞는다.
--
--   ★ 스텁의 VDC 접근 0 회.  MAWR 도 레지스터 래치도 안 건드린다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_extend_0_1_2_<날짜>.tsv  (300 프레임마다)

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"

local STUB, LIST = 0x5C20, 0x5C80
local HOOK = 0x606F                      -- ★ JSR $60A6 자리.  0 채우기 직전
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
-- 레코드 1 개: 패턴 워드 $7900 -> SAT word2 $03C8 -> [3]=$C8, [4]=$B0
local RECORD = { 0x00, 0x00, 0x00, 0xC8, 0xB0 }
local ORIG   = { 0x20, 0xA6, 0x60 }              -- JSR $60A6
local PATCH  = { 0x20, STUB & 0xFF, STUB >> 8 }  -- JSR $5C20

-- 스프라이트 오버레이 지문.  전부 맞아야 쓴다.
local SIG = {
  { 0x601E, { 0xA9, 0x3F, 0x85, 0x17 } },   -- $17 = 전역 슬롯 예산 63
  { 0x6463, { 0xC2 } },                     -- 엔트리 파서 머리 CLY
  { 0x6500, { 0x82, 0xB5, 0x00 } },         -- 푸시 루프 CLX / LDA $00,X
  { 0x60A6, { 0xA6, 0x17 } },               -- 0 채우기 머리 LDX $17
  { 0x6072, { 0x4C, 0xBE, 0x43 } },         -- 그 뒤 JMP $43BE 가 그대로 있나
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
  local name = string.format('C:/snatcher/dump/probe_sat_extend_0_1_2_%s.tsv',
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
  if not fingerprint() then
    absent = absent + 1
    if stranger < 5 and not match(HOOK, PATCH) and not match(HOOK, ORIG) then
      stranger = stranger + 1
      local b = {}
      for i = 0, 5 do b[#b+1] = string.format('%02X', emu.read(HOOK + i, MEM) or 0) end
      say(string.format('[프레임 %d] 다른 오버레이 -- 건드리지 않는다.  $606F = %s',
                        frames, table.concat(b, ' ')))
    end
    return
  end

  live = live + 1
  if match(HOOK, PATCH) then return end
  if not match(HOOK, ORIG) then
    if stranger < 5 then
      stranger = stranger + 1
      local b = {}
      for i = 0, 5 do b[#b+1] = string.format('%02X', emu.read(HOOK + i, MEM) or 0) end
      say(string.format('[프레임 %d] ★ 지문은 맞는데 $606F 가 원본이 아니다: %s',
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
  if installs == 0 then say('★ 지문이 한 번도 안 맞았다') end
  flush()
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_EXTEND 0.1.2 loaded  --  $606F 후킹 · MAWR 무접촉')
