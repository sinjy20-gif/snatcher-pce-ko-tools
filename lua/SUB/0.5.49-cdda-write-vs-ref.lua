-- CD-DA 자리 판별 0.5.49 -- **쓰기**와 **참조**를 갈라서 잰다
--
-- ===========================================================================
-- 왜
-- ===========================================================================
--
-- 2026-09-10 밤, 관찰이 가리키는 자리로 트랙 5·6 을 세 번 옮겼는데 세 번 다 더
-- 깨졌다.  점수가 **반대**였다:
--
--     트랙 5 · 창 50 기준     실기
--         $7300    0/50       제일 멀쩡
--         $3B00    0/50       깁슨 문서 깨짐
--         $6300   50/50       제일 많이 깨짐   ← 만점인데
--
-- 뿌리는 `0.5.47` 의 `buildOccupancy()` 다.  거기서 **사실과 추정을 union** 한다:
--
--     wordMark   VDC 에 실제로 쓰인 워드      <- 사실
--     tileMark   BAT 가 참조하는 타일         <- 16 word 씩 통째로 부풀린다
--     unitMark   스프라이트 패턴 32 word 씩
--     batWords   BAT 본체 · satbSeen  SATB 256 word
--
-- 합친 값 하나만 내보내니 어느 쪽이 틀렸는지 알 길이 없었다.  트랙 3 은 그 값이
-- 22/22 창 막힘이라 하는데 실기는 멀쩡하다 -- 과다계상의 증거다.  반대로 쓰기만
-- 보면 음성 시작 **전에** 올라간 타일을 놓친다 (깁슨 문서가 그렇다: 페이지 넘길
-- 때 $3000 부터 올리고 그 뒤엔 안 쓴다).
--
--     쓰기만    미리 올라간 타일을 놓친다   (과소)
--     참조까지  스쳐간 것까지 센다          (과다)
--
-- 그래서 **두 값을 나란히** 뽑는다.  둘 중 하나가 실기와 맞으면 그걸 쓰고,
-- 둘 다 안 맞으면 지표를 다시 설계해야 한다는 뜻이다.
--
-- ===========================================================================
-- 대조군이 이미 있다 -- 이게 이 프로브의 핵심
-- ===========================================================================
--
--     트랙 3   $4B00 을 쓰는데 실기 **정상**    -> 지표는 "자유" 라고 해야 맞다
--     트랙 5   $7300 을 쓰는데 실기 **깨짐**    -> 지표는 "점유" 라고 해야 맞다
--     트랙 6   $3B00 을 쓰는데 실기 **깨짐**    -> 지표는 "점유" 라고 해야 맞다
--
-- 정답이 있는 문제가 셋이다.  둘 중 이걸 다 맞히는 지표가 쓸 물건이다.
-- 끝날 때 이 표를 그대로 찍는다.  **그것만 보면 된다.**
--
-- ===========================================================================
-- 쓰는 법
-- ===========================================================================
--
--   1  디스크 `build/patch/0.7.2` (BIOS·CUE 둘 다).  ★ 자리를 안 건드린 판이어야
--      위 대조군의 "실기 결과" 가 그대로 성립한다.
--   2  이 파일 하나만 올린다.  자막 엔진·다른 수집기와 같이 올리지 말 것.
--   3  트랙 3 · 5 · 6 을 지난다.  트랙 5 는 **두 장면 다** --
--        11.74s 메탈 초상화 영상   ·   61~75s 깁슨 문서
--   4  화면에는 아무것도 안 그린다.  진도는 로그로 나온다.
--   5  끝내면 판정표가 로그와 파일에 찍힌다.
--
-- 출력
--     dump/cdda_wr_<시각>.tsv        조각마다 두 지표
--     dump/cdda_wr_<시각>.verdict.txt 판정표
-- ---------------------------------------------------------------------------

local SEGMENTS = 'C:/snatcher/build/cutscene_subs/cdda_segments.tsv'
local WATCH_TRACKS = { [3] = true, [5] = true, [6] = true }

-- 실기 결과가 있는 자리들.  '지금 그 트랙이 쓰는 값' 을 같이 적어 둔다.
local WATCH_BASES = { 0x4B00, 0x7300, 0x3B00, 0x3600, 0x6300 }
local SHIPPED = { [3] = 0x4B00, [5] = 0x7300, [6] = 0x3B00 }
local TRUTH   = { [3] = '정상',  [5] = '깨짐',  [6] = '깨짐'  }

