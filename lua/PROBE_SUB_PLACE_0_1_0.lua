-- PROBE_SUB_PLACE 0.1.0  --  자막 줄의 자리를 눈으로 잡는다
--
-- 무엇을 하나
-- ----------
-- 16x16 글리프 한 줄을 **게임 그림보다 앞에** 그리고, 키보드로 움직여
-- 자리를 잡는다.  좌표가 화면에 계속 찍히므로 마음에 드는 곳에서 읽으면 된다.
--
--   I / K     줄을 위 / 아래로
--   J / L     줄의 **가운데**를 왼 / 오른쪽으로
--   U / O     글자 수 -1 / +1   (가운데 기준이라 양쪽으로 같이 늘고 준다)
--   P         지금 좌표를 로그와 TSV 에 박는다
--   (키가 안 먹으면 아래 AUTO_SWEEP 를 true 로.  Y 를 천천히 훑는다)
--
-- 왜 앞에 그려지나
-- --------------
-- 게임의 SATB 조립 시작 $601E 를 가로채 **게임보다 먼저** 민다.
--
--   601E  A9 3F 85 17   ->   20 20 5C EA      (JSR $5C20 + NOP)
--   스텁: LDA #$3F / STA $17    밀려난 원본을 먼저 한다
--         우리 N 개 푸시          슬롯 0.. 을 차지 -> 맨 앞
--         RTS                    게임 루프가 그 뒤 슬롯부터 이어간다
--
-- PCE 는 슬롯 번호가 낮을수록 앞에 그린다.  $606F 에서 밀던 이전 판들은
-- 항상 게임 뒤였고, 그래서 초상화에 가렸다.
--
-- MAWR 은 $6008 에서 슬롯 0 에 서 있고 우리가 밀면 그만큼 전진한다.  같은 푸시가
-- $17 을 깎으므로 $60A6 의 0 채우기도 저절로 맞는다.  ★ VDC 접근 0 회.
--
-- 안전장치 (0.1.3 에서 확정된 구조)
--   지문 5 개가 다 맞을 때만 쓴다.  무장 $6000 / 회수 $6072 -- 프레임 밖으로 안 나간다.
--   오버레이가 갈리면 우리 엔트리만 골라 SATB 에서 지운다 (잔류 제거).
--
-- 실측 전제
--   표시 폭 256 px  (reg $0B HDR = $041F -> HDW=31 -> (31+1)*8)
--   16 px 간격이면 한 줄 최대 16 자, 여백 0
--
-- 출력  로그 + C:/snatcher/dump/probe_sub_place_0_1_0_<날짜>.tsv

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"
local PATTERNS = "C:/snatcher/build/cutscene_subs/poc_patterns.bin"

-- 자막용으로 빌드가 예약한 구간: $5C40-$5E1F (480 B, MPR2)
-- manifest.json  subtitle_ram_code = "5C40-5E1F"
-- 예전에는 $5C20 이라 예약 구간을 32 B 벗어나 걸쳐 있었다.
local STUB, LIST = 0x5C40, 0x5C80
local ARM, HOOK, DISARM = 0x6000, 0x601E, 0x6072
local JSR_AT = 0x5C71
local SATB_BYTE, PAT_VRAM_BYTE = 0x2000, 0xF200
local GLYPHS, ADVANCE, SCREEN_W = 9, 16, 256

-- 시작 자리.  x 는 **줄의 가운데**다 (글자 수를 바꾸면 양쪽으로 같이 늘고 준다)
local center_x, text_y, text_n = 128, 119, 15

local AUTO_SWEEP = false          -- 키가 안 먹으면 true 로
local SWEEP_FROM, SWEEP_TO, SWEEP_HOLD = 96, 200, 120

local ORIG  = { 0xA9, 0x3F, 0x85, 0x17 }
local PATCH = { 0x20, STUB & 0xFF, STUB >> 8, 0xEA }

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } },
  { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } },
  { 0x60A6, { 0xA6, 0x17 } },
  { 0x6072, { 0x4C, 0xBE, 0x43 } },
}

