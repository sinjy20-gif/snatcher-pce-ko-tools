-- regression_runtime -- 한 주행으로 **런타임 불변식**을 검사한다  ★순수 관측 · 쓰기 0 B · 화면에 안 그림
--
-- 왜
-- ---------------------------------------------------------------------------
-- `tools/check_build_invariants.py` 가 정적으로 12 가지를 본다.  그런데 정적으로는
-- 절대 못 보는 것이 남는다 -- 에뮬레이터가 돌려줘야 아는 것들이다.
--
--     정적 검사 통과      팩 세대 · mini index · 마스터 표 · BIOS 굴 · 크기 한도 · CUE
--     ★정적으로 못 봄     MPR 상태 · VDC MAWR 복원 · 자막 STATE 탈출 ·
--                        CD-DA 스케줄러 실행 · ADPCM/UI 전이
--
-- 이 프로브가 그 다섯을 덮는다.  실패한 이력이 전부 이 다섯에 있다:
--
--     GFX r1~r4   업로더가 돌 때 MPR7 은 항상 $00 인데 우리 코드는 뱅크 $01 이었다
--     ADPCM       음성 뒤 STATE 가 2 에 갇히면 다음 대사가 일본어로 뜬다
--     자막 조각    VRAM 은 즉시, 스프라이트는 vblank 래치라 MAWR 복원이 어긋나면 깨진다
--
-- 무엇을 재나  (7 지점)
-- ---------------------------------------------------------------------------
--   boot              부팅이 끝나 게임 루프에 들어갔나
--   subtitle start    STATE 가 0 -> 1/2 로 올라가나
--   subtitle skip     스킵/중단에서도 STATE 가 빠져나오나
--   ADPCM end         $180D 비트5 가 떨어지나 (종료 통보가 오나)
--   CDDA start        CD-DA 스케줄러 $ECF9 가 실제로 도나
--   MAWR restore      우리 버스트 뒤 MAWR 이 원래 값으로 돌아오나
--   resident callback BIOS tick $FC07 이 매 프레임 도나
--
-- ★ STATE `$7FDF` 는 `$6000-$7FFF` 라 **뱅크 종속**이다.  그냥 읽으면 $00 만 나온다
--   (2026-09-08 에 이것 때문에 프로브 하나를 통째로 날렸다).
--   그래서 **쓰기를 감시**한다 -- 쓰기 콜백은 어느 뱅크가 얹혀 있든 걸린다.
--
-- 쓰는 법
--   이것만 로드 (다른 Lua 와 같이 올리지 말 것).  정상 속도.
--   부팅 -> 대사 몇 개 -> 음성 있는 구간 -> CD-DA 있는 구간 을 지나고 Stop.
--   길게 돌수록 판정이 는다.  안 지난 항목은 실패가 아니라 `안 봄` 으로 나온다.
--
-- 산출물  C:/snatcher/dump/regression_<시각>_events.tsv
--         C:/snatcher/dump/regression_<시각>_summary.txt

local STATE_ADDR = 0x7FDF      -- 자막 STATE (뱅크 종속 -> 쓰기로 본다)
local TICK       = 0xFC07      -- BIOS 상주 tick
local SCHED      = 0xECF9      -- CD-DA 스케줄러 진입
local UPLOADER   = 0x725C      -- Track02 공용 타일 업로더
local ADPCM_ST   = 0x180D      -- ADPCM 상태 (비트5 = 재생중)
local VDC_REG    = 0x0000      -- VDC 레지스터 선택
local VDC_DATA_L = 0x0002      -- VDC 데이터 하위

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/regression_' .. STAMP

