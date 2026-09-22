-- SUB 0.4.56 -- VRAM 점유 지도 / 읽기 전용
--
-- ── 왜 이걸 만드는가 (0.4.55 실측, 2026-08-29) ────────────────────────────
--
-- 0.4.55 가 VDC 포트 재구성으로 대조군(ctrl:432,384 LIVE)을 통과한 뒤
-- $3B40-$3FFF 를 재보니 이렇게 나왔다:
--
--     W:1216   B:86   S:0      음성 창 안 183 / 밖 5369
--
-- W 가 정확히 1216 = 0x4C0 = 후보 범위의 **전체 워드 수**다.  일부 충돌이
-- 아니라 게임이 그 영역을 통째로 쓴다.  그런데 이 후보는 0.4.25 의 56 개
-- 공통 후보 중 정적 필터를 통과한 **유일한 하나**였다.  즉 통과 후보가 0 이 됐다.
--
-- 정적 필터가 왜 틀렸는지도 드러났다.  후보를 좁힌 census 는 SATB(스프라이트)
-- 주소뿐이었다.  $3B40 은 스프라이트가 안 쓰는 게 맞았는데 **BG 패턴**이 쓴다
-- (B:86).  스프라이트만 보고 고른 반쪽짜리 필터였다.
--
-- 그래서 후보를 하나씩 찍어서 검사하는 방식을 그만둔다.  **한 번 플레이하는
-- 동안 VRAM 전체의 점유를 통째로 기록**하고, 거기서 답을 뽑는다.
--
-- 이 자료 하나로 두 질문이 같이 풀린다:
--
--   (1) 고정 후보가 하나라도 존재하는가.  있으면 그걸 쓰면 끝난다.
--   (2) 없다면 allocator 가 어느 구간을 노려야 하는가.
--
-- 고정이든 allocator 든 어차피 필요한 자료라 방향을 정하기 전에 찍어도 안 버린다.
--
-- ── 무엇을 기록하는가 ─────────────────────────────────────────────────────
--
-- 워드마다 6 비트 마스크를 쌓는다.
--
--     1  써졌다
--     2  **음성 창 안에서** 써졌다
--     4  BAT 가 가리켰다
--     8  SATB 가 가리켰다
--    16  **음성 창 안에서** BAT 가 가리켰다
--    32  **음성 창 안에서** SATB 가 가리켰다
--
-- 자막은 음성이 나는 동안만 VRAM 을 빌렸다 되돌려준다.  그러니 진짜 조건은
-- "영원히 안 쓴다"(비트 1)가 아니라 "**음성 창 안에서** 안 쓴다"(비트 2)다.
-- 둘 다 세서 어느 쪽으로 답이 나오는지 본다.
--
-- ── 대조군 ────────────────────────────────────────────────────────────────
--
-- 0.4.53 은 대조군을 SATB 테이블로 잡았다가 타이틀 화면(스프라이트 0 개)에서
-- ★DEAD 를 냈다.  화면 내용에 기대는 대조군이었던 게 잘못이다.  이 판은
-- **재구성한 주소·값을 실제 VRAM 과 대조**한다.  화면이 무엇이든 성립한다.
-- 일치율이 낮으면 PASS 를 내지 않는다.
--
-- 읽기 전용.  자막 팩이 필요 없다.  켜 두고 오래 플레이할수록 지도가 촘촘해진다.

local VRAM = emu.memType.pceVideoRam
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local VDC_LO, VDC_HI = 0x0000, 0x03FF
local VRAM_WORDS = 0x8000            -- PCE VRAM = 32K word
local NEED_WORDS = 19 * 0x40         -- 0x4C0.  자막 19 셀
local ALIGN = 0x20                   -- 스프라이트 패턴 base 는 32 word 배수
local VOICE_RATE = 0x0E

local BAT_EVERY = 30                 -- BAT 는 4096 엔트리라 드물게
local SATB_EVERY = 10
local VERIFY_EVERY = 60              -- 디코더 대조 주기(프레임)

local M_WRITE, M_VOICE, M_BAT, M_SATB = 1, 2, 4, 8
local M_BAT_V, M_SATB_V = 16, 32   -- 음성 창 안에서의 참조

local stamp = os.date('%Y%m%d_%H%M%S')
local MAP = 'C:/snatcher/dump/sub_0_4_56_vram_map_' .. stamp .. '.tsv'
local FREE = 'C:/snatcher/dump/sub_0_4_56_free_windows_' .. stamp .. '.tsv'

local frame, closed = 0, false

-- VDC 디코더
local selReg, mawr, dataLo = 0, 0, 0
local sour, desr, lenr = 0, 0, 0
local portHits = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
local cpuWords, dmaWords, dmaRuns = 0, 0, 0

-- 점유 지도
local mark = {}
local markedWords = 0

-- 현재 프레임의 비트.  음성 여부에 따라 매 프레임 갱신한다.
local curWriteBit = M_WRITE
local curBatBit, curSatbBit = M_BAT, M_SATB

