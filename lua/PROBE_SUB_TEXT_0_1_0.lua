-- PROBE_SUB_TEXT 0.1.0  --  진짜 한글 문장을 진짜 폰트로 띄운다
--
-- 여기까지 확정된 것
-- ----------------
--   자리        y 119..134 · 가운데 128       (직접 잡으심)
--   앞뒤        게임 그림·초상화보다 앞        ($601E 가로채 먼저 민다)
--   잔류        오버레이 갈리면 우리 것만 지움
--   표시 폭     256 px 실측  (reg $0B HDR = $041F -> HDW=31)
--
-- 남은 결정이 **글자 크기 하나**였다.  구운 16x16 등폭으로는 한 줄 11 자였고
-- 글자 사이도 벌어 보였다.  Galmuri BDF 를 재보니:
--
--                  한글    ASCII 'A'   4305 행 중 176 px 에 한 번에 들어가는 행
--     Galmuri9     10 px      6 px          98.4%
--     Galmuri11    12 px      8 px          90.8%   (그림폭 192 면 97.4%)
--     Galmuri14    15 px     11 px          61.0%
--
-- **Galmuri 는 비례폭이다.**  영문·숫자가 한글의 2/3 라 실제 문장은 등폭 계산보다
-- 짧다.  우리 레코드는 글자마다 부호 8 비트 X 오프셋을 갖고 있어 비례폭이 공짜다.
--
-- 이 판이 하는 것
-- --------------
--   tools/render_subtitle_line.py 가 뽑아둔 것을 그대로 올린다
--     build/cutscene_subs/line_<폰트>.bin   패턴 64 B x 글자수 (플레인 0=본체 · 1=외곽선)
--     build/cutscene_subs/line_<폰트>.txt   글자마다 펜 위치 (비례폭)
--   F 로 폰트를 바꿔가며 같은 문장을 같은 자리에서 비교한다.
--
--   외곽선을 넣었다 -- 자막이 그림 위에 얹히므로.  펌웨어가 스프라이트 팔레트 0 의
--   색 1 을 흰색, 색 2 를 검정으로 세팅해 두었다 (0.2.13).
--
-- 조작
--   F         폰트 바꾸기 (Galmuri11 -> 9 -> 14 -> ...)
--   I / K     줄을 위 / 아래
--   J / L     줄의 가운데를 좌 / 우
--   P         지금 상태를 로그와 TSV 에 박는다
--
-- 출력  로그 + C:/snatcher/dump/probe_sub_text_0_1_0_<날짜>.tsv

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"
local BASE  = "C:/snatcher/build/cutscene_subs/line_"

-- 자막용으로 빌드가 예약한 구간: $5C40-$5E1F (480 B, MPR2)
-- manifest.json  subtitle_ram_code = "5C40-5E1F"
-- 예전에는 $5C20 이라 예약 구간을 32 B 벗어나 걸쳐 있었다.
local STUB, LIST = 0x5C40, 0x5C80
local ARM, HOOK, DISARM = 0x6000, 0x601E, 0x6072
local JSR_AT = 0x5C71
local SATB_BYTE, PAT_VRAM_BYTE = 0x2000, 0xF200
local SCREEN_W, GLYPH_W = 256, 16

local FONTS = { 'Galmuri11', 'Galmuri9', 'Galmuri14' }
local font_i = 1
local center_x, text_y = 128, 119

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
local stranded, cleared, uploads, slot_seen = 0, 0, 0, -1
local pat, offs, nglyph, line_w = nil, {}, 0, 0
local pushed_this_frame = false
local need_upload = true
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function rb(a, t) return emu.read(a, t or MEM) or 0 end
local function match(addr, want)
  for i = 1, #want do if rb(addr + i - 1) ~= want[i] then return false end end
  return true
end
local function fingerprint()
  for _, s in ipairs(SIG) do if not match(s[1], s[2]) then return false end end
  return true
end

