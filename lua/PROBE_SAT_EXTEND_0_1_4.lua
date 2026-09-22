-- PROBE_SAT_EXTEND 0.1.4  --  한 줄
--
-- 0.1.3 에서 확정된 것
-- ------------------
--   글자가 떴고, 게임 스프라이트를 하나도 안 빼앗았고, 장면 전환 뒤 UI 가 돌아왔다.
--   $601E 무장 / $6072 회수 구조가 CD-RAM 잔류를 없앴다.
--
-- 0.1.4 가 더하는 것
-- ----------------
--   1  poc_patterns.bin 의 글리프 9 개를 전부 VRAM 에 올린다.
--      Lua 가 VRAM 에 직접 쓴다 -- MAWR 을 안 거치므로 §1.3 의 경합이 없다.
--        글리프 g -> VDC 워드 $7900 + g*$40  =  VRAM 바이트 $F200 + g*$80
--        64 B(플레인 0·1) + 64 B 0 채움(플레인 2·3) = 128 B
--   2  레코드 9 개.  X 오프셋은 부호 8 비트라 원점 하나로 ±127 까지다.
--      가운데를 원점으로 잡고 -64..+64 로 뻗는다 (16 px 간격).
--   3  스텁이 남은 자리를 먼저 센다:  쓴 슬롯 >= 64-9 이면 안 민다.
--      게임 슬롯을 밀어내지 않는다.
--
--   ★ 여전히 VDC 접근 0 회.  MAWR 도 레지스터 래치도 안 건드린다.
--
-- 볼 것
--   9 글자가 한 줄로 뜨는가.  게임 스프라이트가 깜빡이지 않는가.
--   PCE 는 스캔라인당 스프라이트 16 개 제한이 있다.  우리 9 개가 길리언 초상과
--   같은 줄에 놓이므로 여기서 처음 그 한계에 닿을 수 있다.  깜빡이면 그 증거다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_extend_0_1_4_<날짜>.tsv  (300 프레임마다)

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"
local PATTERNS = "C:/snatcher/build/cutscene_subs/poc_patterns.bin"

local STUB, LIST = 0x5C20, 0x5C80
local HOOK, ARM, DISARM = 0x606F, 0x601E, 0x6072
local SATB_BYTE = 0x2000
local PAT_VRAM_BYTE = 0xF200           -- VDC 워드 $7900

local N = 9
local JSR_AT = 0x5C5A
local CODE = {
  0x08, 0x78, 0xAD, 0x00, 0x65, 0xC9, 0x82, 0xD0,
  0x34, 0xA5, 0x17, 0x30, 0x30, 0xA9, 0x3F, 0x38,
  0xE5, 0x17, 0xC9, 0x37, 0xB0, 0x27, 0xA9, 0xF4,
  0x85, 0x08, 0xA9, 0x00, 0x85, 0x09, 0xA9, 0x88,
  0x85, 0x0A, 0xA9, 0x00, 0x85, 0x0B, 0x64, 0x0C,
  0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F, 0xA9, 0x80,
  0x85, 0x10, 0xA9, 0x5C, 0x85, 0x11, 0xA9, 0x09,
  0x85, 0x16, 0x20, 0x63, 0x64, 0x28, 0x4C, 0xA6,
  0x60,
}
local RECORD = {
  0x00, 0x00, 0xC0, 0xC8, 0xB0,   -- 글리프 0  X-64  패턴워드 $7900
  0x00, 0x00, 0xD0, 0xCA, 0xB0,   -- 글리프 1  X-48  $7940
  0x00, 0x00, 0xE0, 0xCC, 0xB0,   -- 글리프 2  X-32  $7980
  0x00, 0x00, 0xF0, 0xCE, 0xB0,   -- 글리프 3  X-16  $79C0
  0x00, 0x00, 0x00, 0xD0, 0xB0,   -- 글리프 4  X+0   $7A00
  0x00, 0x00, 0x10, 0xD2, 0xB0,   -- 글리프 5  X+16  $7A40
  0x00, 0x00, 0x20, 0xD4, 0xB0,   -- 글리프 6  X+32  $7A80
  0x00, 0x00, 0x30, 0xD6, 0xB0,   -- 글리프 7  X+48  $7AC0
  0x00, 0x00, 0x40, 0xD8, 0xB0,   -- 글리프 8  X+64  $7B00
}
local ORIG  = { 0x20, 0xA6, 0x60 }
local PATCH = { 0x20, STUB & 0xFF, STUB >> 8 }

local SIG = {
  { 0x601E, { 0xA9, 0x3F, 0x85, 0x17 } },
  { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } },
  { 0x60A6, { 0xA6, 0x17 } },
  { 0x6072, { 0x4C, 0xBE, 0x43 } },
}

