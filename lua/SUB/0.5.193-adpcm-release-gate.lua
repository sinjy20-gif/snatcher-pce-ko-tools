-- SUB 0.5.193 -- ADPCM 자막 철거 관문이 열리는가  ★순수 관측 · 쓰기 0 B · 화면에 안 그림
--
-- 0.5.192 가 알아낸 것
-- ---------------------------------------------------------------------------
-- $FED7 진입 0.  그 블록은 **죽은 코드**다 -- `direct_return_patch` 가 $FEC9 에
-- 무조건 RTS 를 박아 폴스루를 끊어놨다 (`legacy_fec7_fallthrough: false`).
-- 0 이 "이상 없음" 이 아니라 "그 코드는 안 돈다" 였다.
--
-- 살아 있는 자리 -- 뱅크1 $FC38 (정적 디스어셈, 0.6.3-diag-adpcm132-ab)
-- ---------------------------------------------------------------------------
--     $FC38  LDA $7FDF / CMP #$02 / BNE -> $FC65      STATE=2(자막 활성)일 때만
--     $FC3F  LDA $5E1E / CMP #$CD / BEQ -> $FC65
--     $FC46  LDA $180D                                ★ADPCM 재생중 비트
--     $FC49  AND #$20                                  이 시점 A = $180D 원값
--     $FC4B  BEQ -> $FC54                              비트 꺼짐 = 끝났다
--     $FC4D  LDA $2101 / CMP #$84 / BCC -> $FC65       비트 켜짐 = 아직 재생중
--     $FC54  LDA $5CFC / BEQ -> $FC5E                  스킵 걸쇠
--     $FC59  STZ $5CFC / BRA -> $FC65                  걸쇠 있으면 소비만 하고 나감
--     $FC5E  LDA #$03 / STA $7FDF                     ★STATE=3 = 자막 철거·슬롯 반납
--
-- 왜 이게 증상과 맞나
--   $180D 비트5 가 계속 켜진 것으로 읽히면 $FC5E 에 영영 못 간다
--   -> STATE 가 2 에 갇힌다 -> 슬롯이 반납 안 된다
--   -> ADPCM 다음 대사가 치환을 못 받고 **일본어로 뜬다**   ← 지금 증상
--   132/138 의 `diagnostic_force_release_after_frames` 가 이 관문의 우회책이었다
--
-- ⚠ 뱅크 별칭
--   CPU $FC46 은 뱅크0 에도 있다 (거긴 `A9 FF 60`).  뱅크1 서명 `AD 0D 18` 을
--   그 자리에서 직접 읽어 확인하고, 아니면 세지 않는다.
--
-- 무엇을 재나
--   1) $FC38 진입 · 그때의 STATE
--   2) $FC49 에서 A = $180D 원값        ★값 분포가 핵심
--   3) 비트5 켜짐(->$FC4D) / 꺼짐(->$FC54) 갈래별 횟수
--   4) $FC5E 도달 = 철거 성공 횟수
--   5) STATE 가 2 로 연속으로 머문 최장 프레임 (슬롯이 안 돌아온 시간)
--   6) $5CFC 걸쇠가 철거를 삼킨 횟수
--
-- 판정
--   $FC46 > 0, $FC5E == 0        -> ★관문이 안 열린다.  $180D 분포를 볼 것
--   $FC5E > 0, STATE2 최장 짧음  -> 정상.  메센 기준선 확보 (안드로이드와 대조용)
--   $FC54 > 0 인데 $FC5E == 0    -> ★$5CFC 걸쇠가 철거를 삼킨다
--   $FC38 == 0                   -> ★그 장면을 안 지났다.  "이상 없음" 아님
--
-- 쓰는 법
--   1) 이것만 로드.  정상 속도
--   2) ADPCM 음성 -> 그 다음 대사 자리를 두세 번 지난다
--   3) Stop -> _summary.txt
--
-- 산출물  C:/snatcher/dump/relgate_0_5_193_<시각>_events.tsv
--         C:/snatcher/dump/relgate_0_5_193_<시각>_summary.txt

local A_ENTRY   = 0xFC38      -- STATE 검사 진입
local A_HWREAD  = 0xFC46      -- LDA $180D
local A_AFTER   = 0xFC49      -- AND #$20   (A = $180D 원값)
local A_PLAYING = 0xFC4D      -- 비트5 켜짐 갈래 (아직 재생중)
local A_ENDED   = 0xFC54      -- 비트5 꺼짐 갈래 (끝났다)
local A_TEARDN  = 0xFC5E      -- STATE = 3

local STATE  = 0x7FDF
local LATCH  = 0x5CFC
local GUARD  = 0x5E1E
local LEVEL  = 0x2101

local MAX_ROWS = 4000
local REPORT   = 300

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/relgate_0_5_193_' .. STAMP

local eout = assert(io.open(BASE .. '_events.tsv', 'w'))
eout:write('frame\twhat\ta_180D\tstate\tlatch_5CFC\tguard_5E1E\tlevel_2101\n')
eout:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return (ok and type(v) == 'number') and v or -1 end

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
local aNow = makeReader({ 'cpu.a', 'cpu.A', 'a', 'cpu.regA' })

-- ★뱅크1 이 얹혀 있을 때만 센다.  뱅크0 의 $FC46 은 `A9 FF 60` 이다
local function bank1()
  return rd(0xFC46) == 0xAD and rd(0xFC47) == 0x0D and rd(0xFC48) == 0x18
