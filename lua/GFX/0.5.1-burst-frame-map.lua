-- GFX 0.5.1 -- 덩어리가 어느 프레임에 걸쳐 있나  ★순수 관측 · 쓰기 0 B
--
-- 0.5.0 의 결론 (2026-09-09)
-- ---------------------------------------------------------------------------
--   무장 f4906 -> 헌사는 f6494 인데 **프레임 경계 지문 일치 0 회**.
--   헌사 덩어리는 업로더 호출 2,016 회짜리라 몇 프레임 안에 다 지나간다.
--   프레임에 한 번 찍어서 그 16 B 타일이 걸릴 확률이 낮다.
--   => "tick 이 매 프레임 지문을 본다" 는 설계는 폐기.
--
-- 그럼 남는 길은 둘
-- ---------------------------------------------------------------------------
--   A) 타이밍만으로 간다      무장 -> N 프레임 뒤에 주입.  주행 2 회 오차 0 이었다
--   B) 프레임 단위로 오래 남는 다른 신호를 찾는다
--
--   둘 다 **덩어리가 정확히 몇 번째 프레임에 걸쳐 있는지**를 먼저 알아야 한다.
--   지금 아는 +1588 은 *업로더 호출 순서*로 잰 값이지 프레임과의 관계가 아니다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) `$E009` 위치 $03:$5A 로 무장 -- 기준 프레임
--   2) `$725C` (업로더) 진입을 프레임별로 센다
--        -> 덩어리마다  [첫 프레임 .. 끝 프레임] · 총 호출 · 프레임 수
--   3) 호출 **시점**에 `$3B00` 지문을 본다 (0.4.2 와 같은 방법)
--        -> 어느 덩어리가 헌사인지 확정
--   4) 덩어리마다 **첫 호출의 호출자**를 스택에서 읽는다 (첫 호출만 -- 가볍게)
--   5) 각 프레임 **경계**의 `$3B00` 앞 8 B 도 같이 남긴다
--        -> B 안(프레임에서 보이는 신호)이 가능한지 눈으로 볼 재료
--
-- 판정
--   헌사가 프레임 1~2 개 안에 끝난다  -> A 안.  무장+N 프레임에 주입
--   덩어리마다 프레임 수가 뚜렷이 다르다 -> 그 자체가 신원이 될 수도 있다
--
-- 쓰는 법
--   이것만 로드 · 부팅 -> 헌사 지나고 조금 더 (모스크바까지면 넉넉) · Stop
--
-- 산출물  C:/snatcher/dump/gfxmap_0_5_1_<시각>_frames.tsv / _bursts.tsv / _summary.txt

local BUF     = 0x3B00
local CALL    = 0x725C                  -- Track02 업로더 진입
local CD_READ = 0xE009
local ZP_FD, ZP_FE     = 0x20FD, 0x20FE -- HuC6280 zero page 는 $2000-$20FF
local GATE_FD, GATE_FE = 0x03, 0x5A

local GAP_FRAMES = 10                   -- 이만큼 조용하면 덩어리가 끊긴 것으로 본다

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxmap_0_5_1_' .. STAMP

local fF = assert(io.open(BASE .. '_frames.tsv', 'w'))
fF:write('frame\tsince_arm\tcalls\tsig_hits\tbuf8\n')
fF:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

-- ---------------------------------------------------------------- 무장
local armed, armFrame = false, -1
emu.addMemoryCallback(function()
  if armed then return end
  if rd(ZP_FD) == GATE_FD and rd(ZP_FE) == GATE_FE then armed = true end
end, emu.callbackType.exec, CD_READ, CD_READ, CPU, MEM)

-- ---------------------------------------------------------------- 업로더
local frame       = 0
local frameCalls  = 0
local frameHits   = 0
local lastCall    = -999      -- 마지막으로 호출이 있던 프레임
local bursts      = {}
local cur         = nil

-- 스택에서 호출자를 읽는다 (덩어리 첫 호출에서만 -- getState 는 비싸다)
local function callerPC()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  local sp = s['cpu.sp'] or s['sp'] or s['cpu.spl']
  if type(sp) ~= 'number' then return -1 end
  local lo = rd(0x2100 + ((sp + 1) % 0x100))
  local hi = rd(0x2100 + ((sp + 2) % 0x100))
  if lo < 0 or hi < 0 then return -1 end
  return (hi * 256 + lo) - 2
end

