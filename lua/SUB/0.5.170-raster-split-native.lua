-- 분할선(RCR)이 몇 번째 줄에서 쓰이는가.  0.5.170  ★네이티브 판 전용
--
-- 0.5.19 와 무엇이 다른가
-- -----------------------
-- 0.5.19 는 38 줄에서 **옛 Lua 자막 엔진을 불러온다**:
--
--     dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')
--
-- 그때는 자막을 Lua 가 그렸으니 그게 맞았다.  지금은 디스크·BIOS 가 네이티브로
-- 그리는데, 그 Lua 엔진이 **같은 `$5B80` 과 같은 AC 자리**를 쓴다.  둘이 서로
-- 덮어써서 2026-09-16 에 **자막이 아예 안 떴다** (`AC install #1..#15`).
-- 그 상태로 잰 숫자는 네이티브 판의 것이 아니다.
--
-- 이 판은 **아무것도 안 깐다.**  읽기만 한다.
-- 화면에도 안 그린다 (drawString 은 게임 화면을 가려 판정을 막는다).
--
-- 무엇을 재나
-- -----------
-- VDC 레지스터 6(RCR) 에 쓰는 순간의 **스캔라인**을 적는다.
-- `$FEC4`(우리 게이트) 진입 줄도 같이 적어 짝을 맞춘다.
--
--     화면줄 = RCR - 64
--
-- 판정 (2026-08-29 기록의 지표 그대로)
-- ------------------------------------
--     RCR 이 쓰이는 줄 = 차단 창이 닫히는 줄 + 1      (표본 18 · 예외 0)
--     분할선 = 화면줄 7 · 135 · 148
--
--     ★ 화면줄 **135** 를 어디서 쓰는가가 핵심이다
--         줄 250~262 · 줄 30 대   여유 있음.  정상
--         줄 143~199              ★ 차단 창이 분할선을 덮었다 = 국장실 소환
--
-- 쓰는 법
-- -------
--   1) Mesen 에서 이번 판을 **Power Cycle** 로 띄운다 (BIOS 와 CUE 둘 다 그 폴더)
--   2) 이 파일 **하나만** 연다
--   3) 음성이 나오는 장면을 몇 초 본다 (한 바퀴 돌 필요 없다)
--   4) 600 프레임마다 요약이 찍힌다.  그 숫자만 주시면 된다
--
-- 산출물  C:/snatcher/dump/raster_native_0_5_170_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local GATE = 0xFEC4
local WATCH = 135                -- 우리가 보는 분할선 (화면줄)
local BAD_LO, BAD_HI = 143, 199  -- 이 사이에서 쓰이면 소환

local OUT = 'C:/snatcher/dump/raster_native_0_5_170_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tkind\twrite_line\trcr\tscreen_line\n') end

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

local selReg, rcr = 0, 0
local frame, writes = 0, 0
local pending = {}
local gateLine = -1

-- 통계
local watch_ok, watch_bad, watch_other = 0, 0, 0
local worst = -1
local gate_late = 0              -- 게이트가 줄 30 을 넘어 들어온 프레임

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  if selReg ~= 0x06 then return end
  if port == 2 then
    rcr = (rcr & 0xFF00) | value
  elseif port == 3 then
    rcr = (rcr & 0x00FF) | (value << 8)
    writes = writes + 1
    local at = scanline()
    local screen = (rcr & 0x03FF) - 64
    pending[#pending + 1] = { line = at, rcr = rcr & 0x03FF, screen = screen }
    if screen == WATCH then
      if at >= BAD_LO and at <= BAD_HI then
        watch_bad = watch_bad + 1
        if at > worst then worst = at end
      elseif at >= 0 then
        watch_ok = watch_ok + 1
      end
    else
      watch_other = watch_other + 1
    end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function()
  gateLine = scanline()
  if gateLine > 30 then gate_late = gate_late + 1 end
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local list, g = pending, gateLine
  pending, gateLine = {}, -1
  if out and #list > 0 then
    for _, w in ipairs(list) do
      out:write(string.format('%d\tRCR\t%d\t%d\t%d\n', frame, w.line, w.rcr, w.screen))
    end
    if g >= 0 then out:write(string.format('%d\tGATE\t%d\t-\t-\n', frame, g)) end
    out:flush()
  end
  if frame % 600 == 0 then
    local total = watch_ok + watch_bad
    local rate = total > 0 and (100.0 * watch_bad / total) or 0.0
    emu.log(string.format(
      '0.5.170 %df · RCR 쓰기 %d · 줄%d 예약 %d 건 -- 정상 %d · ★늦음 %d (%.2f%%) · 최악 줄%d',
      frame, writes, WATCH, total, watch_ok, watch_bad, rate, worst))
    emu.log(string.format('        게이트가 줄 30 을 넘어 들어온 프레임 %d', gate_late))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.170-raster-split-native  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log('  0.5.19 는 옛 Lua 엔진을 dofile 해서 네이티브 자막과 다툰다 -- 이 판은 안 한다')
emu.log(string.format('  보는 것: 화면줄 %d 예약을 줄 %d~%d 에서 쓰면 ★소환', WATCH, BAD_LO, BAD_HI))
emu.log('  600 프레임마다 요약.  음성 나오는 장면 몇 초면 된다')
emu.log('  -> ' .. OUT)
