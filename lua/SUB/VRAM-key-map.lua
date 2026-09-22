-- SUB VRAM-key-map -- 음성 키마다 "그 음성이 나는 동안" 비어 있던 자리를 찾는다
--
-- ── 왜 이걸 만드나 (2026-08-29) ───────────────────────────────────────────
--
-- 지금 allocator 는 음성 시작 t0 에 SATB/BAT 를 훑어 빈 블록을 고른다.  그런데
-- 초상화는 자막과 **같은 순간**에 올라온다.  고를 때는 비어 보이고 직후에
-- 뺏긴다.  로그의 `게임이 가져갔다` 가 거의 매 음성마다 나오는 이유다.
--
--     지금       t0 의 정보로 t0 에 결정   -> t0 엔 비었는데 t0+3 에 뺏김
--     이 방식    [t0, t1] 전체를 보고 결정 -> 그 구간 내내 비어 있던 자리만
--
-- allocator 는 미래를 못 본다.  오프라인 측정은 본다.  그 하나가 차이다.
--
-- "VRAM 에 남는 자리가 없다" 는 것도 **VRAM 전체·전 구간** 기준의 이야기다.
-- 대사 한 줄이 떠 있는 몇 초 기준으로는 다르다.  캡슐 방에서 $1800-$1A3F 가
-- 초상화 자리여도 다른 대사에서는 초상화가 없거나 다른 데 있다.
--
-- ── 무엇을 하나 ───────────────────────────────────────────────────────────
--
-- rate-$0E ADPCM 이 시작되면 6 B 키를 계산하고, 그 음성이 끝날 때까지
-- VRAM 점유를 누적한다.  끝나면 19 셀($4C0)이 들어갈 32 word 정렬 자유 구간을
-- 계산해 한 줄로 남긴다.
--
-- 점유로 치는 것:
--     VDC 포트로 재구성한 실제 쓰기      (CPU 워드 쓰기 + VRAM-VRAM DMA)
--     BAT 가 가리킨 BG 패턴
--     SATB 가 가리킨 스프라이트 패턴
--
-- ── 반드시 자막 엔진 없이 돌릴 것 ────────────────────────────────────────
--
-- 우리 글리프가 올라가면 그 자리가 "사용 중" 으로 기록되어 관측이 오염된다.
-- 0.4.31/0.4.57~0.4.63 계열을 같이 올리지 말 것.  이 파일 하나만 실행한다.
-- 아무것도 쓰지 않는 읽기 전용이다.
--
-- ── 계측기 자체 검증 ─────────────────────────────────────────────────────
--
-- Mesen 은 pceVideoRam 에 write 콜백을 주지 않는다 (2026-08-29 실측: memType 을
-- 명시한 등록은 전부 0 회).  그래서 VDC 포트를 훅해 MAWR 로 주소를 재구성한다.
-- 재구성이 맞는지 실제 VRAM 과 대조해 일치율을 화면에 띄운다.  이 값이 낮으면
-- 아래 결과를 쓰면 안 된다.  숫자가 0 일 때 "없다" 인지 "못 봤다" 인지 갈라야
-- 하기 때문이다.
--
-- ── 결과 ─────────────────────────────────────────────────────────────────
--
--     dump/vram_key_map_<시각>.tsv    키마다 자유 구간과 후보 base
--     dump/vram_key_spans_<시각>.tsv  키마다 점유 구간 (분석용 원자료)
--
-- 정주행 한 바퀴 돌고 Stop 하면 된다.  오래 돌수록 키가 많이 모인다.

local VRAM = emu.memType.pceVideoRam
local MEM = emu.memType.pceMemory
local APCM = emu.memType.pceAdpcmRam
local CPU = emu.cpuType.pce

local VDC_LO, VDC_HI = 0x0000, 0x03FF
local VRAM_WORDS = 0x8000
local NEED_WORDS = 19 * 0x40          -- 0x4C0
local ALIGN = 0x20                    -- 스프라이트 패턴 base 는 32 word 배수
local VOICE_RATE = 0x0E

local BAT_EVERY = 10                  -- BAT 는 4096 엔트리라 드물게
local VERIFY_EVERY = 60

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/vram_key_map_' .. stamp .. '.tsv'
local SPANS = 'C:/snatcher/dump/vram_key_spans_' .. stamp .. '.tsv'

local out = assert(io.open(OUT, 'w'))
out:write('key\tframes\tmarked\tfree_spans\tbase_count\tfirst_base\tbases\n')
out:flush()

local spansOut = assert(io.open(SPANS, 'w'))
spansOut:write('key\tfirst\tlast\twords\n')
spansOut:flush()

local frame = 0
local closed = false

