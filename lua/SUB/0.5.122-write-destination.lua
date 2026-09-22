-- SUB 0.5.122 -- 복원의 쓰기가 **실제로 어디로 가는지** 전부 센다 (쓰기 0 B)
--
-- 0.5.121 이 남긴 것
-- ---------------------------------------------------------------------------
--     incr=+1 (cr_hi=00) 로 그림자는 정상
--     restore 0 회        $6600-$6ABF 에 들어간 쓰기가 **하나도 없다**
--     MAWR 설정 목록      1000@21 1000@41 1004@41 1008@42 ...  전부 SATB (wipe)
--     DVSSR 2 회          첫 기입 line 229~247
--
-- 그런데 0.5.115 는 복원 프레임의 VDC 쓰기를 **3,336 회**로 셌다 (정상 프레임 536).
-- 약 2,800 회가 어딘가로 간다.  우리 자리는 아니다.
--
--     ★ control block 은 base=$6600 이라고 말하는데, 그 자리에 안 쓴다.
--       그럼 어디에 쓰는가 -- 그것만 묻는다.
--
-- 0.5.121 이 무엇을 잘랐나 (같은 실수 반복 금지)
-- ---------------------------------------------------------------------------
-- `MAX_SETS_LOGGED = 8` 이라 MAWR 설정을 앞 8 개만 찍었다.  setN 은 9~11 이었고,
-- 복원의 MAWR 설정은 wipe 다음이라 **딱 잘린 자리**에 있었다.
-- 0.5.115 의 SAMPLE_CAP 과 같은 실수다.  이 판은 상한을 64 로 올리고,
-- 넘치면 넘쳤다고 **로그에 명시한다** (조용히 자르지 않는다).
--
-- 무엇을 세나 -- 목적지 전수 분류
-- ---------------------------------------------------------------------------
--     our     [base, base+1216)      control block 이 말하는 자리
--     bat     $0000-$0FFF            타일맵 본체
--     satb    $1000-$10FF            스프라이트 표
--     bg      $1100-$2BBF            0.5.118 이 잰, 이 장면 BG 가 참조하는 자리
--     mid     $2BC0-$65FF            그 사이
--     high    $6AC0-$7FFF            우리 자리 위
--     ★ 각 구간마다 첫/마지막 스캔라인과 min/max 주소를 같이 찍는다
--
-- 그리고 MAWR 설정을 **값과 스캔라인 그대로** 최대 64 개까지 남긴다.
-- 이 층은 그림자 전진과 무관하므로 incr 이 또 틀려도 살아남는다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     our ≈ 1216                복원이 제자리로 간다.  0.5.121 이 뭔가 잘못 본 것
--     high 가 크다              base 위쪽으로 샌다 -- MAWR 이 예상보다 높게 잡혔다
--     bg 가 정상보다 크게 늘었다  ★ 산 자리에 쓴다
--                               ⚠ 게임은 원래 자기 BG 를 쓴다.  정상 프레임 기준선과
--                                 **반드시** 비교할 것 -- 이 판은 기준선도 같이 낸다
--     어디에도 안 몰린다         분류 경계가 틀렸다.  min/max 로 다시 잡을 것
--
-- ★ 기준선을 같이 낸다
--     복원이 아닌 프레임의 구간별 평균을 같이 기록한다.  "복원 프레임에서 늘었나" 는
--     기준선 없이 못 읽는다 (0.5.119 초안이 이걸 빠뜨려 판정이 무의미했다).
--
-- ⚠ 이 판이 못 보는 것
--     DMA(SATB 자동전송·VRAM-VRAM)는 포트를 안 거쳐 안 잡힌다.
--     "쓰기 0" 을 "아무 일 없었다" 로 읽지 말 것.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.121 과 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/write_dest_0_5_122_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local STATE_ADDR = 0x7FDF

local REGION_WORDS = 1216
local BIG_HITS = 4000
local MAX_SETS = 64
local DISPLAY_LAST = 238

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/write_dest_0_5_122_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tbase\texec_hits\tincr\ttotal\t'
       .. 'bat\tsatb\tbg\tmid\tour\thigh\t'
       .. 'top_zone\ttop_n\ttop_lo\ttop_hi\ttop_first_line\ttop_last_line\t'
       .. 'mawr_sets\tsets_truncated\tset_list\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- 구간 정의.  our 는 프레임마다 control block 으로 갱신한다
