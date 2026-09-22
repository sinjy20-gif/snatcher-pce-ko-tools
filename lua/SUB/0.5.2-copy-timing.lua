-- SUB 0.5.2 -- 헬퍼의 653 B 복사가 화면 어디를 먹는지 잰다 (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.4.99(게이트 안 열림)에서 번쩍임이 사라지고, 0.5.1(게이트 열되 엔진은
-- 즉시 RTS)에서 그대로 났다.  두 판의 차이는 **게임이 자막 분기를 타느냐**
-- 하나뿐이고, 그 분기 안에서 우리 엔진은 아무것도 하지 않는다.
--
-- 그 분기에 들어 있는 가장 큰 일이 헬퍼의 복사다:
--
--     AC $1F1F00  --653 B-->  CPU $5B80        그리고 JSR $5B83
--
-- HuC6280 블록 전송은 중단 불가다.  653 B 면 대략 8~9 스캔라인 동안 IRQ 가
-- 통째로 막힌다.  그 구간이 **표시 구간에 걸치면** 래스터 분할이 밀리고,
-- 그림 띠가 아래로 번지며 타일맵 위쪽이 화면에 나온다 -- 증상과 같은 모양이다.
--
-- 이 판은 그 가설을 세우는 게 아니라 **재기만** 한다.
--
-- 어떻게
-- ---------------------------------------------------------------------------
-- entry=RTS 엔진을 쓴다.  그러면 $5B80-$5E1F 에 쓰는 것은 **헬퍼의 복사뿐**이고
-- 엔진 자신의 레코드 조립·stage 쓰기가 섞이지 않는다.  그런데 그 상태에서도
-- 번쩍임은 난다 (0.5.1).  즉 순수한 복사만 재면서 증상은 그대로인 조건이다.
--
--     프레임마다  $5B80-$5E1F 쓰기 횟수 · 첫 쓰기 스캔라인 · 마지막 쓰기 스캔라인
--     span 은 (end - start + 263) % 263 로 낸다
--       ★ 0.4.70 은 이 보정을 안 해서 wrap 을 음수로 기록했다.  같은 실수 금지
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     writes ~653          복사 한 번이 잡혔다
--     span 8~10 줄          예상대로.  블록 전송 시간이다
--     start 가 표시 구간     ★ 표시 중에 IRQ 를 막는다 -> 분할이 밀린다
--     start 가 VBlank        복사는 안전한 자리에서 일어난다 -> 다른 것을 봐야 한다
--
-- PC엔진 표시 구간은 대략 line 0..238, VBlank 가 239..262 다.
-- 화면에 마지막 복사의 start/end/span 을 계속 띄운다.
--
-- ★ writes 가 0 이면 아무 판정도 하지 말 것.  Lua 쓰기는 콜백을 안 태울 수
--   있으므로, 복사가 안 잡히면 그건 "복사가 없다" 가 아니라 "못 봤다" 다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 대사 몇 개를 흘린다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

SUB_REARM_INFO_PATH =
  'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm_entryrts.lua'
dofile('C:/snatcher/lua/SUB/0.4.89-marker.lua')
SUB_REARM_INFO_PATH = nil

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local LINES = 263
local DISPLAY_LAST = 238           -- 대략.  이 위는 VBlank 로 본다

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/copy_timing_0_5_2_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tkey\twrites\tstart_line\tend_line\tspan\twhere\n')
end

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

local writes, firstLine, lastLine = 0, -1, -1
local MAX_SAMPLE = 900             -- getState 호출 상한 (복사 653 B 를 덮는다)

emu.addMemoryCallback(function()
  writes = writes + 1
  if writes > MAX_SAMPLE then return end
  local line = scanline()
  if writes == 1 then firstLine = line end
  lastLine = line
end, emu.callbackType.write, ENGINE_LO, ENGINE_HI, CPU, MEM)

local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local frame, copies = 0, 0
local lastReport = '아직 없음'

emu.addEventCallback(function()
  frame = frame + 1
  local n, a, b = writes, firstLine, lastLine
  writes, firstLine, lastLine = 0, -1, -1

  -- 복사로 볼 만한 크기만 보고한다.  자잘한 쓰기는 무시.
  if n >= 64 then
    copies = copies + 1
    -- ★ wrap 보정.  0.4.70 은 이걸 안 해서 음수 span 을 남겼다.
    local span = (a >= 0 and b >= 0) and ((b - a + LINES) % LINES) or -1
    local where
    if a < 0 then where = 'line없음'
    elseif a <= DISPLAY_LAST then where = '표시구간'
    else where = 'VBlank' end
    lastReport = string.format('%d회 line %d->%d span %s (%s)',
                               n, a, b, tostring(span), where)
    prevLog(string.format(
      'SUB 0.5.2 %df · KEY %s · $5B80 쓰기 %d회 · line %d -> %d · span %s줄 · %s',
      frame, curKey, n, a, b, tostring(span), where))
    if out then
      out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%s\n',
                              frame, curKey, n, a, b, span, where))
      out:flush()
    end
  end

  emu.drawString(4, 64, string.format('0.5.2 복사 %d회 · 마지막: %s · line키 %s',
                 copies, lastReport, tostring(LINE_KEY)), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.5.2-copy-timing armed -- entry=RTS · $5B80-$5E1F 쓰기 구간을 잰다')
prevLog('  표시구간 0..238 · VBlank 239..262 · span 은 wrap 보정해서 낸다')
prevLog('  ★ 쓰기 0회면 "복사 없음" 이 아니라 "못 봤다" 다.  판정하지 말 것')
prevLog('  로그: ' .. OUT)
