-- SUB 0.5.32 -- ADPCM 키를 네이티브로 만들기 위한 마지막 두 조각
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- §9.1 의 다섯 항목 중 3(팩 조회)·5(fail-closed)는 **이미 네이티브다.**
-- `build_subtitle_engine_ac_record_poc.py:126` -- 색인을 끝까지 못 찾으면
--
--     STZ ENGINE_LO      매직 해제: 재검색 폭주 방지
--     RTS
--
-- 남은 것은 2 번(6 B 키 생성) 하나다.  지금은 Lua(0.4.31)가 selector 에 써 준다.
--
-- 왜 3 B 부분키로는 안 되나 (실측)
-- ---------------------------------------------------------------------------
--     팩 색인 1950 조각 · 서로 다른 6 B 키 902 개
--     그런데 앞 3 B($22A6/$22A7/$22AA) 접두는 **33 종류뿐**이다
--     그 33 개 중 조각 하나만 가리키는 것은 2 개
--
-- 즉 ADPCM RAM 3 표본(key[3..5])은 못 뺀다.  §9.1.1 의 판단이 맞았다.
--
-- 훅 자리는 확인됐다
-- ---------------------------------------------------------------------------
--     $F5F2:  8D AA 22   STA $22AA      <- 정확히 3 B.  JSR abs 로 치환된다
--
-- 그 시점에 $22A6/$22A7/$22AA 가 다 서 있고, 게임이 ADPCM 포인터를 건드리는 것은
-- `$F5F5` 부터다.  그 사이에 샘플링하면 우리가 포인터를 복원할 필요가 없다.
--
-- 그래서 이 프로브가 재는 것 -- 딱 두 가지
-- ---------------------------------------------------------------------------
--   1) ★ 훅에서 뜬 3 B 를 엔진까지 나를 **스크래치 RAM 3 B** 를 찾는다.
--        $7FE8-$7FFF 는 0.5.30 에서 죽었다 (24 B 전부 게임이 쓴다, PC $EA9E).
--        이번엔 ADPCM 드라이버 변수와 같은 페이지($2280-$22FF)를 본다.
--        읽기도 쓰기도 0 인 주소만 후보다.
--
--   2) 게이트 가드를 `STZ $22A7` 에서 `$22A6` 표식으로 옮길 수 있는가.
--        지금 가드는 $22A7 을 지우는데, 그러면 **엔진이 key[1] 을 못 읽는다.**
--        $22A6 은 finish 하위이고 실측 9/9 항상 $00 이라 키에 정보가 없다.
--        거기에 표식을 세우면 키를 온전히 남긴 채 게이트를 닫을 수 있다.
--        조건: 게임이 `$F601 LDX $22A6` **이후로는** 그것을 읽지 않아야 한다.
--
-- 0.5.30/0.5.31 의 결함을 고쳤다
-- ---------------------------------------------------------------------------
-- 그 둘은 이벤트를 파일에 적었고 상한에 걸려 **정작 필요한 구간이 잘렸다.**
-- ($22A6 읽기 800 건이 전부 부팅 중 idle 이었고 재생 중은 한 건도 안 남았다.)
--
--     이 판은 이벤트를 안 적는다.  **주소별 카운터**만 센다.
--     PC 조회는 주소·종류당 **최초 1 회**뿐이다 (최대 512 회).
--     그래서 상한이 없고 느려지지 않는다.  전 구간이 남는다.
--
-- 읽기 전용이다.  아무 주소에도 쓰지 않고 화면에 아무것도 그리지 않는다.
-- Power Cycle 뒤 이 파일 하나만 로드한다 (0.4.93 금지 -- 그 아래 0.4.31 이
-- $22A6/$22A7/$22AA 를 위조해 측정을 오염시킨다).
--
--     CUE  build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue
--
-- ★ 음성이 나오는 장면을 **여러 개** 돌 것.  스크래치 판정은 "이 주행에서 조용했다"
--   까지만 말할 수 있다.  한 장면만 돌면 답이 아니다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local WIN_LO, WIN_HI = 0x2280, 0x22FF     -- ADPCM 드라이버 변수와 같은 페이지
local A_FIN_LO, A_FIN_HI, A_RATE = 0x22A6, 0x22A7, 0x22AA
local SETUP_HOOK = 0xF5F2                 -- STA $22AA -- 제안된 훅 자리

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/adpcm_key_scratch_0_5_32_' .. STAMP .. '.txt'

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

-- ---------------------------------------------------------------------------
-- 주소별 카운터.  이벤트를 적지 않으므로 상한이 없다
-- ---------------------------------------------------------------------------
local wN, rN = {}, {}          -- 쓰기/읽기 횟수
local wPC, rPC = {}, {}        -- 최초 PC (주소·종류당 1 회만 조회)
for a = WIN_LO, WIN_HI do wN[a], rN[a] = 0, 0 end

emu.addMemoryCallback(function(address)
  local a = address & 0xFFFF
  local n = (wN[a] or 0) + 1
  wN[a] = n
  if n == 1 then wPC[a] = curPC() end
end, emu.callbackType.write, WIN_LO, WIN_HI, CPU, MEM)

emu.addMemoryCallback(function(address)
  local a = address & 0xFFFF
  local n = (rN[a] or 0) + 1
  rN[a] = n
  if n == 1 then rPC[a] = curPC() end
end, emu.callbackType.read, WIN_LO, WIN_HI, CPU, MEM)

