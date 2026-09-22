-- SUB 0.5.156 -- 한 프레임 안의 스크롤 쓰기를 스캔라인까지 찍는다  ★네이티브용 (쓰기 0 B)
--
-- 0.4.96 에서 무엇이 바뀌었나
-- ---------------------------------------------------------------------------
-- `0.4.96` 은 머리에서 08-29 시절 Lua 자막 체인을 `dofile` 하고 그 전역
-- `SUB_REARM_INFO` 에서 엔진 오프셋을 얻었다.  지금 빌드(0.4.6.72)는
-- `lua_required = False` 인 완전 네이티브라 옛 세대를 겹치면 판정을 망친다.
--
--     dofile 제거 · 오프셋은 현행 렌더러 JSON 에서 직접 박는다
--     build/cutscene_subs/engine_ac_lua_frame_rearm_A9722A5F_6600.json
--       engine_bytes 666 · count_ok 130 · blank 665  (blank 은 0.4.6.71 이 넣은 것)
--     ⚠ 옛 값 118 을 쓰면 안 된다 -- 그 시절 오프셋이다
--
-- 무엇을 보려는가 -- 국장실 뒷화면 소환 (천장의 국장)
-- ---------------------------------------------------------------------------
-- `0.5.155` 로 분할 예약(RCR)은 **멀쩡함**이 확인됐다.
-- 6,331 프레임 중 늦은 것이 16 건뿐이고 화면줄 135 는 줄32 에 예약된다
-- (문서 기준 38~39 보다도 이르다).  게이트 진입도 줄13~25 로 정상이다.
--
--     -> "차단 창이 분할선을 밀어낸다" 가설은 **지지되지 않는다**
--     -> 게다가 소환은 **지속**된다.  간헐적 IRQ 놓침으로는 설명이 안 된다
--
-- 그러면 남는 것은 **스크롤 값 자체**다.  0.4.96 머리말이 이미 적어놨다:
--
--     정상 프레임   line  12  BYR=0     line 152  BYR=96   (그림 창 / 아래 띠)
--     이상 프레임   line  12  BYR=0                        <- 아래 띠 복원이 없다
--                   -> 아래쪽이 위쪽 띠의 스크롤을 그대로 물고 감긴다
--                   -> 타일맵의 다른 부분(천장의 인물)이 아래에 나온다
--
-- ★ 판정: line 152 근처의 `BYR=96` 쓰기가 있는가, 없는가.
--   매 프레임 빠지면 계속 밀려 있는 지금 증상과 정확히 맞는다.
--
-- 무엇을 찍나
-- ---------------------------------------------------------------------------
--     BXR($07) · BYR($08) 쓰기마다  (스캔라인, 레지스터, 값)
--     엔진 프레임(count_ok 실행)과 **바로 앞 정상 프레임**을 나란히 낸다
--
-- 앞 프레임이 대조군이라 "이 장면은 원래 이렇다" 와 "이 프레임만 다르다" 가 갈린다.
--
-- ★ 스캔라인을 못 얻으면 line=-1 로 찍힌다.  그때는 순서만 보고 판정한다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 자막 몇 개를 흘린다.

-- ★ 현행 렌더러 오프셋 (engine_ac_lua_frame_rearm_A9722A5F_6600.json)
local ENGINE_LO = 0x5B80
local COUNT_OK = ENGINE_LO + 130

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/scroll_trace_0_5_156_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tkind\tkey\tseq\tline\treg\tvalue\n') end

-- 스캔라인 키 이름은 코어 판마다 다르다.  한 번만 찾아 기억한다 (0.4.70 방식).
local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local selReg = 0
local trace = {}          -- 이 프레임의 쓰기들
local MAXT = 32

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
    return
  end
  if selReg ~= 0x07 and selReg ~= 0x08 then return end
  if #trace >= MAXT then return end
  trace[#trace + 1] = {
    line = scanline(),
    reg = (selReg == 0x07) and 'BXR' or 'BYR',
    half = (port == 2) and 'lo' or 'hi',
    value = value,
  }
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local engineFrame = false
emu.addMemoryCallback(function() engineFrame = true end,
  emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

local function render(t)
  local parts = {}
  for i, w in ipairs(t) do
    parts[#parts + 1] = string.format('%d:%s%s=%d', w.line, w.reg, w.half, w.value)
  end
  return (#parts > 0) and table.concat(parts, ' ') or '(없음)'
end

local function dump(frame, kind, t)
  if not out then return end
  for i, w in ipairs(t) do
    out:write(string.format('%d\t%s\t%s\t%d\t%d\t%s%s\t%d\n',
                            frame, kind, curKey, i, w.line, w.reg, w.half, w.value))
  end
  out:flush()
end

local frame, shots = 0, 0
local prevTrace, prevFrame = {}, 0

emu.addEventCallback(function()
  frame = frame + 1
  local t = trace
  trace = {}

  if engineFrame then
    engineFrame = false
    shots = shots + 1
    prevLog(string.format('SUB 0.5.156 ── 엔진 프레임 %d · KEY %s ──', frame, curKey))
    prevLog(string.format('  앞 프레임 %d (%2d회) %s', prevFrame, #prevTrace,
                          render(prevTrace)))
    prevLog(string.format('  엔진 프레임 %d (%2d회) %s', frame, #t, render(t)))
    dump(prevFrame, 'before', prevTrace)
    dump(frame, 'engine', t)
  end

  prevTrace, prevFrame = t, frame

  emu.drawString(4, 64, string.format('0.5.156 엔진프레임 %d · 이번 프레임 스크롤쓰기 %d · line키 %s',
                 shots, #t, tostring(LINE_KEY)), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.5.156-scroll-trace armed -- 엔진 프레임과 바로 앞 프레임을 나란히 찍는다')
prevLog('  BXR/BYR 쓰기마다 (스캔라인, 레지스터, 값)')
prevLog('  로그: ' .. OUT)
