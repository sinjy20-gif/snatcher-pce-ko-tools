-- SUB 0.4.91 -- 국장실 배경이 우리 글리프 자리를 "그림 데이터"로 쓰는지 본다 (쓰기 0 B)
--
-- 0.4.90 이 무엇을 배제했나
-- ---------------------------------------------------------------------------
--     BAT 최대   128x32 / 64x64 = 4096 word  ->  0..$0FFF
--     SATB       $1000-$10FF
--     글리프     $1600-$1ABF                  ->  BAT 본체보다 위.  clear
--
-- 즉 "글리프가 BAT 표를 덮는다" 는 아니었다.  (국장실에서 128x64 가 나오면
-- 얘기가 달라지므로 0.4.90 의 판정은 계속 같이 띄운다.)
--
-- 그러면 남은 것
-- ---------------------------------------------------------------------------
-- BAT 엔트리는 **타일 번호**다.  그 타일의 그림 데이터는 VRAM 어딘가에 있다.
--
--     tile = entry & 0x07FF          그림 데이터 = tile * 16 word, 16 word 길이
--
-- 국장실 배경 타일이 $1600 근처에 실려 있으면, 우리가 글리프를 쓰는 순간
-- **그림 타일 자체를 덮는다.**  화면에는 그 타일을 쓰는 자리마다 엉뚱한 그림이
-- 나온다 -- 방 그림의 다른 부분이 튀어나오고 배경이 아래까지 번지는 모습이
-- 정확히 그것이다.
--
-- 0.4.90 은 BAT **본체**만 봤지 BAT 가 **가리키는 곳**은 안 봤다.
-- VRAM-key-map-0.2 는 그것도 점유로 치지만 국장실을 측정한 적이 없다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- SCAN_EVERY 프레임마다 BAT 를 훑어 각 엔트리가 가리키는 16 word 구간이
-- 글리프 블록($1600-$1ABF)과 겹치는지 센다.
--
--     hits > 0   배경이 우리 자리를 그림으로 쓴다  -> ★ 이것이 원인이다
--     hits = 0   이 장면 배경은 우리 자리를 안 쓴다
--
-- 같이 찍는 것:
--     tile_lo / tile_hi   이 장면 배경이 실제로 쓰는 그림 데이터의 최저/최고 word
--                         -> 안전한 base 를 어디에 둘지가 여기서 나온다
--
-- 읽기 전용이다.  자막 체인과 같이 올려도 된다 (자유공간 측정이 아니라
-- 배경이 무엇을 가리키는지만 보므로 우리 글리프에 오염되지 않는다).
-- 다만 우리 글리프가 이미 올라가 있으면 그림 데이터는 이미 덮인 상태다.
-- 판정에 쓰는 것은 "BAT 가 그 자리를 가리키는가" 이지 그 내용이 아니다.
--
-- Power Cycle 뒤 0.4.89 와 함께, 또는 단독으로 로드한다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

-- base 를 바꿔 구운 엔진과 같이 돌릴 때는 이 전역으로 맞춘다.
local PAT_VRAM    = rawget(_G, 'SUB_PROBE_PAT_VRAM') or 0x1600   -- subtitle_layout.py
local MAX_GLYPHS  = 19
local GLYPH_WORDS = 0x40
local GLYPH_FIRST = PAT_VRAM
local GLYPH_LAST  = PAT_VRAM + MAX_GLYPHS * GLYPH_WORDS - 1

local TILE_WORDS = 16              -- BG 타일 하나의 그림 데이터
local SCAN_EVERY = 30              -- 프레임.  4096 엔트리 스캔은 싸지 않다

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/bg_overlap_0_4_91_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tcolumns\trows\tbat_words\tsatb\tbat_verdict' ..
            '\tentries\thits\ttile_lo\ttile_hi\tverdict\n')
end