-- 디코더 대조
local verifySamples, verifyOk = 0, 0
local shadow, shadowCount = {}, 0

-- 음성 창
local inVoice, voiceFrames, voiceWindows = false, 0, 0

local installed = false

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(w)
  local at = w * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function note(w, bit)
  local m = mark[w]
  if m == nil then
    mark[w] = bit
    markedWords = markedWords + 1
  elseif (m | bit) ~= m then
    mark[w] = m | bit
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
    if selReg == 0x00 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x10 then sour = (sour & 0xFF00) | value
    elseif selReg == 0x11 then desr = (desr & 0xFF00) | value
    elseif selReg == 0x12 then lenr = (lenr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 0x02 then
      local w = mawr & 0x7FFF
      note(w, curWriteBit)
      cpuWords = cpuWords + 1
      -- 대조용 그림자.  이 프레임에 그 워드에 마지막으로 쓴 값을 남긴다.
      if shadowCount < 64 then
        if shadow[w] == nil then shadowCount = shadowCount + 1 end
      end
      if shadow[w] ~= nil or shadowCount < 64 then
        shadow[w] = dataLo | (value << 8)
      end
      mawr = (mawr + 1) & 0xFFFF
    elseif selReg == 0x10 then
      sour = (sour & 0x00FF) | (value << 8)
    elseif selReg == 0x11 then
      desr = (desr & 0x00FF) | (value << 8)
    elseif selReg == 0x12 then
      lenr = (lenr & 0x00FF) | (value << 8)
      dmaRuns = dmaRuns + 1
      local count = lenr + 1
      dmaWords = dmaWords + count
      local dst = desr & 0x7FFF
      for i = 0, count - 1 do
        note((dst + i) & 0x7FFF, curWriteBit)
      end
    end
  end
end

installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write,
                        VDC_LO, VDC_HI, CPU, MEM)
end)

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

local function voiceActive()
  local ok, state = pcall(emu.getState)
  if not ok or not state then return false end
  if state['cdrom.adpcm.playing'] ~= true then return false end
  return (tonumber(state['cdrom.adpcm.playbackRate']) or 0) & 0xFF == VOICE_RATE
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
      for i = 0, words - 1 do note((base + i) & 0x7FFF, curSatbBit) end
    end
  end
end

local function scanBat()
  local columns, rows = dimensions()
  local entries = math.min(columns * rows, 0x1000)
  for i = 0, entries - 1 do
    local base = (rw(i) & 0x07FF) * 0x10
    for k = 0, 15 do note((base + k) & 0x7FFF, curBatBit) end
  end
end

-- 재구성이 맞는지 실제 VRAM 과 대조한다.  화면 내용과 무관하다.
local function verifyDecoder()
  for w, v in pairs(shadow) do
    verifySamples = verifySamples + 1
    if rw(w) == v then verifyOk = verifyOk + 1 end
  end
  shadow, shadowCount = {}, 0
end

