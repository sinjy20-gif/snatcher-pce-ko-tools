-- SUB 0.5.5 -- 그 128 B 를 19 번 쓰는 코드가 누구인지 PC 로 잡는다 (쓰기 0 B)
--
-- 0.5.4 가 쪼갠 것
-- ---------------------------------------------------------------------------
--     run1      +$000..+$13F    320 B   x1     line 22~24 -> 34~36
--     run2~21   +$0AF..+$12E    128 B   x19    각 4~8 줄, line 35 -> 177
--     run23     +$000..+$29E    671 B   x1     첫 조각에만
--     합계      320 + 19x128 = 2,752 (이후) · +671 = 3,423 (첫)
--
-- 숫자가 bios_preload.json 과 맞는다 (helper 320 B · renderer 671 B).
-- 그리고 19 x 128 B 는 글리프 19 개 x 글리프 크기($40 워드)다.
--
-- 문제는 **우리 엔진이 entry=RTS 라 한 번도 안 돌았다**는 것이다 (PATCHED 0 건).
-- 그런데도 글리프 19 개분 스테이징이 돈다.  누가 하는지 모른다.
-- 바이너리를 추측하지 말고 **PC 를 직접 찍는다.**
--
-- 같이 찍는 것
-- ---------------------------------------------------------------------------
--     run 시작 시점의 PC (+ 가능하면 뱅크)   -> 어느 코드인지
--     $5BED 의 3 바이트                      -> 지금 $5B80 에 있는 것이 무엇인지
--                                               A9 01 EA = 우리 entry=RTS 엔진
--                                               그 외    = 다른 이미지가 올라와 있다
--
-- 두 번째가 중요하다.  0.5.1/0.5.4 는 "우리 엔진이 RTS 라 안 돌았다" 를 전제로
-- 읽었는데, 그 사이 디스크 선적재가 AC 슬롯을 되돌렸을 수 있다.  그러면
-- $5B80 에 올라간 것이 우리 것이 아니고, 앞선 판정의 전제가 흔들린다.
-- 이 값이 그것을 그 자리에서 확인해 준다.
--
-- ★ pc키 none 이면 PC 를 못 얻은 것이다.  그때는 이 판으로 판정하지 말 것.
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
local MARK = 0x5BED                -- $5B80 + $6D.  A9 01 EA = 우리 entry=RTS 엔진

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/writer_pc_0_5_5_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tkey\trun\tfirst\tlast\tlength\tpc\tbank\tline\tmark\n')
end

-- state 키 이름은 코어 판마다 다르다.  한 번만 찾아 기억하고 무엇을 찾았는지 알린다.
local PC_KEY, LINE_KEY, MPR_KEY
local function discover(s)
  if PC_KEY ~= nil then return end
  PC_KEY, LINE_KEY, MPR_KEY = false, false, false
  for _, k in ipairs({'cpu.pc', 'pc', 'cpu.PC'}) do
    if type(s[k]) == 'number' then PC_KEY = k; break end
  end
  for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter'}) do
    if type(s[k]) == 'number' then LINE_KEY = k; break end
  end
  for _, k in ipairs({'cpu.mpr3', 'memoryManager.mprs3', 'cpu.mpr'}) do
    if type(s[k]) == 'number' then MPR_KEY = k; break end
  end
  if not PC_KEY then
    for k, v in pairs(s) do
      if type(v) == 'number' and k:lower():find('%f[%w]pc%f[%W]') then PC_KEY = k; break end
    end
  end
  emu.log(string.format('SUB 0.5.5 state키 · pc=%s · line=%s · mpr=%s',
                        tostring(PC_KEY), tostring(LINE_KEY), tostring(MPR_KEY)))
end

local function sample()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1, -1, -1 end
  discover(s)
  local pc = PC_KEY and s[PC_KEY] or -1
  local line = LINE_KEY and s[LINE_KEY] or -1
  local mpr = MPR_KEY and s[MPR_KEY] or -1
  return math.floor(pc or -1), math.floor(line or -1), math.floor(mpr or -1)
end

local runs, cur, total = {}, nil, 0
local MAX_RUNS = 40

local function closeRun()
  if cur and #runs < MAX_RUNS then runs[#runs + 1] = cur end
  cur = nil
end

emu.addMemoryCallback(function(address)
  total = total + 1
  local off = address - BASE
  if cur then
    if off == cur.last + cur.step then
      cur.last = off; cur.len = cur.len + 1; return
    end
    if cur.len == 1 and (off == cur.first + 1 or off == cur.first - 1) then
      cur.step = (off > cur.first) and 1 or -1
      cur.last = off; cur.len = 2; return
    end
  end
  closeRun()
  local pc, line, mpr = sample()
  cur = { first = off, last = off, len = 1, step = 1, pc = pc, line = line, mpr = mpr }
end, emu.callbackType.write, BASE, TOP, CPU, MEM)

local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local function mark3()
  local a = emu.read(MARK + 0, MEM) or -1
  local b = emu.read(MARK + 1, MEM) or -1
  local c = emu.read(MARK + 2, MEM) or -1
  return string.format('%02X %02X %02X', a & 0xFF, b & 0xFF, c & 0xFF)
end

local frame, bursts = 0, 0
local lastLine = '아직 없음'

emu.addEventCallback(function()
  frame = frame + 1
  closeRun()
  local list, n = runs, total
  runs, total = {}, 0

  if n >= 512 then
    bursts = bursts + 1
    local mk = mark3()
    prevLog(string.format('SUB 0.5.5 ── %df · KEY %s · 총 %d 회 · $5BED=%s%s ──',
      frame, curKey, n, mk,
      mk == 'A9 01 EA' and ' (우리 entry=RTS 엔진)' or ' ★ 우리 것이 아니다'))
    -- 같은 길이/같은 PC 는 한 줄로 접어서 낸다.
    local seen, order = {}, {}
    for _, r in ipairs(list) do
      if r.len >= 16 then
        local sig = string.format('%4d B  +$%03X..+$%03X  PC $%04X  bank %d',
                                  r.len, r.first, r.last, r.pc & 0xFFFF, r.mpr)
        if not seen[sig] then seen[sig] = { n = 0, first = r.line, last = r.line }
          order[#order + 1] = sig end
        local e = seen[sig]
        e.n = e.n + 1
        e.last = r.line
      end
    end
    for _, sig in ipairs(order) do
      local e = seen[sig]
      prevLog(string.format('   x%-3d %s   line %d..%d', e.n, sig, e.first, e.last))
    end
    lastLine = string.format('%d회 · %s', n, mk)
    if out then
      for i, r in ipairs(list) do
        out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n',
          frame, curKey, i, r.first, r.last, r.len, r.pc, r.mpr, r.line, mk))
      end
      out:flush()
    end
  end

  emu.drawString(4, 64, string.format('0.5.5 버스트 %d · %s · pc키 %s',
                 bursts, lastLine, tostring(PC_KEY)), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.5.5-writer-pc armed -- run 시작 PC 와 $5BED 지문을 같이 찍는다')
prevLog('  ★ pc키 none 이면 PC 를 못 얻은 것이다.  판정하지 말 것')
prevLog('  로그: ' .. OUT)