local selReg, mwrReg, dvssr = 0, nil, nil
local portHits = 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  portHits = portHits + 1
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0x09 then mwrReg = value
    elseif selReg == 0x13 then dvssr = ((dvssr or 0) & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0x13 then dvssr = ((dvssr or 0) & 0x00FF) | (value << 8) end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local function dimensions()
  if mwrReg then
    local w = (mwrReg >> 4) & 0x03
    local columns = (w == 0) and 32 or (w == 1) and 64 or 128
    local rows = (((mwrReg >> 6) & 1) == 1) and 64 or 32
    return columns, rows
  end
  local ok, state = pcall(emu.getState)
  if ok and state then
    local c, r = state['vdc.hvReg.columnCount'], state['vdc.hvReg.rowCount']
    if type(c) == 'number' and type(r) == 'number' then
      return math.floor(c), math.floor(r)
    end
  end
  return 0, 0
end

local function satbAddress()
  if dvssr then return dvssr & 0x7FFF end
  return -1
end

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(word) local at = word * 2; return rb(at) | (rb(at + 1) << 8) end

local frame, last = 0, nil
local hits, tileLo, tileHi, entries = 0, nil, nil, 0

local function scan()
  local columns, rows = dimensions()
  entries = columns * rows
  hits, tileLo, tileHi = 0, nil, nil
  if entries == 0 then return columns, rows end
  for i = 0, entries - 1 do
    local tile = rw(i) & 0x07FF
    local first = tile * TILE_WORDS
    local lastw = first + TILE_WORDS - 1
    if tileLo == nil or first < tileLo then tileLo = first end
    if tileHi == nil or lastw > tileHi then tileHi = lastw end
    if lastw >= GLYPH_FIRST and first <= GLYPH_LAST then hits = hits + 1 end
  end
  return columns, rows
end

emu.addEventCallback(function()
  frame = frame + 1
  local columns, rows
  if frame % SCAN_EVERY == 0 then
    columns, rows = scan()
  else
    columns, rows = dimensions()
  end

  local batWords = columns * rows
  local batLast = batWords - 1
  local batVerdict = (batWords == 0) and 'unknown'
                     or ((GLYPH_FIRST <= batLast) and 'BAT-OVERLAP' or 'bat-clear')
  local verdict = (entries == 0) and 'unknown'
                  or ((hits > 0) and 'BG-OVERLAP' or 'bg-clear')
  local satb = satbAddress()

  local key = string.format('%s|%s|%d|%d|%s|%s', batVerdict, verdict, columns, rows,
                            tostring(tileLo), tostring(tileHi))
  if frame % SCAN_EVERY == 0 and key ~= last then
    last = key
    emu.log(string.format(
      'SUB 0.4.91 %df · BAT %dx%d(0..$%04X) %s · SATB $%04X · 배경타일 $%04X-$%04X · ' ..
      '글리프 $%04X-$%04X 를 가리키는 엔트리 %d/%d · %s',
      frame, columns, rows, batLast < 0 and 0 or batLast, batVerdict,
      satb < 0 and 0 or satb, tileLo or 0, tileHi or 0,
      GLYPH_FIRST, GLYPH_LAST, hits, entries,
      verdict == 'BG-OVERLAP' and '★ 배경이 우리 자리를 그림으로 쓴다' or verdict))
    if out then
      out:write(string.format('%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\n',
        frame, columns, rows, batWords, satb, batVerdict, entries, hits,
        tileLo or -1, tileHi or -1, verdict))
      out:flush()
    end
  end

  emu.drawString(4, 54, string.format(
    '0.4.91 BAT %dx%d %s · 배경타일 $%04X-$%04X · 겹침 %d/%d %s',
    columns, rows, batVerdict, tileLo or 0, tileHi or 0, hits, entries, verdict),
    (verdict == 'BG-OVERLAP' or batVerdict == 'BAT-OVERLAP') and 0x4040FF or 0x80FF80,
    0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.91-bg-pattern-overlap armed -- BAT 가 "가리키는 곳" 까지 본다')
emu.log(string.format('  글리프 $%04X-$%04X · %d 프레임마다 BAT 전수 스캔',
                      GLYPH_FIRST, GLYPH_LAST, SCAN_EVERY))
emu.log('  배경타일 lo-hi 가 안전한 base 를 정하는 근거가 된다')
emu.log('  로그: ' .. OUT)