emu.addEventCallback(function()
  frame = frame + 1

  local nowVoice = voiceActive()
  if nowVoice and not inVoice then voiceWindows = voiceWindows + 1 end
  inVoice = nowVoice
  if inVoice then voiceFrames = voiceFrames + 1 end
  curWriteBit = inVoice and (M_WRITE | M_VOICE) or M_WRITE
  curBatBit = inVoice and (M_BAT | M_BAT_V) or M_BAT
  curSatbBit = inVoice and (M_SATB | M_SATB_V) or M_SATB

  if frame % SATB_EVERY == 0 then scanSatb() end
  if frame % BAT_EVERY == 0 then scanBat() end
  if frame % VERIFY_EVERY == 0 then verifyDecoder() end

  local rate = verifySamples > 0 and (verifyOk * 100 // verifySamples) or -1
  local trust = rate >= 90
  emu.drawString(4, 4, string.format('0.4.56 MAP  words %d/%d (%d%%)',
                 markedWords, VRAM_WORDS, markedWords * 100 // VRAM_WORDS),
                 0xFFFFFF, 0x000000)
  emu.drawString(4, 14, string.format('decoder %s %d%% (%d)',
                 trust and 'OK' or '★CHECK', rate, verifySamples),
                 trust and 0x40FF40 or 0xFFA000, 0x000000)
  emu.drawString(4, 24, string.format('cpu %d  dma %d/%d  port %d/%d/%d',
                 cpuWords, dmaWords, dmaRuns,
                 portHits[0], portHits[2], portHits[3]), 0x909090, 0x000000)
  emu.drawString(4, 34, string.format('voice %s  창 %d  %d frames',
                 inVoice and 'ON ' or 'off', voiceWindows, voiceFrames),
                 inVoice and 0x60D0FF or 0x808080, 0x000000)
end, emu.eventType.endFrame)

-- ── 저장 ──────────────────────────────────────────────────────────────────

local function writeMap()
  local f = io.open(MAP, 'w')
  if not f then return end
  f:write('first\tlast\twords\tmask\twritten\tvoice_written\tbat\tsatb\n')
  local runStart, runMask = 0, mark[0] or 0
  for w = 1, VRAM_WORDS do
    local m = (w < VRAM_WORDS) and (mark[w] or 0) or nil
    if m ~= runMask then
      f:write(string.format('%04X\t%04X\t%d\t%X\t%d\t%d\t%d\t%d\n',
        runStart, w - 1, w - runStart, runMask,
        (runMask & M_WRITE) ~= 0 and 1 or 0,
        (runMask & M_VOICE) ~= 0 and 1 or 0,
        (runMask & M_BAT) ~= 0 and 1 or 0,
        (runMask & M_SATB) ~= 0 and 1 or 0))
      runStart, runMask = w, m
    end
  end
  f:close()
end

-- 19 셀이 들어갈 32 word 정렬 창을 두 기준으로 찾는다.
local function scanWindows(f, label, forbid)
  local found = 0
  local base = 0
  while base + NEED_WORDS <= VRAM_WORDS do
    local ok = true
    local w = base
    while w < base + NEED_WORDS do
      if ((mark[w] or 0) & forbid) ~= 0 then ok = false; break end
      w = w + 1
    end
    if ok then
      found = found + 1
      f:write(string.format('%s\t%04X\t%04X\t%d\n',
        label, base, base + NEED_WORDS - 1, NEED_WORDS))
      base = base + ALIGN
    else
      -- 걸린 워드 다음 정렬 경계로 건너뛴다.
      base = ((w + ALIGN) // ALIGN) * ALIGN
    end
  end
  return found
end

local function writeFree()
  local f = io.open(FREE, 'w')
  if not f then return 0, 0 end
  f:write('criterion\tfirst\tlast\twords\n')
  -- STRICT: 언제든 쓰기·참조가 한 번도 없었던 창
  local strict = scanWindows(f, 'STRICT', M_WRITE | M_BAT | M_SATB)
  -- VOICE_SAFE: 음성 창 안에서 써지지도, 참조되지도 않은 창.
  -- 부팅 때 써졌더라도 음성 창 동안 화면에 안 나오면 빌렸다 돌려줄 수 있다.
  local voice = scanWindows(f, 'VOICE_SAFE', M_VOICE | M_BAT_V | M_SATB_V)
  f:close()
  return strict, voice
end

emu.addEventCallback(function()
  if closed then return end
  closed = true

  verifyDecoder()
  local rate = verifySamples > 0 and (verifyOk * 100 // verifySamples) or -1
  local trust = installed and verifySamples > 0 and rate >= 90

  writeMap()
  local strict, voice = writeFree()

  emu.log(string.format('SUB 0.4.56 지도 완료 -- frames=%d  덮인 워드 %d/%d (%d%%)',
    frame, markedWords, VRAM_WORDS, markedWords * 100 // VRAM_WORDS))
  emu.log(string.format('  디코더 대조 %d 표본 중 %d 일치 (%d%%)',
    verifySamples, verifyOk, rate))
  if not trust then
    emu.log('  ★ 디코더를 믿을 수 없다.  아래 후보 수를 근거로 쓰지 마라.')
  end
  emu.log(string.format('  재구성 cpu %d 워드 · dma %d 워드 (%d 회)',
    cpuWords, dmaWords, dmaRuns))
  if dmaRuns == 0 then
    emu.log('    DMA 가 0 회다.  이 게임이 VRAM-VRAM DMA 를 안 쓰거나, 디코더가 못 본다.')
  end
  emu.log(string.format('  음성 창 %d 개 · %d 프레임', voiceWindows, voiceFrames))
  emu.log(string.format('  19 셀 창 후보 -- STRICT %d 개 · VOICE_SAFE %d 개',
    strict, voice))
  if strict == 0 and voice == 0 then
    emu.log('    ★ 둘 다 0.  이 플레이 범위에서는 고정 주소가 성립하지 않는다.')
    emu.log('      -> allocator 방향이 맞다.  지도로 어느 구간을 노릴지 정하면 된다.')
  elseif strict == 0 then
    emu.log('    STRICT 는 없지만 VOICE_SAFE 가 있다.  자막은 음성 창에만 뜨므로')
    emu.log('    이쪽이 실제 조건이다.  다만 더 긴 플레이로 재확인해야 한다.')
  end
  emu.log('SUB 0.4.56 map:  ' .. MAP)
  emu.log('SUB 0.4.56 free: ' .. FREE)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.56 loaded -- VRAM 점유 지도 · 읽기 전용 · 자막 팩 불필요')
emu.log(string.format('  VRAM %d word · 찾는 창 %d word (19 셀) · 정렬 %d',
                      VRAM_WORDS, NEED_WORDS, ALIGN))
emu.log('  installed: ' .. tostring(installed))
emu.log('  오래 플레이할수록 지도가 촘촘해진다.  끝나면 Stop.')
emu.log('  map:  ' .. MAP)
emu.log('  free: ' .. FREE)
