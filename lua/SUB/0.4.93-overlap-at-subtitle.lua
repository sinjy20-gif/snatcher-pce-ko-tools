-- SUB 0.4.93 -- "자막이 뜨는 그 순간, 그 장면" 의 겹침을 잰다 (프로브는 쓰기 0 B)
--
-- 0.4.91 이 답하지 못한 것
-- ---------------------------------------------------------------------------
-- 0.4.91 은 겹침을 4/44 스캔에서 봤다 (165 · 165 · 78 · 45 엔트리).  그런데
-- **그 프레임이 국장실인지 알 수 없다.**  BAT 크기로 좁혀도 64x64 는 여러
-- 장면이 쓴다.  게다가 그 측정은 자막 없이 돌았으므로 "자막이 뜨는 순간" 과
-- 이어지지 않는다.  둘을 묶지 않으면 다음 두 가지를 못 가른다:
--
--     A  국장실에서 겹친다      -> 주소 충돌이 국장실 증상의 원인이다
--     B  국장실은 bg-clear 다   -> 그 겹침은 다른 장면의 별도 문제이고,
--                                 국장실 번쩍임의 원인은 여전히 따로 있다
--
-- 그래서 이 판은 **자막 조각이 실제로 올라가는 프레임에만** BAT 를 훑는다.
-- 같이 찍는 음성 키가 장면 식별자다 (팩의 키로 어느 대사인지 되짚을 수 있다).
--
-- ★ base 는 $1600 이다.  이 질문은 원래 base 로 재야 뜻이 있다.
--   $7900 판정은 0.4.92 로 따로 한다.
--
-- 무엇을 어떻게
-- ---------------------------------------------------------------------------
--     emu.log 를 사슬로 물어 '★ KEY #n <hex>' 에서 현재 음성 키를 잡는다
--       (0.4.48 이 쓰는 것과 같은 방법.  prevLog 를 반드시 다시 부른다)
--     ENGINE+count_ok 실행 = 엔진이 실제로 글리프를 올리는 프레임
--       -> 그 프레임 끝에서 BAT 전수 스캔 1회
--
--     hits > 0   그 자막이 그 장면에서 배경 그림을 덮고 있다  -> A 확정
--     hits = 0   그 장면 배경은 우리 자리를 안 쓴다            -> B
--
-- 스캔은 자막 조각당 한 번뿐이라 평상시 부하가 없다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  (0.4.89 재무장 체인을 같이 올린다 --
-- 재무장 여부는 이 측정과 무관하고, 지금 도는 경로를 그대로 쓰기 위함이다.)

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local info = rawget(_G, 'SUB_REARM_INFO')
local ENGINE_LO = info and info.engine_lo or 0x5B80
local COUNT_OK = ENGINE_LO + (info and info.offsets.count_ok or 118)
local PAT_VRAM = info and info.pat_vram or 0x1600

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local MAX_GLYPHS, GLYPH_WORDS = 19, 0x40
local GLYPH_FIRST = PAT_VRAM
local GLYPH_LAST = PAT_VRAM + MAX_GLYPHS * GLYPH_WORDS - 1
local TILE_WORDS = 16

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/overlap_at_subtitle_0_4_93_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tkey\tcolumns\trows\tbat_words\tentries\thits\thits_visible' ..
            '\ttile_lo\ttile_hi\tbxr\tbyr\tverdict\n')
end

