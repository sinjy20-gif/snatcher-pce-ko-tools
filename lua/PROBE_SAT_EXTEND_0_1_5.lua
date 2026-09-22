-- PROBE_SAT_EXTEND 0.1.5  --  16 글자 전폭 · 스캔라인 점유 실측
--
-- 왜 이것을 먼저 하나
-- ----------------
-- 0.1.4 로 9 글자가 떴다.  남은 일(디스크 패치화 · 오버레이 B · 동적 글리프)은
-- 전부 "스프라이트로 자막을 그린다" 는 전제 위에 쌓는 작업이다.
-- 그 전제를 깰 수 있는 것은 하나뿐이다:
--
--   PCE VDC 는 스캔라인당 스프라이트 16 개까지만 그린다.
--   32 폭 스프라이트는 2 개로 친다.  넘으면 넘은 것부터 안 그려진다.
--
-- 자막 한 줄 16 글자 = 16 개.  게임 스프라이트가 같은 줄에 하나라도 있으면
-- 이미 초과다.  **되는지 안 되는지가 아래 층 설계를 전부 바꾼다.**
-- 그래서 이것부터 잰다.
--
-- 0.1.5 가 하는 것
-- --------------
--   1  글리프 16 개를 화면 X 0..255 전폭으로 깐다 (poc 9 개를 돌려 쓴다)
--      X 오프셋 -120..+120 -- 부호 8 비트 안이라 재연결 레코드가 아직 필요없다
--   2  매 프레임 SATB 64 칸을 전부 디코드해서, 자막이 놓인 16 줄 각각에
--      **몇 개가 겹치는지** 센다.  32 폭은 2 칸으로 친다.
--        스프라이트 수  -- 16 초과면 초과분이 사라진다
--        칸 수(cells)   -- VDC 패턴 페치 예산.  같은 16 이 한계
--   3  자막 첫 글자·끝 글자가 SATB 에 살아있는지 같이 본다
--
-- 눈으로 볼 것
--   글자가 깜빡이거나, 게임 스프라이트(길리언 초상)가 깜빡이면 초과한 것이다.
--   로그의 최대 점유 숫자와 반드시 같이 볼 것.
--
-- 스텁·무장/회수는 0.1.3 에서 확정된 구조 그대로.  VDC 접근 0 회.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_extend_0_1_5_<날짜>.tsv  (300 프레임마다)

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
local GLYPHS = 9                       -- poc_patterns.bin 이 가진 개수
local CGY = { [0] = 16, [1] = 32, [2] = 64, [3] = 64 }
local LIMIT = 16                       -- PCE 스캔라인당 스프라이트 한계

