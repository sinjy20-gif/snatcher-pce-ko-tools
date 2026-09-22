-- 국장실 소환을 **직접** 잰다.  0.5.171
--
-- 무엇이 소환인가 (2026-09-03 기록 그대로)
-- ----------------------------------------
-- 그림 창 스크롤 `BYR=96` 은 **줄 32 에서** 쓰여야 한다.  늦게 쓰이면 그 프레임의
-- 화면 위쪽이 **옛 스크롤(BYR=0 · 타일맵 꼭대기 = 천장)** 으로 그려진다.
-- 그 천장에 국장이 매달려 보인다.
--
--     원본 BIOS   BYR=96 쓴 프레임 10,016  ->  줄 32 가 100.00%   예외 0
--     우리        BYR=96 쓴 프레임  5,156  ->  줄 32 가  99.36%
--                                             줄 33~72 로 늦은 것 33 건 (0.64%)
--
-- ★ 원본 대조군이 이미 있다 -- 비교 기준이 있는 몇 안 되는 축이다.
--
-- 왜 0.5.170 을 못 쓰나
-- ---------------------
-- 0.5.170 은 **RCR** 을 쟀다.  그건 옆에서 본 정황이고 소환 그 자체가 아니다.
-- 게다가 빈도가 0.64% 라 "늦음 0" 이 **정상이라는 뜻이 아니라 아직 못 잡았다**는
-- 뜻일 수 있는데 그 구분이 없었다.  여기서는 **표본 수를 같이 찍어** 판정 가능
-- 여부를 먼저 알 수 있게 한다.
--
-- ⚠ 0.5.19 처럼 옛 Lua 엔진을 부르지 않는다.  아무것도 안 깔고 화면에도 안 그린다.
--
-- 쓰는 법
-- -------
--   1) Power Cycle 로 이번 판을 띄운다 (BIOS 와 CUE 둘 다 그 폴더)
--   2) 이 파일 **하나만** 연다
--   3) 자막이 나오는 장면을 돌아다닌다.  표본이 쌓여야 판정이 된다
--   4) 600 프레임마다 요약이 찍힌다
--
-- 읽는 법
-- -------
--     표본 0              아직 판정 불가.  그 장면이 BYR=96 을 안 쓴다
--     늦음 0 · 표본 1000+ 이 구간에서는 안 난다
--     늦음 N (x.xx%)      ★ 소환.  0.64% 근처면 2026-09-03 과 같은 수준
--
-- 산출물  C:/snatcher/dump/byr_summon_0_5_171_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local BYR_REG = 0x08             -- VDC 레지스터 8 = BYR (세로 스크롤)
local WATCH_VALUE = 96           -- 그림 창 스크롤
local ON_TIME = 32               -- 여기서 쓰여야 정상

local OUT = 'C:/snatcher/dump/byr_summon_0_5_171_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\twrite_line\tbyr\n') end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local selReg, byr = 0, 0
local frame = 0
local samples, on_time, late = 0, 0, 0
local worst = -1
local hist = {}                  -- 늦은 줄 분포

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  -- 레지스터 선택만 매번 보고, 나머지는 한 번 비교하고 빠진다 (메센이 안 기어가게)
  if port == 0 then selReg = value return end
  if selReg ~= BYR_REG then return end
  if port == 2 then
    byr = (byr & 0xFF00) | value
    return
  end
  if port ~= 3 then return end
  byr = (byr & 0x00FF) | (value << 8)
  if (byr & 0x01FF) ~= WATCH_VALUE then return end
  local at = scanline()
  if at < 0 then return end
  samples = samples + 1
  if at <= ON_TIME then
    on_time = on_time + 1
  else
    late = late + 1
    if at > worst then worst = at end
    hist[at] = (hist[at] or 0) + 1
  end
  if out then out:write(string.format('%d\t%d\t%d\n', frame, at, byr & 0x01FF)) end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 ~= 0 then return end
  if out then out:flush() end
  if samples == 0 then
    emu.log(string.format('0.5.171 %df · BYR=%d 표본 0 -- ★판정 불가 (그 장면이 안 쓴다)',
                          frame, WATCH_VALUE))
    return
  end
  local rate = 100.0 * late / samples
  emu.log(string.format(
    '0.5.171 %df · BYR=%d 표본 %d · 줄%d 정시 %d (%.2f%%) · ★늦음 %d (%.2f%%) · 최악 줄%d',
    frame, WATCH_VALUE, samples, ON_TIME, on_time, 100.0 - rate, late, rate, worst))
  if late > 0 then
    local parts = {}
    for line, n in pairs(hist) do parts[#parts + 1] = string.format('줄%d×%d', line, n) end
    table.sort(parts)
    emu.log('        늦은 줄 분포: ' .. table.concat(parts, ' '))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.171-byr-summon  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log(string.format('  BYR=%d 를 줄 %d 안에 못 쓰면 화면 위쪽이 천장으로 그려진다 = 소환',
                      WATCH_VALUE, ON_TIME))
emu.log('  원본 BIOS 대조군: 줄 32 가 100.00% · 예외 0 (2026-09-03)')
emu.log('  ★ 표본이 0 이면 판정 불가다 -- 자막 나오는 장면을 돌아다닐 것')
emu.log('  -> ' .. OUT)
