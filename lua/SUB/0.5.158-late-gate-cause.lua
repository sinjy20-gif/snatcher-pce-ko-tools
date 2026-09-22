-- SUB 0.5.158 -- 늦는 프레임은 무엇이 다른가.  게이트 진입줄과 BYR 지연을 짝짓는다
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- `0.5.157` 이 원본 BIOS 대조로 원인을 확정했다:
--
--     원본   BYR=96 을 10,016 프레임 **전부** 줄 32 에 쓴다.  예외 0
--     우리   5,156 중 33 건이 줄 33~72 로 밀린다 (최대 40 스캔라인)
--            -> 그 프레임만 화면 위쪽이 옛 스크롤(BYR=0 = 천장)로 그려진다
--
-- `0.5.155` 는 게이트($FEC4) 진입이 줄13~25 가 6,090 건인데
-- **줄30~80 이 219 건**임을 봤다.  둘을 짝지으면 "늦는 프레임의 정체" 가 나온다.
--
-- 무엇을 재나 -- 한 프레임 안에서 전부
-- ---------------------------------------------------------------------------
--     GATE   $FEC4 진입 스캔라인 (여러 번이면 전부)
--     ENGINE $5C02 (count_ok) 실행 스캔라인      -- 렌더러가 돈 프레임인가
--     HELPER $5B80 진입 오퍼랜드로 가른다        -- 헬퍼(복원)가 돈 프레임인가
--     BYR96  BYR=96 이 닿은 스캔라인             ★ 판정값
--
-- 늦은 프레임(BYR96 != 32)만 자세히 찍고, 정상 프레임은 개수만 센다.
--
-- 판정
--     늦은 프레임에 ENGINE 이 있다        -> 렌더러가 밀어낸다.  글리프 업로드를 줄인다
--     늦은 프레임에 HELPER 가 있다        -> 복원이 밀어낸다.  그쪽을 옮긴다
--     둘 다 없는데 GATE 만 늦다           -> 게이트 진입 자체가 밀린다.  우리 앞단이 아니다
--     늦은 프레임에 아무 표시도 없다      -> 게임이 그 프레임에 뭔가 더 한다.  우리 무죄
--
-- ★ 상한 없음.  늦은 프레임은 전부 남긴다 (인계서 §2-1 규칙)
--
-- 산출물  C:/snatcher/dump/late_gate_0_5_158_<시각>.tsv

local GATE     = 0xFEC4
local ENGINE   = 0x5B80
local COUNT_OK = ENGINE + 130      -- engine_ac_lua_frame_rearm_A9722A5F_6600.json
local GOOD_LINE = 32               -- 원본이 100% 지키는 줄

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/late_gate_0_5_158_' .. STAMP .. '.tsv'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local out = io.open(PATH, 'w')
out:write('frame\tbyr96_line\tdelay\tgate_lines\tengine_lines\thelper\tnote\n')
local function say(m) emu.log(m); print(m) end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local selReg = 0
local byr96, gates, engines, helperSeen = -1, {}, {}, false

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  -- BYR($08) 하위에 96 이 실리는 순간이 그림 창 스크롤 확정이다
  if selReg == 0x08 and port == 2 and value == 96 and byr96 < 0 then
    byr96 = scanline()
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function()
  if #gates < 8 then gates[#gates + 1] = scanline() end
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

emu.addMemoryCallback(function()
  if #engines < 8 then engines[#engines + 1] = scanline() end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

-- 헬퍼와 렌더러는 같은 $5B80 을 쓴다.  entry 오퍼랜드로 가른다
--   헬퍼   AD 30 5D (LDA command)   ·   렌더러  AD F9 5C (LDA ready)
emu.addMemoryCallback(function()
  local ok, a = pcall(emu.read, ENGINE + 4, MEM)
  if ok and a == 0x5D then helperSeen = true end
end, emu.callbackType.exec, ENGINE + 3, ENGINE + 3, CPU, MEM)

local frame, good, late, kinds = 0, 0, 0, {}

local function join(t)
  if #t == 0 then return '-' end
  local p = {}
  for i, v in ipairs(t) do p[i] = tostring(v) end
  return table.concat(p, ',')
end

emu.addEventCallback(function()
  frame = frame + 1
  if byr96 >= 0 then
    if byr96 == GOOD_LINE then
      good = good + 1
    else
      late = late + 1
      local g, e = join(gates), join(engines)
      local kind = ('gate=%s engine=%s helper=%s'):format(g, e, helperSeen and 'Y' or 'N')
      kinds[kind] = (kinds[kind] or 0) + 1
      out:write(('%d\t%d\t%d\t%s\t%s\t%s\t★늦음\n'):format(
        frame, byr96, byr96 - GOOD_LINE, g, e, helperSeen and 'Y' or 'N'))
      out:flush()
      say(('★늦음 f%-6d BYR96=줄%-3d (+%d)  gate=%s  engine=%s  helper=%s'):format(
        frame, byr96, byr96 - GOOD_LINE, g, e, helperSeen and 'Y' or 'N'))
    end
  end
  byr96, gates, engines, helperSeen = -1, {}, {}, false
  if frame % 1200 == 0 then
    say(('== 프레임 %d · 정상 %d · 늦음 %d (%.2f%%) =='):format(
      frame, good, late, 100 * late / math.max(good + late, 1)))
    for k, n in pairs(kinds) do say(('   n=%-4d %s'):format(n, k)) end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.158-late-gate-cause armed -- 늦는 프레임만 자세히 남긴다')
say(('  기준: BYR=96 이 줄 %d 에 닿으면 정상 (원본은 100%%)'):format(GOOD_LINE))
say('  ' .. PATH)
