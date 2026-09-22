-- SUB 0.4.53 -- $3B40-$3FFF 수명 감시 / 읽기 전용
--
-- 0.4.26 의 후속.  대상 주소가 $1600-$1ABF 에서 $3B40-$3FFF 로 바뀌었다.
--
-- ── 왜 옮겼나 (2026-08-29 정적 재검) ───────────────────────────────────────
--
-- 0.4.25 가 뽑은 최종 공통 후보 56 개를 두 단계로 걸렀다.
--
--   1단  allocator_skip_log.tsv 의 침범 실측 25 범위      -> 34 개 생존
--   2단  같은 로그의 SATB 덤프 1,604 줄에서 뽑은
--        "게임이 실제로 가리킨 고유 패턴 주소" 221 개     -> 1 개 생존
--
-- 1단만으로는 안 된다.  침범 로그는 **그때 우리 블록이 앉아 있던 자리와 겹칠
-- 때만** 기록되므로, "침범 없음" 이 "게임이 안 쓴다" 를 뜻하지 않는다.  실제로
-- 1단을 통과한 $3A40 은 2단에서 게임 슬롯 17 의 상시 주소로 드러나 탈락했다.
--
-- 살아남은 하나가 $3B40-$3FFF 다.  스프라이트 크기를 $40 / $80 / $100 / $200
-- 어느 쪽으로 가정해도 221 개 실측 주소와 충돌이 0 이었다.
--
-- 반대로 옛 후보 $1600-$1ABF 안에서는 이런 것이 나왔다:
--
--     $1A00  95 프레임      $1A40  95 프레임
--     $16A0   $1780   $1860        <- 0x20 정렬
--
-- 우리 글리프 블록은 항상 $40 배수다.  따라서 0x20 정렬인 뒤 셋은 구조적으로
-- 우리 것일 수 없다.  후보 한복판에 게임 스프라이트가 들어와 있었다는 뜻이다.
--
-- ── 0.4.26 대비 바뀐 것 ────────────────────────────────────────────────────
--
--   (1) SATB 스캔을 매 프레임으로.  0.4.26 은 10 프레임마다 봤다.  10 프레임
--       미만으로 스치는 스프라이트는 원리상 못 본다.  SATB 는 64 슬롯뿐이라
--       매 프레임 봐도 싸다.  BAT 는 최대 4096 엔트리라 10 프레임 간격을 둔다.
--
--   (2) 콜백 자체 검증.  0.4.26 은 write 0 / SATB ref 0 으로 PASS 를 냈는데,
--       같은 범위를 allocator 로그는 가리킨다고 적었다.  둘 중 하나가 틀렸다.
--       그래서 이 판은 **반드시 써지는 범위**(SATB 테이블 $1000-$10FF word)에
--       똑같은 write 콜백을 하나 더 걸고, 그쪽이 0 이면 계측기가 죽은 것으로
--       보고 PASS 대신 INCONCLUSIVE 를 찍는다.  0 을 근거로 쓰려면 그 0 이
--       "안 일어났다" 인지 "못 봤다" 인지부터 갈라야 한다.
--
--   (3) SATB 주소 전수 census.  대상과 겹치는 것만 세지 않고, 게임이 가리킨
--       패턴 주소를 **전부** 기록해 두 번째 TSV 로 남긴다.  이번 후보가 떨어져도
--       다음 후보를 고를 자료가 그 한 번의 실행에서 같이 나온다.
--
--   (4) 음성 창(voice window) 표시.  자막은 음성이 나는 동안에만 그 VRAM 을
--       빌렸다가 되돌려준다.  그러니 필요한 조건은 "게임이 영원히 안 쓴다" 가
--       아니라 "**음성 창 안에서** 안 쓴다" 다.  이 판은 rate-$0E ADPCM 재생
--       여부를 매 프레임 보고, 충돌을 창 안/창 밖으로 나눠 센다.
--
--       다만 창 밖이라고 안심할 일은 아니다.  스내처는 음성과 초상화가 같이
--       나오므로 음성 창은 초상화가 **가장 빽빽한** 구간이지 안전한 부분집합이
--       아니다.  그래서 무조건부 감시를 버리지 않고, 표시만 덧붙인다.
--       PASS/FAIL 판정은 여전히 무조건부 기준이고, 창 밖에서만 충돌이 났다면
--       그건 "완화해서 다시 볼 여지가 있다" 는 뜻이지 자동 통과가 아니다.
--
-- 이 스크립트는 CPU/VRAM/AC 에 아무것도 쓰지 않는다.
-- 켜 두고 평소대로 플레이한 뒤 Stop 하면 된다.  자막 팩은 필요 없다.

