-- PROBE_SUB_FIT 0.1.0  --  몇 자가 들어가는지 눈으로 고른다
--
-- 왜
-- --
-- 표시 폭은 실측 256 px 이다 (reg $0B HDR = $041F -> HDW=31 -> (31+1)*8).
-- 자막이 놓일 자리는 그림 아래쪽 띠.  거기 몇 자가 들어가야 읽을 만한지는
-- 계산으로 정할 게 아니라 보고 골라야 한다.
--
-- 스프라이트는 16x16 이지만 X 는 픽셀 단위로 아무 데나 놓을 수 있고 겹쳐도 된다.
-- 즉 **글자 간격(advance)** 과 **글자 수** 는 따로 정할 수 있다.
-- 간격을 좁히려면 글리프를 그 폭에 맞춰 다시 그리면 된다.
--
-- 이 판은 조합을 3 초(180 프레임)씩 돌려가며 보여준다.
-- 화면 왼쪽 위에 현재 조합이 찍힌다.  괜찮은 게 나오면 그걸로 박으면 된다.
--
-- 그리는 방식
--   게임의 SATB 조립 시작($601E) 을 가로채 **게임보다 먼저** 민다.
--     601E  A9 3F 85 17   ->   20 20 5C EA      (JSR $5C20 + NOP)
--     스텁: LDA #$3F / STA $17    밀려난 원본을 먼저
--           우리 N 개 푸시          슬롯 0.. -> 맨 앞
--           RTS                    게임 루프가 그 뒤부터 이어간다
--   그래서 자막이 **그림·초상화보다 앞에** 그려진다.
--   MAWR 은 $6008 에서 슬롯 0 에 서 있고 우리가 밀면 그만큼 전진하며,
--   같은 푸시가 $17 을 깎으므로 $60A6 의 0 채우기도 저절로 맞는다.
--   ★ VDC 접근 0 회.
--
--   무장 $6000 / 회수 $6072 -- 패치가 프레임 밖으로 안 나간다 (0.1.3 에서 확정).
--   오버레이가 갈리면 우리 엔트리만 골라 SATB 에서 지운다 (잔류 제거).
--
-- 조작
--   자동으로 돈다.  특정 조합을 오래 보고 싶으면 아래 CONFIGS 를 한 줄만 남기면 된다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sub_fit_0_1_0_<날짜>.tsv

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"
local PATTERNS = "C:/snatcher/build/cutscene_subs/poc_patterns.bin"

local STUB, LIST = 0x5C20, 0x5C80
local ARM, HOOK, DISARM = 0x6000, 0x601E, 0x6072
local JSR_AT = 0x5C51
local SATB_BYTE, PAT_VRAM_BYTE = 0x2000, 0xF200
local GLYPHS = 9
local SCREEN_W = 256

-- 자막 줄의 화면 Y.  그림 아래쪽 띠 (빨간 원 구간)
local TEXT_Y = 124

-- { 간격, 글자수 }  -- 3 초씩 돌아간다
local CONFIGS = {
  { 16,  9 }, { 16, 12 }, { 16, 14 }, { 16, 16 },
  { 14, 14 }, { 14, 16 }, { 14, 18 },
  { 12, 16 }, { 12, 18 }, { 12, 21 },
}
local HOLD = 180

local ORIG  = { 0xA9, 0x3F, 0x85, 0x17 }               -- LDA #$3F / STA $17
local PATCH = { 0x20, STUB & 0xFF, STUB >> 8, 0xEA }   -- JSR $5C20 / NOP

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } },
  { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } },
  { 0x60A6, { 0xA6, 0x17 } },
  { 0x6072, { 0x4C, 0xBE, 0x43 } },
}

-- 스텁.  N 과 원점만 자리 채우면 된다 (1-기준 색인: Ylo 15 · Yhi 19 · Xlo 23 · Xhi 27 · N 47)
local function build_stub(n, x_origin, y_origin)
  return {
    0x08, 0x78,
    0xA9, 0x3F, 0x85, 0x17,                 -- 밀려난 원본
    0xAD, 0x00, 0x65, 0xC9, 0x82,           -- LDA $6500 / CMP #$82
    0xD0, 0x27,                             -- BNE exit ($5C54)
    0xA9, y_origin & 0xFF, 0x85, 0x08,
    0xA9, (y_origin >> 8) & 0xFF, 0x85, 0x09,
    0xA9, x_origin & 0xFF, 0x85, 0x0A,
    0xA9, (x_origin >> 8) & 0xFF, 0x85, 0x0B,
    0x64, 0x0C, 0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F,
    0xA9, LIST & 0xFF, 0x85, 0x10,
    0xA9, LIST >> 8,   0x85, 0x11,
    0xA9, n, 0x85, 0x16,
    0x20, 0x63, 0x64,                       -- JSR $6463   ($5C51)
    0x28, 0x60,                             -- PLP / RTS   ($5C54)
  }