local ZONES = { 'bat', 'satb', 'bg', 'mid', 'our', 'high' }
local function zoneOf(a, regLo, regHi)
  if regLo >= 0 and a >= regLo and a <= regHi then return 'our' end
  if a <= 0x0FFF then return 'bat' end
  if a <= 0x10FF then return 'satb' end
  if a <= 0x2BBF then return 'bg' end
  if a < (regLo >= 0 and regLo or 0x6600) then return 'mid' end
  return 'high'
end

local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits, total = 0, 0
local z = {}
local setN, sets = 0, {}
local regLo, regHi = -1, -1
local SAMPLE_EVERY = 64

local function resetZones()
  z = {}
  for _, n in ipairs(ZONES) do
    z[n] = { n = 0, lo = -1, hi = -1, first = -1, last = -1 }
  end
end
resetZones()

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if port == 2 then
    if selReg == 0x00 then pendLo = value end
    return
  end
  if selReg == 0x00 then
    mawr = ((value << 8) | pendLo) & 0xFFFF
    setN = setN + 1
    if #sets < MAX_SETS then
      sets[#sets + 1] = string.format('%04X@%d', mawr & 0x7FFF, scanline())
    end
  elseif selReg == 0x05 then
    incr = incrFrom(value)
  elseif selReg == 0x02 then
    local a = mawr & 0x7FFF
    local e = z[zoneOf(a, regLo, regHi)]
    e.n = e.n + 1
    if e.lo < 0 or a < e.lo then e.lo = a end
    if e.hi < 0 or a > e.hi then e.hi = a end
    if e.n == 1 or e.n % SAMPLE_EVERY == 0 then
      local l = scanline()
      if e.first < 0 then e.first = l end
      e.last = l
    end
    total = total + 1
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

-- 기준선 (복원이 아닌 프레임)
local baseN, baseSum = 0, {}
for _, n in ipairs(ZONES) do baseSum[n] = 0 end

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local isRestore = hits >= BIG_HITS

  if isRestore then
    restores = restores + 1
    local base = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)

    -- 가장 많이 몰린 구간
    local topName, top = nil, nil
    for _, n in ipairs(ZONES) do
      if top == nil or z[n].n > top.n then topName, top = n, z[n] end
    end

    local truncated = (setN > MAX_SETS) and ('★' .. (setN - MAX_SETS) .. '개잘림') or 'no'
    out:write(string.format(
      '%d\t복원\t%d\t%04X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%04X\t%04X\t%d\t%d\t%d\t%s\t%s\n',
      frame, rd(STATE_ADDR), base, hits, incr, total,
      z.bat.n, z.satb.n, z.bg.n, z.mid.n, z.our.n, z.high.n,
      topName, top.n, top.lo < 0 and 0 or top.lo, top.hi < 0 and 0 or top.hi,
      top.first, top.last, setN, truncated, table.concat(sets, ' ')))
    out:flush()

    say('0.5.122 f%d base=$%04X 총 %d  bat=%d satb=%d bg=%d mid=%d our=%d high=%d',
        frame, base, total, z.bat.n, z.satb.n, z.bg.n, z.mid.n, z.our.n, z.high.n)
    say('           최다 %s %d회 $%04X-$%04X line %d..%d  · MAWR설정 %d회 (%s)',
        topName, top.n, top.lo < 0 and 0 or top.lo, top.hi < 0 and 0 or top.hi,
        top.first, top.last, setN, truncated)
    if baseN > 0 then
      local parts = {}
      for _, n in ipairs(ZONES) do
        parts[#parts+1] = string.format('%s %d(기준 %.0f)', n, z[n].n, baseSum[n] / baseN)
      end
      say('           기준선 대비: ' .. table.concat(parts, ' · '))
    end
    say('           MAWR: %s', table.concat(sets, ' '))
  else
    baseN = baseN + 1
    for _, n in ipairs(ZONES) do baseSum[n] = baseSum[n] + z[n].n end
  end

  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then regLo, regHi = b, b + REGION_WORDS - 1 else regLo, regHi = -1, -1 end
  hits, total, setN, sets = 0, 0, 0, {}
  resetZones()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.122 끝 -- 복원 %d 회 · 기준선 프레임 %d', restores, baseN)
  if restores == 0 then say('0.5.122 ⚠ 복원을 못 봤다.  판정하지 말 것') end
  say('0.5.122 ⚠ DMA 는 포트를 안 거쳐 안 잡힌다.  "쓰기 0" 을 "아무 일 없었다" 로 읽지 말 것')
  say('0.5.122 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.122-write-destination armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 복원 프레임의 VDC 쓰기 약 2,800 회가 어느 VRAM 구간으로 가는가')
say('  기준선(복원 아닌 프레임)을 같이 내므로 "늘었는지" 를 읽을 수 있다')
say('  덤프 : ' .. PATH)
