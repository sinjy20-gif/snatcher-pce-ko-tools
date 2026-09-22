-- CDDA 0.4.0 -- $263B 이 트랙마다 바뀌는가 · OR 이 0 이 되는가
--
-- 순수 관측. 아무것도 안 쓰고 화면에도 안 그린다.
--
-- 왜
-- --
-- 2026-09-07 Mednafen 에서 트랙 17→18→19 를 넘기며 다섯 지점을 떴다:
--
--     $20A2   $263B   $263C   $2638   OR
--      17      17      01      00      1
--      17      17      00      01      1
--      18      18      01      01      1
--      18      18      01      01      1
--      19      19      01      00      1
--
-- 둘을 읽었다.
--   ① OR($263C|$2638) 이 트랙 경계에서도 0 이 안 됐다 -> OR 에지는 못 쓴다
--   ② $263B 이 트랙마다 정확히 바뀐다. 게임 드라이버($6000 대역)가
--      스스로 유지하는 값이라 우리 패치 타이밍과 무관하다
--
-- 그런데 그 다섯 장은 **표본**이다. 브레이크 사이에 OR 이 잠깐 0 이 됐을 수
-- 있다. 메센에서는 쓰기 콜백으로 **모든 전이**를 잡을 수 있으니 그걸 확정한다.
--
-- 이 프로브가 답할 것 -- 셋
--   ① $263B 이 메센에서도 트랙마다 바뀌는가 (Mednafen 표와 대조)
--   ② OR 이 단 한 번이라도 0 이 되는가. 되면 언제, 몇 프레임이나
--   ③ $263B 이 바뀌는 순간과 무장이 일어나는 순간의 순서
--
-- 쓰는 법
--   1) 0.6.0-rc3-restored 로 Power Cycle.
--   2) 이 스크립트 하나만. 상태를 바꾸는 Lua 는 같이 올리지 않는다.
--   3) CD-DA 트랙이 두 번 이상 바뀌는 구간을 지난다 (오프닝이면 충분).
--   4) ★ 반드시 Stop 한다. 요약이 그때 나온다.
--
-- 산출물  C:/snatcher/dump/cdda_track_signal_0_4_0_<시각>.tsv

local VERSION = '0.4.0'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/cdda_track_signal_0_4_0_' .. STAMP .. '.tsv'

local A_263B = 0x263B   -- 게임이 유지하는 현재 트랙 (BCD)
local A_263C = 0x263C   -- 짧은 에지
local A_2638 = 0x2638   -- 레벨
local A_20A2 = 0x20A2   -- SUBQ 트랙 (BCD)
local A_26F9 = 0x26F9   -- raw 트랙 (hex)
local A_5E1A = 0x5E1A   -- CD-DA 사설 상태
local A_5E1B = 0x5E1B   -- 무장된 트랙

local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\tpc\t263B\t20A2\t26F9\t263C\t2638\tOR\t5E1A\t5E1B\tnote\n')

local frame, rows = 0, 0
local last = {}
local orZeroFrames, orZeroRuns = 0, 0
local inOrZero = false
local trackChanges, arms = 0, 0
local firstOrZero = nil

local function rb(a) return emu.read(a, MEM, false) or 0 end
local function say(m) emu.log(m); print(m) end

local function pc()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' or type(st.cpu) ~= 'table' then return -1 end
  return st.cpu.pc or st.cpu.PC or -1
end

local function emit(kind, note)
  local c, e = rb(A_263C), rb(A_2638)
  local p = pc()
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%d\t%02X\t%02X\t%s\n',
    frame, kind, p >= 0 and string.format('%04X', p) or '-',
    rb(A_263B), rb(A_20A2), rb(A_26F9), c, e,
    ((c ~= 0 or e ~= 0) and 1 or 0), rb(A_5E1A), rb(A_5E1B), note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end

-- ---- 쓰기를 전부 잡는다. 표본이 아니라 전이 그 자체 -------------------------