emu.addMemoryCallback(function()
  frameCalls = frameCalls + 1

  -- 덩어리 시작?
  if cur == nil or (frame - lastCall) > GAP_FRAMES then
    cur = { f0 = frame, f1 = frame, calls = 0, hits = 0,
            caller = callerPC(),
            since = (armFrame > 0) and (frame - armFrame) or -1 }
    bursts[#bursts + 1] = cur
  end
  lastCall   = frame
  cur.f1     = frame
  cur.calls  = cur.calls + 1

  -- 호출 시점 지문 (0.4.2 와 같은 방법)
  local ok = true
  for i = 1, #SIG do
    if rd(BUF + i - 1) ~= SIG[i] then ok = false; break end
  end
  if ok then
    cur.hits  = cur.hits + 1
    frameHits = frameHits + 1
  end
end, emu.callbackType.exec, CALL, CALL, CPU, MEM)

-- ---------------------------------------------------------------- 프레임
local rows = 0
emu.addEventCallback(function()
  frame = frame + 1
  if armed and armFrame < 0 then
    armFrame = frame
    say(('★f%d  게이트 무장'):format(frame))
  end

  if frameCalls > 0 then
    local head = {}
    for i = 0, 7 do head[#head + 1] = ('%02X'):format(rd(BUF + i)) end
    if rows < 4000 then
      rows = rows + 1
      fF:write(('%d\t%d\t%d\t%d\t%s\n'):format(
        frame, (armFrame > 0) and (frame - armFrame) or -1,
        frameCalls, frameHits, table.concat(head, ' ')))
      fF:flush()
    end
    if frameHits > 0 then
      say(('  ★f%d  호출 %d · 지문 %d  (무장후 %s)'):format(
        frame, frameCalls, frameHits,
        (armFrame > 0) and (frame - armFrame) or '무장전'))
    end
  end

  frameCalls, frameHits = 0, 0

  if frame % 600 == 0 then
    say(('f%d  무장 %s · 덩어리 %d'):format(
      frame, armed and ('f' .. armFrame) or '아직', #bursts))
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------- 마무리
emu.addEventCallback(function()
  fF:close()

  local fB = assert(io.open(BASE .. '_bursts.tsv', 'w'))
  fB:write('n\tf0\tf1\tframes\tsince_arm\tcalls\tsig\tcaller\n')
  for i, b in ipairs(bursts) do
    fB:write(('%d\t%d\t%d\t%d\t%d\t%d\t%d\t$%04X\n'):format(
      i, b.f0, b.f1, b.f1 - b.f0 + 1, b.since, b.calls, b.hits, b.caller))
  end
  fB:close()

  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end

  put(('프레임 %d · 무장 %s · 덩어리 %d'):format(
    frame, armFrame > 0 and ('f' .. armFrame) or '없음', #bursts))
  put('')
  put(' #   프레임범위      길이  무장후  호출수   지문  호출자')
  put(' --------------------------------------------------------')
  for i, b in ipairs(bursts) do
    put(('%2d  f%-6d..f%-6d %3d  %6d  %6d  %5d  $%04X%s'):format(
      i, b.f0, b.f1, b.f1 - b.f0 + 1, b.since, b.calls, b.hits, b.caller,
      b.hits > 0 and '   ★헌사' or ''))
  end
  put('')

  local ded = nil
  for _, b in ipairs(bursts) do if b.hits > 0 then ded = b; break end end
  if ded then
    put(('★ 헌사 = 무장후 %d 프레임에 시작 · %d 프레임 동안 · 호출 %d'):format(
      ded.since, ded.f1 - ded.f0 + 1, ded.calls))
    if ded.f1 - ded.f0 + 1 <= 3 then
      put('  짧다 -- 타이밍(A 안)으로 가야 한다.  프레임 확인은 못 쓴다')
    else
      put('  길다 -- 그 안의 프레임 경계를 frames.tsv 에서 볼 것 (B 안 가능성)')
    end
    local uniq = 0
    for _, b in ipairs(bursts) do
      if b.since == ded.since then uniq = uniq + 1 end
    end
    put(('  무장후 %d 프레임에 시작하는 덩어리 수: %d %s'):format(
      ded.since, uniq, uniq == 1 and '(유일 -- 타이밍이 신원이 된다)' or '(겹친다)'))
  else
    put('⚠ 지문이 한 번도 안 맞았다 -- 헌사를 안 지났거나 경로가 다르다')
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.5.1-burst-frame-map armed -- 덩어리<->프레임 대응 · 쓰기 0 B')
say('  부팅 -> 헌사 지나고 조금 더 (모스크바까지면 넉넉) · Stop')
say('  ' .. BASE .. '_bursts.tsv')