-- ── VDC 포트 추적 (MWR/BXR/BYR).  VRAM-key-map-0.2 와 같은 방식 ──────────────
local selReg, mwrReg = 0, nil
local bxr, byr = 0, 0
local portHits = 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  portHits = portHits + 1
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0x09 then mwrReg = value
    elseif selReg == 0x07 then bxr = (bxr & 0xFF00) | value
    elseif selReg == 0x08 then byr = (byr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0x07 then bxr = (bxr & 0x00FF) | (value << 8)
    elseif selReg == 0x08 then byr = (byr & 0x00FF) | (value << 8) end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

-- ★ MWR($09)은 화면 모드가 바뀔 때만 쓰인다.  세이브스테이트로 장면에 바로
-- 들어가면 그 쓰기는 이미 지나간 뒤라 포트 감시만으로는 영영 못 본다.
-- 그때 BAT 0x0 으로 판정하면 "겹침 없음" 을 거짓으로 말하게 되므로,
-- 0.4.90/0.4.91 과 같이 Mesen state 를 폴백으로 둔다.
local function dimensions()
  if mwrReg then
    local w = (mwrReg >> 4) & 0x03
    local columns = (w == 0) and 32 or (w == 1) and 64 or 128
    local rows = (((mwrReg >> 6) & 1) == 1) and 64 or 32
    return columns, rows, 'mwr'
  end
  local ok, state = pcall(emu.getState)
  if ok and state then
    local c, r = state['vdc.hvReg.columnCount'], state['vdc.hvReg.rowCount']
    if type(c) == 'number' and type(r) == 'number' and c > 0 and r > 0 then
      return math.floor(c), math.floor(r), 'state'
    end
  end
  return 0, 0, 'none'
end

-- ── 음성 키를 로그 사슬에서 잡는다 ──────────────────────────────────────────
local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local text = tostring(message)
  local key = text:match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

-- ── 엔진이 글리프를 올리는 프레임만 표시 ────────────────────────────────────
local pending = false
emu.addMemoryCallback(function() pending = true end,
  emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(word) local at = word * 2; return rb(at) | (rb(at + 1) << 8) end

local frame, scans, overlaps = 0, 0, 0
local lastHits, lastVisible, lastKey = -1, -1, '-'

emu.addEventCallback(function()
  frame = frame + 1
  if pending then
    pending = false
    scans = scans + 1
    local columns, rows, source = dimensions()
    local entries = columns * rows
    local hits, visible, tileLo, tileHi = 0, 0, nil, nil
    -- 화면에 실제로 보이는 창.  BXR/BYR 은 픽셀 단위라 8 로 나눠 타일로 만든다.
    local col0 = (bxr >> 3) % (columns > 0 and columns or 1)
    local row0 = (byr >> 3) % (rows > 0 and rows or 1)
    for i = 0, entries - 1 do
      local tile = rw(i) & 0x07FF
      local first = tile * TILE_WORDS
      local lastw = first + TILE_WORDS - 1
      if tileLo == nil or first < tileLo then tileLo = first end
      if tileHi == nil or lastw > tileHi then tileHi = lastw end
      if lastw >= GLYPH_FIRST and first <= GLYPH_LAST then
        hits = hits + 1
        -- 32x28 타일이 보이는 범위.  BAT 는 세로/가로로 감긴다.
        local c, r = i % columns, i // columns
        local dc = (c - col0) % columns
        local dr = (r - row0) % rows
        if dc < 32 and dr < 29 then visible = visible + 1 end
      end
    end
    if hits > 0 then overlaps = overlaps + 1 end
    lastHits, lastVisible, lastKey = hits, visible, curKey
    local verdict = (entries == 0) and 'unknown'
                    or ((hits > 0) and 'BG-OVERLAP' or 'bg-clear')
    prevLog(string.format(
      'SUB 0.4.93 %df · KEY %s · BAT %dx%d(%s) · 배경타일 $%04X-$%04X · ' ..
      '글리프 $%04X-$%04X 겹침 %d/%d (화면 안 %d) · BXR %d BYR %d · %s',
      frame, curKey, columns, rows, source, tileLo or 0, tileHi or 0,
      GLYPH_FIRST, GLYPH_LAST, hits, entries, visible, bxr, byr,
      verdict == 'unknown' and 'unknown(BAT 크기를 못 얻었다 -- 판정 불가)' or verdict))
    if out then
      out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n',
        frame, curKey, columns, rows, entries, entries, hits, visible,
        tileLo or -1, tileHi or -1, bxr, byr, verdict))
      out:flush()
    end
  end

  emu.drawString(4, 64, string.format(
    '0.4.93 scans:%d overlap:%d · last KEY %s 겹침 %d (화면 %d) · hits:%d',
    scans, overlaps, lastKey, lastHits, lastVisible, portHits),
    overlaps > 0 and 0x4040FF or 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.4.93-overlap-at-subtitle armed -- 자막 조각마다 BAT 전수 스캔 1회')
prevLog(string.format('  글리프 $%04X-$%04X · count_ok $%04X · 키를 같이 찍는다',
                      GLYPH_FIRST, GLYPH_LAST, COUNT_OK))
prevLog('  ★ scans 가 안 올라가면 엔진이 안 돈 것이다.  그때의 판정은 무의미하다')
prevLog('  로그: ' .. OUT)
