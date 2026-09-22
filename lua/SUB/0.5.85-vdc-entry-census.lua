-- SUB 0.5.85 -- 진입 직전 VDC 상태의 전수 조사 (0.5.84 divergence 의 후속)
--
-- 0.5.84 가 증명한 것
-- ---------------------------------------------------------------------------
-- ```
-- 진입 6936f  게임   sel=$02  mawr=$1000  inc=+1     pc $5B83
-- 반환 6936f  우리   sel=$02  mawr=$7D40  inc=+1     RTS pc $5CB6
-- 달라진 것   MAWR $1000 -> $7D40   (select 도 increment 도 안 깨진다)
-- ```
--
-- 이 판이 답하는 것 -- 딱 하나
-- ---------------------------------------------------------------------------
-- **진입 MAWR 이 늘 같은 값인가.**
--
-- HuC6270 은 MAWR 을 되읽을 수 없다 (NOTES.md 미결 항목).  그래서 반환 직후
-- 복원하려면 값을 코드에 박는 수밖에 없는데, 지금 표본이 1 개뿐이다.
-- 한 표본으로 상수를 박으면 그건 복원이 아니라 가설이다.
--
--     진입 상태가 늘 (sel $02 · mawr $1000 · inc +1)  -> 8 바이트 복원으로 끝난다
--     값이 흩어진다                                    -> 상수 복원은 불가.  그 분포를 보고
--                                                         다음을 정한다
--
-- 세는 것
-- ---------------------------------------------------------------------------
--   entry   진입 직전 (sel · mawr · inc) 조합별 횟수.  새 조합은 즉시 로그
--   exit    반환 직후 (sel · mawr · inc) 조합별 횟수.  우리가 남기는 값의 분포
--   delta   select / increment 가 깨진 적이 있는가 (0.5.84 는 없다고 했다)
--
-- 0.5.84 의 빠른 구조 그대로다.  PC 조회는 새 조합을 처음 볼 때만 한다.
--
-- ★ 게임을 한 바이트도 안 고친다.  VRAM/RAM/AC/state/키 입력에 쓰지 않는다.
-- ★ 화면에 아무것도 그리지 않는다.  결과는 즉시 로그 -- 언로드 불필요.
--
--   BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA 끝까지 -> ACT1 까지
--
-- 산출물  C:/snatcher/dump/cdda_vdc_census_0_5_85_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_vdc_census_0_5_85_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local ENG_LO, ENG_HI = 0x5B80, 0x5E1E

local frame = 0
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end

local function pcNow()                       -- ★ 새 조합을 처음 볼 때만
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  local v = s['cpu.pc'] or (s.cpu and s.cpu.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

-- ===========================================================================
-- VDC 상태 (0.5.75 / 0.5.80 의 검증된 디코더)
-- ===========================================================================
local selReg, mawr, crHi = 0, 0, 0
local INCNAME = { [0] = '+1', [1] = '+32', [2] = '+64', [3] = '+128' }
local function incr() return INCNAME[(crHi >> 3) & 3] end
local function key() return string.format('sel=$%02X mawr=$%04X inc=%s',
                                          selReg, mawr & 0x7FFF, incr()) end

-- ===========================================================================
-- 조합 세기
-- ===========================================================================
local entryTally, entryOrder = {}, {}
local exitTally,  exitOrder  = {}, {}
local entries, selBroke, incBroke = 0, 0, 0
local entrySel, entryInc = nil, nil

local function tally(t, order, k, kind)
  if not t[k] then
    t[k] = 0
    order[#order + 1] = k
    if #order <= 40 then
      local pc = pcNow()
      say('0.5.85 · %df  새 %s 조합 #%d :  %s   (pc $%04X)',
          frame, kind, #order, k, pc)
      rec(kind .. '_new', '#%d %s pc=$%04X', #order, k, pc)
    end
  end
  t[k] = t[k] + 1
end

-- ===========================================================================
-- 소유자 -- exec 플래그 (0.5.84 와 같음)
-- ===========================================================================
local inEngine = false
local haveEntry = false
local gameWroteSinceExit = false

emu.addMemoryCallback(function(address)
  if not inEngine then
    inEngine = true
    if (not haveEntry) or gameWroteSinceExit then
      haveEntry = true
      gameWroteSinceExit = false
      entries = entries + 1
      entrySel, entryInc = selReg, incr()
      tally(entryTally, entryOrder, key(), 'entry')
    end
  end
  if (emu.read(address, MEM) or 0) == 0x60 then          -- RTS -> 나간다
    if inEngine then
      inEngine = false
      tally(exitTally, exitOrder, key(), 'exit')
      if entrySel ~= nil and selReg ~= entrySel then selBroke = selBroke + 1 end
      if entryInc ~= nil and incr() ~= entryInc then incBroke = incBroke + 1 end
    end
  end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

-- ===========================================================================
-- VDC 포트 -- 순수 디코딩 (PC 조회 없음)
-- ===========================================================================
local installed = pcall(function()
  emu.addMemoryCallback(function(address, value)
    local port = address & 3
    value = (value or 0) & 0xFF
    if not inEngine then gameWroteSinceExit = true end
    if port == 0 then
      selReg = value
    elseif port == 2 then
      if selReg == 0 then mawr = (mawr & 0xFF00) | value end
    elseif port == 3 then
      if selReg == 0 then
        mawr = (mawr & 0x00FF) | (value << 8)
      elseif selReg == 5 then
        crHi = value
      elseif selReg == 2 then
        mawr = (mawr + 1) & 0xFFFF
      end
    end
  end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)
end)
if not installed then
  say('0.5.85 ** VDC 포트 콜백 설치 실패 -- 판정 불가')
  rec('fatal', 'vdc callback install failed')
end

-- ===========================================================================
-- 중간 집계 -- 언로드 없이도 답이 나온다
-- ===========================================================================
local function report(tag)
  say('0.5.85 ===== %s  진입 %d 회 · 진입조합 %d 종 · 반환조합 %d 종',
      tag, entries, #entryOrder, #exitOrder)
  say('        select 깨짐 %d 회 · increment 깨짐 %d 회', selBroke, incBroke)
  for i = 1, math.min(#entryOrder, 10) do
    local k = entryOrder[i]
    say('        진입 %2d)  %s   x%d', i, k, entryTally[k])
    rec('entry_tally', '%s count=%d', k, entryTally[k])
  end
  for i = 1, math.min(#exitOrder, 10) do
    local k = exitOrder[i]
    say('        반환 %2d)  %s   x%d', i, k, exitTally[k])
    rec('exit_tally', '%s count=%d', k, exitTally[k])
  end
  if #entryOrder == 1 then
    say('        ==> ★ 진입 상태가 한 종류다.  그 값을 반환 직후 복원하면 된다')
  else
    say('        ==> 진입 상태가 %d 종류다.  상수 복원은 불가 -- 분포를 보고 정한다',
        #entryOrder)
  end
  rec('report', '%s entries=%d entry_kinds=%d exit_kinds=%d sel_broke=%d inc_broke=%d',
      tag, entries, #entryOrder, #exitOrder, selBroke, incBroke)
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then report(string.format('%df 중간집계', frame)) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  report('종료')
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.85-vdc-entry-census armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  묻는 것은 하나 : 진입 직전 MAWR 이 늘 $1000 인가')
say('  1800 프레임마다 중간집계가 나온다 -- 언로드 불필요')
say('  덤프 : ' .. PATH)
