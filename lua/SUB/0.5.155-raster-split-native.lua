-- SUB 0.5.155 -- 분할선(RCR)과 게이트 진입 줄을 잰다  ★네이티브 빌드용 (쓰기 0 B)
--
-- 0.5.19 에서 무엇이 바뀌었나
-- ---------------------------------------------------------------------------
-- `0.5.19` 는 머리에서 `dofile('.../0.4.89-vdc-rearm.lua')` 로 **08-29 시절 Lua
-- 자막 체인**을 같이 올렸다.  그때는 Lua 가 자막을 그려야 했기 때문이다.
--
-- 지금 빌드(0.4.6.72)는 `lua_required = False` 인 완전 네이티브다.
-- 옛 세대를 겹쳐 올리면 **세대 혼합**이 되고(옛 12-hex 표 vs 현행 이름형 표),
-- 없던 깨짐이 생겨 판정을 망친다.  그래서 그 한 줄만 뺐다.
--
--     측정부는 체인과 무관하다 -- GATE($FEC4)는 네이티브 빌드에도 그대로 있고
--     (build_snatcher_0_4_6_29_native_arm 이 패치한다), RCR 은 VDC 만 본다
--
-- 왜 재나
-- ---------------------------------------------------------------------------
-- 국장실 뒷화면 소환(천장의 국장)이 재발했다.  **오버클록하면 사라진다** ->
-- 논리가 아니라 **마감 시간(사이클 예산)** 문제다.  0.4.6.68 에서도 나오므로
-- 09-03 작업(.69~.72)은 무죄다.
--
-- 옛 이력이 지표를 정해뒀다 (ENV_B_20260830_START_HERE §1-1):
--
--     RCR 이 쓰이는 줄 = 차단 창이 닫히는 줄 + 1     표본 18 · 예외 0
--     분할선 = 화면줄 7 · 135 · 148
--     차단 있을 때  창 120~174 -> 135 를 줄143~199 에 쓴다   ★ 넘긴다 = 소환
--     차단 없을 때  지연 6~7 줄 -> 줄38~39                    여유 128 줄
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     RCR($06) 에 쓰이는 값        = 래스터 인터럽트가 걸릴 스캔라인
--     그 값이 프레임마다 몇 개인가  = 화면을 몇 조각으로 나누는가
--     쓰이는 시점의 스캔라인        = 언제 다음 분할을 예약하는가
--     게이트($FEC4) 진입 스캔라인   = 우리 차단이 시작되는 곳
--
-- HuC6270 의 RCR 은 "이 줄에서 IRQ" 를 지정한다.  실제 화면 줄은 보통
-- `RCR - 64` 로 읽는다.  둘 다 찍는다.
--
-- 판정
--     RCR 135 가 줄 135 안에 쓰인다    -> 분할 정상.  소환 원인은 딴 데
--     RCR 135 가 줄 143~199 에 쓰인다  -> ★ 확정.  차단 창이 밀어낸 것
--                                         -> 다음은 0.5.21-window-decompose
--
-- ★ RCR 쓰기가 0 이면 판정하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 대사를 흘린다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local GATE = 0xFEC4

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/raster_lines_0_5_155_' .. STAMP .. '.tsv'
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
      emu.log(string.format('SUB 0.5.155 %df · gate line %d · 분할 예약 %d개 · %s',
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

  emu.drawString(4, 84, string.format('0.5.155 RCR 쓰기 %d · 보고 %d · line키 %s',
                 writes, reported, tostring(LINE_KEY)),
                 writes > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.155-raster-split-lines armed -- 분할선(RCR)과 게이트 진입 줄을 잰다')
emu.log('  ★ RCR 쓰기 0 이면 판정 불가')
emu.log('  로그: ' .. OUT)