local function onWrite(addr, name)
  emu.addMemoryCallback(function(_a, value)
    local before = last[name]
    if before == value then return end
    last[name] = value
    local note = string.format('%s %s->%02X',
      name, before and string.format('%02X', before) or '?', value)
    if name == '263B' then
      trackChanges = trackChanges + 1
      note = note .. '  ★트랙 바뀜'
      say(string.format('f%-7d TRACK   $263B %s->%02X   $20A2=%02X $26F9=%02X',
        frame, before and string.format('%02X', before) or '?', value,
        rb(A_20A2), rb(A_26F9)))
    end
    emit('WRITE', note)
  end, emu.callbackType.write, addr, addr, CPU, MEM)
end

onWrite(A_263B, '263B')
onWrite(A_263C, '263C')
onWrite(A_2638, '2638')

-- 무장 순간도 같이 본다 ($5E1A 에 02 가 써질 때)
emu.addMemoryCallback(function(_a, value)
  if value ~= 2 then return end
  arms = arms + 1
  emit('ARM', string.format('무장 #%d', arms))
  say(string.format('f%-7d ARM     $263B=%02X $20A2=%02X  $263C=%02X $2638=%02X',
    frame, rb(A_263B), rb(A_20A2), rb(A_263C), rb(A_2638)))
end, emu.callbackType.write, A_5E1A, A_5E1A, CPU, MEM)

-- ---- 프레임마다 OR 이 0 인지 센다 -------------------------------------------
--
-- ★ 이것은 프레임 표본이다. 프레임 사이에 OR 이 잠깐 0 이었다가 돌아오면
--   여기서는 안 잡힌다. 다만 위의 쓰기 콜백이 모든 전이를 잡으므로,
--   둘을 대조하면 0 구간을 놓칠 일이 없다.

emu.addEventCallback(function()
  frame = frame + 1
  local zero = (rb(A_263C) == 0 and rb(A_2638) == 0)
  if zero then
    orZeroFrames = orZeroFrames + 1
    if not inOrZero then
      inOrZero = true
      orZeroRuns = orZeroRuns + 1
      if not firstOrZero then firstOrZero = frame end
      emit('OR_ZERO_IN', '★OR 이 0 이 됐다')
      say(string.format('f%-7d OR=0    $263B=%02X $20A2=%02X   ★', frame,
        rb(A_263B), rb(A_20A2)))
    end
  elseif inOrZero then
    inOrZero = false
    emit('OR_ZERO_OUT', 'OR 이 다시 1')
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say(string.format('끝  프레임 %d', frame))
  say(string.format('  트랙 바뀜($263B 쓰기)  %d회', trackChanges))
  say(string.format('  무장($5E1A<-02)        %d회', arms))
  say('')
  if orZeroRuns == 0 then
    say('  ★ OR 이 한 번도 0 이 안 됐다.')
    say('     Mednafen 표본과 같은 결론 -- OR 에지는 신호로 못 쓴다.')
  else
    say(string.format('  OR 이 0 인 구간 %d개 · 합 %d프레임 · 첫 발생 f%d',
      orZeroRuns, orZeroFrames, firstOrZero or -1))
    say('     0 이 되는 구간이 있다. 길이와 위치를 트랙 경계와 대조할 것.')
  end
  say('')
  if trackChanges == 0 then
    say('  ★ $263B 이 한 번도 안 바뀌었다. 트랙 경계를 안 지났거나')
    say('     메센에서는 이 바이트가 트랙을 안 따라간다. TSV 를 직접 볼 것')
  else
    say('  $263B 이 트랙마다 바뀐다면 Mednafen(17→18→19)과 같다.')
    say('  TSV 의 263B / 20A2 칸이 나란히 가는지 확인할 것.')
  end
  out:write('#\n')
  out:write(string.format('# frames=%d track_changes=%d arms=%d or_zero_runs=%d or_zero_frames=%d\n',
    frame, trackChanges, arms, orZeroRuns, orZeroFrames))
  out:close()
  say('-> ' .. OUT)
end, emu.eventType.scriptEnded)

say('CDDA ' .. VERSION .. ' track-signal -- 화면 표시 없음')
say('  $263B/$263C/$2638 쓰기를 전부 잡고, OR 이 0 이 되는지 센다')
say('  Mednafen 실측: 17→18→19 를 넘는 동안 OR 이 한 번도 0 이 아니었다')
say('-> ' .. OUT)
