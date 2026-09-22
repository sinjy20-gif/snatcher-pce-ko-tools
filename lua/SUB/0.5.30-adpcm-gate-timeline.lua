-- SUB 0.5.30 -- ADPCM 감지기의 게이트 조건을 산술로 확정한다
--
-- 왜 필요한가
-- ---------------------------------------------------------------------------
-- 0.4.6.26 이 실기에서 크래시했다 (BASELINE §11.8).  decision 75/76 B 로 정적
-- 빌드·디스어셈은 전부 통과했는데 게이트가 **매 프레임 열렸다**.
--
--     LDA $180D / AND #$20 / BEQ idle      "재생 중이면 통과"
--
-- 여기에 "음성이 끝나면 이 비트가 0 이 된다" 를 얹었는데 **한 번도 재지 않았다.**
-- 기존 게이트는 `CMP #$68` 로 음성 하나만 받아 이 문제가 안 드러났을 뿐이다.
--
--     ★ $180D 비트 의미는 측정 대상이지 독해 대상이 아니다.
--
-- 이 프로브가 그 그래프를 만든다.  나오기 전에는 아무것도 빌드에 넣지 않는다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) 음성 한 개 동안 프레임 단위 타임라인
--        $180D bit $20   시작 · 유지 · 종료.  조각 사이에 0 이 되는가
--        $22A7           음성이 끝난 뒤에도 값이 남는가 (남으면 재무장 조건이 못 된다)
--        $22A6 / $22AA   같은 구간에서의 움직임
--        $7FDF           state 가 실제로 몇 번 1 이 되는가
--   2) 정확한 모서리 -- 위 주소들에 대한 **쓰기/읽기 이벤트** (값 · PC · 프레임)
--        프레임 격자는 전이 순간을 놓친다.  콜백이 그 사이를 메운다
--   3) ★ 후보 게이트 6 종을 Lua 에서 **모의 실행**해 무장 횟수를 센다
--        실제 음성 수와 같은 것 하나만이 답이다.  빌드 왕복 없이 산술로 고른다
--   4) ★ $7FE8-$7FFF 쓰기 감시 (§11.7 의 나머지 의존성 -- `last` 를 둘 1 B)
--        같은 주행에서 공짜로 얻는다.  한 바이트라도 게임이 건드리면 그 자리는 탈락
--
-- 왜 포트를 폴링해 읽지 않는가
-- ---------------------------------------------------------------------------
-- $180C/$180D 는 하드웨어 포트다.  emu.read 로 매 프레임 두드리면 상태 래치를
-- 건드려 **측정이 대상을 바꿀 수 있다.**  그래서 두 경로만 쓴다.
--
--     $180D  게임의 **쓰기**를 그림자로 추적한다 (제어 래치라 쓰기가 곧 값이다)
--     $180C  게임이 **스스로 읽을 때** 콜백으로 그 값을 주워 담는다 ($F6EF 폴링 루틴)
--
-- 그래서 이 프로브는 ADPCM 재생에 어떤 영향도 주지 않는다.
--
-- ⚠ $7FDF 는 $6000-$7FFF (MPR3) 다.  뱅크 $6A 가 안 걸린 프레임의 읽기값은
--   남의 뱅크다.  mpr3 열을 같이 적고, 어긋난 프레임은 state 를 `-` 로 남긴다.
--   (프로젝트 규칙: 뱅크 확인 없이 이 창을 프레임 단위로 믿지 않는다)
--
-- 읽기 전용이다.  자막 스택을 물지 않고 화면에 아무것도 그리지 않는다.
-- Power Cycle 뒤 이 파일 하나만 로드하고, **음성이 여러 개 나오는 구간**을 돈다.
-- 조각이 여럿인 긴 음성이 하나라도 포함되게 돌 것 (조각 사이 거동이 핵심이다).

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

-- ---------------------------------------------------------------------------
-- 감시 대상
-- ---------------------------------------------------------------------------
local A_FIN_LO, A_FIN_HI, A_RATE = 0x22A6, 0x22A7, 0x22AA
local STATE                      = 0x7FDF
local PORT_LO, PORT_HI           = 0x1800, 0x180F
local FREE_LO, FREE_HI           = 0x7FE8, 0x7FFF   -- §11.7 후보 24 B