local N = 16
local JSR_AT = 0x5C5A
local TEXT_Y = 180
local CODE = {
  0x08, 0x78, 0xAD, 0x00, 0x65, 0xC9, 0x82, 0xD0,
  0x34, 0xA5, 0x17, 0x30, 0x30, 0xA9, 0x3F, 0x38,
  0xE5, 0x17, 0xC9, 0x30, 0xB0, 0x27, 0xA9, 0xF4,
  0x85, 0x08, 0xA9, 0x00, 0x85, 0x09, 0xA9, 0x98,
  0x85, 0x0A, 0xA9, 0x00, 0x85, 0x0B, 0x64, 0x0C,
  0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F, 0xA9, 0x80,
  0x85, 0x10, 0xA9, 0x5C, 0x85, 0x11, 0xA9, 0x10,
  0x85, 0x16, 0x20, 0x63, 0x64, 0x28, 0x4C, 0xA6,
  0x60,
}
local RECORD = {
  0x00, 0x00, 0x88, 0xC8, 0xB0,   --  0  screen x=  0
  0x00, 0x00, 0x98, 0xCA, 0xB0,   --  1  screen x= 16
  0x00, 0x00, 0xA8, 0xCC, 0xB0,   --  2  screen x= 32
  0x00, 0x00, 0xB8, 0xCE, 0xB0,   --  3  screen x= 48
  0x00, 0x00, 0xC8, 0xD0, 0xB0,   --  4  screen x= 64
  0x00, 0x00, 0xD8, 0xD2, 0xB0,   --  5  screen x= 80
  0x00, 0x00, 0xE8, 0xD4, 0xB0,   --  6  screen x= 96
  0x00, 0x00, 0xF8, 0xD6, 0xB0,   --  7  screen x=112
  0x00, 0x00, 0x08, 0xD8, 0xB0,   --  8  screen x=128
  0x00, 0x00, 0x18, 0xC8, 0xB0,   --  9  screen x=144
  0x00, 0x00, 0x28, 0xCA, 0xB0,   -- 10  screen x=160
  0x00, 0x00, 0x38, 0xCC, 0xB0,   -- 11  screen x=176
  0x00, 0x00, 0x48, 0xCE, 0xB0,   -- 12  screen x=192
  0x00, 0x00, 0x58, 0xD0, 0xB0,   -- 13  screen x=208
  0x00, 0x00, 0x68, 0xD2, 0xB0,   -- 14  screen x=224
  0x00, 0x00, 0x78, 0xD4, 0xB0,   -- 15  screen x=240
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
local peak_n, peak_cells, over_frames = 0, 0, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local pf = io.open(PATTERNS, "rb")
if pf == nil then emu.log('★ 패턴을 못 열었다: ' .. PATTERNS) return end
local pat = pf:read("a"); pf:close()

local function rb(a, t) return emu.read(a, t or MEM) or 0 end
local function vw(o) return rb(o, VRAM) + rb(o + 1, VRAM) * 256 end

local function match(addr, want)
  for i = 1, #want do
    if rb(addr + i - 1) ~= want[i] then return false end
  end
  return true
end

local function fingerprint()
  for _, s in ipairs(SIG) do
    if not match(s[1], s[2]) then return false end
  end
  return true
end

local function upload()
  for g = 0, GLYPHS - 1 do
    local base = PAT_VRAM_BYTE + g * 0x80
    for i = 0, 63 do emu.write(base + i, pat:byte(g * 64 + i + 1) or 0, VRAM) end
    for i = 64, 127 do emu.write(base + i, 0, VRAM) end
  end
  uploads = uploads + 1
end

local function patterns_ok()
  for g = 0, GLYPHS - 1 do
    if rb(PAT_VRAM_BYTE + g * 0x80 + 4, VRAM) ~= (pat:byte(g * 64 + 5) or 0) then
      return false
    end
  end
  return true
end

-- 자막이 놓인 16 줄에서 스캔라인당 스프라이트 수와 칸 수를 센다.
-- 32 폭은 2 칸.  PCE 는 16 을 넘으면 넘은 것부터 안 그린다.
local function occupancy()
  local bn, bc, by = 0, 0, -1
  for sy = TEXT_Y, TEXT_Y + 15 do
    local n, cells = 0, 0
    for s = 0, 63 do
      local o = SATB_BYTE + s * 8
      local y, a = vw(o), vw(o + 6)
      if y ~= 0 then
        local top = y - 64
        local hgt = CGY[math.floor(a / 4096) % 4]
        if sy >= top and sy < top + hgt then
          n = n + 1
          cells = cells + ((math.floor(a / 256) % 2 == 1) and 2 or 1)
        end
      end
    end
    if cells > bc then bn, bc, by = n, cells, sy end
  end
  return bn, bc, by
end

local function flush()
  local name = string.format('C:/snatcher/dump/probe_sat_extend_0_1_5_%s.tsv',
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
      for i = 0, 5 do b[#b+1] = string.format('%02X', rb(HOOK + i)) end
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
  slot_seen = 0x3F - rb(0x2017)
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frames = frames + 1

  if not loaded then
    tries = tries + 1
    for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end
    local bad = 0
    for i = 1, #data do
      if rb(AC_ENGINE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
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
    local ok = rb(a, VRAM) == 0xF4 and rb(z, VRAM) == 0xF4
    if ok then alive = alive + 1 else dead = dead + 1 end

    local n, cells, at = occupancy()
    if cells > peak_cells then peak_cells, peak_n = cells, n end
    if cells > LIMIT then over_frames = over_frames + 1 end

    if logged < 6 then
      logged = logged + 1
      say(string.format('[프레임 %d] 슬롯 %d..%d %s  |  최대점유 y=%d  스프라이트 %d · 칸 %d  %s',
                        frames, slot_seen, slot_seen + N - 1,
                        ok and '★ 생존' or '지워짐', at, n, cells,
                        cells > LIMIT and string.format('★ 한계 %d 초과', LIMIT) or '여유'))
    end
    slot_seen = -1
  end

  if frames % 300 == 0 then
    say(string.format('--- %d --- 무장 %d · 푸시 %d · 생존 %d · 지워짐 %d · 회수실패 %d · 경계잔류 %d',
                      frames, arms, pushes, alive, dead, stranded, stranger))
    say(string.format('    점유 최대 스프라이트 %d · 칸 %d  (한계 %d) · 초과 프레임 %d',
                      peak_n, peak_cells, LIMIT, over_frames))
    flush()
  end
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  disarm('종료')
  say(string.format('--- 정리 --- %d 프레임 · 푸시 %d · 생존 %d · 지워짐 %d · 회수실패 %d · 경계잔류 %d',
                    frames, pushes, alive, dead, stranded, stranger))
  say(string.format('    점유 최대 스프라이트 %d · 칸 %d  (한계 %d) · 초과 프레임 %d / %d',
                    peak_n, peak_cells, LIMIT, over_frames, pushes))
  if peak_cells > LIMIT then
    say('★ 한계 초과 -- 16 글자 한 줄은 이대로는 안 된다.  32 폭 스프라이트로 8 개로 줄일 것')
  elseif pushes > 0 then
    say('★ 한계 안 -- 16 글자 한 줄이 그대로 된다')
  end
  flush()
end, emu.eventType.scriptEnded)

emu.log(string.format('PROBE_SAT_EXTEND 0.1.5 loaded  --  글리프 %d 개 전폭 · 스캔라인 점유 실측', N))