end

-- 레코드 5 B x N.  [2] 는 부호 8 비트 X 오프셋
local function build_records(n, adv)
  local half = math.floor((n - 1) * adv / 2)
  local r = {}
  for g = 0, n - 1 do
    local w2 = 0x3C8 + 2 * (g % GLYPHS)
    local off = g * adv - half
    r[#r+1] = 0x00; r[#r+1] = 0x00; r[#r+1] = off & 0xFF
    r[#r+1] = w2 & 0xFF; r[#r+1] = 0x80 | ((w2 >> 8) << 4)
  end
  return r, half
end

local frames, loaded, tries = 0, false, 0
local armed, arms, pushes = false, 0, 0
local refused, stranded, cleared = 0, 0, 0
local cfg_i, cfg_since = 1, 0
local CODE, RECORD, cur_n, cur_adv, cur_x0, cur_x1 = {}, {}, 0, 0, 0, 0
local uploads, slot_seen = 0, -1
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

local function apply(i)
  local adv, n = CONFIGS[i][1], CONFIGS[i][2]
  local half
  RECORD, half = build_records(n, adv)
  -- 줄을 화면 가운데에 놓는다
  local center = math.floor(SCREEN_W / 2)
  CODE = build_stub(n, center + 32, TEXT_Y + 64)
  cur_n, cur_adv = n, adv
  cur_x0 = center - half
  cur_x1 = center - half + (n - 1) * adv + 15
  say(string.format('[프레임 %d] 간격 %d px · %d 자 · 줄폭 %d px · 화면 x %d..%d %s',
        frames, adv, n, (n - 1) * adv + 16, cur_x0, cur_x1,
        (cur_x0 < 0 or cur_x1 > SCREEN_W - 1) and '★ 화면 밖' or ''))
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

-- 오버레이가 갈리면 우리 엔트리만 골라 지운다
local function clear_ours()
  local y = (TEXT_Y + 64)
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local ey = rb(o, VRAM) + rb(o + 1, VRAM) * 256
    local w2 = rb(o + 4, VRAM) + rb(o + 5, VRAM) * 256
    local at = rb(o + 6, VRAM) + rb(o + 7, VRAM) * 256
    if ey == y and at == 0x0080 and w2 >= 0x3C8 and w2 <= 0x3D8 then
      for i = 0, 7 do emu.write(o + i, 0, VRAM) end
      cleared = cleared + 1
    end
  end
end

local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다: ' .. PATH) return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end
apply(1)

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
  for i = 1, #CODE   do emu.write(STUB + i - 1, CODE[i],   MEM) end
  for i = 1, #RECORD do emu.write(LIST + i - 1, RECORD[i], MEM) end
  for i = 1, #PATCH  do emu.write(HOOK + i - 1, PATCH[i],  MEM) end
  armed = true; arms = arms + 1
end, emu.callbackType.exec, ARM, ARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function() disarm() end,
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

  if armed then disarm() end

  if not fingerprint() then clear_ours() end

  cfg_since = cfg_since + 1
  if cfg_since >= HOLD then
    cfg_since = 0
    cfg_i = cfg_i % #CONFIGS + 1
    apply(cfg_i)
  end

  emu.drawString(4, 4, string.format('adv %2d  n %2d  w %3d  x %d..%d',
        cur_adv, cur_n, (cur_n - 1) * cur_adv + 16, cur_x0, cur_x1), 0xFFFFFF, 0x000000)
  emu.drawString(4, 14, string.format('slot %d  push %d  clr %d',
        slot_seen, pushes, cleared), 0xFFFF80, 0x000000)

  if frames % 600 == 0 then
    say(string.format('--- %d --- 무장 %d · 푸시 %d · 회수실패 %d · 잔류지움 %d · 첫슬롯 %d',
                      frames, arms, pushes, stranded, cleared, slot_seen))
    local f = io.open(string.format('C:/snatcher/dump/probe_sub_fit_0_1_0_%s.tsv',
                                    os.date('%Y%m%d_%H%M%S')), 'w')
    if f then
      f:write('line\n')
      for _, s in ipairs(lines) do f:write(s .. '\n') end
      f:close()
    end
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_FIT 0.1.0 loaded')
emu.log(string.format('  화면 y=%d 에 한 줄.  간격/글자수 조합을 3 초씩 돌린다', TEXT_Y))
emu.log('  게임보다 먼저 밀어 그림·초상화보다 앞에 그린다')
