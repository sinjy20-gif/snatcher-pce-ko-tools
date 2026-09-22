-- CD-DA 관찰 커버리지 0.5.48 -- 트랙 5·6 을 **다 지났는지** 알려준다
--
-- ===========================================================================
-- 왜 이걸 만들었나 (2026-09-10 밤)
-- ===========================================================================
--
-- 오늘 트랙 5 의 자리를 $7300 -> $3B00 으로 옮겨 메탈 초상화 깨짐을 고쳤는데,
-- 같은 트랙의 **깁슨 문서 화면**(75.23s)이 대신 깨졌다.
--
--   깁슨 문서 타일은 $3000 에서 올라가고 250~307 장(≈4,900 word)이라
--   $434F 까지 뻗는다.  $3B00 은 그 한복판이다.
--
-- 관찰은 그 자리를 "자유"라고 했었다.  프로브가 틀린 게 아니라 **그 장면을 한
-- 번도 안 지나가서** 점유가 기록되지 않았을 뿐이다.  자유자리는 관찰들의
-- 교집합이라, 안 본 장면은 제약을 걸지 못한다 -- 그래서 조용히 틀린 답이 된다.
--
-- 즉 이 문제의 정체는 **관찰 부족**이고, 부족한지 아닌지를 주행 중에 알 길이
-- 없었던 것이 진짜 구멍이다.  이 판은 그 구멍만 막는다.
--
-- ===========================================================================
-- 무엇을 하나
-- ===========================================================================
--
-- 본체(0.5.47)를 그대로 돌린다.  출력 형식도 경로 규칙도 안 건드린다 --
-- `dump/cdda_vram_spans_<시각>.tsv` 는 빌더가 자동으로 먹는다.
--
-- 그 위에 얹는 것은 하나뿐이다: **트랙 5·6 의 조각을 몇 개나 지났는지 센다.**
--
--   * 진도가 바뀔 때마다 로그에 한 줄.  화면에는 아무것도 안 그린다
--     (오버레이는 판정을 가린다 -- HUD 도 끈다).
--   * 끝날 때 아직 안 지난 조각을 **시각과 함께** 남긴다.  그 표를 보고
--     그 장면만 다시 지나면 된다.
--
-- ===========================================================================
-- 쓰는 법
-- ===========================================================================
--
--   1  디스크는 `build/patch/0.7.3` (BIOS·CUE 둘 다).
--   2  이 파일 하나만 올린다.  자막 엔진 스크립트와 같이 올리지 말 것.
--   3  트랙 5 는 **두 장면**을 다 지나야 한다:
--        11.74s  메탈 초상화 영상 재생
--        75.23s  깁슨 문서 (꽃가루 장)
--      트랙 6 은 처음부터 끝까지.
--   4  로그에 `트랙 5  51/51` `트랙 6  59/59` 가 뜨면 다 채운 것이다.
--   5  Mesen 을 닫거나 스크립트를 내리면 커버리지 표가 저장된다.
--
-- ⚠ STRICT BAT 은 켠 채로 둔다.  창고(`cdda_vram_observations.tsv`)에 이미
--   STRICT 로 잰 관찰이 쌓여 있어서, 섞으면 기준이 두 가지가 된다.
--   (STRICT 는 점유를 과하게 센다 -- 트랙 3 이 실기 정상인데 22/22 막힘으로
--    나오는 것이 그 탓이다.  그래도 일관성이 먼저다.)
-- ---------------------------------------------------------------------------

local BODY     = 'C:/snatcher/lua/SUB/0.5.47-vram-key-map-0.4.lua'
local SEGMENTS = 'C:/snatcher/build/cutscene_subs/cdda_segments.tsv'
local WATCH    = { [5] = true, [6] = true }   -- 채우려는 트랙
local REPORT_EVERY = 120                      -- 프레임

local stamp = os.date('%Y%m%d_%H%M%S')
local COVER = 'C:/snatcher/dump/cdda_coverage_5_6_' .. stamp .. '.tsv'

-- ---------------------------------------------------------------------------
-- 본체를 올린다.  설정은 **dofile 앞에서** 넣어야 한다 (본체가 로드 시점에
-- rawget 으로 읽는다).
-- ---------------------------------------------------------------------------
SUB_VRAM_MAP_STRICT_BAT = true
SUB_VRAM_MAP_HIDE_HUD   = true

-- 화면에 그리는 함수를 통째로 무력화한다.  HIDE_HUD 로도 되지만, 본체가
-- 손대는 자리가 늘면 또 새니 여기서 막는다.  판정을 가리면 주행이 헛돈다.
local realDrawString = emu.drawString
emu.drawString = function() end

