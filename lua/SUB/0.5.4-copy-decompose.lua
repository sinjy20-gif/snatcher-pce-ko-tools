-- SUB 0.5.4 -- 조각마다 도는 4~5 패스를 주소 순서로 쪼갠다 (쓰기 0 B)
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
--     0.5.2  자막 분기는 $5B80-$5E1F 에 조각마다 2,755~3,425 회를 29~44 줄 동안
--            쏟는다.  표시 구간 한복판이다
--     0.5.3  음성 중 게임의 그 구간 쓰기는 2,724 프레임 동안 **정확히 0**.
--            즉 그 폭주는 100 % 우리 분기가 만든 것이다
--
--     2,755 / 672 = 4.1     이후 조각
--     3,425 / 672 = 5.1     첫 조각      (차이 670 ≈ 672 -- 딱 한 패스)
--
-- 그래서 "672 B 를 네다섯 번 옮긴다" 까지는 나왔다.  무엇을 네다섯 번인지가
-- 남았다.  subtitle_layout.py 에 `AC_CPU_CACHE_BACKUP = 0x1F0E00  # $5B80-$5E1E`
-- 가 있으니 백업 -> 복사 -> 복원 구조로 보이지만, 확인한 적은 없다.
--
-- 어떻게 쪼개나
-- ---------------------------------------------------------------------------
-- 블록 전송은 주소가 **연속**이다.  그래서 쓰기 주소를 순서대로 보며
-- `addr == last+1`(오름) 또는 `addr == last-1`(내림) 이 끊기는 지점마다
-- 구간(run)을 닫는다.  한 프레임의 run 목록이 곧 패스 목록이다.
--
--     run 4 개 x 672 B 오름       -> 같은 일을 네 번 한다
--     길이가 제각각               -> 백업/복사/복원이 서로 다른 양이다
--     내림 run 이 섞임            -> TDD 계열 전송이 있다
--
-- run 의 시작/끝 스캔라인도 같이 찍는다 (경계에서만 getState 를 부르므로 싸다).
-- 이걸로 "어느 패스가 표시 구간을 먹는가" 까지 한 번에 나온다.
--
-- entry=RTS 엔진을 쓴다.  우리 엔진 자신의 쓰기가 섞이지 않아야 패스가 깨끗하다.
--
-- ★ run 이 0 개면 판정하지 말 것.  버스트를 못 잡은 것이다.
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
local BASE, TOP = 0x5B80, 0x5E1F
local LINES = 263
local DISPLAY_LAST = 238

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/copy_decompose_0_5_4_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tkey\trun\tfirst\tlast\tlength\tdir\tstart_line\tend_line\twhere\n')
end

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

local runs = {}          -- 이 프레임의 구간들
local cur = nil
local total = 0
local MAX_RUNS = 40

local function closeRun()
  if cur then
    cur.endLine = scanline()
    if #runs < MAX_RUNS then runs[#runs + 1] = cur end
    cur = nil
  end
end

emu.addMemoryCallback(function(address)
  total = total + 1
  local off = address - BASE
  if cur and (off == cur.last + cur.step) then
    cur.last = off
    cur.len = cur.len + 1
    return
  end
  -- 두 번째 쓰기에서 방향을 정한다 (오름/내림).
  if cur and cur.len == 1 and (off == cur.first + 1 or off == cur.first - 1) then
    cur.step = (off > cur.first) and 1 or -1
    cur.last = off
    cur.len = 2
    return
  end
  closeRun()
  cur = { first = off, last = off, len = 1, step = 1, startLine = scanline() }
end, emu.callbackType.write, BASE, TOP, CPU, MEM)

local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local frame, bursts = 0, 0
local lastSummary = '아직 없음'

emu.addEventCallback(function()
  frame = frame + 1
  closeRun()
  local list, n = runs, total
  runs, total = {}, 0

  -- 자잘한 것은 버린다.  버스트만 본다.
  if n >= 512 then
    bursts = bursts + 1
    prevLog(string.format('SUB 0.5.4 ── %df · KEY %s · 총 %d 회 · run %d 개 ──',
                          frame, curKey, n, #list))
    local parts = {}
    for i, r in ipairs(list) do
      local span = (r.startLine >= 0 and r.endLine >= 0)
                   and ((r.endLine - r.startLine + LINES) % LINES) or -1
      local where = (r.startLine < 0) and 'line없음'
                    or (r.startLine <= DISPLAY_LAST and '표시' or 'VBlank')
      local dir = (r.step > 0) and '오름' or '내림'
      if r.len >= 16 then
        prevLog(string.format('   run%-2d +$%03X..+$%03X  %4d B  %s  line %d->%d (%d줄, %s)',
                              i, r.first, r.last, r.len, dir,
                              r.startLine, r.endLine, span, where))
        parts[#parts + 1] = tostring(r.len)
      end
      if out then
        out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%s\n',
          frame, curKey, i, r.first, r.last, r.len, dir,
          r.startLine, r.endLine, where))
      end
    end
    if out then out:flush() end
    lastSummary = string.format('%d회 / run %d [%s]', n, #list,
                                table.concat(parts, '+'))
  end

  emu.drawString(4, 64, string.format('0.5.4 버스트 %d · 마지막: %s',
                 bursts, lastSummary), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.5.4-copy-decompose armed -- 버스트를 연속 구간(run)으로 쪼갠다')
prevLog('  entry=RTS · 512 회 이상인 프레임만 본다 · 16 B 이상 run 만 로그')
prevLog('  ★ run 이 0 개면 버스트를 못 잡은 것이다.  판정하지 말 것')
prevLog('  로그: ' .. OUT)
