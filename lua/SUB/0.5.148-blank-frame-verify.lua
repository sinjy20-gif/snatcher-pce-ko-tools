-- SUB 0.5.148 -- 0.4.6.71 의 '빈 한 프레임' 이 실제로 도는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- ⚠ 주소가 0.5.146/0.5.147 과 다르다.  엔진이 13 B 늘어 오프셋이 +12 밀렸다.
--   0.4.6.70 이하에 이 판을 쓰면 엉뚱한 값을 읽는다.
--
--     count               $5CEE -> $5CFA
--     pattern_base_lo     $5C95 -> $5CA1
--     pattern_attr        $5C9A -> $5CA6
--     vram_base_hi        $5C72 -> $5C7E
--     blank (새로 생김)            $5E19
--
-- 무엇이 바뀌었나 (0.4.6.71)
-- ---------------------------------------------------------------------------
-- 조각 경계에서 엔진이 **한 프레임 쉰다.**  스케줄러가 ready 를 내린 프레임에는
-- 글리프도 안 올리고 push 도 안 한다.  push 를 건너뛰면 그 프레임 스프라이트
-- 목록에 우리 칸이 안 실려 다음 프레임에 줄이 빈다.
--
--     N     ready=0 · blank=0  ->  INC blank · RTS      (아무것도 안 함)
--     N+1   ready=0 · blank=1  ->  rebuild              글리프 새것 · push 새 목록
--           이 프레임 화면은 **비어 있어야 한다**
--     N+2   새 줄이 온전히 뜬다
--
-- 판정
-- ---------------------------------------------------------------------------
--     글리프가 바뀐 프레임에 화면 칸 = 0        -> ★ 고쳐졌다
--     글리프가 바뀐 프레임에 화면 칸 = 옛 칸수  -> ★ 안 고쳐졌다 (0.4.6.70 과 같다)
--     빈 프레임이 2 프레임 이상 이어진다        -> 너무 오래 비운다.  보고할 것
--
-- 산출물  C:/snatcher/dump/blank_verify_0_5_148_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE  = 0x5B80
local A_COUNT = 0x5CFA
local A_VHI   = 0x5C7E
local A_PATLO = 0x5CA1
local A_ATTR  = 0x5CA6
local A_BLANK = 0x5E19
local STATE_ADDR = 0x7FDF
local SATB = 0x1000
local SCAN_SLOTS   = 20
local MAX_PATTERNS = 38
local GLYPHS = 19

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/blank_verify_0_5_148_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tblank\tcount\tscreen\tdglyph\tchanged\txs\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

local function glyphSig(vhi)
  local base, sig = vhi << 8, {}
  for i = 0, GLYPHS-1 do
    local at = base + i*64
    sig[i] = rw(at) * 65536 + rw(at + 32)
  end
  return sig
end

local function scanSprites(baseLo, patHi)
  local n, xs = 0, {}
  for i = 0, SCAN_SLOTS-1 do
    local at  = SATB + i*4
    local pat = rw(at + 2) & 0x07FF
    if pat ~= 0 and ((pat >> 8) & 0x07) == patHi then
      local d = (pat & 0xFF) - baseLo
      if d >= 0 and d < MAX_PATTERNS then
        n = n + 1
        xs[#xs+1] = rw(at + 1) & 0x03FF
      end
    end
  end
  return n, xs
end

local function join(t)
  local p = {}
  for i = 1, #t do p[#p+1] = tostring(t[i]) end
  return table.concat(p, ',')
end

local frame, good, bad, blanks = 0, 0, 0, 0
local pScreen, pXs, pSig = -1, '', nil

emu.addEventCallback(function()
  frame = frame + 1
  if not engineUp() then return end
  local count  = rd(A_COUNT)
  local vhi    = rd(A_VHI)
  local baseLo = rd(A_PATLO)
  local attr   = rd(A_ATTR)
  local blank  = rd(A_BLANK)
  if count < 0 or vhi < 0 or baseLo < 0 or attr < 0 then return end

  local screen, xs = scanSprites(baseLo, (attr >> 4) & 0x07)
  local sig = glyphSig(vhi)

  local changed = {}
  if pSig then
    for i = 0, GLYPHS-1 do
      if sig[i] ~= pSig[i] then changed[#changed+1] = i end
    end
  end
  local dGlyph  = (#changed > 0) and 1 or 0
  local dSprite = (join(xs) ~= pXs or screen ~= pScreen) and 1 or 0

  if dGlyph + dSprite > 0 or blank ~= 0 then
    local state = rd(STATE_ADDR)
    local kind, note = 'CHG', ''
    if dGlyph == 1 then
      if screen == 0 then
        good = good + 1; kind = 'OK'
        note = '글리프가 바뀐 프레임에 화면이 비어 있다 -- 고쳐졌다'
        say(('  OK   f%-7d 글리프 갱신 · 화면 0 칸 (count=%d)'):format(frame, count))
      else
        bad = bad + 1; kind = 'BAD'
        note = ('글리프가 바뀌었는데 화면에 %d 칸 남아 있다'):format(screen)
        say(('★BAD f%-7d 글리프 갱신 · 화면 %d 칸 (count=%d)  x %s')
              :format(frame, screen, count, join(xs)))
      end
    end
    if screen == 0 and pScreen > 0 then blanks = blanks + 1 end
    out:write(('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n'):format(
      frame, kind, state, blank, count, screen, dGlyph, join(changed), join(xs), note))
    out:flush()
  end

  pScreen, pXs, pSig = screen, join(xs), sig
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# OK %d · BAD %d · 빈 프레임 %d\n'):format(good, bad, blanks))
  out:close()
  say(('끝 -- OK %d 건 · ★BAD %d 건 · 빈 프레임 %d 회'):format(good, bad, blanks))
end, emu.eventType.scriptEnded)

say('SUB 0.5.148-blank-frame-verify armed -- 순수 관측')
say('  ★ 0.4.6.71 전용.  0.4.6.70 이하에 쓰면 주소가 어긋난다')
say('  볼 것: 글리프가 바뀐 프레임에 화면이 0 칸인가 (OK) · 옛 칸이 남는가 (★BAD)')
say('  ' .. PATH)
