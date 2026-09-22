-- SUB 0.4.90 -- 글리프 블록이 BAT 본체 안에 들어앉는지 본다 (쓰기 0 B)
--
-- 왜
-- ---------------------------------------------------------------------------
-- 국장실에서 "타일맵 위쪽이 짧게 보이고 배경이 아래까지 덮는" 증상이 한 글자
-- 엔진(0.4.87)에서도, VDC 재무장 엔진(0.4.89)에서도 그대로였다.  즉 주소는
-- 우리가 지정한 대로 정확히 쓰이고 있었고, 의심할 것은 **그 주소 자체**다.
--
--     글리프 블록   $1600 .. $1ABF   (PAT_VRAM $1600 · 19 x $40 word)
--     BAT 본체      word 0 .. columns*rows-1
--
-- BAT 가 128x64 면 본체가 word 0..$1FFF 다.  그러면 글리프가 **BAT 표 한복판**
-- 에 떨어지고, 덮인 엔트리는 방 그림의 엉뚱한 타일을 가리키게 된다.
-- VRAM-key-map-0.2 머리말이 이미 같은 것을 지목해 두었다:
--     "BAT 본체를 점유로 안 쳤다 … 거기 글리프를 쓰면 타일맵이 통째로 망가진다"
--     "화면이 128x64 면 8192 엔트리다 … 국장실에서 타일맵 윗부분이 튀어나온
--      원인으로 가장 유력하다"
--
-- 측정 기록(dump/vram_key_map2_20260829_140304.tsv)의 자유 구간 $1110-$1FFF 는
-- **BAT 가 작았던 장면**(정커 본부까지)의 값이다.  국장실은 측정된 적이 없다.
--
-- 무엇을 잡나
-- ---------------------------------------------------------------------------
-- VDC 포트 쓰기를 따라가며 MWR($09) 로 BAT 크기를, DVSSR($13) 으로 SATB 주소를
-- 잡는다.  (추적 코드는 VRAM-key-map-0.2 에서 그대로 가져왔다.)
-- 매 프레임 겹침을 따져 바뀔 때만 로그하고 화면에 띄운다.
--
--     ★OVERLAP    글리프 블록이 BAT 본체 안이다  -> 이것이 원인이다
--     clear       BAT 밖이다                     -> 다른 곳을 봐야 한다
--
-- ★ portHits 를 같이 띄운다.  0 이면 콜백이 아예 안 걸린 것이고, 그때의
--   "clear" 는 아무 뜻도 없다.  (0.4.69 가 헤더만 남긴 채 끝난 전례가 있다.)
--
-- 자막 체인과 **같이** 올려도 된다.  읽기 전용이고 자유공간 측정이 아니라
-- BAT 크기만 보므로 오염되지 않는다.  단독 실행도 된다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local PAT_VRAM   = 0x1600          -- tools/subtitle_layout.py
local MAX_GLYPHS = 19
local GLYPH_WORDS = 0x40
local GLYPH_FIRST = PAT_VRAM
local GLYPH_LAST  = PAT_VRAM + MAX_GLYPHS * GLYPH_WORDS - 1

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/bat_overlap_0_4_90_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tport_hits\tmwr\tcolumns\trows\tbat_words\tbat_last\tsatb\tverdict\n')
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

-- MWR($09):  bits 5-4 폭 00=32 01=64 10/11=128 · bit 6 높이 0=32 1=64
local function dimensions()
  if mwrReg then
    local w = (mwrReg >> 4) & 0x03
    local columns = (w == 0) and 32 or (w == 1) and 64 or 128
    local rows = (((mwrReg >> 6) & 1) == 1) and 64 or 32
    return columns, rows, true
  end
  local ok, state = pcall(emu.getState)
  if ok and state then
    local c, r = state['vdc.hvReg.columnCount'], state['vdc.hvReg.rowCount']
    if type(c) == 'number' and type(r) == 'number' then
      return math.floor(c), math.floor(r), false
    end
  end
  return 0, 0, false
end

local function satbAddress()
  if dvssr then return dvssr & 0x7FFF end
  local ok, state = pcall(emu.getState)
  if ok and state then
    local v = state['vdc.satbAddress'] or state['vdc.dvssr']
    if type(v) == 'number' then return math.floor(v) & 0x7FFF end
  end
  return -1
end

local frame, last = 0, nil

emu.addEventCallback(function()
  frame = frame + 1
  local columns, rows, fromMwr = dimensions()
  local batWords = columns * rows
  local batLast = (batWords > 0) and (batWords - 1) or -1
  local satb = satbAddress()
  local overlap = batWords > 0 and GLYPH_FIRST <= batLast
  local verdict = (batWords == 0) and 'unknown'
                  or (overlap and 'OVERLAP' or 'clear')

  local line = string.format('%s|%d|%d|%s|%d', verdict, columns, rows, tostring(satb),
                             portHits > 0 and 1 or 0)
  if line ~= last then
    last = line
    emu.log(string.format(
      'SUB 0.4.90 %df · BAT %dx%d = %d word (0..$%04X)%s · SATB $%04X · ' ..
      '글리프 $%04X-$%04X · %s · portHits=%d',
      frame, columns, rows, batWords, batLast < 0 and 0 or batLast,
      fromMwr and '' or ' (state추정)', satb < 0 and 0 or satb,
      GLYPH_FIRST, GLYPH_LAST,
      verdict == 'OVERLAP' and '★ 글리프가 BAT 본체 안이다' or verdict,
      portHits))
    if out then
      out:write(string.format('%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n',
        frame, portHits, mwrReg and string.format('%02X', mwrReg) or '-',
        columns, rows, batWords, batLast, satb, verdict))
      out:flush()
    end
  end

  emu.drawString(4, 54, string.format('0.4.90 BAT %dx%d=%d  glyph $%04X-$%04X  %s  hits:%d',
                 columns, rows, batWords, GLYPH_FIRST, GLYPH_LAST, verdict, portHits),
                 verdict == 'OVERLAP' and 0x4040FF or 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.90-bat-overlap armed -- 읽기 전용 BAT 크기/겹침 감시')
emu.log(string.format('  글리프 블록 $%04X-$%04X · MWR($09)로 BAT, DVSSR($13)로 SATB',
                      GLYPH_FIRST, GLYPH_LAST))
emu.log('  ★ hits:0 이면 콜백이 안 걸린 것이다.  그때의 clear 는 아무 뜻도 없다')
emu.log('  로그: ' .. OUT)