local PRE_ROLL  = 30      -- 음성 시작 전 보관 프레임
local TAIL      = 180     -- 종료 후 계속 기록할 프레임 (약 3 초)
local MAX_EVENT = 4000    -- 이벤트 파일 상한

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT_T = 'C:/snatcher/dump/adpcm_gate_timeline_0_5_30_' .. STAMP .. '.tsv'
local OUT_E = 'C:/snatcher/dump/adpcm_gate_events_0_5_30_'   .. STAMP .. '.tsv'
local OUT_S = 'C:/snatcher/dump/adpcm_gate_summary_0_5_30_'  .. STAMP .. '.txt'

local ft = io.open(OUT_T, 'w')
local fe = io.open(OUT_E, 'w')
local fs = io.open(OUT_S, 'w')

if ft then
  ft:write('frame\tvoice\tphase\tplaying\td180D\tbit20\td180C\t' ..
           's22A6\ts22A7\ts22AA\tstate\tmpr3\t' ..
           'A\tA2\tB\tC\tD\tE\n')
end
if fe then fe:write('frame\tkind\taddr\tvalue\tpc\tnote\n') end

-- ---------------------------------------------------------------------------
-- 상태 읽기
-- ---------------------------------------------------------------------------
local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function curPC()
  local s = st()
  if not s then return -1 end
  for _, k in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[k]) == 'number' then return math.floor(s[k]) & 0xFFFF end
  end
  return -1
end

local function mpr3(s)
  for _, k in ipairs({ 'cpu.mpr[3]', 'mpr3', 'memoryManager.mpr[3]' }) do
    local v = s and s[k]
    if type(v) == 'number' then return math.floor(v) & 0xFF end
  end
  return -1
end

local function rb(a) return emu.read(a, MEM) or 0 end

-- ---------------------------------------------------------------------------
-- 포트 그림자 -- 폴링 대신 쓰기/읽기 콜백으로 값을 안다
-- ---------------------------------------------------------------------------
local shadow180D = 0      -- 게임이 마지막으로 **쓴** 값
local seen180C   = 0      -- 게임이 마지막으로 **읽은** 값
local seen180C_f = -1

local frame     = 0
local eventN    = 0
local voices    = 0
local recording = false
local tailLeft  = 0

local function ev(kind, addr, value, pc, note)
  if not fe or eventN >= MAX_EVENT then return end
  eventN = eventN + 1
  fe:write(string.format('%d\t%s\t%04X\t%02X\t%04X\t%s\n',
           frame, kind, addr & 0xFFFF, value & 0xFF, pc & 0xFFFF, note or ''))
end

emu.addMemoryCallback(function(address, value)
  local a, v = address & 0xFFFF, (value or 0) & 0xFF
  if a == 0x180D then
    local was = shadow180D
    shadow180D = v
    if ((was ~ v) & 0x20) ~= 0 then
      ev('W180D', a, v, curPC(), (v & 0x20) ~= 0 and 'bit20 0->1' or 'bit20 1->0')
    else
      ev('W180D', a, v, curPC(), '')
    end
  else
    ev('Wport', a, v, curPC(), '')
  end
end, emu.callbackType.write, PORT_LO, PORT_HI, CPU, MEM)

