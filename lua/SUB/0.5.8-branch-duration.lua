-- SUB 0.5.8 -- 자막 분기가 CPU 를 얼마나, 화면 어디서 잡는지 통째로 잰다 (쓰기 0 B)
--
-- 왜 방식을 바꾸나
-- ---------------------------------------------------------------------------
-- 지금까지의 측정은 전부 **$5B80-$5E1F 쓰기**만 봤다.  열쇠구멍이었다.
--
--     0.5.7  백업/복원 19 -> 1 로 줄여도 번쩍임 그대로  -> 그 루프는 범인이 아니다
--
-- 그런데 분기는 그 범위 밖에서도 일한다 -- VDC 쓰기, AC 셋업, SATB 조작,
-- 그리고 상주부 32 B($7FA0-$7FBF) **바깥**의 코드($7FC3 등).  한 번도 안 쟀다.
--
-- 그래서 "어디에 쓰는가" 대신 **"CPU 가 얼마나 오래 어디에 있는가"** 를 잰다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) 분기 전체 길이   gate $FEC4 진입 -> $FF0F 복귀 까지의 스캔라인
--                       (0.4.31 의 GATE / GATE_RET 와 같은 주소)
--   2) 어디에 있었나     실행 콜백을 네 구역에 걸어 프레임당 적중 수를 센다
--                         resident  $7E00-$7FFF
--                         engine    $5B80-$5E1F
--                         cave      $FE00-$FFFF
--                         bios      $E000-$EFFF
--
-- 1) 이 "분기가 표시 구간 몇 줄을 먹는가" 의 답이고,
-- 2) 가 "그 시간이 어느 코드에 있는가" 의 답이다.  둘을 같이 보면 다음 이분
--    지점이 추측 없이 정해진다.
--
-- ★ gate 적중이 0 이면 판정하지 말 것.  주소가 이 빌드와 다른 것이다.
-- ★ 실행 콜백을 넓게 걸면 느리다.  판정용이지 상시 실행용이 아니다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 대사 몇 개를 흘린다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local GATE, GATE_RET = 0xFEC4, 0xFF0F      -- 0.4.31 과 같은 주소
local LINES = 263
local DISPLAY_LAST = 238

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/branch_duration_0_5_8_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tkey\tgate_line\tret_line\tspan\twhere\tresident\tengine\tcave\tbios\n')
end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter'}) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local hit = { resident = 0, engine = 0, cave = 0, bios = 0 }
local function counter(name)
  return function() hit[name] = hit[name] + 1 end
end

emu.addMemoryCallback(counter('resident'), emu.callbackType.exec, 0x7E00, 0x7FFF, CPU, MEM)
emu.addMemoryCallback(counter('engine'),   emu.callbackType.exec, 0x5B80, 0x5E1F, CPU, MEM)
emu.addMemoryCallback(counter('cave'),     emu.callbackType.exec, 0xFE00, 0xFFFF, CPU, MEM)
emu.addMemoryCallback(counter('bios'),     emu.callbackType.exec, 0xE000, 0xEFFF, CPU, MEM)

local gateLine, retLine, gateHits = -1, -1, 0
emu.addMemoryCallback(function()
  gateLine = scanline(); gateHits = gateHits + 1
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)
emu.addMemoryCallback(function()
  retLine = scanline()
end, emu.callbackType.exec, GATE_RET, GATE_RET, CPU, MEM)

local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local frame, reports = 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local g, r = gateLine, retLine
  local h = { resident = hit.resident, engine = hit.engine, cave = hit.cave, bios = hit.bios }
  gateLine, retLine = -1, -1
  hit.resident, hit.engine, hit.cave, hit.bios = 0, 0, 0, 0

  -- 분기를 탄 프레임만 본다.
  if g >= 0 or h.engine > 0 then
    reports = reports + 1
    local span = (g >= 0 and r >= 0) and ((r - g + LINES) % LINES) or -1
    local where = (g < 0) and '-' or (g <= DISPLAY_LAST and '표시' or 'VBlank')
    prevLog(string.format(
      'SUB 0.5.8 %df · KEY %s · gate line %d -> %d (%s줄, %s) · ' ..
      '실행 resident %d · engine %d · cave %d · bios %d',
      frame, curKey, g, r, tostring(span), where,
      h.resident, h.engine, h.cave, h.bios))
    if out then
      out:write(string.format('%d\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\n',
        frame, curKey, g, r, span, where, h.resident, h.engine, h.cave, h.bios))
      out:flush()
    end
  end

  emu.drawString(4, 74, string.format('0.5.8 보고 %d · gate적중 %d · line키 %s',
                 reports, gateHits, tostring(LINE_KEY)), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.5.8-branch-duration armed -- 분기 길이 + 어느 코드에 있었나')
prevLog(string.format('  gate $%04X -> $%04X · 실행 구역 resident/engine/cave/bios',
                      GATE, GATE_RET))
prevLog('  ★ gate 적중이 0 이면 판정하지 말 것 (주소가 다른 빌드다)')
prevLog('  ★ 실행 콜백이 넓어 느리다.  판정용이다')
prevLog('  로그: ' .. OUT)
