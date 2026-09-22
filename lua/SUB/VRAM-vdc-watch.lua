-- SUB 0.4.55 -- VDC 포트를 훅해 VRAM 쓰기를 재구성한다 / 읽기 전용
--
-- ── 왜 다시 짜는가 (0.4.54-cbprobe 실측, 2026-08-29) ───────────────────────
--
--     V1  VRAM cpuType=nil        0           <- 0.4.26 / 0.4.53 이 쓴 형태
--     V2  VRAM cpuType=pce        0
--     V3  VRAM 4-arg             11,528,616
--     V4  zeropage                1,398,605
--     V5  CPU $0000-$03FF         1,398,605
--
-- memType 을 명시한 V1·V2 가 둘 다 0 이다.  Mesen 은 pceVideoRam 에 write
-- 콜백을 주지 않는다.  V3 이 뜨는 것은 4 인자 형태가 memType 을 생략해 VRAM 이
-- 아니라 CPU 버스를 보기 때문이고 (프레임당 4,423 회, SATB 256 워드와 규모가
-- 안 맞는다), 따라서 답이 아니다.
--
-- 그 결과 **0.4.26 의 "147,247 프레임 write 0 -> SUMMARY_PASS" 는 무효다.**
-- 아무것도 재지 않은 0 이었다.  $1600-$1ABF 의 수명 감시 근거는 폐기한다.
--
-- 살아 있는 길은 V4 == V5 가 가리킨다.  두 카운트가 정확히 같다는 것은 그
-- 트래픽이 전부 $0000-$0003 이라는 뜻이고, PCE 의 I/O 페이지에서 그 자리는
-- VDC 다 (VDC 는 $0000-$03FF 에 4 바이트 주기로 미러링된다).
--
-- 그래서 이 판은 VRAM 을 직접 훅하지 않는다.  **VDC 포트 쓰기를 훅해서 VRAM
-- 주소를 재구성한다.**
--
-- ── VDC 쓰기 규약 ─────────────────────────────────────────────────────────
--
--     $0000  레지스터 선택
--     $0002  데이터 하위 바이트
--     $0003  데이터 상위 바이트
--
--   reg $00 MAWR  쓰기 주소.  lo/hi 로 설정된다.
--   reg $02 VWR   VRAM 데이터.  **hi 바이트가 써질 때** 한 워드가 VRAM 에
--                 들어가고 MAWR 이 1 증가한다.
--   reg $10 SOUR / $11 DESR / $12 LENR  VRAM->VRAM DMA.
--                 LENR 의 hi 가 써지면 DMA 가 돌면서 DESR 부터 LENR+1 워드가
--                 **VRAM 에 써진다.**  CPU 한 워드씩 쓰는 경로가 아니므로
--                 따로 세지 않으면 통째로 놓친다.  0.4.26 계열이 설령 VRAM
--                 콜백을 받았더라도 이 경로는 못 봤을 것이다.
--
-- ── 자체 검증 ─────────────────────────────────────────────────────────────
--
-- 재구성이 맞는지 스스로 본다.  게임은 SATB 테이블($1000-$10FF word)을 매
-- 프레임 다시 쓴다.  거기에 재구성된 쓰기가 안 잡히면 디코더가 틀린 것이므로
-- PASS 를 내지 않고 INCONCLUSIVE 를 낸다.  포트별 원시 카운트도 같이 남겨서,
-- 디코더가 틀렸을 때 무엇이 틀렸는지 같은 실행에서 보이게 한다.
--
-- 대상은 0.4.55 와 같은 $3B40-$3FFF 다.  읽기 전용이고 자막 팩이 필요 없다.

local VRAM = emu.memType.pceVideoRam
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local FIRST_WORD, LAST_WORD = 0x3B40, 0x3FFF
local NEED_WORDS = LAST_WORD - FIRST_WORD + 1

-- 자체 검증용: 게임이 매 프레임 다시 쓰는 SATB 테이블.
local CTRL_FIRST, CTRL_LAST = 0x1000, 0x10FF

local VDC_LO, VDC_HI = 0x0000, 0x03FF
local BAT_SCAN_EVERY = 10
local VOICE_RATE = 0x0E

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_55_vdc_lifetime_' .. stamp .. '.tsv'
local CENSUS = 'C:/snatcher/dump/sub_0_4_55_satb_census_' .. stamp .. '.tsv'

local file = assert(io.open(OUT, 'w'))
file:write('frame\tvoice\tevent\twrites\tunique_words\tfirst_word\tlast_word\t' ..
           'bat_refs\tsatb_refs\tdetail\n')

local frame, closed = 0, false

-- VDC 디코더 상태
local selReg, mawr = 0, 0
local dataLo = 0
local sour, desr, lenr = 0, 0, 0
local portHits = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }

-- 재구성 결과
local cpuWordWrites, dmaWordWrites = 0, 0
local targetWrites, targetUnique = 0, 0
local ctrlWrites = 0
local everWritten = {}
local pending, pendingCount, pendingFirst, pendingLast = {}, 0, nil, nil
local writeFrames = 0
local dmaRuns = 0