-- VDC 디코더
local selReg, mawr, dataLo = 0, 0, 0
local desr, lenr = 0, 0
local portHits = 0
local cpuWords, dmaWords = 0, 0

-- 현재 음성
local curKey, curFrames, curMarked = nil, 0, 0
local mark = {}                       -- 이 음성 동안의 점유
local seenKeys, keyCount = {}, 0
local rowCount = 0

-- 디코더 대조
local shadow, shadowCount = {}, 0
local verifySamples, verifyOk = 0, 0

local installed = false

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(w)
  local at = w * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function note(w)
  if curKey == nil then return end
  if mark[w] == nil then
    mark[w] = true
    curMarked = curMarked + 1
  end
end

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  portHits = portHits + 1

  if port == 0 then
    selReg = value
  elseif port == 2 then
    dataLo = value
    if selReg == 0x00 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x11 then desr = (desr & 0xFF00) | value
    elseif selReg == 0x12 then lenr = (lenr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 0x02 then
      local w = mawr & 0x7FFF
      note(w)
      cpuWords = cpuWords + 1
      if shadowCount < 64 then
        if shadow[w] == nil then shadowCount = shadowCount + 1 end
        shadow[w] = dataLo | (value << 8)
      elseif shadow[w] ~= nil then
        shadow[w] = dataLo | (value << 8)
      end
      mawr = (mawr + 1) & 0xFFFF
    elseif selReg == 0x11 then
      desr = (desr & 0x00FF) | (value << 8)
    elseif selReg == 0x12 then
      lenr = (lenr & 0x00FF) | (value << 8)
      local count = lenr + 1
      dmaWords = dmaWords + count
      local dst = desr & 0x7FFF
      for i = 0, count - 1 do note((dst + i) & 0x7FFF) end
    end
  end
end

installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write,
                        VDC_LO, VDC_HI, CPU, MEM)
end)

local function number(state, name)
  local v = state[name]
  return type(v) == 'number' and math.floor(v) or 0
end

