-- SUB 0.4.70-when -- **언제** 쓰는가 · 게임이 그 자리에 다시 그리는가 (쓰기 0)
--
-- ── 두 가지를 한 번에 잰다 ───────────────────────────────────────────────
--
-- 【A】 글리프 업로드가 화면 그리는 구간에 걸치는가
--
--   지금까지의 감시는 전부 "무엇을 썼나" 를 봤다.  값은 다 정상이었다.
--   한 번도 안 본 것이 **"언제 썼나"** 다.
--
--   계산상 우리 업로드는 조각당
--       글리프 19 × (AC→stage 64 B + stage→VDC 128 B) = 3,648 B ≈ 22,000 사이클
--   인데 PC엔진 vblank 는 약 10,000 사이클이다.  **두 배가 넘는다.**
--
--   게다가 HuC6280 의 블록전송(TIA)은 인터럽트를 못 받는다.  128 B 전송 하나가
--   약 785 사이클 ≈ 1.7 스캔라인 동안 IRQ 를 막는다.  스내처는 그림 창을 만들려고
--   래스터 분할 IRQ 를 쓰므로, 그게 늦어지면 스크롤이 엉뚱한 줄에서 바뀐다
--   -> 그림 창이 밀리고 매 프레임 밀린 정도가 달라 **덜덜 떨린다.**
--
--   0.4.69 가 아무것도 못 잡은 것도 이것과 맞는다.  게임은 **올바른 값을 올바른
--   레지스터에** 쓴다.  다만 잘못된 시각에 쓴다.  값 감시로는 안 잡힌다.
--
--   -> 업로드 시작/끝의 스캔라인을 찍는다.  화면 구간에 걸치면 가설 확정.
--
-- 【B】 우리가 쓰고 나간 자리에 게임이 다시 그리는가
--
--   "빌린 자리를 깨끗이 비워주면 게임이 알아서 다시 그릴 것" 이라는 생각을
--   확인한다.  그러려면 게임이 그 VRAM 을 **다시 로드**해야 한다.
--
--   음성이 끝난 뒤에도 그 블록 범위를 계속 지켜본다.
--     게임이 쓴다   -> 다시 그린다.  비우기만 해도 안전하다
--     안 쓴다       -> VRAM 에 남아 있다고 믿는다.  비우면 구멍이 남는다
--
--   VDC 포트를 디코드해 MAWR 기반 워드쓰기와 DMA 목적지를 재구성한다
--   (VRAM-key-map 과 같은 방식).
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드 (안에서 0.4.64 를 부른다)
--     국장실처럼 떨리는 장면 + 초상화가 바뀌는 장면을 지난다
--     dump/when_0_4_70_<시각>.tsv

-- Wrapper가 지정하면 같은 시간 측정을 다른 정상 자막 경로 위에서도 수행한다.
-- 기본값은 기존 0.4.64를 유지한다.
local CHILD = rawget(_G, 'SUB_WHEN_CHILD') or
              'C:/snatcher/lua/SUB/0.4.64-fixedbase.lua'
dofile(CHILD)

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENGINE     = 0x5B80
local COUNT_OK   = ENGINE + 118
local GLYPH_DONE = ENGINE + 289
local VRAM_LO, VRAM_HI = 144, 146
local NEED = 19 * 0x40
local VDC_LO, VDC_HI = 0x0000, 0x03FF
local WATCH_FRAMES = 600               -- 음성이 끝난 뒤 이만큼 더 지켜본다

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/when_0_4_70_' .. stamp .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('kind\tkey\tbase\tstart_line\tend_line\tspan\tredraw_frames\tredraw_words\n')
  out:flush()
end

