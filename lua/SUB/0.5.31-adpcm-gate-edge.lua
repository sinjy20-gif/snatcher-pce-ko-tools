-- SUB 0.5.31 -- ADPCM 게이트에 **에지**를 어디서 얻는가
--
-- 0.5.30 이 답한 것 (다시 재지 않는다)
-- ---------------------------------------------------------------------------
--   1) $180D bit $20 은 재생 종료와 **동시에 정확히 0 이 된다** (frame 5060->5061).
--      §11.8 이 의심한 가정은 사실 맞았다.
--   2) 그런데 0.4.6.26 은 그것 때문에 죽은 게 아니다.  음성 **하나**에 게이트가
--      **183 번** 열렸다.  `$180D & $20` 은 에지가 아니라 **레벨**이다.
--      재생 중 매 프레임 열려서 상주부가 helper/renderer 를 183 번 재적재했다.
--   3) $180C bit $08 도 똑같이 레벨이다 (B=183).  포트 비트로는 못 푼다.
--   4) $22A7 은 종료 후 180 프레임이 지나도 값이 남는다.  단독 재무장 조건 불가.
--   5) ★ $7FE8-$7FFF 는 24 B 전부 게임이 쓴다 (PC $EA9E, 부팅 즉시).
--      §11.7 이 `last` 를 두려던 자리가 죽었다.  **부정으로 확정.**
--
--   -> 에지 메모리가 반드시 필요한데, 두려던 1 B 가 없다.  이것이 지금 병목이다.
--
-- 0.5.30 의 결함 (이 판에서 고친 것)
-- ---------------------------------------------------------------------------
-- 포트 감시를 `$1800-$180F` 로 잡았는데 그 창의 앞쪽은 ADPCM 이 아니라 **CD-ROM
-- 레지스터**다.  로딩 중 쓰기가 폭주하고, 쓰기마다 `emu.getState()` 를 부르니
-- 게임이 기어갔다 (사용자에게 "부팅이 안 된다" 로 보였다).  게다가 그 폭주가
-- 이벤트 상한 4000 을 부팅 중에 다 먹어 정작 필요한 W180D/R180C 가 0 건이었다.
--
--     고침 1  포트 창을 $180C-$180D 로 좁힌다
--     고침 2  PC 조회를 **실제로 기록하는 이벤트에서만** 한다
--     고침 3  이벤트 상한을 종류별로 나눈다 (한 종류가 다른 종류를 굶기지 못한다)
--     고침 4  $7FE8-$7FFF 감시를 뺀다 (이미 답이 나왔다)
--
-- 이번에 재는 것 -- 추가 RAM 없이 에지를 만들 수 있는가
-- ---------------------------------------------------------------------------
-- 게이트는 이미 `$22A6==0` 을 요구한다.  그리고 게임은 음성마다 `$F5E2` 에서
-- `$22A6` 에 `$00` 을 **다시 쓴다**.  그렇다면
--
--     무장할 때 $22A6 에 표식을 넣는다   -> 게이트가 닫힌다
--     다음 음성 셋업이 그것을 $00 으로 덮는다 -> 자동으로 다시 열린다
--
-- 추가 바이트 0 인 에지 검출기다.  그런데 게임이 `$F601 LDX $22A6` 로 그 값을
-- **읽는다.**  재생이 시작된 뒤에도 다시 읽는다면 이 설계는 못 쓴다.
--
--     ★ 그래서 쓰기 전에 잰다.  `$22A6-$22AA` **읽기 감시**가 이 판의 핵심이다.
--       (프로젝트 규칙: 런타임에 죽어 있음을 증명하기 전에는 그 자리에 쓰지 않는다)
--
-- 이 프로브는 여전히 **읽기 전용**이다.  $22A6 에 실제로 쓰지 않는다.
-- 표식 설계는 그림자 변수로 **모의**만 한다 (게이트 F).
--
-- 화면에 아무것도 그리지 않는다.
-- Power Cycle 뒤 이 파일 하나만 로드한다.  0.4.93 은 같이 올리지 않는다
-- (그것이 $22A6/$22A7/$22AA 를 위조해 쓰므로 측정 대상이 게임 것이 아니게 된다).
--
--     CUE  build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue
--
-- ★ 음성을 **여러 개** 받을 것.  조각이 여럿인 긴 음성이 하나 이상 포함되게.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local A_FIN_LO, A_FIN_HI, A_RATE = 0x22A6, 0x22A7, 0x22AA
local STATE                      = 0x7FDF