local function hex(s)
  return (s:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

-- 0.4.31 의 actualVoice 와 같은 계산이어야 팩 키와 맞는다.
local function actualVoice()
  local ok, state = pcall(emu.getState)
  if not ok or not state or state['cdrom.adpcm.playing'] ~= true then return nil end
  local finish = (number(state, 'cdrom.adpcm.readAddress') +
                  number(state, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
  local rate = number(state, 'cdrom.adpcm.playbackRate') & 0xFF
  if rate ~= VOICE_RATE then return nil end
  -- 표본 자리는 이대로 **고정**한다 (build_voice_console_keys.py 와 같아야 한다).
  -- 옮겨서 충돌을 줄이려는 시도는 2026-09-02 에 실패했다 -- 버퍼 앞쪽 자리는
  -- 클립 범위 밖이라 산출이 1,211 -> 1,022 로 줄어든다.  그쪽 주석 참고.
  local a1, a2, a3 = finish // 4, finish // 2, (finish * 5) // 8
  local key = string.char(finish & 0xFF, finish >> 8, rate,
                          emu.read(a1, APCM) or 0,
                          emu.read(a2, APCM) or 0,
                          emu.read(a3, APCM) or 0)
  return hex(key)
end

local function saneDimension(v, fallback)
  v = tonumber(v)
  if v == 32 or v == 64 or v == 128 then return v end
  return fallback
end

local function dimensions()
  local ok, state = pcall(emu.getState)
  if not ok or not state then return 64, 64 end
  return saneDimension(state['vdc.hvReg.columnCount'], 64),
         saneDimension(state['vdc.hvReg.rowCount'], 64)
end

local function scanSatb()
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local y = rb(at) | (rb(at + 1) << 8)
    local x = rb(at + 2) | (rb(at + 3) << 8)
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local wide = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local tall = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local base = (pattern & 0x07FF) << 5
      local words = wide * tall * 0x40
      for i = 0, words - 1 do note((base + i) & 0x7FFF) end
    end
  end
end

local function scanBat()
  local columns, rows = dimensions()
  local entries = math.min(columns * rows, 0x1000)
  for i = 0, entries - 1 do
    local base = (rw(i) & 0x07FF) * 0x10
    for k = 0, 15 do note((base + k) & 0x7FFF) end
  end
end

local function verifyDecoder()
  for w, v in pairs(shadow) do
    verifySamples = verifySamples + 1
    if rw(w) == v then verifyOk = verifyOk + 1 end
  end
  shadow, shadowCount = {}, 0
end

-- 음성이 끝났다.  누적 점유에서 자유 구간과 후보 base 를 뽑아 기록한다.
local function finishVoice()
  if curKey == nil then return end

  -- 자유 구간 (연속으로 mark 가 없는 곳)
  local spans, spanN = {}, 0
  local runStart = nil
  for w = 0, VRAM_WORDS do
    local free = (w < VRAM_WORDS) and (mark[w] == nil) or false
    if free then
      if runStart == nil then runStart = w end
    elseif runStart ~= nil then
      spanN = spanN + 1
      spans[spanN] = { runStart, w - 1 }
      runStart = nil
    end
  end

  -- 19 셀이 들어가는 32 word 정렬 base
  local bases, baseN = {}, 0
  for i = 1, spanN do
    local f, l = spans[i][1], spans[i][2]
    local b = ((f + ALIGN - 1) // ALIGN) * ALIGN
    while b + NEED_WORDS - 1 <= l do
      baseN = baseN + 1
      bases[baseN] = b
      b = b + ALIGN
    end
  end

  local list, listN = {}, 0
  for i = 1, math.min(baseN, 24) do
    listN = listN + 1
    list[listN] = string.format('%04X', bases[i])
  end

  out:write(string.format('%s\t%d\t%d\t%d\t%d\t%s\t%s\n',
    curKey, curFrames, curMarked, spanN, baseN,
    baseN > 0 and string.format('%04X', bases[1]) or '-',
    table.concat(list, ',')))
  out:flush()

  for i = 1, spanN do
    local f, l = spans[i][1], spans[i][2]
    if l - f + 1 >= ALIGN then
      spansOut:write(string.format('%s\t%04X\t%04X\t%d\n', curKey, f, l, l - f + 1))
    end
  end
  spansOut:flush()

  rowCount = rowCount + 1
  if baseN == 0 then
    emu.log(string.format('VRAM-key-map ★ %s : 자유 base 0 개 (%d 프레임 · 점유 %d word)',
                          curKey, curFrames, curMarked))
  end

  curKey, curFrames, curMarked = nil, 0, 0
  mark = {}
end

emu.addEventCallback(function()
  frame = frame + 1

  local key = actualVoice()

  if key ~= curKey then
    if curKey ~= nil then finishVoice() end
    if key ~= nil then
      curKey, curFrames, curMarked = key, 0, 0
      mark = {}
      if not seenKeys[key] then
        seenKeys[key] = true
        keyCount = keyCount + 1
      end
      -- 시작 프레임의 화면 상태도 점유로 친다.
      scanSatb()
      scanBat()
    end
  end

  if curKey ~= nil then
    curFrames = curFrames + 1
    scanSatb()
    if frame % BAT_EVERY == 0 then scanBat() end
  end

  if frame % VERIFY_EVERY == 0 then verifyDecoder() end

  local rate = verifySamples > 0 and (verifyOk * 100 // verifySamples) or -1
  local trust = rate >= 90
  emu.drawString(4, 4, string.format('KEY-MAP  키 %d  기록 %d', keyCount, rowCount),
                 0xFFFFFF, 0x000000)
  emu.drawString(4, 14, string.format('decoder %s %d%% (%d)',
                 trust and 'OK' or '★CHECK', rate, verifySamples),
                 trust and 0x40FF40 or 0xFFA000, 0x000000)
  if curKey then
    emu.drawString(4, 24, string.format('voice %s  %df  점유 %d',
                   curKey, curFrames, curMarked), 0x60D0FF, 0x000000)
  else
    emu.drawString(4, 24, string.format('cpu %d  dma %d  port %d',
                   cpuWords, dmaWords, portHits), 0x808080, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  if curKey ~= nil then finishVoice() end
  verifyDecoder()
  local rate = verifySamples > 0 and (verifyOk * 100 // verifySamples) or -1
  out:close()
  spansOut:close()
  emu.log(string.format('VRAM-key-map 끝 -- 프레임 %d · 고유 키 %d · 기록 %d',
                        frame, keyCount, rowCount))
  emu.log(string.format('  디코더 대조 %d 표본 중 %d 일치 (%d%%)',
                        verifySamples, verifyOk, rate))
  if not installed or verifySamples == 0 or rate < 90 then
    emu.log('  ★ 디코더를 믿을 수 없다.  이 결과를 근거로 쓰지 마라.')
  end
  emu.log('  map:   ' .. OUT)
  emu.log('  spans: ' .. SPANS)
end, emu.eventType.scriptEnded)

emu.log('SUB VRAM-key-map loaded -- 음성 키마다 자유 자리 측정 · 읽기 전용')
emu.log(string.format('  찾는 창 %d word (19 셀) · 정렬 %d · rate $%02X 만',
                      NEED_WORDS, ALIGN, VOICE_RATE))
emu.log('  ★ 자막 엔진(0.4.31/0.4.57~0.4.63)과 같이 올리지 말 것')
emu.log('  installed: ' .. tostring(installed))
emu.log('  map:   ' .. OUT)
emu.log('  spans: ' .. SPANS)