local VRAM = emu.memType.pceVideoRam
local FIRST_WORD, LAST_WORD = 0x3B40, 0x3FFF
local FIRST_BYTE, LAST_BYTE = FIRST_WORD * 2, LAST_WORD * 2 + 1
local NEED_WORDS = LAST_WORD - FIRST_WORD + 1

-- 계측기 생존 확인용.  게임이 매 프레임 다시 쓰는 SATB 테이블.
local CTRL_FIRST_WORD, CTRL_LAST_WORD = 0x1000, 0x10FF
local CTRL_FIRST_BYTE, CTRL_LAST_BYTE = CTRL_FIRST_WORD * 2, CTRL_LAST_WORD * 2 + 1

local SATB_FIRST = 0x1000
local BAT_SCAN_EVERY = 10
local VOICE_RATE = 0x0E

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_53_vram_lifetime_' .. stamp .. '.tsv'
local CENSUS = 'C:/snatcher/dump/sub_0_4_53_satb_census_' .. stamp .. '.tsv'

local file = assert(io.open(OUT, 'w'))
file:write('frame\tvoice\tevent\tcallback_writes\tunique_words\tfirst_word\tlast_word\t' ..
           'bat_refs\tsatb_refs\tdetail\n')

local frame, closed = 0, false
local callbackWrites, writeFrames, totalUniqueWrites = 0, 0, 0
local ctrlWrites = 0
local everWritten = {}
local pending = {}
local pendingCount, pendingFirst, pendingLast = 0, nil, nil
local satbScans, batScans, batRefFrames, satbRefFrames = 0, 0, 0, 0
local lastBatRefs, lastSatbRefs = 0, 0
local maxBatRefs, maxSatbRefs = 0, 0
local callbackInstalled, ctrlInstalled = false, false

-- census: 게임이 가리킨 패턴 주소 -> {frames, minWords, maxWords, firstFrame}
local census, censusCount = {}, 0

-- 음성 창.  rate-$0E ADPCM 이 도는 동안만 자막이 VRAM 을 빌린다.
local inVoice, voiceFrames, voiceWindows = false, 0, 0
local inWindowWriteFrames, outWindowWriteFrames = 0, 0
local inWindowRefFrames, outWindowRefFrames = 0, 0

local function voiceActive()
  local ok, state = pcall(emu.getState)
  if not ok or not state then return false end
  if state['cdrom.adpcm.playing'] ~= true then return false end
  return (tonumber(state['cdrom.adpcm.playbackRate']) or 0) & 0xFF == VOICE_RATE
end

local function rb(at)
  return emu.read(at, VRAM) or 0
end

local function rw(wordAt)
  local at = wordAt * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function overlaps(first, count)
  local last = first + count - 1
  return first <= LAST_WORD and last >= FIRST_WORD
end

-- pceVideoRam addresses are bytes.  Coalesce every callback in one frame so a
-- DMA-sized upload cannot flood the console or TSV with thousands of lines.
local function onWrite(address)
  local word = math.floor(address / 2)
  if word < FIRST_WORD or word > LAST_WORD then return end
  callbackWrites = callbackWrites + 1
  if not pending[word] then
    pending[word] = true
    pendingCount = pendingCount + 1
    pendingFirst = pendingFirst and math.min(pendingFirst, word) or word
    pendingLast = pendingLast and math.max(pendingLast, word) or word
  end
  if not everWritten[word] then
    everWritten[word] = true
    totalUniqueWrites = totalUniqueWrites + 1
  end