local loaded, tries, frames = false, 0, 0
local armed, arms, pushes, alive, dead = false, 0, 0, 0, 0
local refused, stranded, stranger = 0, 0, 0
local uploads, slot_seen, logged = 0, -1, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local pf = io.open(PATTERNS, "rb")
if pf == nil then emu.log('★ 패턴을 못 열었다: ' .. PATTERNS) return end
local pat = pf:read("a"); pf:close()
say(string.format('패턴 %d B = 글리프 %d 개', #pat, math.floor(#pat / 64)))

local function match(addr, want, t)
  for i = 1, #want do
    if emu.read(addr + i - 1, t or MEM) ~= want[i] then return false end
  end
  return true
end

local function fingerprint()
  for _, s in ipairs(SIG) do
    if not match(s[1], s[2]) then return false end
  end
  return true
end

-- 글리프 N 개를 VRAM 에 직접 쓴다.  128 B/개 (64 B 플레인 0·1 + 64 B 0)
local function upload()
  for g = 0, N - 1 do
    local base = PAT_VRAM_BYTE + g * 0x80
    for i = 0, 63 do
      emu.write(base + i, pat:byte(g * 64 + i + 1) or 0, VRAM)
    end
    for i = 64, 127 do emu.write(base + i, 0, VRAM) end
  end
  uploads = uploads + 1
end

-- 매 프레임 값싸게 확인: 글리프마다 한 바이트씩
local function patterns_ok()
  for g = 0, N - 1 do
    local want = pat:byte(g * 64 + 5) or 0
    if emu.read(PAT_VRAM_BYTE + g * 0x80 + 4, VRAM) ~= want then return false end
  end
  return true
end

local function flush()
  local name = string.format('C:/snatcher/dump/probe_sat_extend_0_1_4_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close(); emu.log('-> ' .. name)
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
    stranded = stranded + 1
    if stranded <= 3 then
      local b = {}
      for i = 0, 5 do b[#b+1] = string.format('%02X', emu.read(HOOK + i, MEM) or 0) end
      say(string.format('[프레임 %d] ★ %s 회수 실패 -- $606F = %s',
                        frames, where, table.concat(b, ' ')))
    end
  end
  armed = false
end

emu.addMemoryCallback(function()
  if armed then disarm('재무장') end
  if not fingerprint() then refused = refused + 1; return end
  if not match(HOOK, ORIG) then refused = refused + 1; return end
  if not patterns_ok() then upload() end
  for i = 1, #CODE   do emu.write(STUB + i - 1, CODE[i],   MEM) end
  for i = 1, #RECORD do emu.write(LIST + i - 1, RECORD[i], MEM) end
  for i = 1, #PATCH  do emu.write(HOOK + i - 1, PATCH[i],  MEM) end
  armed = true; arms = arms + 1
  if arms <= 3 then say(string.format('[프레임 %d] 지문 일치 -- 무장 %d 회째', frames, arms)) end
end, emu.callbackType.exec, ARM, ARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function() disarm('$6072') end,
  emu.callbackType.exec, DISARM, DISARM, emu.cpuType.pce, MEM)

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

  if armed then
    stranger = stranger + 1
    if stranger <= 3 then
      say(string.format('[프레임 %d] ★ 프레임 경계에 무장이 남았다', frames))
    end
    disarm('프레임경계')
  end

  if slot_seen >= 0 then
    local a = SATB_BYTE + slot_seen * 8
    local z = SATB_BYTE + (slot_seen + N - 1) * 8
    local ok = emu.read(a, VRAM) == 0xF4 and emu.read(a + 4, VRAM) == RECORD[4]
                 and emu.read(z, VRAM) == 0xF4
    if ok then alive = alive + 1 else dead = dead + 1 end
    if logged < 5 then
      logged = logged + 1
      local b, c = {}, {}
      for i = 0, 7 do b[#b+1] = string.format('%02X', emu.read(a + i, VRAM) or 0) end
      for i = 0, 7 do c[#c+1] = string.format('%02X', emu.read(z + i, VRAM) or 0) end
      say(string.format('[프레임 %d] 슬롯 %d..%d  첫 %s  끝 %s  %s',
                        frames, slot_seen, slot_seen + N - 1,
                        table.concat(b, ' '), table.concat(c, ' '),
                        ok and '★ 생존' or '지워짐'))
    end
    slot_seen = -1
  end

  if frames % 300 == 0 then
    say(string.format('--- %d --- 무장 %d · 거부 %d · 푸시 %d · 생존 %d · 지워짐 %d · 회수실패 %d · 경계잔류 %d · 패턴업로드 %d',
                      frames, arms, refused, pushes, alive, dead, stranded, stranger, uploads))
    flush()
  end
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  disarm('종료')
  say(string.format('--- 정리 --- %d 프레임 · 무장 %d · 푸시 %d · 생존 %d · 지워짐 %d · 회수실패 %d · 경계잔류 %d · 패턴업로드 %d',
                    frames, arms, pushes, alive, dead, stranded, stranger, uploads))
  flush()
end, emu.eventType.scriptEnded)

emu.log(string.format('PROBE_SAT_EXTEND 0.1.4 loaded  --  글리프 %d 개 한 줄', N))