local VRAM_WORDS = 0x8000
local NEED_WORDS = 19 * 0x40        -- 0x4C0 -- 글리프 창
local ALIGN      = 0x20
local VDC_LO, VDC_HI = 0x0000, 0x03FF
local CDDA_STOP_GRACE = 12
local BAT_SLICE = 4

local VRAM = emu.memType.pceVideoRam
local MEM  = emu.memType.pceMemory
local CPU  = emu.cpuType.pce

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT     = 'C:/snatcher/dump/cdda_wr_' .. stamp .. '.tsv'
local VERDICT = 'C:/snatcher/dump/cdda_wr_' .. stamp .. '.verdict.txt'

-- ---------------------------------------------------------------------------
-- 구간표
-- ---------------------------------------------------------------------------
local function split(line)
  local c, n = {}, 0
  for f in (line .. '\t'):gmatch('([^\t]*)\t') do n = n + 1; c[n] = f end
  return c
end

local segs, segN = {}, 0
do
  local fh = io.open(SEGMENTS, 'r')
  if fh == nil then
    emu.log('★ 구간표를 못 연다: ' .. SEGMENTS)
  else
    local head, col = split(fh:read('*l') or ''), {}
    for i = 1, #head do col[head[i]] = i end
    for line in fh:lines() do
      local c = split(line)
      local t = tonumber(c[col.track] or '')
      if t and WATCH_TRACKS[t] then
        segN = segN + 1
        segs[segN] = { track = t, clip = c[col.clip] or '',
                       a = tonumber(c[col.lba_from] or '') or 0,
                       b = tonumber(c[col.lba_to] or '') or 0,
                       sec = tonumber(c[col.start_sec] or '') or 0 }
      end
    end
    fh:close()
  end
end
table.sort(segs, function(p, q) return p.a < q.a end)

local function segAt(sector)
  local lo, hi = 1, segN
  while lo <= hi do
    local mid = (lo + hi) // 2
    local s = segs[mid]
    if sector < s.a then hi = mid - 1
    elseif sector >= s.b then lo = mid + 1
    else return s end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- VRAM 쓰기 추적 (0.5.47 과 같은 배관 -- 사실만 담는다)
-- ---------------------------------------------------------------------------
local wordMark, tileMark, unitMark, satbSeen = {}, {}, {}, {}
local batWords = 0
local mawr, selReg, dataLo, mwrReg, desr, lenr, dvssr = 0, 0, 0, nil, 0, 0, nil
local cur, curFrames = nil, 0
local frame = 0

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(w) local at = w * 2; return rb(at) | (rb(at + 1) << 8) end

local function noteWord(w) if cur then wordMark[w] = true end end

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    dataLo = value
    if selReg == 0x00 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x09 then mwrReg = value
    elseif selReg == 0x11 then desr = (desr & 0xFF00) | value
    elseif selReg == 0x12 then lenr = (lenr & 0xFF00) | value
    elseif selReg == 0x13 then dvssr = ((dvssr or 0) & 0xFF00) | value
    end
  elseif port == 3 then
    if selReg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 0x02 then
      noteWord(mawr & 0x7FFF)
      mawr = (mawr + 1) & 0xFFFF
    elseif selReg == 0x11 then
      desr = (desr & 0x00FF) | (value << 8)
    elseif selReg == 0x12 then
      lenr = (lenr & 0x00FF) | (value << 8)
      local dst = desr & 0x7FFF
      for i = 0, lenr do noteWord((dst + i) & 0x7FFF) end
    elseif selReg == 0x13 then
      dvssr = ((dvssr or 0) & 0x00FF) | (value << 8)
    end
  end
end

local installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write,
                        VDC_LO, VDC_HI, CPU, MEM)
end)

-- ---------------------------------------------------------------------------
-- 참조 추적 (BAT · 스프라이트) -- 추정 쪽
-- ---------------------------------------------------------------------------
local function dimensions()
  if mwrReg then
    local w = (mwrReg >> 4) & 0x03
    return (w == 0) and 32 or (w == 1) and 64 or 128,
           (((mwrReg >> 6) & 1) == 1) and 64 or 32
  end
  return 64, 64
end

local function satbAddress()
  if dvssr then return dvssr & 0x7FFF end
  return 0x1000
end

