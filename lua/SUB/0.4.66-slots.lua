-- SUB 0.4.66-slots -- 스프라이트 슬롯 감시.  읽기 전용 (쓰기 0)
--
-- ── 왜 만들었나 ──────────────────────────────────────────────────────────
--
-- 0.4.65-verify 가 이 세션의 전제를 무너뜨렸다:
--
--     배치 13번 전부 · 업로드 후 90프레임 동안 블록 1 word 도 안 변함
--     침범 0 · 미업로드 0
--
-- 게임은 우리 VRAM 을 **가져가지 않는다.**  그런데 화면은 깨진다.
-- 그러면 깨지는 것은 글리프 패턴이 아니라 **스프라이트 쪽**이다.
--
-- 유력한 후보는 슬롯 예산이다.  옛 인계서에 이렇게 적혀 있다:
--
--     $601E  LDA #$3F / STA $17     ★ $17 = 전역 슬롯 예산 63
--
-- 스프라이트 슬롯은 64 개가 전부고, 게임이 먼저 쓰고 남은 것을 우리가 쓴다.
-- 장면이 진행되면 초상화가 1 -> 2 -> 3 개로 늘어난다.  그만큼 슬롯이 줄어든다.
-- "앞 세 문장은 완벽한데 그 뒤부터 깨진다" 가 이것으로 설명된다.
--
-- ── 무엇을 재나 ──────────────────────────────────────────────────────────
--
-- count_ok 시점에 base 와 기대 글자수(engine+344 = count)를 잡아 두고,
-- SATB DMA 가 반영되는 몇 프레임 뒤에 실제 SATB 를 훑어 셋으로 가른다.
--
--     ours   패턴 주소가 우리 블록 안 -> 우리 자막 글자
--     game   그 밖의 활성 스프라이트   -> 게임 것
--     free   빈 슬롯
--
-- `ours < 기대` 면 우리 글자가 슬롯을 못 얻은 것이다.  그게 화면에서
-- 빠지거나 엉뚱하게 그려지는 정체다.
--
-- VRAM 쪽도 같이 본다.  0.4.65 는 배치 3 프레임 뒤에 지문을 떠서 그 이전에
-- 깨진 경우를 못 봤다.  여기서는 **1 프레임**에 뜬다.
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드 (안에서 0.4.64 를 부른다)
--     dump/slots_0_4_66_<시각>.tsv
--
-- 화면 아래: `0.4.66 배치 N  슬롯부족 N  최소여유 N`

dofile('C:/snatcher/lua/SUB/0.4.64-fixedbase.lua')

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.cpuType.pce

local ENGINE   = 0x5B80
local COUNT_OK = ENGINE + 118
local SELECTOR = ENGINE + 345
local COUNT_AT = ENGINE + 344          -- 엔진이 밀 스프라이트 개수
local VRAM_LO, VRAM_HI = 144, 146

local NEED = 19 * 0x40
local SAMPLES = 64
local STEP = NEED // SAMPLES
local SATB_WORD = 0x1000               -- 지금까지 모든 판이 쓴 값 (SATB 본체)
local CHECK_AT = 2                     -- SATB DMA 가 반영되는 데 필요한 프레임
local CAPTURE_AT = 1                   -- VRAM 지문은 1 프레임에 (0.4.65 는 3)

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/slots_0_4_66_' .. stamp .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('key\tbase\texpect\tours\tgame\tfree\tourY\tonline\tpeak\tvram\tnote\n')
  out:flush()
end

local function rw(w)
  local at = w * 2
  return (emu.read(at, VRAM) or 0) | ((emu.read(at + 1, VRAM) or 0) << 8)
end

local function keyHex()
  local t = {}
  for i = 0, 5 do
    t[i + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0)
  end
  return table.concat(t)
end

local function fingerprint(base)
  local t = {}
  for i = 0, SAMPLES - 1 do t[i + 1] = rw(base + i * STEP) end
  return t
end