local function load_font(i)
  local name = FONTS[i]
  local f = io.open(BASE .. name .. '.bin', 'rb')
  if f == nil then say('★ 패턴이 없다: ' .. BASE .. name .. '.bin'); return false end
  pat = f:read('a'); f:close()
  local t = io.open(BASE .. name .. '.txt', 'r')
  if t == nil then say('★ 오프셋이 없다: ' .. BASE .. name .. '.txt'); return false end
  offs = {}
  for line in t:lines() do
    local v = tonumber(line)
    if v then offs[#offs+1] = v end
  end
  t:close()
  nglyph = math.floor(#pat / 64)
  if #offs < nglyph then nglyph = #offs end
  -- 줄 폭 = 마지막 펜 위치 + 마지막 글자 폭.  글자 폭은 앞뒤 펜 차이로 추정한다
  local last_adv = nglyph > 1 and (offs[nglyph] - offs[nglyph - 1]) or GLYPH_W
  line_w = offs[nglyph] + last_adv
  need_upload = true
  say(string.format('[프레임 %d] %s  글자 %d  줄 폭 %d px', frames, name, nglyph, line_w))
  return true
end

local function left_x()  return center_x - math.floor(line_w / 2) end
local function right_x() return left_x() + line_w - 1 end

local function upload()
  for g = 0, nglyph - 1 do
    local base = PAT_VRAM_BYTE + g * 0x80
    for i = 0, 63 do emu.write(base + i, pat:byte(g * 64 + i + 1) or 0, VRAM) end
    for i = 64, 127 do emu.write(base + i, 0, VRAM) end
  end
  uploads = uploads + 1
  need_upload = false
end

local function build_stub()
  -- 원점 = 줄의 왼쪽 끝.  오프셋이 부호 8 비트라 가운데를 원점으로 잡고
  -- 오프셋을 -w/2 .. +w/2 로 돌린다
  local xo, yo = left_x() + math.floor(line_w / 2) + 32, text_y + 64
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
    0xA9, nglyph, 0x85, 0x16,
    0x20, 0x63, 0x64,
    0x28, 0x60,
  }
end

local function build_records()
  local half = math.floor(line_w / 2)
  local r = {}
  for g = 1, nglyph do
    local w2 = 0x3C8 + 2 * (g - 1)
    local off = offs[g] - half
    if off < -128 then off = -128 elseif off > 127 then off = 127 end
    r[#r+1] = 0x00; r[#r+1] = 0x00; r[#r+1] = off & 0xFF
    r[#r+1] = w2 & 0xFF; r[#r+1] = 0x80 | ((w2 >> 8) << 4)
  end
  return r
end

local function clear_ours()
  local hi = 0x3C8 + 2 * 31
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local w2 = rb(o + 4, VRAM) + rb(o + 5, VRAM) * 256
    local at = rb(o + 6, VRAM) + rb(o + 7, VRAM) * 256
    if at == 0x0080 and w2 >= 0x3C8 and w2 <= hi then
      for i = 0, 7 do emu.write(o + i, 0, VRAM) end
      cleared = cleared + 1
    end
  end
end

if not load_font(font_i) then return end

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
  if not fingerprint() then return end
  if not match(HOOK, ORIG) then return end
  if need_upload then upload() end
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
  pushed_this_frame = true
  slot_seen = 0x3F - rb(0x2017)
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

local function down(k)
  local ok, v = pcall(emu.isKeyPressed, k)
  return ok and v == true
end

local function report(tag)
  say(string.format('%s  %s  글자 %d  줄폭 %d  가운데 %d  y %d  ->  화면 x %d..%d (여백 %d/%d) %s',
        tag, FONTS[font_i], nglyph, line_w, center_x, text_y,
        left_x(), right_x(), left_x(), SCREEN_W - 1 - right_x(),
        (left_x() < 0 or right_x() > SCREEN_W - 1) and '★ 화면 밖' or ''))
  local f = io.open(string.format('C:/snatcher/dump/probe_sub_text_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
  end
end

local held, f_held, p_held = 0, false, false
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

  -- 잔류 제거.  지문이 아니라 **이번 프레임에 실제로 밀었는지**로 판단한다.
  -- 지문은 맞는데 $601E 를 안 지나는 상태(메뉴 등)가 있고, 그때 SATB 에는
  -- 지난 프레임의 우리 엔트리가 그대로 남아 화면에 조각으로 보인다.
  if not pushed_this_frame then clear_ours() end
  pushed_this_frame = false

  held = held + 1
  if held >= 3 then
    held = 0
    if down('I') then text_y = text_y - 1 end
    if down('K') then text_y = text_y + 1 end
    if down('J') then center_x = center_x - 1 end
    if down('L') then center_x = center_x + 1 end
    if text_y < 0 then text_y = 0 end
    if text_y > 207 then text_y = 207 end
  end

  local fk = down('F')
  if fk and not f_held then
    font_i = font_i % #FONTS + 1
    load_font(font_i)
  end
  f_held = fk

  local pk = down('P')
  if pk and not p_held then report('찍음') end
  p_held = pk

  local x0, x1 = left_x(), right_x()
  emu.drawString(4, 4, string.format('%s  n %d  w %d  x %d..%d', FONTS[font_i], nglyph, line_w, x0, x1),
        (x0 < 0 or x1 > SCREEN_W - 1) and 0xFF6060 or 0xFFFFFF, 0x000000)
  emu.drawString(4, 14, string.format('mid %d  y %d   F=font IJKL=move P=mark', center_x, text_y),
        0xFFFF80, 0x000000)
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_TEXT 0.1.0 loaded')
emu.log('  F 폰트바꾸기 · I/K 위아래 · J/L 좌우 · P 좌표찍기')