end

local frame, rows = 0, 0
local nEntry, nHw, nPlaying, nEnded, nTeardown, nLatchEat = 0, 0, 0, 0, 0, 0
local nAlias = 0
local hwVals, stateAtEntry, stateSeen = {}, {}, {}
local run2, run2max = 0, 0

local function row(what, a)
  if rows >= MAX_ROWS then return end
  rows = rows + 1
  eout:write(('%d\t%s\t%s\t$%02X\t$%02X\t$%02X\t$%02X\n'):format(
    frame, what,
    (type(a) == 'number' and a >= 0) and ('$%02X'):format(a & 0xFF) or '',
    rd(STATE) & 0xFF, rd(LATCH) & 0xFF, rd(GUARD) & 0xFF, rd(LEVEL) & 0xFF))
  eout:flush()
end

local function hook(addr, fn)
  emu.addMemoryCallback(function()
    if not bank1() then nAlias = nAlias + 1 return end
    fn()
  end, emu.callbackType.exec, addr, addr, CPU, MEM)
end

hook(A_ENTRY, function()
  nEntry = nEntry + 1
  local s = rd(STATE) & 0xFF
  stateAtEntry[s] = (stateAtEntry[s] or 0) + 1
  row('ENTRY', -1)
end)

hook(A_HWREAD, function()
  nHw = nHw + 1
  row('STATE2_OK', -1)
end)

hook(A_AFTER, function()
  local a = aNow() & 0xFF
  hwVals[a] = (hwVals[a] or 0) + 1
  row('HW_180D', a)
end)

hook(A_PLAYING, function()
  nPlaying = nPlaying + 1
  row('STILL_PLAYING', -1)
end)

hook(A_ENDED, function()
  nEnded = nEnded + 1
  if (rd(LATCH) & 0xFF) ~= 0 then nLatchEat = nLatchEat + 1 end
  row('ENDED_PATH', -1)
end)

hook(A_TEARDN, function()
  nTeardown = nTeardown + 1
  row('TEARDOWN', -1)
end)

emu.addEventCallback(function()
  frame = frame + 1
  local s = rd(STATE) & 0xFF
  stateSeen[s] = (stateSeen[s] or 0) + 1
  if s == 0x02 then
    run2 = run2 + 1
    if run2 > run2max then run2max = run2 end
  else
    run2 = 0
  end
  if frame % REPORT == 0 then
    say(('f%d  진입 %d · STATE2통과 %d · 재생중 %d · 끝남 %d · 철거 %d   STATE=$%02X')
        :format(frame, nEntry, nHw, nPlaying, nEnded, nTeardown, s))
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
    for i = 1, math.min(#r, 8) do parts[#parts + 1] = (fmt):format(r[i].v, r[i].c) end
    put(('%s (%d 가지): %s'):format(name, #r, table.concat(parts, ' · ')))
  end

  put(('프레임 %d'):format(frame))
  put('')
  put(('$FC38 진입        %d      (뱅크0 별칭으로 걸러낸 것 %d)'):format(nEntry, nAlias))
  put(('$FC46 STATE2 통과 %d'):format(nHw))
  put(('$FC4D 아직재생중  %d'):format(nPlaying))
  put(('$FC54 끝남 갈래   %d'):format(nEnded))
  put(('$FC5E 철거        %d'):format(nTeardown))
  put(('  그중 $5CFC 걸쇠가 삼킨 것 %d'):format(nLatchEat))
  put('')

  if nEntry == 0 then
    put('★ 상태기계가 한 번도 안 돌았다.  0 은 "이상 없음" 이 아니다.')
    put('   ADPCM 음성이 나오고 그 다음 대사가 뜨는 자리를 지나야 한다.')
  elseif nHw == 0 then
    put('★ STATE 가 2 인 적이 없다 -- 자막이 활성으로 안 들어간다.')
    dist('   진입 시 STATE', stateAtEntry, '$%02X x%d')
  elseif nTeardown == 0 then
    put('★★ 철거에 한 번도 도달 못 한다.  STATE 가 2 에 갇힌다.')
    put('   -> 슬롯이 반납 안 되고 다음 대사가 일본어로 뜬다.  증상과 일치.')
    dist('   $180D 원값', hwVals, '$%02X x%d')
    if nEnded > 0 then
      put(('   ※ 끝남 갈래에는 %d 번 갔는데 철거는 0 -> $5CFC 걸쇠가 삼킨다'):format(nEnded))
    end
  else
    put('철거가 돈다 -- 이 환경에서는 관문이 정상이다 (기준선 확보).')
    dist('   $180D 원값', hwVals, '$%02X x%d')
  end

  put('')
  dist('STATE 프레임 표본', stateSeen, '$%02X x%d')
  put(('STATE 가 $02 로 연속으로 머문 최장 구간: %d 프레임'):format(run2max))
  if run2max > 600 then
    put('   ★ 10초 넘게 활성이다 -- 사실상 안 풀린 것으로 본다')
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.193-adpcm-release-gate armed -- 뱅크1 $FC38-$FC5E · 쓰기 0 B · 화면에 안 그림')
say('  ADPCM 음성 -> 그 다음 대사 자리를 두세 번 지난 뒤 Stop')
say('  ' .. BASE .. '_events.tsv')