local frames, loaded, tries = 0, false, 0
local armed, arms, pushes = false, 0, 0
local refused, stranded, cleared = 0, 0, 0
local uploads, slot_seen = 0, -1
local keys_ok, sweep_i, sweep_since = true, 0, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local pf = io.open(PATTERNS, "rb")
if pf == nil then emu.log('★ 패턴을 못 열었다: ' .. PATTERNS) return end
local pat = pf:read("a"); pf:close()

local function rb(a, t) return emu.read(a, t or MEM) or 0 end
local function match(addr, want)
  for i = 1, #want do if rb(addr + i - 1) ~= want[i] then return false end end
  return true
end
local function fingerprint()
  for _, s in ipairs(SIG) do if not match(s[1], s[2]) then return false end end
  return true
end

-- 줄의 진짜 가운데를 center_x 에 맞춘다.
-- 주의: 스프라이트 원점은 글자의 **왼쪽 끝**이라 글자 폭의 절반을 빼야 한다.
-- (이걸 빼먹어서 가운데=128 일 때 여백이 16/0 으로 어긋났다)
local GLYPH_W = 16
local function width_px() return (text_n - 1) * ADVANCE + GLYPH_W end
local function left_x()   return center_x - math.floor(width_px() / 2) end
local function right_x()  return left_x() + width_px() - 1 end
local function origin_x() return left_x() + math.floor((text_n - 1) * ADVANCE / 2) end

local function build_stub()
  local xo, yo = origin_x() + 32, text_y + 64
  return {
    0x08, 0x78,
    0xA9, 0x3F, 0x85, 0x17,
    0xAD, 0x00, 0x65, 0xC9, 0x82,
    0xD0, 0x27,
    0xA9, yo & 0xFF, 0x85, 0x08,
    0xA9, (yo >> 8) & 0xFF, 0x85, 0x09,
    0xA9, xo & 0xFF, 0x85, 0x0A,
    0xA9, (xo >> 8) & 0xFF, 0x85, 0x0B,
    0x64, 0x0C, 0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F,
    0xA9, LIST & 0xFF, 0x85, 0x10,
    0xA9, LIST >> 8,   0x85, 0x11,
    0xA9, text_n, 0x85, 0x16,
    0x20, 0x63, 0x64,
    0x28, 0x60,
  }
end