-- 참조 감시
local satbScans, batScans, batRefFrames, satbRefFrames = 0, 0, 0, 0
local lastBatRefs, lastSatbRefs = 0, 0
local maxBatRefs, maxSatbRefs = 0, 0
local census, censusCount = {}, 0

-- 음성 창
local inVoice, voiceFrames, voiceWindows = false, 0, 0
local inWindowHits, outWindowHits = 0, 0

local installed = false

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(wordAt)
  local at = wordAt * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function overlaps(first, count)
  return first <= LAST_WORD and (first + count - 1) >= FIRST_WORD
end

-- 재구성된 VRAM 워드 쓰기 하나.
local function noteWordWrite(word)
  word = word & 0xFFFF
  if word >= CTRL_FIRST and word <= CTRL_LAST then
    ctrlWrites = ctrlWrites + 1
  end
  if word < FIRST_WORD or word > LAST_WORD then return end
  targetWrites = targetWrites + 1
  if not pending[word] then
    pending[word] = true
    pendingCount = pendingCount + 1
    pendingFirst = pendingFirst and math.min(pendingFirst, word) or word
    pendingLast = pendingLast and math.max(pendingLast, word) or word
  end
  if not everWritten[word] then
    everWritten[word] = true
    targetUnique = targetUnique + 1
  end
end

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  portHits[port] = portHits[port] + 1

  if port == 0 then
    selReg = value
  elseif port == 2 then
    dataLo = value
    if selReg == 0x00 then
      mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x10 then
      sour = (sour & 0xFF00) | value
    elseif selReg == 0x11 then
      desr = (desr & 0xFF00) | value
    elseif selReg == 0x12 then
      lenr = (lenr & 0xFF00) | value
    end
  elseif port == 3 then
    if selReg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 0x02 then
      -- hi 바이트가 한 워드를 확정하고 MAWR 을 올린다.
      noteWordWrite(mawr)
      cpuWordWrites = cpuWordWrites + 1
      mawr = (mawr + 1) & 0xFFFF
    elseif selReg == 0x10 then
      sour = (sour & 0x00FF) | (value << 8)
    elseif selReg == 0x11 then
      desr = (desr & 0x00FF) | (value << 8)
    elseif selReg == 0x12 then
      lenr = (lenr & 0x00FF) | (value << 8)
      -- LENR hi 쓰기가 DMA 를 띄운다.  DESR 부터 LENR+1 워드가 써진다.
      dmaRuns = dmaRuns + 1
      local count = lenr + 1
      dmaWordWrites = dmaWordWrites + count
      -- 대상/대조 범위와 겹칠 때만 워드 단위로 돈다.  전량 순회는 비싸다.
      local dst = desr
      local dlast = desr + count - 1
      if dlast >= FIRST_WORD and dst <= LAST_WORD then
        local a = math.max(dst, FIRST_WORD)
        local b = math.min(dlast, LAST_WORD)
        for w = a, b do noteWordWrite(w) end
      end
      if dlast >= CTRL_FIRST and dst <= CTRL_LAST then
        local a = math.max(dst, CTRL_FIRST)
        local b = math.min(dlast, CTRL_LAST)
        ctrlWrites = ctrlWrites + (b - a + 1)
      end
    end
  end
end

installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write,
                        VDC_LO, VDC_HI, CPU, MEM)
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

local function voiceActive()
  local ok, state = pcall(emu.getState)
  if not ok or not state then return false end
  if state['cdrom.adpcm.playing'] ~= true then return false end
  return (tonumber(state['cdrom.adpcm.playbackRate']) or 0) & 0xFF == VOICE_RATE