end

local function onCtrlWrite()
  ctrlWrites = ctrlWrites + 1
end

callbackInstalled = pcall(function()
  emu.addMemoryCallback(onWrite, emu.callbackType.write,
                        FIRST_BYTE, LAST_BYTE, nil, VRAM)
end)

ctrlInstalled = pcall(function()
  emu.addMemoryCallback(onCtrlWrite, emu.callbackType.write,
                        CTRL_FIRST_BYTE, CTRL_LAST_BYTE, nil, VRAM)
end)

local function saneDimension(value, fallback)
  value = tonumber(value)
  if value == 32 or value == 64 or value == 128 then return value end
  return fallback
end

local function dimensions()
  local ok, state = pcall(emu.getState)
  if not ok or not state then return 64, 64 end
  return saneDimension(state['vdc.hvReg.columnCount'], 64),
         saneDimension(state['vdc.hvReg.rowCount'], 64)
end

-- SATB 는 64 슬롯뿐이라 매 프레임 본다.  겹치는 것만 세지 않고 전부 census 에
-- 담는다.  0.4.26 은 겹치는 것만 봐서, 후보가 떨어졌을 때 다음 후보를 고를
-- 자료가 남지 않았다.
local function scanSatb()
  local refs, details = 0, {}
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local y = rb(at) | (rb(at + 1) << 8)
    local x = rb(at + 2) | (rb(at + 3) << 8)
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local widthCells = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local heightCells = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local base = (pattern & 0x07FF) << 5
      local words = widthCells * heightCells * 0x40

      local rec = census[base]
      if not rec then
        rec = { frames = 0, minWords = words, maxWords = words,
                firstFrame = frame, palette = attr & 0x0F, y = y, x = x }
        census[base] = rec
        censusCount = censusCount + 1
      end
      rec.frames = rec.frames + 1
      if words < rec.minWords then rec.minWords = words end
      if words > rec.maxWords then rec.maxWords = words end

      if overlaps(base, words) then
        refs = refs + 1
        if #details < 12 then
          details[#details + 1] = string.format(
            'SATB[%02d]->%04X-%04X pal=%X y=%d x=%d',
            slot, base, base + words - 1, attr & 0x0F, y, x)
        end
      end
    end
  end
  return refs, table.concat(details, ',')
end