local PRE_ROLL  = 30
local TAIL      = 180
local CAP       = 800     -- 이벤트 종류별 상한.  한 종류가 다른 종류를 굶히지 못한다

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT_T = 'C:/snatcher/dump/adpcm_edge_timeline_0_5_31_' .. STAMP .. '.tsv'
local OUT_E = 'C:/snatcher/dump/adpcm_edge_events_0_5_31_'   .. STAMP .. '.tsv'
local OUT_S = 'C:/snatcher/dump/adpcm_edge_summary_0_5_31_'  .. STAMP .. '.txt'

local ft = io.open(OUT_T, 'w')
local fe = io.open(OUT_E, 'w')
local fs = io.open(OUT_S, 'w')

if ft then
  ft:write('frame\tvoice\tphase\tplaying\td180D\tbit20\td180C\t' ..
           's22A6\ts22A7\ts22AA\tstate\tmpr3\tmarkF\t' ..
           'A\tA2\tB\tC\tD\tF\tE\n')
end
if fe then fe:write('frame\tkind\taddr\tvalue\tpc\tphase\tnote\n') end

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
-- 상태
-- ---------------------------------------------------------------------------
local shadow180D = 0
local seen180C   = 0
local frame      = 0
local voices     = 0
local recording  = false
local tailLeft   = 0
local playingNow = false

local capN   = {}
local totalN = {}

-- ★ PC 조회는 **기록하는 이벤트에서만** 한다.  0.5.30 이 느렸던 이유가 이것이다
local function ev(kind, addr, value, note)
  totalN[kind] = (totalN[kind] or 0) + 1
  local n = (capN[kind] or 0)
  if not fe or n >= CAP then return end
  capN[kind] = n + 1
  fe:write(string.format('%d\t%s\t%04X\t%02X\t%04X\t%s\t%s\n',
           frame, kind, addr & 0xFFFF, value & 0xFF, curPC() & 0xFFFF,
           playingNow and 'play' or 'idle', note or ''))
end

-- ---------------------------------------------------------------------------
-- 포트 -- $180C/$180D 만.  CD-ROM 레지스터는 건드리지 않는다
-- ---------------------------------------------------------------------------
emu.addMemoryCallback(function(address, value)
  local a, v = address & 0xFFFF, (value or 0) & 0xFF
  if a ~= 0x180D then return end
  local was = shadow180D
  shadow180D = v
  local note = ''
  if ((was ~ v) & 0x20) ~= 0 then
    note = (v & 0x20) ~= 0 and 'bit20 0->1' or 'bit20 1->0'
  end
  ev('W180D', a, v, note)
end, emu.callbackType.write, 0x180C, 0x180D, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local a, v = address & 0xFFFF, (value or 0) & 0xFF
  if a == 0x180C then
    seen180C = v
    ev('R180C', a, v, '')
  else
    ev('R180D', a, v, string.format('shadow=%02X', shadow180D))
  end
end, emu.callbackType.read, 0x180C, 0x180D, CPU, MEM)

-- ---------------------------------------------------------------------------
-- ★ 이 판의 핵심 -- $22A6-$22AA 읽기/쓰기
--
--   표식 설계가 성립하려면 게임이 $22A6 을 **셋업 때만** 읽어야 한다.
--   재생 중(play)에 읽는 것이 한 건이라도 있으면 그 설계는 탈락이다.
-- ---------------------------------------------------------------------------
local markF = false           -- 표식 그림자.  실제로 쓰지 않는다
local a6ReadTotal, a6ReadDuringPlay = 0, 0
local a6ReadPC = {}