-- 게임이 $180C 를 읽을 때만 값을 줍는다.  우리는 두드리지 않는다
emu.addMemoryCallback(function(address, value)
  local a, v = address & 0xFFFF, (value or 0) & 0xFF
  if a == 0x180C then
    seen180C, seen180C_f = v, frame
    ev('R180C', a, v, curPC(), '')
  elseif a == 0x180D then
    ev('R180D', a, v, curPC(), 'shadow=' .. string.format('%02X', shadow180D))
  end
end, emu.callbackType.read, 0x180C, 0x180D, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  ev('Wkey', address & 0xFFFF, (value or 0) & 0xFF, curPC(), '')
end, emu.callbackType.write, A_FIN_LO, A_RATE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  ev('Wstate', address & 0xFFFF, (value or 0) & 0xFF, curPC(), '')
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

-- ---------------------------------------------------------------------------
-- §11.7 -- $7FE8-$7FFF 가 정말 죽어 있는가.  한 바이트라도 걸리면 탈락
-- ---------------------------------------------------------------------------
local freeHits = {}
local freeTotal = 0
emu.addMemoryCallback(function(address, value)
  local a = address & 0xFFFF
  freeHits[a] = (freeHits[a] or 0) + 1
  freeTotal = freeTotal + 1
  if freeHits[a] == 1 then
    local pc = curPC()
    ev('WFREE', a, (value or 0) & 0xFF, pc, 'bank6A 후보 탈락 가능')
    emu.log(string.format('SUB 0.5.30 ★ $%04X 에 게임이 썼다 (PC $%04X) -- last 후보에서 탈락',
                          a, pc))
  end
end, emu.callbackType.write, FREE_LO, FREE_HI, CPU, MEM)

-- ---------------------------------------------------------------------------
-- 후보 게이트 모의 실행
-- ---------------------------------------------------------------------------
--   A   0.4.6.26 실물 그대로 ($22A6==0 · $22A7!=0 · $180D&$20).  ★ 실패한 것
--   A2  §11.7 설계 (A + `last` 변수로 같은 음성 재무장 차단)
--   B   $180D 대신 $180C bit $08 (게임 자신이 읽는 상태 비트)
--   C   포트를 아예 안 본다.  $22A7 이 바뀌었을 때만
--   D   $22A6/$22A7/$22AA 3 B 가 통째로 바뀌었을 때만
--   E   에뮬레이터 진실값 playing 의 상승 에지 = **조각 수**
--       (기준선은 E 가 아니라 기록창 수 V 다.  한 음성이 여러 조각이면 E > V)
local armA, armA2, armB, armC, armD, armE = 0, 0, 0, 0, 0, 0
local lastA2, lastC = -1, -1
local lastD = { -1, -1, -1 }
local prevPlaying = false

local function simulate(fin_lo, fin_hi, rate, playing)
  local d20 = (shadow180D & 0x20) ~= 0
  local busy = (seen180C & 0x08) ~= 0

  if fin_lo == 0 and fin_hi ~= 0 and d20 then armA = armA + 1 end

  if fin_lo == 0 and fin_hi ~= 0 and d20 and fin_hi ~= lastA2 then
    lastA2 = fin_hi; armA2 = armA2 + 1
  end

  if fin_lo == 0 and fin_hi ~= 0 and busy then armB = armB + 1 end

  if fin_lo == 0 and fin_hi ~= 0 and fin_hi ~= lastC then
    lastC = fin_hi; armC = armC + 1
  end

  if fin_hi ~= 0 and (fin_lo ~= lastD[1] or fin_hi ~= lastD[2] or rate ~= lastD[3]) then
    lastD = { fin_lo, fin_hi, rate }; armD = armD + 1
  end

  if playing and not prevPlaying then armE = armE + 1 end
  prevPlaying = playing
end

-- ---------------------------------------------------------------------------
-- 프레임 타임라인
-- ---------------------------------------------------------------------------
local ring = {}
local curVoiceStart, curVoiceFrames, bit20Drops, bit20Frames = -1, 0, 0, 0
local a7AfterEnd, a7AtStart = -1, -1
local summary = {}

local function row(voice, phase, playing, s)
  local m = mpr3(s)
  local state = (m == 0x6A) and string.format('%02X', rb(STATE)) or '-'
  return string.format('%d\t%d\t%s\t%d\t%02X\t%d\t%02X\t%02X\t%02X\t%02X\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n',
    frame, voice, phase, playing and 1 or 0,
    shadow180D, (shadow180D & 0x20) ~= 0 and 1 or 0, seen180C,
    rb(A_FIN_LO), rb(A_FIN_HI), rb(A_RATE), state,
    m >= 0 and string.format('%02X', m) or '??',
    armA, armA2, armB, armC, armD, armE)
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end

  local playing = s['cdrom.adpcm.playing'] == true
  local fin_lo, fin_hi, rate = rb(A_FIN_LO), rb(A_FIN_HI), rb(A_RATE)

  simulate(fin_lo, fin_hi, rate, playing)

  -- 음성 시작
  if playing and not recording then
    voices = voices + 1
    recording = true
    curVoiceStart, curVoiceFrames = frame, 0
    bit20Drops, bit20Frames = 0, 0
    a7AtStart = fin_hi
    if ft then
      for _, r in ipairs(ring) do ft:write(r) end
    end
    emu.log(string.format('SUB 0.5.30 ★ VOICE #%d 시작  frame %d  $22A7=$%02X  $180D=$%02X',
                          voices, frame, fin_hi, shadow180D))
  end

  if recording then
    curVoiceFrames = curVoiceFrames + 1
    if (shadow180D & 0x20) ~= 0 then bit20Frames = bit20Frames + 1
    elseif playing then bit20Drops = bit20Drops + 1 end

    local phase = playing and 'play' or 'tail'
    if not playing then
      if tailLeft == 0 then tailLeft = TAIL end
      tailLeft = tailLeft - 1
      if a7AfterEnd < 0 then a7AfterEnd = fin_hi end
    else
      tailLeft = 0
    end
    if ft then ft:write(row(voices, phase, playing, s)) end

    if not playing and tailLeft <= 0 then
      -- 이 음성 마감
      summary[#summary + 1] = string.format(
        'VOICE #%d  frame %d..%d (%d)  $22A7 시작 $%02X · 종료직후 $%02X · %d 프레임 뒤 $%02X\n' ..
        '          bit20 유지 %d 프레임 · 재생 중 0 으로 떨어진 프레임 %d\n' ..
        '          누적무장  A=%d  A2=%d  B=%d  C=%d  D=%d  E(조각)=%d\n',
        voices, curVoiceStart, frame, curVoiceFrames,
        a7AtStart, a7AfterEnd, TAIL, fin_hi,
        bit20Frames, bit20Drops, armA, armA2, armB, armC, armD, armE)
      emu.log('SUB 0.5.30 ' .. summary[#summary]:gsub('\n%s*', ' | '))
      recording, a7AfterEnd = false, -1
      if ft then ft:flush() end
      if fe then fe:flush() end
    end
  else
    -- pre-roll 링버퍼 (삽입 순서 그대로 -- 시작 시점에 순서대로 편다)
    ring[#ring + 1] = row(0, 'idle', false, s)
    if #ring > PRE_ROLL then table.remove(ring, 1) end
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------------------
-- 종료 요약
-- ---------------------------------------------------------------------------
emu.addEventCallback(function()
  if not fs then return end
  fs:write('SUB 0.5.30 -- ADPCM 게이트 조건 측정\n')
  fs:write(string.format('프레임 %d · 음성 %d · 이벤트 %d\n\n', frame, voices, eventN))
  for _, l in ipairs(summary) do fs:write(l) end

  fs:write('\n== 후보 게이트 무장 횟수 ==\n')
  fs:write(string.format('  A   0.4.6.26 실물          %d\n', armA))
  fs:write(string.format('  A2  §11.7 (last 변수)      %d\n', armA2))
  fs:write(string.format('  B   $180C bit $08          %d\n', armB))
  fs:write(string.format('  C   $22A7 변화만           %d\n', armC))
  fs:write(string.format('  D   $22A6/A7/AA 3 B 변화   %d\n', armD))
  fs:write(string.format('  E   playing 상승 에지 = 조각 수   %d\n', armE))
  fs:write(string.format('  V   기록창 = 음성 수 (기준선)     %d\n', voices))
  fs:write('\n  ★ 답은 V 와 같은 것이다.  V 보다 크면 재무장, 작으면 놓친 음성이다.\n')
  fs:write('    E > V 이면 한 음성이 여러 조각으로 끊긴다는 뜻이고, 그때\n')
  fs:write('    bit20 이 조각 사이에 0 이 되는지가 곧 재무장 여부를 가른다.\n')

  fs:write('\n== $7FE8-$7FFF 쓰기 감시 (§11.7 `last` 후보) ==\n')
  if freeTotal == 0 then
    fs:write('  쓰기 0 건.  이 주행에서는 조용했다.\n')
    fs:write('  ⚠ 한 주행으로는 부족하다.  여러 장면에서 반복해 0 이어야 쓸 수 있다.\n')
  else
    fs:write(string.format('  쓰기 %d 건 -- 게임이 쓴다.  아래 주소는 전부 탈락\n', freeTotal))
    for a = FREE_LO, FREE_HI do
      if freeHits[a] then fs:write(string.format('    $%04X  %d 회\n', a, freeHits[a])) end
    end
    local ok = {}
    for a = FREE_LO, FREE_HI do if not freeHits[a] then ok[#ok + 1] = string.format('$%04X', a) end end
    fs:write('  조용한 주소: ' .. (#ok > 0 and table.concat(ok, ' ') or '(없음)') .. '\n')
  end
  fs:close()
  emu.log('SUB 0.5.30 요약 기록: ' .. OUT_S)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.30-adpcm-gate-timeline armed -- 읽기 전용.  ADPCM 에 영향 없음')
emu.log('  $180D 는 게임의 쓰기를 그림자로, $180C 는 게임의 읽기를 주워서 안다')
emu.log('  ★ 음성이 여러 개 나오는 구간을 돌 것.  조각이 여럿인 긴 음성 하나는 꼭 포함')
emu.log('  ★ 끝나면 Lua 창을 Stop 해야 요약 파일이 닫힌다')
emu.log('  타임라인: ' .. OUT_T)
emu.log('  이벤트  : ' .. OUT_E)
emu.log('  요약    : ' .. OUT_S)
