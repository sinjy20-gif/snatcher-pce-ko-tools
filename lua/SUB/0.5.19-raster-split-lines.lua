-- SUB 0.5.19 -- 분할선이 몇 번째 줄인가.  우리 차단 구간이 그것을 덮는가 (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.5.18 로 창에 **렌더만** 남겨도 증상이 났다.  렌더는 ~15 스캔라인뿐이다.
--
--     -> 총 시간이 문제가 아니다.  **차단 구간이 분할선을 덮느냐**가 문제다
--     -> 짧게 만드는 것만으로는 못 고친다
--
-- 그러면 다음 질문은 하나다: **분할선이 어디인가.**
-- 게이트는 line 21~25 에 불린다 (0.5.8).  렌더 ~15 줄이면 차단은 대략 21~40.
-- 그 구간이 분할선을 덮는지 숫자로 확인되면 "얼마나 옮겨야 하는지" 가 나온다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     RCR($06) 에 쓰이는 값        = 래스터 인터럽트가 걸릴 스캔라인
--     그 값이 프레임마다 몇 개인가  = 화면을 몇 조각으로 나누는가
--     쓰이는 시점의 스캔라인        = 언제 다음 분할을 예약하는가
--     게이트 진입 스캔라인          = 우리 차단이 시작되는 곳
--
-- HuC6270 의 RCR 은 "이 줄에서 IRQ" 를 지정한다.  실제 화면 줄은 보통
-- `RCR - 64` 로 읽는다 (레지스터가 64 오프셋을 쓴다).  둘 다 찍는다.
--
-- 읽는 법
--     분할선이 21~40 안에 있으면   우리 차단이 그것을 덮는다 -> 원인 확정
--     분할선이 그 밖이면            차단 위치를 옮기는 것만으로는 안 된다.
--                                   다른 설명을 찾아야 한다
--
-- ★ RCR 쓰기가 0 이면 판정하지 말 것.
-- 자막 체인을 같이 올려 게이트 진입 줄도 같이 본다.  읽기 전용이다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 대사를 흘린다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local GATE = 0xFEC4

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/raster_lines_0_5_19_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tkind\twrite_line\trcr\tscreen_line\n') end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local selReg, rcr = 0, 0
local writes, frame = 0, 0
local perFrame = {}          -- 이 프레임에 예약된 분할선들
local seen = {}              -- (예약줄) -> 횟수
local gateLine = -1

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if selReg ~= 0x06 then return end
  if port == 2 then rcr = (rcr & 0xFF00) | value
  elseif port == 3 then
    rcr = (rcr & 0x00FF) | (value << 8)
    writes = writes + 1
    local wl = scanline()
    local screen = (rcr & 0x03FF) - 64
    perFrame[#perFrame + 1] = { line = wl, rcr = rcr & 0x03FF, screen = screen }
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() gateLine = scanline() end,
  emu.callbackType.exec, GATE, GATE, CPU, MEM)

local reported = 0

emu.addEventCallback(function()
  frame = frame + 1
  local list, g = perFrame, gateLine
  perFrame, gateLine = {}, -1

  if #list > 0 then
    -- 같은 조합은 몇 번만 찍는다
    local parts = {}
    for _, w in ipairs(list) do
      parts[#parts + 1] = string.format('%d(줄%d)', w.screen, w.line)
    end
    local sig = table.concat(parts, ' ')
    seen[sig] = (seen[sig] or 0) + 1
    if seen[sig] <= 3 then
      reported = reported + 1
      emu.log(string.format('SUB 0.5.19 %df · gate line %d · 분할 예약 %d개 · %s',
                            frame, g, #list, sig))
      emu.log('   (형식: 화면줄(예약된시점줄).  화면줄 = RCR - 64)')
    end
    if out then
      for _, w in ipairs(list) do
        out:write(string.format('%d\tRCR\t%d\t%d\t%d\n', frame, w.line, w.rcr, w.screen))
      end
      if g >= 0 then out:write(string.format('%d\tGATE\t%d\t-\t-\n', frame, g)) end
      out:flush()
    end
  end

  emu.drawString(4, 84, string.format('0.5.19 RCR 쓰기 %d · 보고 %d · line키 %s',
                 writes, reported, tostring(LINE_KEY)),
                 writes > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.19-raster-split-lines armed -- 분할선(RCR)과 게이트 진입 줄을 잰다')
emu.log('  ★ RCR 쓰기 0 이면 판정 불가')
emu.log('  로그: ' .. OUT)