local function scanBat(full)
  if not cur then return end
  local columns, rows = dimensions()
  local entries = math.min(columns * rows, VRAM_WORDS)
  if entries > batWords then batWords = entries end
  local from, to
  if full then
    from, to = 0, entries - 1
  else
    local step = (entries + BAT_SLICE - 1) // BAT_SLICE
    from = (frame % BAT_SLICE) * step
    to = math.min(from + step, entries) - 1
  end
  for i = from, to do tileMark[rw(i) & 0x07FF] = true end
end

local function scanSatb()
  if not cur then return end
  local satb = satbAddress()
  satbSeen[satb] = true
  for slot = 0, 63 do
    local at = satb + slot * 4
    local y, x = rw(at), rw(at + 1)
    local pattern, attr = rw(at + 2), rw(at + 3)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local wide = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local tall = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local base = (pattern & 0x07FF) << 5
      for i = 0, wide * tall * 2 - 1 do
        unitMark[((base >> 5) + i) & 0x3FF] = true
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- 자유 base 계산 -- 같은 코드를 두 점유집합에 각각 돌린다
-- ---------------------------------------------------------------------------
local function freeBases(used)
  local free, n = {}, 0
  local runStart = nil
  for w = 0, VRAM_WORDS do
    local isFree = (w < VRAM_WORDS) and (used[w] == nil) or false
    if isFree then
      if runStart == nil then runStart = w end
    elseif runStart ~= nil then
      local b = ((runStart + ALIGN - 1) // ALIGN) * ALIGN
      while b + NEED_WORDS - 1 <= w - 1 do
        free[b] = true; n = n + 1; b = b + ALIGN
      end
      runStart = nil
    end
  end
  return free, n
end

-- 구조적 점유(BAT 본체·SATB)는 **두 지표 모두에** 넣는다.  그건 추정이 아니다.
local function structural(used)
  for i = 0, batWords - 1 do used[i] = true end
  for satb in pairs(satbSeen) do
    for k = 0, 255 do
      local w = satb + k
      if w < VRAM_WORDS then used[w] = true end
    end
  end
end

local out = assert(io.open(OUT, 'w'))
out:write('track\tclip\tlba_from\tlba_to\tframes\tw_used\tr_used\tw_nfree\tr_nfree')
for _, b in ipairs(WATCH_BASES) do out:write(string.format('\tb%04X', b)) end
out:write('\n')

-- 트랙별 집계: base -> {쓰기기준 자유 조각수, 참조기준 자유 조각수, 전체}
local tally = {}
local function bump(t, b, w, r)
  tally[t] = tally[t] or {}
  tally[t][b] = tally[t][b] or { 0, 0 }
  if w then tally[t][b][1] = tally[t][b][1] + 1 end
  if r then tally[t][b][2] = tally[t][b][2] + 1 end
end
local segCount = {}

local function finish()
  if cur == nil then return end

  -- 쓰기 기준
  local wUsed = {}
  for w in pairs(wordMark) do wUsed[w] = true end
  structural(wUsed)
  local wFree, wN = freeBases(wUsed)
  local wCount = 0; for _ in pairs(wUsed) do wCount = wCount + 1 end

  -- 참조 기준 = 쓰기 + 타일/스프라이트 참조
  local rUsed = {}
  for w in pairs(wUsed) do rUsed[w] = true end
  for t in pairs(tileMark) do
    local base = t * 0x10
    for k = 0, 15 do if base + k < VRAM_WORDS then rUsed[base + k] = true end end
  end
  for u in pairs(unitMark) do
    local base = u * 0x20
    for k = 0, 31 do if base + k < VRAM_WORDS then rUsed[base + k] = true end end
  end
  local rFree, rN = freeBases(rUsed)
  local rCount = 0; for _ in pairs(rUsed) do rCount = rCount + 1 end

  out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d',
    cur.track, cur.clip, cur.a, cur.b, curFrames, wCount, rCount, wN, rN))
  for _, b in ipairs(WATCH_BASES) do
    local w, r = wFree[b] == true, rFree[b] == true
    out:write('\t' .. (r and 'WR' or (w and 'W' or '-')))
    bump(cur.track, b, w, r)
  end
  out:write('\n')
  out:flush()

  segCount[cur.track] = (segCount[cur.track] or 0) + 1

  cur, curFrames = nil, 0
  wordMark, tileMark, unitMark, satbSeen = {}, {}, {}, {}
  batWords = 0
end

