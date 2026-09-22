-- SUB 0.5.192 -- 자막 트리거 관문이 어디서 새는가  ★순수 관측 · 쓰기 0 B · 화면에 안 그림
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- ADPCM 음성 **바로 다음 대사 하나**만 치환이 안 되고 일본어로 뜬다.
-- 다른 대사는 전부 정상.  PC 는 되는데 안드로이드 RetroArch 는 코어 3 종
-- (PCE Fast · SuperGrafx · GearFX) 전부 처음부터 안 됐다.
--
-- BIOS $FED7-$FEF9 가 그 트리거 전체다 (0.6.3-diag-adpcm132-ab 실측 디스어셈):
--
--     $FED7  LDA $22A6 / BNE 탈출            ┐
--     $FEDC  LDA $22A7 / CMP #$68 / BNE 탈출 ├ 지문 "E6800_0E"  전부 게임 RAM
--     $FEE3  LDA $22AA / CMP #$0E / BNE 탈출 ┘
--     $FEEA  LDA $180D                        ★ 하드웨어 레지스터
--     $FEED  AND #$20
--     $FEEF  BEQ  -> $FF0D                    ★ 여기서 새면 아래 둘 다 못 한다
--     $FEF1  LDA #$01 / STA $7FDF             STATE = 1
--     $FEF6  STZ $22A7                        consume (지문 소거)
--     $FEF9  RTS
--
-- ★ 이 경로에서 **유일하게 에뮬 구현에 의존하는 곳이 `$FEEA` 하나다.**
--   지문 셋은 게임 RAM 이라 어느 에뮬에서든 같은 값이 나온다.
--
-- 새면 증상이 둘 한꺼번에 나온다 -- 별개 버그가 아니라 한 분기다:
--     STATE 를 못 세운다   -> ADPCM 자막이 안 뜬다
--     STZ 를 못 지난다     -> $22A7 에 $68 이 남는다
--                          -> 다음 대사가 트리거로 오인돼 치환을 건너뛴다 (일본어)
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) $FED7 진입 횟수            -- 트리거 루틴이 돌기는 하는가
--   2) $FEEA 도달 횟수            -- 지문 셋을 통과했는가
--   3) $FEED 에서 A 값            -- ★$180D 가 실제로 돌려준 바이트.  값 분포로 남긴다
--   4) $FEF1 / $FEF6 도달 횟수    -- 관문을 통과했는가 · consume 이 돌았는가
--   5) $22A7 에 누가 쓰는가        -- consume 말고 다른 쓰기가 있는가
--   6) 매 프레임 $22A7 · $7FDF 표본 -- $68 이 남아 굳는 순간이 보인다
--
-- 판정
--   $FEEA > 0 이고 $FEF1 == 0            -> ★관문에서 샌다.  $180D 값 분포가 답이다
--   $FEEA > 0 이고 $FEF1 == $FEEA        -> 관문 정상.  범인은 여기가 아니다
--   $FEEA == 0 이고 $FED7 > 0            -> 지문에서 이미 탈락.  $22A6/$22A7/$22AA 를 볼 것
--   $FED7 == 0                           -> ★그 장면을 안 지났다.  "이상 없음"이 아니다
--                                           음성 있는 자리를 다시 지날 것
--
-- 쓰는 법
--   1) 이것만 로드 (다른 Lua 와 같이 올리지 말 것).  정상 속도
--   2) ADPCM 음성이 나오고 **그 다음 대사가 뜨는 자리**를 지난다
--      -- 음성 -> 대사 를 두세 번 반복하면 표본이 는다
--   3) Stop -> _summary.txt 를 본다
--
-- 산출물  C:/snatcher/dump/triggergate_0_5_192_<시각>_events.tsv
--         C:/snatcher/dump/triggergate_0_5_192_<시각>_summary.txt

local A_ENTRY   = 0xFED7      -- 지문 검사 시작
local A_HWREAD  = 0xFEEA      -- LDA $180D   (지문 통과)
local A_AFTER   = 0xFEED      -- AND #$20    이 시점 A = $180D 원값
local A_PASS    = 0xFEF1      -- 관문 통과
local A_CONSUME = 0xFEF6      -- STZ $22A7
local FLAG      = 0x22A7      -- 지문 하위바이트
local FLAG_HI   = 0x22A6
local FLAG_2    = 0x22AA
local STATE     = 0x7FDF