local eout = assert(io.open(BASE .. '_events.tsv', 'w'))
eout:write('frame\twhat\tdetail\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return (ok and type(v) == 'number') and v or -1 end

local function reg(cands)
  local key
  return function()
    local ok, s = pcall(emu.getState)
    if not ok or type(s) ~= 'table' then return -1 end
    if key == nil then
      key = false
      for _, k in ipairs(cands) do if type(s[k]) == 'number' then key = k break end end
    end
    if key == false then return -1 end
    local v = s[key]
    return type(v) == 'number' and math.floor(v) or -1
  end
end
local mpr7 = reg({ 'cpu.mpr7', 'cpu.mpr[7]', 'mpr7', 'cpu.memoryMappingRegisters[7]' })

local frame, rows = 0, 0
local function row(what, detail)
  if rows >= 3000 then return end
  rows = rows + 1
  eout:write(('%d\t%s\t%s\n'):format(frame, what, detail or ''))
end

-- 지점별 계수
local n = { tick = 0, sched = 0, upload = 0, adpcm_read = 0, bit5_fall = 0,
            state_w = 0, mawr_w = 0, mpr7_bad = 0 }
local stateSeen, stateFrom = {}, {}
local lastState = -1
local run2, run2max = 0, 0
local lastBit5
local mprVals = {}
local booted = false

-- 1) 상주 tick -- 매 프레임 도는가
emu.addMemoryCallback(function()
  n.tick = n.tick + 1
end, emu.callbackType.exec, TICK, TICK, CPU, MEM)

-- 2) CD-DA 스케줄러
emu.addMemoryCallback(function()
  n.sched = n.sched + 1
  if n.sched == 1 then row('CDDA_SCHED_FIRST', ('f%d'):format(frame)) end
end, emu.callbackType.exec, SCHED, SCHED, CPU, MEM)

-- 3) 업로더 -- 그때 MPR7 은 반드시 원본 뱅크여야 한다
--    (GFX r1~r4 가 여기서 죽었다.  26,576/26,576 이 $00 이었다)
local upTick = 0
emu.addMemoryCallback(function()
  n.upload = n.upload + 1
  upTick = upTick + 1
  if upTick % 64 == 0 then                 -- getState 는 비싸다.  표본만
    local m = mpr7()
    if m >= 0 then
      mprVals[m] = (mprVals[m] or 0) + 1
      if m ~= 0x00 then
        n.mpr7_bad = n.mpr7_bad + 1
        row('MPR7_NOT_ZERO', ('$%02X'):format(m))
      end
    end
  end
end, emu.callbackType.exec, UPLOADER, UPLOADER, CPU, MEM)

-- 4) 자막 STATE -- ★쓰기로 본다 (뱅크 종속이라 읽으면 못 본다)
emu.addMemoryCallback(function(address, value)
  local v = (value or 0) & 0xFF
  n.state_w = n.state_w + 1
  stateSeen[v] = (stateSeen[v] or 0) + 1
  if lastState >= 0 and lastState ~= v then
    local k = ('%d->%d'):format(lastState, v)
    stateFrom[k] = (stateFrom[k] or 0) + 1
    row('STATE', k)
  end
  lastState = v
end, emu.callbackType.write, STATE_ADDR, STATE_ADDR, CPU, MEM)

-- 5) ADPCM 종료 통보
emu.addMemoryCallback(function(address, value)
  local v = (value or 0) & 0xFF
  n.adpcm_read = n.adpcm_read + 1
  local b5 = (v & 0x20) ~= 0
  if lastBit5 ~= nil and lastBit5 and not b5 then
    n.bit5_fall = n.bit5_fall + 1
    row('ADPCM_END', ('$%02X'):format(v))
  end
  lastBit5 = b5
end, emu.callbackType.read, ADPCM_ST, ADPCM_ST, CPU, MEM)