-- ---------------------------------------------------------------------------
-- 프레임 루프
-- ---------------------------------------------------------------------------
local prevSector, lastAdvance = nil, nil
local lastLog = 0

emu.addEventCallback(function()
  frame = frame + 1

  local state = emu.getState()
  local sector = state and state['cdrom.audioPlayer.currentSector']
  local seg = nil
  if type(sector) == 'number' then
    sector = math.floor(sector)
    if prevSector ~= nil then
      if sector ~= prevSector then lastAdvance = frame end
      if lastAdvance and frame - lastAdvance < CDDA_STOP_GRACE then
        seg = segAt(sector)
      end
    end
    prevSector = sector
  end

  if seg ~= cur then
    finish()
    cur, curFrames = seg, 0
    if cur then scanBat(true); scanSatb() end     -- 첫 프레임은 전수
  end

  if cur then
    curFrames = curFrames + 1
    scanBat(false)
    scanSatb()
    if frame - lastLog >= 300 then
      lastLog = frame
      emu.log(string.format('  ... 트랙 %d  %.2fs  조각 %d 개째',
                            cur.track, cur.sec, (segCount[cur.track] or 0) + 1))
    end
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------------------
-- 끝 -- 판정표
-- ---------------------------------------------------------------------------
local closed = false
emu.addEventCallback(function()
  if closed then return end
  closed = true
  finish()
  out:close()

  local lines = {}
  local function say(s) lines[#lines + 1] = s; emu.log(s) end

  say('')
  say('=========== 판별표 -- 정답이 있는 문제 셋 ===========')
  say('')
  say('  트랙   실기    쓰는 자리     쓰기기준        참조기준')
  local wScore, rScore, asked = 0, 0, 0
  for _, t in ipairs({ 3, 5, 6 }) do
    local b = SHIPPED[t]
    local n = segCount[t] or 0
    local e = (tally[t] or {})[b]
    if n == 0 or e == nil then
      say(string.format('  %4d   %s    $%04X        (안 지남)', t, TRUTH[t], b))
    else
      asked = asked + 1
      -- 실기 '정상' 이면 지표도 자유라고 해야 맞다.  '깨짐' 이면 점유라고 해야 맞다.
      local wFreeAll = (e[1] == n)
      local rFreeAll = (e[2] == n)
      local wOk = (TRUTH[t] == '정상') == wFreeAll
      local rOk = (TRUTH[t] == '정상') == rFreeAll
      if wOk then wScore = wScore + 1 end
      if rOk then rScore = rScore + 1 end
      say(string.format('  %4d   %s    $%04X      %2d/%2d 자유 %s    %2d/%2d 자유 %s',
        t, TRUTH[t], b, e[1], n, wOk and 'O' or 'X', e[2], n, rOk and 'O' or 'X'))
    end
  end
  say('')
  if asked == 0 then
    say('  ★ 트랙 3·5·6 을 하나도 안 지났다.  다시 주행할 것')
  else
    say(string.format('  맞힌 개수    쓰기기준 %d/%d    참조기준 %d/%d',
                      wScore, asked, rScore, asked))
    if wScore > rScore then
      say('  -> **쓰기 기준**이 실기와 더 맞는다.  buildOccupancy 에서 참조 union 을 뺄 것')
    elseif rScore > wScore then
      say('  -> **참조 기준**이 더 맞는다.  지금 지표가 맞고 다른 데서 틀린 것이다')
    else
      say('  -> 둘 다 같다.  이 두 지표로는 못 가른다 -- 지표를 다시 설계할 것')
    end
  end
  say('')
  say('  조각마다의 값: ' .. OUT)

  local fh = io.open(VERDICT, 'w')
  if fh then fh:write(table.concat(lines, '\n') .. '\n'); fh:close() end
end, emu.eventType.scriptEnded)

emu.log('')
emu.log('CDDA 자리 판별 0.5.49 -- 쓰기 vs 참조')
emu.log(string.format('  구간 %d 개 (트랙 3·5·6) · 창 %d word · 정렬 %d',
                      segN, NEED_WORDS, ALIGN))
emu.log('  installed: ' .. tostring(installed))
emu.log('  ★ 디스크는 0.7.2 -- 자리를 안 건드린 판이어야 대조군이 성립한다')
emu.log('  ★ 트랙 5 는 두 장면 다: 11.74s 초상화 영상 · 61~75s 깁슨 문서')
emu.log('  -> ' .. OUT)