local MAX_ROWS = 4000
local REPORT   = 300

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/triggergate_0_5_192_' .. STAMP

local eout = assert(io.open(BASE .. '_events.tsv', 'w'))
eout:write('frame\twhat\ta_or_value\tflag_22A6\tflag_22A7\tflag_22AA\tstate_7FDF\tpc\n')
eout:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return (ok and type(v) == 'number') and v or -1 end

-- emu.getState() 는 평평한 키다.  판마다 이름이 달라서 후보를 훑어 한 번만 정한다
local function makeReader(cands)
  local key
  return function()
    local ok, s = pcall(emu.getState)
    if not ok or type(s) ~= 'table' then return -1 end
    if key == nil then
      key = false
      for _, k in ipairs(cands) do
        if type(s[k]) == 'number' then key = k break end
      end
    end
    if key == false then return -1 end
    local v = s[key]
    return type(v) == 'number' and math.floor(v) or -1
  end
end

local pcNow = makeReader({ 'cpu.pc', 'cpu.programCounter', 'pc', 'cpu.PC' })
local aNow  = makeReader({ 'cpu.a', 'cpu.A', 'a', 'cpu.regA' })

local frame, rows = 0, 0
local nEntry, nHw, nPass, nConsume = 0, 0, 0, 0
local hwVals   = {}          -- $180D 원값 분포
local entryFp  = {}          -- 지문 탈락 조합 분포
local flagSeen = {}          -- 매 프레임 $22A7 분포
local stuckRun, stuckMax = 0, 0
local otherWrites, consumeWrites = 0, 0
local otherPc = {}

local function row(what, val)
  if rows >= MAX_ROWS then return end
  rows = rows + 1
  eout:write(('%d\t%s\t%s\t$%02X\t$%02X\t$%02X\t$%02X\t$%04X\n'):format(
    frame, what,
    (type(val) == 'number' and val >= 0) and ('$%02X'):format(val & 0xFF) or '',
    rd(FLAG_HI) & 0xFF, rd(FLAG) & 0xFF, rd(FLAG_2) & 0xFF, rd(STATE) & 0xFF,
    pcNow() & 0xFFFF))
  eout:flush()
end

-- 1) 트리거 진입
emu.addMemoryCallback(function()
  nEntry = nEntry + 1
  local k = ('%02X/%02X/%02X'):format(rd(FLAG_HI) & 0xFF, rd(FLAG) & 0xFF, rd(FLAG_2) & 0xFF)
  entryFp[k] = (entryFp[k] or 0) + 1
  row('ENTRY', -1)
end, emu.callbackType.exec, A_ENTRY, A_ENTRY, CPU, MEM)

-- 2) 지문 통과 -- 이제 하드웨어를 읽는다
emu.addMemoryCallback(function()
  nHw = nHw + 1
  row('FP_OK', -1)
end, emu.callbackType.exec, A_HWREAD, A_HWREAD, CPU, MEM)

-- 3) ★ $180D 가 돌려준 원값 (A 에 들어 있다)
emu.addMemoryCallback(function()
  local a = aNow() & 0xFF
  hwVals[a] = (hwVals[a] or 0) + 1
  row('HW_180D', a)
end, emu.callbackType.exec, A_AFTER, A_AFTER, CPU, MEM)

-- 4) 관문 통과
emu.addMemoryCallback(function()
  nPass = nPass + 1
  row('GATE_PASS', -1)
end, emu.callbackType.exec, A_PASS, A_PASS, CPU, MEM)

-- 5) consume 실행
emu.addMemoryCallback(function()
  nConsume = nConsume + 1
  row('CONSUME', -1)
end, emu.callbackType.exec, A_CONSUME, A_CONSUME, CPU, MEM)