local function build_records()
  local half = math.floor((text_n - 1) * ADVANCE / 2)
  local r = {}
  for g = 0, text_n - 1 do
    local w2 = 0x3C8 + 2 * (g % GLYPHS)
    r[#r+1] = 0x00; r[#r+1] = 0x00; r[#r+1] = (g * ADVANCE - half) & 0xFF
    r[#r+1] = w2 & 0xFF; r[#r+1] = 0x80 | ((w2 >> 8) << 4)
  end
  return r
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
    if rb(PAT_VRAM_BYTE + g * 0x80 + 4, VRAM) ~= (pat:byte(g * 64 + 5) or 0) then return false end
  end
  return true
end

local function clear_ours()
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local w2 = rb(o + 4, VRAM) + rb(o + 5, VRAM) * 256
    local at = rb(o + 6, VRAM) + rb(o + 7, VRAM) * 256
    -- Y 는 보지 않는다.  예전 판이 다른 Y 에 남긴 것도 거둔다
    if at == 0x0080 and w2 >= 0x3C8 and w2 <= 0x3D8 then
      for i = 0, 7 do emu.write(o + i, 0, VRAM) end
      cleared = cleared + 1
    end
  end
end

local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다: ' .. PATH) return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

local function disarm()
  if not armed then return end
  if match(HOOK, PATCH) then
    for i = 1, #ORIG do emu.write(HOOK + i - 1, ORIG[i], MEM) end
  else
    stranded = stranded + 1
    if stranded <= 3 then say(string.format('[프레임 %d] ★ 회수 실패', frames)) end
  end
  armed = false
end

emu.addMemoryCallback(function()
  if armed then disarm() end
  if not fingerprint() then refused = refused + 1; return end
  if not match(HOOK, ORIG) then refused = refused + 1; return end
  if not patterns_ok() then upload() end
  local code, rec = build_stub(), build_records()
  for i = 1, #code  do emu.write(STUB + i - 1, code[i], MEM) end
  for i = 1, #rec   do emu.write(LIST + i - 1, rec[i],  MEM) end
  for i = 1, #PATCH do emu.write(HOOK + i - 1, PATCH[i], MEM) end
  armed = true; arms = arms + 1
end, emu.callbackType.exec, ARM, ARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function() disarm() end,
  emu.callbackType.exec, DISARM, DISARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  pushes = pushes + 1
  slot_seen = 0x3F - rb(0x2017)
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

local function down(k)
  local ok, v = pcall(emu.isKeyPressed, k)
  if not ok then keys_ok = false; return false end
  return v == true
end

local function report(tag)
  local x0, x1 = left_x(), right_x()
  say(string.format('%s  가운데=%d  y=%d  n=%d  ->  화면 x %d..%d (%d px, 좌여백 %d · 우여백 %d) · y %d..%d %s',
        tag, center_x, text_y, text_n, x0, x1,
        width_px(), x0, SCREEN_W - 1 - x1, text_y, text_y + 15,
        (x0 < 0 or x1 > SCREEN_W - 1) and '★ 화면 밖' or ''))
  local f = io.open(string.format('C:/snatcher/dump/probe_sub_place_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
  end
end

local held, p_held = 0, false
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
      report('시작')
    elseif tries >= 300 then loaded = true; say('★ AC 적재 실패') end
  end

  if armed then disarm() end
  if not fingerprint() then clear_ours() end

  -- 키 입력.  3 프레임에 1 px
  held = held + 1
  if held >= 3 then
    held = 0
    if down('I') then text_y = text_y - 1 end
    if down('K') then text_y = text_y + 1 end
    if down('J') then center_x = center_x - 1 end
    if down('L') then center_x = center_x + 1 end
    if down('U') and text_n > 1  then text_n = text_n - 1 end
    if down('O') and text_n < 24 then text_n = text_n + 1 end
    if text_y < 0 then text_y = 0 end
    if text_y > 223 then text_y = 223 end
  end
  local p = down('P')
  if p and not p_held then report('찍음') end
  p_held = p

  if AUTO_SWEEP or not keys_ok then
    sweep_since = sweep_since + 1
    if sweep_since >= SWEEP_HOLD then
      sweep_since = 0
      text_y = SWEEP_FROM + sweep_i * 4
      if text_y > SWEEP_TO then text_y = SWEEP_FROM; sweep_i = 0 else sweep_i = sweep_i + 1 end
      say(string.format('[훑기] y=%d', text_y))
    end
  end

  local x0, x1 = left_x(), right_x()
  emu.drawString(4, 4, string.format('mid %3d  y %3d  n %2d  x %3d..%3d  margin %d/%d',
        center_x, text_y, text_n, x0, x1, x0, SCREEN_W - 1 - x1),
        (x0 < 0 or x1 > 255) and 0xFF6060 or 0xFFFFFF, 0x000000)
  emu.drawString(4, 14, string.format('slot %d  push %d  clr %d  %s',
        slot_seen, pushes, cleared, keys_ok and 'IJKL/UO/P' or 'AUTO'),
        0xFFFF80, 0x000000)
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_PLACE 0.1.0 loaded')
emu.log('  I/K 위아래 · J/L 좌우 · U/O 글자수 · P 좌표 찍기')
emu.log(string.format('  시작 가운데=%d y=%d n=%d · 16 px 간격 · 게임 그림보다 앞', center_x, text_y, text_n))
