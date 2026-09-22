-- SUB 0.5.147 -- 조각 전환 프레임에 글리프가 스프라이트보다 먼저 바뀌는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 0.5.146 이 확정한 것
-- ---------------------------------------------------------------------------
--     f291   count=14 화면=14   x 102..208
--     f380   count=9  화면=14   x 102..208   <- count 는 새것, 스프라이트는 옛것
--     f381   count=9  화면=9    x 121..195
--
-- 8 번 전부 같은 모양.  **스프라이트가 한 프레임 늦는다** (JSR $6463 은 목록에
-- 넣을 뿐이고 SATB 반영은 다음 프레임).
--
-- 남은 고리 하나
-- ---------------------------------------------------------------------------
-- 글리프 패턴은 VDC 에 직접 쓰므로 **그 프레임에 바로** 보일 것이다.  그렇다면
-- 그 한 프레임 동안 화면은
--
--     앞 9 칸 = 새 글자   ·   남는 5 칸 = 옛 글자      (둘 다 옛 x 자리)
--
-- 가 되고, 그게 소유자 사진("길리언시드다만이" + "임명된") 이다.
-- **이 판은 그 한 고리만 잰다.**  사진 말고 숫자로.
--
-- 어떻게 재나
-- ---------------------------------------------------------------------------
-- 글리프 i 의 VRAM 자리는 렌더러의 MAWR 계산에서 나온다:
--
--     lo = (i & 3) << 6 · hi = vram_base_hi + (i >> 2)
--     -> 워드주소 = (vram_base_hi << 8) + i*64
--
-- 글리프마다 2 워드만 떠서 지문을 만든다 (빠르게 돌려야 프레임이 안 밀린다).
--
-- 판정
--     count 가 바뀐 프레임에 지문도 같이 바뀌고 스프라이트는 그대로
--         -> ★★ 확정.  글리프가 스프라이트보다 한 프레임 앞선다
--     지문이 스프라이트와 **같은** 프레임에 바뀐다
--         -> 내 설명이 틀렸다.  깨짐은 다른 데서 온다
--
-- 산출물  C:/snatcher/dump/glyph_leads_0_5_147_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE  = 0x5B80
local A_COUNT = 0x5CEE
local A_VHI   = 0x5C72
local A_PATLO = 0x5C95
local A_ATTR  = 0x5C9A
local STATE_ADDR = 0x7FDF
local SATB = 0x1000
local SCAN_SLOTS   = 20        -- 실측상 우리 스프라이트는 슬롯 0..15
local MAX_PATTERNS = 38
local GLYPHS = 19

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/glyph_leads_0_5_147_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tcount\tscreen\tdcount\tdsprite\tdglyph\tchanged\txs\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

-- 글리프 i 두 워드 -> 지문
local function glyphSig(vhi)
  local base = vhi << 8
  local sig = {}
  for i = 0, GLYPHS-1 do
    local at = base + i*64
    sig[i] = rw(at) * 65536 + rw(at + 32)
  end
  return sig
end

local function scanSprites(baseLo, patHi)
  local xs, n = {}, 0
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

local frame, confirmed, denied = 0, 0, 0
local pCount, pScreen, pXs, pSig = -1, -1, '', nil

emu.addEventCallback(function()
  frame = frame + 1
  if not engineUp() then return end
  local count  = rd(A_COUNT)
  local vhi    = rd(A_VHI)
  local baseLo = rd(A_PATLO)
  local attr   = rd(A_ATTR)
  if count < 0 or vhi < 0 or baseLo < 0 or attr < 0 then return end

  local screen, xs = scanSprites(baseLo, (attr >> 4) & 0x07)
  local sig = glyphSig(vhi)

  local changed = {}
  if pSig then
    for i = 0, GLYPHS-1 do
      if sig[i] ~= pSig[i] then changed[#changed+1] = i end
    end
  end
  local dCount  = (count ~= pCount) and 1 or 0
  local dSprite = (join(xs) ~= pXs or screen ~= pScreen) and 1 or 0
  local dGlyph  = (#changed > 0) and 1 or 0

  if dCount + dSprite + dGlyph > 0 then
    local state = rd(STATE_ADDR)
    local kind, note = 'CHG', ''
    -- ★ 결정적 조합: count 는 새것 · 글리프도 새것 · 스프라이트만 옛것
    if dCount == 1 and dGlyph == 1 and dSprite == 0 and pScreen > 0 then
      confirmed = confirmed + 1
      kind = 'LEAD'
      note = ('글리프 %d 칸이 바뀌었는데 스프라이트는 그대로 (%d 칸, 옛 x)')
               :format(#changed, screen)
      say(('★LEAD f%-7d state=%d  count %d -> %d · 글리프 바뀐 칸 %s · 스프라이트 %d 칸 그대로')
            :format(frame, state, pCount, count, join(changed), screen))
      say(('        x %s   <- 직전과 동일'):format(join(xs)))
    elseif dGlyph == 1 and dSprite == 1 then
      denied = denied + 1
      kind = 'SAME'
      note = '글리프와 스프라이트가 같은 프레임에 바뀌었다'
    end
    out:write(('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n'):format(
      frame, kind, state, count, screen, dCount, dSprite, dGlyph,
      join(changed), join(xs), note))
    out:flush()
  end

  pCount, pScreen, pXs, pSig = count, screen, join(xs), sig
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# LEAD %d 건 · SAME %d 건\n'):format(confirmed, denied))
  out:close()
  say(('끝 -- ★LEAD %d 건 · SAME %d 건'):format(confirmed, denied))
end, emu.eventType.scriptEnded)

say('SUB 0.5.147-glyph-leads-sprite armed -- 순수 관측')
say('  ★LEAD 가 나오면 확정: 글리프가 스프라이트보다 한 프레임 앞선다')
say('  SAME 만 나오면 내 설명이 틀린 것')
say('  ' .. PATH)