local function scanBat()
  local refs, details = 0, {}
  local columns, rows = dimensions()
  local batEntries = math.min(columns * rows, SATB_FIRST)
  for i = 0, batEntries - 1 do
    local pattern = rw(i) & 0x07FF
    local base = pattern * 0x10
    if overlaps(base, 0x10) then
      refs = refs + 1
      if #details < 12 then
        details[#details + 1] = string.format('BAT[%04X]->%04X', i, base)
      end
    end
  end
  return refs, table.concat(details, ',')
end

local function logRow(event, writes, unique, first, last, bat, satb, detail)
  file:write(string.format('%d\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t%d\t%s\n',
    frame, inVoice and 1 or 0, event, writes or 0, unique or 0,
    first and string.format('%04X', first) or '',
    last and string.format('%04X', last) or '',
    bat or 0, satb or 0, detail or ''))
  file:flush()
end

emu.addEventCallback(function()
  frame = frame + 1

  local nowVoice = voiceActive()
  if nowVoice and not inVoice then voiceWindows = voiceWindows + 1 end
  inVoice = nowVoice
  if inVoice then voiceFrames = voiceFrames + 1 end

  if pendingCount > 0 then
    writeFrames = writeFrames + 1
    if inVoice then inWindowWriteFrames = inWindowWriteFrames + 1
    else outWindowWriteFrames = outWindowWriteFrames + 1 end
    logRow('WRITE', callbackWrites, pendingCount, pendingFirst, pendingLast,
           lastBatRefs, lastSatbRefs, '')
    emu.log(string.format(
      'SUB 0.4.53 ★ TARGET WRITE f=%d unique=%d span=$%04X-$%04X total_callbacks=%d',
      frame, pendingCount, pendingFirst, pendingLast, callbackWrites))
    pending, pendingCount, pendingFirst, pendingLast = {}, 0, nil, nil
  end

  satbScans = satbScans + 1
  local satb, satbDetail = scanSatb()

  local bat, batDetail = lastBatRefs, ''
  if frame == 1 or frame % BAT_SCAN_EVERY == 0 then
    batScans = batScans + 1
    bat, batDetail = scanBat()
  end

  if bat > 0 then batRefFrames = batRefFrames + 1 end
  if satb > 0 then satbRefFrames = satbRefFrames + 1 end
  if bat > 0 or satb > 0 then
    if inVoice then inWindowRefFrames = inWindowRefFrames + 1
    else outWindowRefFrames = outWindowRefFrames + 1 end
  end
  maxBatRefs, maxSatbRefs = math.max(maxBatRefs, bat), math.max(maxSatbRefs, satb)

  if bat ~= lastBatRefs or satb ~= lastSatbRefs then
    local event = (bat > 0 or satb > 0) and 'REF_CHANGE_COLLISION' or 'REF_CLEAR'
    local detail = satbDetail
    if batDetail ~= '' then
      detail = (detail ~= '' and (detail .. ',') or '') .. batDetail
    end
    logRow(event, 0, 0, nil, nil, bat, satb, detail)
    if bat > 0 or satb > 0 then
      emu.log(string.format(
        'SUB 0.4.53 ★ TARGET REFERENCED f=%d BAT=%d SATB=%d %s',
        frame, bat, satb, detail))
    else
      emu.log(string.format('SUB 0.4.53 target references cleared f=%d', frame))
    end
  end
  lastBatRefs, lastSatbRefs = bat, satb

  -- 계측기가 살아 있는지.  ctrl 이 0 이면 아래 W/B/S 의 0 은 증거가 아니다.
  local alive = ctrlWrites > 0
  local bad = callbackWrites > 0 or maxBatRefs > 0 or maxSatbRefs > 0
  local colour = bad and 0xFF4040 or (alive and 0x40FF40 or 0xFFA000)
  emu.drawString(4, 4, string.format('0.4.53 $3B40 WATCH  W:%d B:%d S:%d',
                 callbackWrites, maxBatRefs, maxSatbRefs), colour, 0x000000)
  emu.drawString(4, 14, string.format('ctrl:%d %s  census:%d',
                 ctrlWrites, alive and 'LIVE' or '★DEAD', censusCount),
                 alive and 0xC0C0C0 or 0xFFA000, 0x000000)
  emu.drawString(4, 24, string.format('voice %s  창 %d  충돌 in:%d out:%d',
                 inVoice and 'ON ' or 'off', voiceWindows,
                 inWindowWriteFrames + inWindowRefFrames,
                 outWindowWriteFrames + outWindowRefFrames),
                 inVoice and 0x60D0FF or 0x808080, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true

  local alive = ctrlInstalled and ctrlWrites > 0
  local quiet = callbackWrites == 0 and maxBatRefs == 0 and maxSatbRefs == 0
  local verdict
  if not callbackInstalled or not alive then
    -- 조용했더라도 계측기가 죽었으면 PASS 라고 부르지 않는다.
    verdict = 'SUMMARY_INCONCLUSIVE'
  elseif quiet then
    verdict = 'SUMMARY_PASS'
  else
    verdict = 'SUMMARY_FAIL'
  end

  logRow(verdict, callbackWrites, totalUniqueWrites, FIRST_WORD, LAST_WORD,
         maxBatRefs, maxSatbRefs,
         string.format('frames=%d;write_frames=%d;satb_scans=%d;bat_scans=%d;' ..
                       'bat_ref_frames=%d;satb_ref_frames=%d;' ..
                       'callback_installed=%d;ctrl_installed=%d;ctrl_writes=%d;' ..
                       'census=%d;voice_frames=%d;voice_windows=%d;' ..
                       'in_window_writes=%d;out_window_writes=%d;' ..
                       'in_window_refs=%d;out_window_refs=%d',
                       frame, writeFrames, satbScans, batScans,
                       batRefFrames, satbRefFrames,
                       callbackInstalled and 1 or 0, ctrlInstalled and 1 or 0,
                       ctrlWrites, censusCount, voiceFrames, voiceWindows,
                       inWindowWriteFrames, outWindowWriteFrames,
                       inWindowRefFrames, outWindowRefFrames))
  file:close()

  -- census 를 별도 TSV 로.  이번 후보가 떨어져도 다음 후보를 이걸로 고른다.
  local ok, cf = pcall(io.open, CENSUS, 'w')
  if ok and cf then
    cf:write('base\tlast_min\tlast_max\tframes\tfirst_frame\tpalette\thits_target\n')
    local keys = {}
    for base in pairs(census) do keys[#keys + 1] = base end
    table.sort(keys)
    for _, base in ipairs(keys) do
      local r = census[base]
      cf:write(string.format('%04X\t%04X\t%04X\t%d\t%d\t%X\t%d\n',
        base, base + r.minWords - 1, base + r.maxWords - 1,
        r.frames, r.firstFrame, r.palette,
        overlaps(base, r.maxWords) and 1 or 0))
    end
    cf:close()
  end

  emu.log(string.format(
    'SUB 0.4.53 ★ %s: frames=%d writes=%d unique_words=%d maxBAT=%d maxSATB=%d ctrl=%d',
    verdict, frame, callbackWrites, totalUniqueWrites,
    maxBatRefs, maxSatbRefs, ctrlWrites))
  if verdict == 'SUMMARY_INCONCLUSIVE' then
    emu.log('  ★ 계측기가 죽었다.  W/B/S 의 0 은 "안 일어났다" 가 아니라 "못 봤다" 다.')
  end
  emu.log(string.format('  음성 창 %d 개 · %d 프레임 · 충돌 창안 %d / 창밖 %d',
    voiceWindows, voiceFrames,
    inWindowWriteFrames + inWindowRefFrames,
    outWindowWriteFrames + outWindowRefFrames))
  if voiceWindows == 0 then
    emu.log('  ★ 음성 창이 0 이다.  창안/창밖 구분은 이 실행에서 의미가 없다.')
  elseif verdict == 'SUMMARY_FAIL' and
         inWindowWriteFrames + inWindowRefFrames == 0 then
    emu.log('  충돌이 전부 음성 창 밖이었다.  자동 통과는 아니지만 완화 검토 여지가 있다.')
  end
  emu.log('SUB 0.4.53 saved: ' .. OUT)
  emu.log('SUB 0.4.53 census: ' .. CENSUS)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.53 loaded -- $3B40-$3FFF lifetime write/reference audit')
emu.log(string.format('  target: $%04X-$%04X (%d words / 19 cells)',
                      FIRST_WORD, LAST_WORD, NEED_WORDS))
emu.log(string.format('  control: $%04X-$%04X (SATB table, must be written every frame)',
                      CTRL_FIRST_WORD, CTRL_LAST_WORD))
emu.log('  read-only · 자막 팩 불필요 · 켜 두고 평소대로 플레이한 뒤 Stop')
emu.log('  callback installed: ' .. tostring(callbackInstalled) ..
        ' · control installed: ' .. tostring(ctrlInstalled))
emu.log('  output: ' .. OUT)
emu.log('  census: ' .. CENSUS)