dofile(BODY)

-- ---------------------------------------------------------------------------
-- 구간표를 읽는다 (본체와 같은 파일이지만 본체는 이걸 안 내준다)
-- ---------------------------------------------------------------------------
local function split(line)
  local cols, n = {}, 0
  for field in (line .. '\t'):gmatch('([^\t]*)\t') do
    n = n + 1
    cols[n] = field
  end
  return cols
end

local segs, segN = {}, 0
do
  local fh = io.open(SEGMENTS, 'r')
  if fh == nil then
    emu.log('★ 구간표를 못 연다: ' .. SEGMENTS)
  else
    local header = split(fh:read('*l') or '')
    local col = {}
    for i = 1, #header do col[header[i]] = i end
    for line in fh:lines() do
      local c = split(line)
      local track = tonumber(c[col.track] or '')
      if track and WATCH[track] then
        segN = segN + 1
        segs[segN] = {
          track = track,
          clip  = c[col.clip] or '',
          a     = tonumber(c[col.lba_from] or '') or 0,
          b     = tonumber(c[col.lba_to] or '') or 0,
          sec   = tonumber(c[col.start_sec] or '') or 0,
          jp    = c[col.jp_whisper] or '',
          seen  = false,
        }
      end
    end
    fh:close()
  end
end

-- 트랙별 전체 수
local total = {}
for i = 1, segN do
  total[segs[i].track] = (total[segs[i].track] or 0) + 1
end

local seenCount = {}
for t in pairs(total) do seenCount[t] = 0 end

local function progressLine()
  local parts, n = {}, 0
  for t = 1, 32 do
    if total[t] then
      n = n + 1
      parts[n] = string.format('트랙 %d  %d/%d', t, seenCount[t], total[t])
    end
  end
  return table.concat(parts, '   ·   ')
end

emu.log('')
emu.log('CDDA 커버리지 0.5.48  --  트랙 5·6 을 다 지났는지 센다')
emu.log('  ' .. progressLine())
emu.log('  놓친 조각 표: ' .. COVER)
emu.log('  ★ 트랙 5 는 두 장면 -- 11.74s 초상화 영상 · 75.23s 깁슨 문서')

-- ---------------------------------------------------------------------------
-- 매 프레임 재생 sector 를 보고 지나간 조각을 표시한다
-- ---------------------------------------------------------------------------
local coverFrame, lastReport, dirty = 0, -1, false

emu.addEventCallback(function()
  coverFrame = coverFrame + 1

  local state = emu.getState()
  local sector = state and state['cdrom.audioPlayer.currentSector']
  if type(sector) == 'number' then
    sector = math.floor(sector)
    for i = 1, segN do
      local s = segs[i]
      if not s.seen and sector >= s.a and sector < s.b then
        s.seen = true
        seenCount[s.track] = seenCount[s.track] + 1
        dirty = true
      end
    end
  end

  if dirty and coverFrame - lastReport >= REPORT_EVERY then
    lastReport = coverFrame
    dirty = false
    emu.log('커버리지  ' .. progressLine())
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------------------
-- 끝날 때 -- 아직 안 지난 조각을 시각과 함께 남긴다
-- ---------------------------------------------------------------------------
local coverClosed = false
emu.addEventCallback(function()
  if coverClosed then return end
  coverClosed = true

  local fh = io.open(COVER, 'w')
  if fh then
    fh:write('track\tstart_sec\tlba_from\tlba_to\tseen\tclip\tjp\n')
    for i = 1, segN do
      local s = segs[i]
      fh:write(string.format('%d\t%.2f\t%d\t%d\t%s\t%s\t%s\n',
        s.track, s.sec, s.a, s.b, s.seen and 'yes' or 'NO', s.clip, s.jp))
    end
    fh:close()
  end

  emu.log('')
  emu.log('CDDA 커버리지 최종  ' .. progressLine())
  local missing = 0
  for i = 1, segN do
    if not segs[i].seen then
      missing = missing + 1
      if missing <= 20 then
        emu.log(string.format('  안 지남  트랙 %d  %6.2fs  %s',
                              segs[i].track, segs[i].sec, segs[i].jp:sub(1, 34)))
      end
    end
  end
  if missing == 0 then
    emu.log('  ★ 트랙 5·6 을 전부 지났다.  이 주행으로 자리를 다시 고를 수 있다')
  else
    emu.log(string.format('  남은 조각 %d 개 -- 표: %s', missing, COVER))
  end

  emu.drawString = realDrawString
end, emu.eventType.scriptEnded)