-- ── 스캔라인 읽기 -- Mesen 의 키 이름을 모르므로 후보를 훑어 찾는다 ────────
local LINE_KEY = nil
local function findLineKey()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return end
  local cands = {}
  for k, v in pairs(s) do
    if type(v) == 'number' then
      local lk = k:lower()
      if lk:find('scanline') or lk:find('vcounter') or lk:find('vpos')
         or lk:find('.line') or lk:find('row') then
        cands[#cands + 1] = k
      end
    end
  end
  table.sort(cands)
  for _, k in ipairs(cands) do
    emu.log('  스캔라인 후보: ' .. k .. ' = ' .. tostring(s[k]))
  end
  -- 가장 그럴듯한 것 하나를 고른다.
  for _, want in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
    if type(s[want]) == 'number' then return want end
  end
  return cands[1]
end

local function line()
  if not LINE_KEY then return -1 end
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- ── VDC 쓰기 디코더 (게임이 VRAM 어디에 쓰는지) ──────────────────────────
local selReg, mawr, desr, lenr = 0, 0, 0, 0
local inEngine = false
local used = {}                        -- base -> {frames=0, words=0, key=..}

local function gameWrote(w)
  if inEngine then return end          -- 우리 쓰기는 제외
  for base, rec in pairs(used) do
    if w >= base and w < base + NEED then
      rec.words = rec.words + 1
      if rec.redrawAt == nil then rec.redrawAt = rec.age end
    end
  end
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if port == 2 then
    if selReg == 0x00 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x11 then desr = (desr & 0xFF00) | value
    elseif selReg == 0x12 then lenr = (lenr & 0xFF00) | value end
    return
  end
  if port ~= 3 then return end
  if selReg == 0x00 then
    mawr = (mawr & 0x00FF) | (value << 8)
  elseif selReg == 0x02 then
    gameWrote(mawr & 0x7FFF)
    mawr = (mawr + 1) & 0xFFFF
  elseif selReg == 0x11 then
    desr = (desr & 0x00FF) | (value << 8)
  elseif selReg == 0x12 then
    lenr = (lenr & 0x00FF) | (value << 8)
    local dst = desr & 0x7FFF
    for i = 0, lenr do gameWrote((dst + i) & 0x7FFF) end
  end
end, emu.callbackType.write, VDC_LO, VDC_HI, CPU, MEM)

-- ── 【A】 업로드 구간의 스캔라인 ──────────────────────────────────────────
local pending, spans, worst = nil, 0, 0

-- 【C】 쓰기 직전에 그 자리가 **지금 화면에 쓰이고 있는가**
--
-- 순서는 이렇다:  초상화를 그린다 -> 음성 재생 -> 우리 자막.
-- 그러면 우리가 쓰는 순간 그 초상화는 이미 화면에 있다.  "나중에 다시 그리나"
-- 보다 앞선 질문은 **지금 떠 있는 것을 덮고 있지 않은가** 다.
--
-- 업로드 직전에 BAT 와 SATB 가 우리 블록을 가리키는지 직접 본다.
local VRAM_MT = emu.memType.pceVideoRam
local function rwv(w)
  local at = w * 2
  return (emu.read(at, VRAM_MT) or 0) | ((emu.read(at + 1, VRAM_MT) or 0) << 8)
end

local function liveRefs(base)
  local sprites, tiles = 0, 0
  for slot = 0, 63 do
    local at = 0x1000 + slot * 4
    local y, x = rwv(at), rwv(at + 1)
    local pattern, attr = rwv(at + 2), rwv(at + 3)
    if not (y == 0 and x == 0 and pattern == 0 and attr == 0) then
      local first = (pattern & 0x07FF) << 5
      local wide = ((attr & 0x0100) ~= 0) and 2 or 1
      local hc = (attr >> 12) & 0x03
      local tall = (hc == 0) and 1 or ((hc == 1) and 2 or 4)
      local last = first + wide * tall * 0x40 - 1
      if last >= base and first < base + NEED then sprites = sprites + 1 end
    end
  end
  for i = 0, 4095 do                   -- BAT 64x64 기준.  넓으면 일부만 본다
    local t = (rwv(i) & 0x07FF) * 0x10
    if t >= base and t < base + NEED then tiles = tiles + 1 end
  end
  return sprites, tiles
end

local liveHits = 0