-- 6) $22A7 에 누가 쓰는가 (consume 말고 다른 놈이 있는지)
emu.addMemoryCallback(function(address, value)
  local pc = pcNow() & 0xFFFF
  if pc >= 0xFEF6 and pc <= 0xFEF9 then
    consumeWrites = consumeWrites + 1
  else
    otherWrites = otherWrites + 1
    otherPc[pc] = (otherPc[pc] or 0) + 1
    row('WRITE_OTHER', value)
  end
end, emu.callbackType.write, FLAG, FLAG, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local f = rd(FLAG) & 0xFF
  flagSeen[f] = (flagSeen[f] or 0) + 1
  if f == 0x68 then
    stuckRun = stuckRun + 1
    if stuckRun > stuckMax then stuckMax = stuckRun end
  else
    stuckRun = 0
  end
  if frame % REPORT == 0 then
    say(('f%d  진입 %d · 지문통과 %d · 관문통과 %d · consume %d   $22A7=$%02X')
        :format(frame, nEntry, nHw, nPass, nConsume, f))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  eout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end

  local function dist(name, t, fmt)
    local r = {}
    for v, c in pairs(t) do r[#r + 1] = { v = v, c = c } end
    table.sort(r, function(x, y) return x.c > y.c end)
    local parts = {}
    for i = 1, math.min(#r, 8) do
      parts[#parts + 1] = (fmt):format(r[i].v, r[i].c)
    end
    put(('%s (%d 가지): %s'):format(name, #r, table.concat(parts, ' · ')))
  end

  put(('프레임 %d'):format(frame))
  put('')
  put(('$FED7 진입      %d'):format(nEntry))
  put(('$FEEA 지문통과  %d'):format(nHw))
  put(('$FEF1 관문통과  %d'):format(nPass))
  put(('$FEF6 consume   %d'):format(nConsume))
  put('')

  if nEntry == 0 then
    put('★ 트리거 루틴이 한 번도 안 돌았다.')
    put('   0 은 "이상 없음" 이 아니라 "안 보고 있었음" 이다.')
    put('   ADPCM 음성이 나오고 그 다음 대사가 뜨는 자리를 지나야 한다.')
  elseif nHw == 0 then
    put('★ 지문에서 이미 탈락한다.  $180D 까지 못 갔다.')
    put('   기대값: $22A6=$00 · $22A7=$68 · $22AA=$0E')
    dist('   진입 시 지문 조합 22A6/22A7/22AA', entryFp, '%s x%d')
  elseif nPass == 0 then
    put('★★ 관문 $FEEF 에서 전부 샌다.  $180D 비트5 가 한 번도 안 섰다.')
    put('   -> STATE 도 못 서고 consume 도 못 돈다.  증상 둘이 여기서 같이 나온다.')
    dist('   $180D 원값', hwVals, '$%02X x%d')
  elseif nPass < nHw then
    put(('관문을 %d/%d 만 통과한다 -- 샐 때가 있다.'):format(nPass, nHw))
    dist('   $180D 원값', hwVals, '$%02X x%d')
  else
    put('관문은 정상 통과한다 (지문통과 == 관문통과).  범인은 여기가 아니다.')
    dist('   $180D 원값', hwVals, '$%02X x%d')
  end

  put('')
  put(('$22A7 쓰기   consume %d · 그 밖 %d'):format(consumeWrites, otherWrites))
  if otherWrites > 0 then
    local r = {}
    for p, c in pairs(otherPc) do r[#r + 1] = { p = p, c = c } end
    table.sort(r, function(x, y) return x.c > y.c end)
    for i = 1, math.min(#r, 10) do
      put(('   PC $%04X  %d 회'):format(r[i].p, r[i].c))
    end
  end
  dist('$22A7 프레임 표본', flagSeen, '$%02X x%d')
  put(('$22A7 가 $68 로 연속으로 남은 최장 구간: %d 프레임'):format(stuckMax))
  if stuckMax > 120 then
    put('   ★ 지문이 오래 굳어 있다 -- 이 동안 들어온 대사는 치환을 건너뛴다')
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.192-trigger-gate armed -- $FED7-$FEF6 감시 · 쓰기 0 B · 화면에 안 그림')
say('  ADPCM 음성 -> 그 다음 대사 자리를 두세 번 지난 뒤 Stop')
say('  ' .. BASE .. '_events.tsv')