-- ---------------------------------------------------------------------------
-- $22A6 표식 설계의 성립 조건
--
--   setup 창    = $F5F2 훅 진입 ~ $F601(LDX $22A6) 까지.  여기서 읽는 것은 정상
--   그 이후 읽기 = 표식 설계 탈락 근거
--
-- setup 창은 "훅이 돈 프레임" 으로 근사한다.  프레임 안에서 $F5F2 -> $F601 은
-- 몇 명령 거리라 같은 프레임에 들어간다.
-- ---------------------------------------------------------------------------
local setupFrame = -1
local frame = 0
local a6ReadInSetup, a6ReadOutside = 0, 0
local a6OutsidePC = {}
local hookHits = 0

emu.addMemoryCallback(function()
  hookHits = hookHits + 1
  setupFrame = frame
end, emu.callbackType.exec, SETUP_HOOK, SETUP_HOOK, CPU, MEM)

emu.addMemoryCallback(function()
  if frame == setupFrame then
    a6ReadInSetup = a6ReadInSetup + 1
  else
    a6ReadOutside = a6ReadOutside + 1
    local pc = curPC() & 0xFFFF
    a6OutsidePC[pc] = (a6OutsidePC[pc] or 0) + 1
  end
end, emu.callbackType.read, A_FIN_LO, A_FIN_LO, CPU, MEM)

-- ---------------------------------------------------------------------------
-- 커버리지 -- 음성을 몇 개나 지나갔나
-- ---------------------------------------------------------------------------
local voices, prevPlaying = 0, false
emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end
  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not prevPlaying then
    voices = voices + 1
    if voices % 5 == 0 then
      emu.log(string.format('SUB 0.5.32 음성 %d 개 · 훅 %d 회 · 프레임 %d',
                            voices, hookHits, frame))
    end
  end
  prevPlaying = playing
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------------------
-- 종료 요약
-- ---------------------------------------------------------------------------
emu.addEventCallback(function()
  local f = io.open(OUT, 'w')
  if not f then return end
  f:write('SUB 0.5.32 -- ADPCM 키 네이티브화의 남은 두 조각\n')
  f:write(string.format('프레임 %d · 음성 %d · $F5F2 훅 실행 %d 회\n',
                        frame, voices, hookHits))
  if hookHits == 0 then
    f:write('\n⚠ $F5F2 가 한 번도 안 돌았다.  음성이 없는 구간만 돈 것이다.\n')
    f:write('  이 주행으로는 아무것도 판정할 수 없다 (스크래치 후보 포함).\n')
  end

  f:write('\n== 1) 스크래치 후보 -- $2280-$22FF 에서 읽기도 쓰기도 0 인 주소 ==\n')
  local dead = {}
  for a = WIN_LO, WIN_HI do
    if wN[a] == 0 and rN[a] == 0 then dead[#dead + 1] = a end
  end
  if #dead == 0 then
    f:write('  없다.  이 창은 전부 게임이 쓴다.  창을 옮겨 다시 재야 한다.\n')
  else
    f:write(string.format('  %d B 조용했다.  연속 3 B 이상만 쓸 수 있다:\n', #dead))
    -- 연속 구간으로 묶어 출력
    local i = 1
    while i <= #dead do
      local j = i
      while j < #dead and dead[j + 1] == dead[j] + 1 do j = j + 1 end
      local len = j - i + 1
      f:write(string.format('    $%04X-$%04X  %d B%s\n',
              dead[i], dead[j], len, len >= 3 and '   ★ 후보' or ''))
      i = j + 1
    end
    f:write('\n  ⚠ "이 주행에서 조용했다" 까지만이다.  장면을 바꿔 반복해 0 이어야 쓴다.\n')
  end

  f:write('\n== 창 안에서 실제로 쓰인 주소 (최초 PC) ==\n')
  for a = WIN_LO, WIN_HI do
    if wN[a] > 0 or rN[a] > 0 then
      f:write(string.format('  $%04X  W %-7d R %-7d  최초 W PC $%04X · R PC $%04X\n',
              a, wN[a], rN[a], (wPC[a] or -1) & 0xFFFF, (rPC[a] or -1) & 0xFFFF))
    end
  end

  f:write('\n== 2) $22A6 표식 설계가 성립하는가 ==\n')
  f:write(string.format('  setup 창(훅과 같은 프레임) 안 읽기 %d 건\n', a6ReadInSetup))
  f:write(string.format('  그 밖의 읽기                    %d 건\n', a6ReadOutside))
  if a6ReadOutside == 0 then
    f:write('  -> setup 밖 읽기 0.  $22A6 에 표식을 세워도 게임이 안 본다.\n')
    f:write('     가드를 STZ $22A7 -> $22A6 표식으로 옮길 수 있다 (키가 온전히 남는다)\n')
  else
    f:write('  -> ✗ setup 밖에서도 읽는다.  $22A6 표식은 탈락.\n')
    f:write('     읽은 PC:\n')
    local pcs = {}
    for pc in pairs(a6OutsidePC) do pcs[#pcs + 1] = pc end
    table.sort(pcs)
    for _, pc in ipairs(pcs) do
      f:write(string.format('       $%04X  %d 회\n', pc, a6OutsidePC[pc]))
    end
    f:write('     (참고: $FEDA 는 우리 BIOS 게이트 자신이다 -- 게임 아님)\n')
  end
  f:close()
  emu.log('SUB 0.5.32 요약 기록: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.32-adpcm-key-scratch-hunt armed -- 읽기 전용 · 카운터만 센다')
emu.log('  1) $2280-$22FF 에서 죽은 3 B 를 찾는다 (키 3 B 를 나를 스크래치)')
emu.log('  2) $22A6 표식 설계가 성립하는지 본다 (가드를 옮겨 키를 살린다)')
emu.log('  ★ 음성이 나오는 장면을 여러 개 돌 것.  훅 0 회면 판정 불가')
emu.log('  ★ 끝나면 Lua 창을 Stop 해야 요약이 닫힌다')
emu.log('  요약: ' .. OUT)