emu.addMemoryCallback(function()
  inEngine = true
  local base = (emu.read(ENGINE + VRAM_LO, MEM) or 0) |
               ((emu.read(ENGINE + VRAM_HI, MEM) or 0) << 8)
  local sp, tl = liveRefs(base)
  if sp > 0 or tl > 0 then
    liveHits = liveHits + 1
    emu.log(string.format(
      'SUB 0.4.70 ★★ base $%04X 를 덮으려는데 **지금 화면이 쓰고 있다** · 스프라이트 %d · BG타일 %d',
      base, sp, tl))
    if out then
      out:write(string.format('live\t-\t%04X\t-\t-\t-\tsprite=%d\ttile=%d\n', base, sp, tl))
      out:flush()
    end
  end
  pending = { base = base, start = line() }
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addMemoryCallback(function()
  inEngine = false
  if not pending then return end
  local e = line()
  local s = pending.start
  local span = (s >= 0 and e >= 0) and (e - s) or -1
  if span > worst then worst = span end
  spans = spans + 1
  if out then
    out:write(string.format('upload\t-\t%04X\t%d\t%d\t%d\t-\t-\n',
                            pending.base, s, e, span))
    out:flush()
  end
  if spans <= 12 then
    emu.log(string.format('SUB 0.4.70 업로드 base $%04X · 스캔라인 %d → %d (%d줄)',
                          pending.base, s, e, span))
  end
  -- 【B】 이 블록을 이제부터 지켜본다.
  if used[pending.base] == nil then
    used[pending.base] = { age = 0, words = 0, redrawAt = nil }
  else
    used[pending.base].age = 0
  end
  pending = nil
end, emu.callbackType.exec, GLYPH_DONE, GLYPH_DONE, CPU, MEM)

-- ── 【B】 정리와 보고 ────────────────────────────────────────────────────
local redrawn, notRedrawn = 0, 0

emu.addEventCallback(function()
  for base, rec in pairs(used) do
    rec.age = rec.age + 1
    if rec.age >= WATCH_FRAMES then
      if rec.words > 0 then redrawn = redrawn + 1 else notRedrawn = notRedrawn + 1 end
      if out then
        out:write(string.format('redraw\t-\t%04X\t-\t-\t-\t%s\t%d\n',
          base, rec.redrawAt and tostring(rec.redrawAt) or '없음', rec.words))
        out:flush()
      end
      emu.log(string.format('SUB 0.4.70 %s base $%04X · %d프레임 관찰 · 게임 쓰기 %d word%s',
        rec.words > 0 and '↻ 다시 그림' or '✗ 안 그림', base, WATCH_FRAMES, rec.words,
        rec.redrawAt and (' · 처음 +' .. rec.redrawAt .. 'f') or ''))
      used[base] = nil
    end
  end

  emu.drawString(4, 94, string.format('0.4.70 업로드 %d (최대 %d줄)  산자리덮음 %d  다시그림 %d/%d',
                 spans, worst, liveHits, redrawn, notRedrawn),
                 (liveHits > 0 or worst > 8) and 0xFF8080 or 0xC0C0FF, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close(); out = nil end
  emu.log(string.format('SUB 0.4.70 끝 -- 업로드 %d회 · 가장 긴 구간 %d 스캔라인', spans, worst))
  emu.log(string.format('  블록 관찰: 게임이 다시 그림 %d · 안 그림 %d', redrawn, notRedrawn))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

LINE_KEY = findLineKey()
emu.log('SUB 0.4.70-when armed -- 언제 쓰는가 + 게임이 다시 그리는가 (쓰기 0)')
emu.log('  스캔라인 키: ' .. tostring(LINE_KEY))
emu.log('  【A】 업로드가 여러 스캔라인에 걸치면 화면 구간을 침범한 것이다')
emu.log(string.format('  【B】 음성 뒤 %d프레임 동안 그 블록에 게임이 쓰는지 본다', WATCH_FRAMES))
emu.log('  ' .. OUT)