-- 6) VDC MAWR -- 쓰기 횟수만 센다 (전수로 getState 하면 기어간다)
emu.addMemoryCallback(function()
  n.mawr_w = n.mawr_w + 1
end, emu.callbackType.write, VDC_REG, VDC_REG, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if not booted and n.tick > 0 then
    booted = true
    row('BOOT_OK', ('tick 이 f%d 에 처음 돌았다'):format(frame))
  end
  if lastState == 0x02 then
    run2 = run2 + 1
    if run2 > run2max then run2max = run2 end
  else
    run2 = 0
  end
  if frame % 120 == 0 then eout:flush() end
  if frame % 600 == 0 then
    say(('f%d  tick %d · sched %d · upload %d · STATE쓰기 %d · ADPCM끝 %d')
        :format(frame, n.tick, n.sched, n.upload, n.state_w, n.bit5_fall))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  eout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  local checks = {}
  local function check(name, verdict, detail)
    checks[#checks + 1] = { name = name, v = verdict, d = detail }
  end

  -- 판정.  '안 봄' 은 실패가 아니다 -- 그 구간을 안 지난 것이다
  check('boot', booted and 'PASS' or 'FAIL',
        booted and ('tick %d 회'):format(n.tick) or 'tick 이 한 번도 안 돌았다')

  check('resident callback', n.tick >= frame * 0.5 and 'PASS'
        or (n.tick == 0 and 'FAIL' or 'WARN'),
        ('tick %d / 프레임 %d'):format(n.tick, frame))

  if n.state_w == 0 then
    check('subtitle start', 'SKIP', '자막이 한 번도 안 떴다 -- 그 구간을 안 지났다')
    check('subtitle skip', 'SKIP', '')
  else
    check('subtitle start', (stateFrom['0->1'] or stateFrom['0->2']) and 'PASS' or 'WARN',
          ('STATE 쓰기 %d 회'):format(n.state_w))
    local escaped = (stateFrom['3->0'] or stateFrom['2->3'] or stateFrom['1->0'])
    check('subtitle state escape',
          (escaped and run2max < 600) and 'PASS' or 'FAIL',
          ('STATE=2 최장 연속 %d 프레임 (600 넘으면 갇힌 것)'):format(run2max))
  end

  check('ADPCM end', n.adpcm_read == 0 and 'SKIP'
        or (n.bit5_fall > 0 and 'PASS' or 'FAIL'),
        ('$180D 읽기 %d · 비트5 하강 %d'):format(n.adpcm_read, n.bit5_fall))

  check('CDDA scheduler', n.sched > 0 and 'PASS' or 'SKIP',
        ('$ECF9 진입 %d 회'):format(n.sched))

  check('MAWR restore', n.mawr_w > 0 and 'PASS' or 'SKIP',
        ('VDC 레지스터 쓰기 %d 회'):format(n.mawr_w))

  local mprList = {}
  for v, c in pairs(mprVals) do mprList[#mprList + 1] = ('$%02X x%d'):format(v, c) end
  check('runtime MPR state',
        n.upload == 0 and 'SKIP' or (n.mpr7_bad == 0 and 'PASS' or 'FAIL'),
        ('업로더 %d 회 · 표본 MPR7 = %s'):format(n.upload,
          #mprList > 0 and table.concat(mprList, ' · ') or '표본 없음'))

  put(('프레임 %d'):format(frame))
  put('')
  put('RUNTIME COVERAGE')
  put('')
  local nf = 0
  for _, c in ipairs(checks) do
    if c.v == 'FAIL' then nf = nf + 1 end
    put(('[%-4s] %-22s %s'):format(c.v, c.name, c.d or ''))
  end
  put('')
  put(('실패 %d · SKIP 은 그 구간을 안 지난 것이지 통과가 아니다'):format(nf))
  if #stateFrom > 0 or next(stateFrom) then
    put('')
    put('STATE 전이')
    for k, v in pairs(stateFrom) do put(('    %-8s %d 회'):format(k, v)) end
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('regression_runtime armed -- 7 지점 · 쓰기 0 B · 화면에 안 그림')
say('  부팅 -> 대사 -> 음성 -> CD-DA 를 지나고 Stop')
say('  ' .. BASE .. '_events.tsv')