end

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
                firstFrame = frame, palette = attr & 0x0F }
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
  local batEntries = math.min(columns * rows, 0x1000)
  for i = 0, batEntries - 1 do
    local base = (rw(i) & 0x07FF) * 0x10
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
    if inVoice then inWindowHits = inWindowHits + 1
    else outWindowHits = outWindowHits + 1 end
    logRow('WRITE', targetWrites, pendingCount, pendingFirst, pendingLast,
           lastBatRefs, lastSatbRefs,
           string.format('cpu=%d;dma=%d;dma_runs=%d',
                         cpuWordWrites, dmaWordWrites, dmaRuns))
    emu.log(string.format(
      'SUB 0.4.55 ★ TARGET WRITE f=%d unique=%d span=$%04X-$%04X total=%d',
      frame, pendingCount, pendingFirst, pendingLast, targetWrites))
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
    if inVoice then inWindowHits = inWindowHits + 1
    else outWindowHits = outWindowHits + 1 end
  end
  maxBatRefs = math.max(maxBatRefs, bat)
  maxSatbRefs = math.max(maxSatbRefs, satb)

  if bat ~= lastBatRefs or satb ~= lastSatbRefs then
    local event = (bat > 0 or satb > 0) and 'REF_CHANGE_COLLISION' or 'REF_CLEAR'
    local detail = satbDetail
    if batDetail ~= '' then
      detail = (detail ~= '' and (detail .. ',') or '') .. batDetail
    end
    logRow(event, 0, 0, nil, nil, bat, satb, detail)
    if bat > 0 or satb > 0 then
      emu.log(string.format('SUB 0.4.55 ★ TARGET REFERENCED f=%d BAT=%d SATB=%d %s',
                            frame, bat, satb, detail))
    end
  end
  lastBatRefs, lastSatbRefs = bat, satb

  local alive = ctrlWrites > 0
  local bad = targetWrites > 0 or maxBatRefs > 0 or maxSatbRefs > 0
  emu.drawString(4, 4, string.format('0.4.55 $3B40 WATCH  W:%d B:%d S:%d',
                 targetWrites, maxBatRefs, maxSatbRefs),
                 bad and 0xFF4040 or (alive and 0x40FF40 or 0xFFA000), 0x000000)
  emu.drawString(4, 14, string.format('ctrl:%d %s  cpu:%d dma:%d/%d',
                 ctrlWrites, alive and 'LIVE' or '★DEAD',
                 cpuWordWrites, dmaWordWrites, dmaRuns),
                 alive and 0xC0C0C0 or 0xFFA000, 0x000000)
  emu.drawString(4, 24, string.format('port 0:%d 2:%d 3:%d  census:%d',
                 portHits[0], portHits[2], portHits[3], censusCount),
                 0x909090, 0x000000)
  emu.drawString(4, 34, string.format('voice %s  창 %d  충돌 in:%d out:%d',
                 inVoice and 'ON ' or 'off', voiceWindows,
                 inWindowHits, outWindowHits),
                 inVoice and 0x60D0FF or 0x808080, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true

  local alive = installed and ctrlWrites > 0
  local quiet = targetWrites == 0 and maxBatRefs == 0 and maxSatbRefs == 0
  local verdict
  if not alive then
    verdict = 'SUMMARY_INCONCLUSIVE'
  elseif quiet then
    verdict = 'SUMMARY_PASS'
  else
    verdict = 'SUMMARY_FAIL'
  end

  logRow(verdict, targetWrites, targetUnique, FIRST_WORD, LAST_WORD,
         maxBatRefs, maxSatbRefs,
         string.format('frames=%d;write_frames=%d;satb_scans=%d;bat_scans=%d;' ..
                       'installed=%d;ctrl_writes=%d;cpu_words=%d;dma_words=%d;' ..
                       'dma_runs=%d;port0=%d;port2=%d;port3=%d;census=%d;' ..
                       'voice_frames=%d;voice_windows=%d;in_window=%d;out_window=%d',
                       frame, writeFrames, satbScans, batScans,
                       installed and 1 or 0, ctrlWrites, cpuWordWrites,
                       dmaWordWrites, dmaRuns,
                       portHits[0], portHits[2], portHits[3], censusCount,
                       voiceFrames, voiceWindows, inWindowHits, outWindowHits))
  file:close()

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

  emu.log(string.format('SUB 0.4.55 ★ %s: frames=%d target_writes=%d unique=%d ' ..
                        'maxBAT=%d maxSATB=%d ctrl=%d',
    verdict, frame, targetWrites, targetUnique, maxBatRefs, maxSatbRefs, ctrlWrites))
  emu.log(string.format('  재구성: cpu %d 워드 · dma %d 워드 (%d 회)',
                        cpuWordWrites, dmaWordWrites, dmaRuns))
  emu.log(string.format('  포트: sel %d · lo %d · hi %d',
                        portHits[0], portHits[2], portHits[3]))
  if not installed then
    emu.log('  ★ 콜백 등록 자체가 실패했다.')
  elseif ctrlWrites == 0 then
    emu.log('  ★ SATB 테이블에 재구성된 쓰기가 하나도 없다.  디코더가 틀렸다.')
    emu.log('    포트 카운트를 보라.  sel/lo/hi 가 다 0 이면 훅이 VDC 가 아니다.')
    emu.log('    0 을 근거로 쓰지 마라.')
  end
  emu.log(string.format('  음성 창 %d 개 · %d 프레임 · 충돌 창안 %d / 창밖 %d',
    voiceWindows, voiceFrames, inWindowHits, outWindowHits))
  emu.log('SUB 0.4.55 saved: ' .. OUT)
  emu.log('SUB 0.4.55 census: ' .. CENSUS)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.55 loaded -- VDC 포트 재구성 방식 · 읽기 전용')
emu.log(string.format('  target: $%04X-$%04X (%d words / 19 cells)',
                      FIRST_WORD, LAST_WORD, NEED_WORDS))
emu.log(string.format('  control: $%04X-$%04X (SATB, 매 프레임 써져야 한다)',
                      CTRL_FIRST, CTRL_LAST))
emu.log('  installed: ' .. tostring(installed))
emu.log('  output: ' .. OUT)
