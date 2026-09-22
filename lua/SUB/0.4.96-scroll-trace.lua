-- SUB 0.4.96 -- 한 프레임 안의 스크롤 쓰기를 스캔라인까지 그대로 찍는다 (쓰기 0 B)
--
-- 왜 횟수로는 부족한가
-- ---------------------------------------------------------------------------
-- 0.4.94/0.4.95 는 프레임당 BXR/BYR **횟수**를 셌고, 음성 첫 조각 프레임에서
-- BYR·BXR·RCR·CR 이 나란히 하나씩 줄었다.  하지만 화면이 무엇을 보여줄지는
-- 횟수가 아니라 **어느 스캔라인에 얼마를 썼는가** 가 정한다.
--
--     정상 프레임   line  12  BYR=0      line 152  BYR=96   (그림 창 / 아래 띠)
--     이상 프레임   line  12  BYR=0                          <- 아래 띠 복원이 없다
--                   -> 아래쪽이 위쪽 띠의 스크롤을 그대로 물고 감긴다
--                   -> 타일맵의 다른 부분(천장의 인물)이 아래에 나온다
--
-- 그 시퀀스를 그대로 찍으면 "어느 쓰기가 빠졌나" 와 "그래서 화면이 어디를
-- 가리켰나" 가 추측 없이 나온다.  눈으로 본 상관("엔진 숫자 올라갈 때마다
-- 뒷 그림이 나오는 것 같은데 완벽히 일치는 아니다")을 프레임 단위 자료로
-- 바꾸는 것이 이 판의 목적이다.
--
-- 무엇을 찍나
-- ---------------------------------------------------------------------------
--     BXR($07) · BYR($08) 쓰기마다  (스캔라인, 레지스터, 값)
--     엔진 프레임(count_ok 실행)과 **바로 앞 정상 프레임**을 나란히 낸다
--
-- 앞 프레임을 같이 내는 것이 핵심이다.  같은 장면의 정상 프레임이 대조군이라
-- "이 장면은 원래 이렇다" 와 "이 프레임만 다르다" 를 그 자리에서 가른다.
--
-- ★ 스캔라인을 못 얻으면 line=-1 로 찍힌다.  그때는 순서만 보고 판정한다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 자막 몇 개를 흘린다.

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local info = rawget(_G, 'SUB_REARM_INFO')
local ENGINE_LO = info and info.engine_lo or 0x5B80
local COUNT_OK = ENGINE_LO + (info and info.offsets.count_ok or 118)

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/scroll_trace_0_4_96_' .. STAMP .. '.tsv'
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
    prevLog(string.format('SUB 0.4.96 ── 엔진 프레임 %d · KEY %s ──', frame, curKey))
    prevLog(string.format('  앞 프레임 %d (%2d회) %s', prevFrame, #prevTrace,
                          render(prevTrace)))
    prevLog(string.format('  엔진 프레임 %d (%2d회) %s', frame, #t, render(t)))
    dump(prevFrame, 'before', prevTrace)
    dump(frame, 'engine', t)
  end

  prevTrace, prevFrame = t, frame

  emu.drawString(4, 64, string.format('0.4.96 엔진프레임 %d · 이번 프레임 스크롤쓰기 %d · line키 %s',
                 shots, #t, tostring(LINE_KEY)), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.4.96-scroll-trace armed -- 엔진 프레임과 바로 앞 프레임을 나란히 찍는다')
prevLog('  BXR/BYR 쓰기마다 (스캔라인, 레지스터, 값)')
prevLog('  로그: ' .. OUT)