-- SATB 를 훑어 우리 것 / 게임 것 / 빈 칸으로 가른다.
--
-- ★ 스캔라인 압력도 같이 잰다.
--
-- PC엔진 VDC 는 **스캔라인당 스프라이트 16 개**가 한계다.  넘으면 초과분이
-- 그려지지 않고 깜빡인다.  그런데 자막 한 줄은 19 글자가 **같은 높이**에
-- 놓이므로 그것만으로 이미 3 개 초과다.  초상화가 같은 높이에 걸치면 더하다.
--
-- "화면이 덜덜 떨린다 · 자막이 사라질 때 잔상" 이 이 한 증상의 두 얼굴일 수
-- 있다.  그래서 우리 줄이 놓인 스캔라인의 스프라이트 수를 직접 센다.
local function census(base)
  local ours, game, free = 0, 0, 0
  local rows = {}                      -- y -> 그 줄에 걸친 스프라이트 수
  local ourY = nil

  for slot = 0, 63 do
    local at = SATB_WORD + slot * 4
    local y, x = rw(at), rw(at + 1)
    local pattern, attr = rw(at + 2), rw(at + 3)
    if y == 0 and x == 0 and pattern == 0 and attr == 0 then
      free = free + 1
    else
      local first = (pattern & 0x07FF) << 5
      local mine = first >= base and first < base + NEED
      if mine then
        ours = ours + 1
        ourY = ourY or y
      else
        game = game + 1
      end
      -- 스프라이트가 덮는 세로 범위.  attr 비트 12-13 이 높이다.
      local hcode = (attr >> 12) & 0x03
      local tall = (hcode == 0) and 16 or ((hcode == 1) and 32 or 64)
      for line = y, y + tall - 1 do
        rows[line] = (rows[line] or 0) + 1
      end
    end
  end

  local peak, peakLine = 0, 0
  for line, n in pairs(rows) do
    if n > peak then peak, peakLine = n, line end
  end
  local onOurLine = (ourY and rows[ourY]) or 0
  return ours, game, free, peak, peakLine, onOurLine, ourY
end

local watch = nil
local placed, starved, vramBad, overLine = 0, 0, 0, 0
local minFree = 64

emu.addMemoryCallback(function()
  local base = (emu.read(ENGINE + VRAM_LO, MEM) or 0) |
               ((emu.read(ENGINE + VRAM_HI, MEM) or 0) << 8)
  watch = {
    base = base,
    key = keyHex(),
    expect = emu.read(COUNT_AT, MEM) or 0,
    age = 0,
    fp = nil,
    vram = '-',
  }
  placed = placed + 1
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  local w = watch
  if w then
    w.age = w.age + 1

    if w.age == CAPTURE_AT then
      w.fp = fingerprint(w.base)
      local nz = 0
      for i = 1, SAMPLES do if w.fp[i] ~= 0 then nz = nz + 1 end end
      if nz == 0 then w.vram = '전부0' end
    elseif w.fp and w.vram == '-' then
      for i = 1, SAMPLES do
        if rw(w.base + (i - 1) * STEP) ~= w.fp[i] then
          w.vram = string.format('변함+%df', w.age)
          vramBad = vramBad + 1
          break
        end
      end
    end

    if w.age == CHECK_AT then
      local ours, game, free, peak, peakLine, onOurLine, ourY = census(w.base)
      if free < minFree then minFree = free end
      local note = {}
      if ours < w.expect then
        starved = starved + 1
        note[#note + 1] = string.format('슬롯부족 %d/%d', ours, w.expect)
      end
      if onOurLine > 16 then
        overLine = overLine + 1
        note[#note + 1] = string.format('자막줄 %d개 (한계 16)', onOurLine)
      end
      if #note > 0 then
        emu.log(string.format(
          'SUB 0.4.66 ★ %s base $%04X · %s · 우리 %d/%d 게임 %d 빈칸 %d · 최다줄 %d개@y%d',
          w.key, w.base, table.concat(note, ' · '), ours, w.expect, game, free,
          peak, peakLine))
      end
      if out then
        out:write(string.format('%s\t%04X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n',
          w.key, w.base, w.expect, ours, game, free,
          ourY or -1, onOurLine, peak, w.vram, table.concat(note, ' ')))
        out:flush()
      end
      w.reported = true
    end

    if w.age > 90 then watch = nil end
  end

  emu.drawString(4, 64, string.format('0.4.66 배치 %d  슬롯부족 %d  줄초과 %d  VRAM변함 %d  최소빈칸 %d',
                 placed, starved, overLine, vramBad, minFree),
                 (starved > 0 or vramBad > 0 or overLine > 0) and 0xFF6060 or 0x60FF60, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close(); out = nil end
  emu.log(string.format('SUB 0.4.66 끝 -- 배치 %d · 슬롯부족 %d · 줄초과 %d · VRAM변함 %d · 최소 빈칸 %d',
                        placed, starved, overLine, vramBad, minFree))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.66-slots armed -- 스프라이트 슬롯 감시 (쓰기 0)')
emu.log(string.format('  count_ok 뒤 %d프레임에 SATB 64슬롯을 우리/게임/빈칸으로 가른다', CHECK_AT))
emu.log(string.format('  VRAM 지문은 %d프레임에 뜬다 (0.4.65 의 3프레임 사각을 메운다)', CAPTURE_AT))
emu.log('  우리 글자가 기대보다 적게 슬롯을 얻으면 ★ 로 찍힌다')
emu.log('  ' .. OUT)
