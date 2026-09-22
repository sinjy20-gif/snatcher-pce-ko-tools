-- SUB 0.5.150 -- 자막 자리의 알록달록한 띠는 '남의 데이터를 그리는 우리 스프라이트' 인가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 여기까지 온 길
-- ---------------------------------------------------------------------------
-- 0.5.149  배경 타일맵이 우리 블록을 가리키는가  ->  **겹침 0** (배경 최대 $2BBF,
--          우리 블록 $6600-$6ABF).  VRAM 겹침 가설 폐기.
--
-- 배경이 우리 자리를 안 가리키는데 그림 위에 가로 띠가 뜬다면, 그 띠는 배경이
-- 아니라 **스프라이트**다 (스프라이트는 배경 위에 아무 데나 뜬다).
-- 즉 자막이 뜨긴 뜨는데 엉뚱한 데이터를 그리고 있다.
--
-- 어떻게 가리나 -- 플레인 2·3 이 증거다
-- ---------------------------------------------------------------------------
-- 우리 글리프는 **2 플레인만** 싣는다.  렌더러가 올리는 128 B 중 위 64 B 는 0 이다
-- (build_subtitle_engine.py: "128 B · 위 64 B 는 0 (플레인 2·3)").
--
--     16x16 스프라이트 = 64 워드 = 4 플레인 x 16 줄
--     워드 0..15 플레인0 · 16..31 플레인1 · **32..63 플레인2·3 -> 우리 것은 전부 0**
--
-- 그 자리가 0 이 아니면 우리 데이터가 아니다.  그리고 플레인 2·3 이 0 이 아니면
-- 화면에는 색이 4 개를 넘어 **알록달록한 블록**으로 나온다.  사진 그대로다.
--
-- 판정
--     ★JUNK 가 뜬다      -> 확정.  우리 스프라이트가 남의 데이터를 그리고 있다
--                            어느 칸이 더러운지 · 언제부터인지가 같이 찍힌다
--     JUNK 가 안 뜬다    -> 글리프는 깨끗하다.  그럼 팔레트를 봐야 한다
--                            (팔레트 15 색이 흰/검이 아니면 같은 그림이 나온다)
--
-- 산출물  C:/snatcher/dump/glyph_junk_0_5_150_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE  = 0x5B80
local A_COUNT = 0x5CFA        -- ★ 0.4.6.71 기준
local A_VHI   = 0x5C7E
local A_PATLO = 0x5CA1
local A_ATTR  = 0x5CA6
local STATE_ADDR = 0x7FDF
local SATB, SCAN_SLOTS = 0x1000, 20
local MAX_PATTERNS = 38
local GLYPHS = 19

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/glyph_junk_0_5_150_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tcount\tscreen\tvram_hi\tdirty\tdirty_cells\tpal15\txs\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

-- 팔레트 15 의 색 1·2 (있으면).  없으면 -1
local PAL = nil
local function pal15()
  if PAL == nil then
    PAL = false
    for _, n in ipairs({'pcePaletteRam', 'pceVideoRam'}) do
      if emu.memType[n] and n == 'pcePaletteRam' then PAL = emu.memType[n] break end
    end
  end
  if PAL == false then return -1, -1 end
  local function c(i)
    local at = (0x100 + 15*16 + i) * 2
    local ok1, lo = pcall(emu.read, at, PAL)
    local ok2, hi = pcall(emu.read, at+1, PAL)
    if not (ok1 and ok2) then return -1 end
    return (lo | (hi << 8)) & 0x1FF
  end
  return c(1), c(2)
end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

-- 화면에 뜬 우리 스프라이트가 가리키는 칸 번호
local function usedCells(baseLo, patHi)
  local cells, xs = {}, {}
  for i = 0, SCAN_SLOTS-1 do
    local at  = SATB + i*4
    local pat = rw(at + 2) & 0x07FF
    if pat ~= 0 and ((pat >> 8) & 0x07) == patHi then
      local d = (pat & 0xFF) - baseLo
      if d >= 0 and d < MAX_PATTERNS then
        cells[#cells+1] = d // 2
        xs[#xs+1] = rw(at + 1) & 0x03FF
      end
    end
  end
  return cells, xs
end

-- 그 칸의 플레인 2·3 이 0 인가.  0 이 아니면 우리 데이터가 아니다
local function dirtyCells(vhi, cells)
  local base, bad = vhi << 8, {}
  local seen = {}
  for _, c in ipairs(cells) do
    if not seen[c] and c < GLYPHS then
      seen[c] = true
      local at = base + c*64
      for w = 32, 63 do
        if rw(at + w) ~= 0 then bad[#bad+1] = c break end
      end
    end
  end
  return bad
end

local function join(t)
  local p = {}
  for i = 1, #t do p[#p+1] = tostring(t[i]) end
  return table.concat(p, ',')
end

local frame, last, junks = 0, nil, 0

emu.addEventCallback(function()
  frame = frame + 1
  if not engineUp() then return end
  local count, vhi = rd(A_COUNT), rd(A_VHI)
  local baseLo, attr = rd(A_PATLO), rd(A_ATTR)
  if count < 0 or vhi <= 0 or baseLo < 0 or attr < 0 then return end

  local cells, xs = usedCells(baseLo, (attr >> 4) & 0x07)
  if #cells == 0 then return end
  local bad = dirtyCells(vhi, cells)
  local c1, c2 = pal15()

  local k = ('%d|%d|%s|%s'):format(count, #cells, join(bad), join(xs))
  if k == last then return end
  last = k

  local state = rd(STATE_ADDR)
  local kind, note = 'OK', ''
  if #bad > 0 then
    junks = junks + 1
    kind = 'JUNK'
    note = ('플레인2·3 이 0 이 아닌 칸 %d 개 -- 우리 데이터가 아니다'):format(#bad)
    say(('★JUNK f%-7d state=%d  화면 %d 칸 중 더러운 칸 %s  (vram_hi=$%02X)')
          :format(frame, state, #cells, join(bad), vhi))
    say(('        x %s'):format(join(xs)))
    say(('        팔레트15 색1=$%03X 색2=$%03X  (정상은 $1FF · $000)'):format(c1, c2))
  end
  out:write(('%d\t%s\t%d\t%d\t%d\t%02X\t%d\t%s\t%03X/%03X\t%s\t%s\n'):format(
    frame, kind, state, count, #cells, vhi, #bad, join(bad), c1, c2, join(xs), note))
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# JUNK %d 건\n'):format(junks))
  out:close()
  say(('끝 -- ★JUNK %d 건'):format(junks))
end, emu.eventType.scriptEnded)

say('SUB 0.5.150-glyph-junk armed -- 순수 관측')
say('  ★ 볼 것: ★JUNK 가 뜨는가 (우리 글리프 자리에 남의 데이터가 있는가)')
say('    안 뜨면 팔레트15 색을 볼 것 -- 정상은 색1=$1FF(흰) 색2=$000(검)')
say('  ' .. PATH)