emu.addMemoryCallback(function(address, value)
  local a, v = address & 0xFFFF, (value or 0) & 0xFF
  if a == A_FIN_LO then
    -- 게임이 $22A6 을 덮었다 -> 표식이 지워진다.  게이트 F 가 다시 열린다
    if markF then markF = false end
    ev('W22A6', a, v, 'markF cleared')
  else
    ev('Wkey', a, v, '')
  end
end, emu.callbackType.write, A_FIN_LO, A_RATE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local a, v = address & 0xFFFF, (value or 0) & 0xFF
  if a == A_FIN_LO then
    a6ReadTotal = a6ReadTotal + 1
    -- PC 귀속도 예산 안에서만.  0.5.30 이 느렸던 이유가 무제한 getState 였다
    if a6ReadTotal <= 2000 then
      local pc = curPC() & 0xFFFF
      a6ReadPC[pc] = (a6ReadPC[pc] or 0) + 1
    end
    if playingNow then
      a6ReadDuringPlay = a6ReadDuringPlay + 1
      ev('R22A6', a, v, '★ 재생 중 읽기 -- 표식 설계 탈락 근거')
    else
      ev('R22A6', a, v, '')
    end
  else
    ev('Rkey', a, v, '')
  end
end, emu.callbackType.read, A_FIN_LO, A_RATE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  ev('Wstate', address & 0xFFFF, (value or 0) & 0xFF, '')
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

-- ---------------------------------------------------------------------------
-- 후보 게이트 모의 실행
-- ---------------------------------------------------------------------------
--   A   0.4.6.26 실물          ✗ 0.5.30 에서 183/음성 으로 이미 탈락.  대조군으로만 남긴다
--   A2  A + `last` 변수         ✔ 그러나 둘 자리가 없다 ($7FE8 사망)
--   B   $180C bit $08          ✗ 역시 레벨
--   C   $22A7 변화만            ✔ `last` 1 B 필요
--   D   $22A6/A7/AA 3 B 변화    ✔ `last` 3 B 필요
--   F   ★ $22A6 표식 (추가 RAM 0).  이번에 판정하려는 것
--   E   playing 상승 에지 = 조각 수 (기준선은 기록창 수 V)
local armA, armA2, armB, armC, armD, armF, armE = 0, 0, 0, 0, 0, 0, 0
local lastA2, lastC = -1, -1
local lastD = { -1, -1, -1 }
local prevPlaying = false

local function simulate(fin_lo, fin_hi, rate, playing)
  local d20  = (shadow180D & 0x20) ~= 0
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

  -- F: 게임이 본 $22A6 이 0 이고 표식이 안 서 있을 때만.  무장하며 표식을 세운다
  if fin_lo == 0 and fin_hi ~= 0 and d20 and not markF then
    markF = true; armF = armF + 1
  end

  if playing and not prevPlaying then armE = armE + 1 end
  prevPlaying = playing
end

-- ---------------------------------------------------------------------------
-- 타임라인
-- ---------------------------------------------------------------------------
local ring = {}
local curVoiceStart, curVoiceFrames, bit20Drops, bit20Frames = -1, 0, 0, 0
local a7AtStart, a7AfterEnd = -1, -1
local summary = {}

local function row(voice, phase, playing, s)
  local m = mpr3(s)
  local state = (m == 0x6A) and string.format('%02X', rb(STATE)) or '-'
  return string.format(
    '%d\t%d\t%s\t%d\t%02X\t%d\t%02X\t%02X\t%02X\t%02X\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n',
    frame, voice, phase, playing and 1 or 0,
    shadow180D, (shadow180D & 0x20) ~= 0 and 1 or 0, seen180C,
    rb(A_FIN_LO), rb(A_FIN_HI), rb(A_RATE), state,
    m >= 0 and string.format('%02X', m) or '??',
    markF and 1 or 0,
    armA, armA2, armB, armC, armD, armF, armE)
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end

  local playing = s['cdrom.adpcm.playing'] == true
  playingNow = playing
  local fin_lo, fin_hi, rate = rb(A_FIN_LO), rb(A_FIN_HI), rb(A_RATE)

  simulate(fin_lo, fin_hi, rate, playing)

  if playing and not recording then
    voices = voices + 1
    recording = true
    curVoiceStart, curVoiceFrames = frame, 0
    bit20Drops, bit20Frames = 0, 0
    a7AtStart, a7AfterEnd = fin_hi, -1
    if ft then for _, r in ipairs(ring) do ft:write(r) end end
    ring = {}
    emu.log(string.format('SUB 0.5.31 ★ VOICE #%d 시작  frame %d  $22A7=$%02X  $180D=$%02X',
                          voices, frame, fin_hi, shadow180D))
  end

  if recording then
    curVoiceFrames = curVoiceFrames + 1
    if (shadow180D & 0x20) ~= 0 then bit20Frames = bit20Frames + 1
    elseif playing then bit20Drops = bit20Drops + 1 end

    if not playing then
      if tailLeft == 0 then tailLeft = TAIL end
      tailLeft = tailLeft - 1
      if a7AfterEnd < 0 then a7AfterEnd = fin_hi end
    else
      tailLeft = 0
    end

    if ft then ft:write(row(voices, playing and 'play' or 'tail', playing, s)) end

    if not playing and tailLeft <= 0 then
      summary[#summary + 1] = string.format(
        'VOICE #%d  frame %d..%d (%d)  $22A7 시작 $%02X · 종료직후 $%02X · %d 프레임 뒤 $%02X\n' ..
        '          bit20 유지 %d 프레임 · 재생 중 0 으로 떨어진 프레임 %d\n' ..
        '          누적무장  A=%d  A2=%d  B=%d  C=%d  D=%d  F=%d  E(조각)=%d  V=%d\n',
        voices, curVoiceStart, frame, curVoiceFrames,
        a7AtStart, a7AfterEnd, TAIL, fin_hi,
        bit20Frames, bit20Drops,
        armA, armA2, armB, armC, armD, armF, armE, voices)
      emu.log('SUB 0.5.31 ' .. summary[#summary]:gsub('\n%s*', ' | '))
      recording = false
      if ft then ft:flush() end
      if fe then fe:flush() end
    end
  else
    ring[#ring + 1] = row(0, 'idle', false, s)
    if #ring > PRE_ROLL then table.remove(ring, 1) end
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------------------
-- 종료 요약
-- ---------------------------------------------------------------------------
emu.addEventCallback(function()
  if not fs then return end
  fs:write('SUB 0.5.31 -- ADPCM 게이트 에지 측정\n')
  fs:write(string.format('프레임 %d · 음성 %d\n\n', frame, voices))
  for _, l in ipairs(summary) do fs:write(l) end

  fs:write('\n== 후보 게이트 무장 횟수 ==\n')
  fs:write(string.format('  A   0.4.6.26 실물 ($180D 레벨)     %d\n', armA))
  fs:write(string.format('  A2  A + last 변수                  %d\n', armA2))
  fs:write(string.format('  B   $180C bit $08 (레벨)           %d\n', armB))
  fs:write(string.format('  C   $22A7 변화만 (last 1 B)        %d\n', armC))
  fs:write(string.format('  D   $22A6/A7/AA 변화 (last 3 B)    %d\n', armD))
  fs:write(string.format('  F   ★ $22A6 표식 (추가 RAM 0)      %d\n', armF))
  fs:write(string.format('  E   playing 상승 에지 = 조각 수     %d\n', armE))
  fs:write(string.format('  V   음성 수 (기준선)                %d\n', voices))
  fs:write('\n  ★ V 와 같은 것이 답이다.  F 가 V 와 같으면 추가 RAM 없이 끝난다.\n')

  fs:write('\n== ★ $22A6 읽기 감시 -- 표식 설계가 성립하는가 ==\n')
  fs:write(string.format('  총 읽기 %d 건 · 그중 **재생 중** %d 건\n',
                         a6ReadTotal, a6ReadDuringPlay))
  if a6ReadDuringPlay == 0 then
    fs:write('  -> 재생 중 읽기 0.  게임은 셋업 때만 본다.  표식 설계 **성립 가능**\n')
    fs:write('     ⚠ 한 주행으로 확정하지 않는다.  장면을 바꿔 반복해 0 이어야 한다\n')
  else
    fs:write('  -> ✗ 재생 중에 읽는다.  $22A6 표식 설계는 **탈락**.\n')
    fs:write('     에지 메모리를 둘 다른 1 B 를 다시 찾아야 한다\n')
  end
  fs:write('  읽은 PC:\n')
  local pcs = {}
  for pc in pairs(a6ReadPC) do pcs[#pcs + 1] = pc end
  table.sort(pcs)
  for _, pc in ipairs(pcs) do
    fs:write(string.format('    $%04X  %d 회\n', pc, a6ReadPC[pc]))
  end

  fs:write(string.format('\n== 이벤트 건수 (상한 %d/종류) ==\n', CAP))
  for k, v in pairs(totalN) do
    fs:write(string.format('  %-8s %d (기록 %d)\n', k, v, capN[k] or 0))
  end
  fs:close()
  emu.log('SUB 0.5.31 요약 기록: ' .. OUT_S)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.31-adpcm-gate-edge armed -- 읽기 전용.  $22A6 에 쓰지 않는다')
emu.log('  포트 창을 $180C-$180D 로 좁혔다 -- 0.5.30 의 CD-ROM 레지스터 폭주 제거')
emu.log('  ★ 핵심: $22A6 을 게임이 **재생 중에도 읽는가**.  0 이면 표식 설계가 산다')
emu.log('  ★ 음성 여러 개 + 조각이 여럿인 긴 음성 하나 이상')
emu.log('  ★ 끝나면 Lua 창을 Stop 해야 요약이 닫힌다')
emu.log('  타임라인: ' .. OUT_T)
emu.log('  이벤트  : ' .. OUT_E)
emu.log('  요약    : ' .. OUT_S)
