-- GFX 0.5.0 -- tick(프레임 1회)이 $3B00 지문을 볼 수 있나  ★순수 관측 · 쓰기 0 B
--
-- 왜 재나 (2026-09-09)
-- ---------------------------------------------------------------------------
-- r1~r4 는 Track02 업로더 `$7256` 을 훅했다.  그런데 업로더가 돌 때 MPR7 은
-- **항상 원본 뱅크 `$00`** 이고 우리 코드는 뱅크 `$01` 이라, `JSR $FF74` 가
-- 원본 BIOS 로 뛴다 (`0.4.3` 실측 26,576 회 예외 0).  넷이 전부 그래서 죽었다.
--
-- 그래서 r5 는 **BIOS 안에서만** 끝내려 한다:
--
--     무장   CD_READ($E009) 위치 $20FD:$20FE = $03:$5A   ← BIOS 호출
--     대기   tick 이 프레임을 센다 (+1588, 주행 2 회 오차 0)
--     확인   $3B00 의 16 B 타일 지문                      ← RAM 이라 읽힌다
--     주입   기존 injector (369 B) 그대로
--
-- 그러면 Track02 를 한 바이트도 안 건드리므로 뱅크 문제가 원리적으로 사라지고,
-- 코드 자리를 새로 찾을 필요도 없다.
--
-- ★ 딱 하나 모르는 것
--     지금까지 지문은 **업로더 호출마다** 확인했다 (한 덩어리에 수천 번).
--     tick 은 **프레임에 한 번**만 본다.  그 순간에도 `$3B00` 에 그 타일이
--     남아 있는가?  r2 가 "나중에 보니 공용 버퍼가 이미 덮여 있었다" 로
--     실패했으므로 이것은 확인이 필요하다.
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
--   1) `$E009` 에서 위치 $03:$5A 를 만나면 무장하고 그 프레임을 적는다
--   2) **매 프레임 끝**에 `$3B00` 의 16 B 를 읽어 지문과 대조한다
--      (tick 이 볼 수 있는 것과 같은 시점 · 같은 방법)
--   3) 맞은 프레임을 전부 남긴다 -- 무장 기준 몇 번째 프레임인지 같이
--
-- 판정
--   무장+1588 근처에서 맞는 프레임이 있다   -> ★설계 확정.  tick 이 볼 수 있다
--   한 프레임도 안 맞는다                   -> 버퍼가 프레임 사이에 덮인다
--                                              타이밍만으로 가거나 다른 신호 필요
--   엉뚱한 데서도 맞는다                    -> 프레임 단위 지문은 오탐이 있다
--
-- 쓰는 법
--   이것만 로드 · 부팅 -> 헌사 까지만 (접수처까지 안 가도 된다) · Stop
--
-- 산출물  C:/snatcher/dump/gfxtick_0_5_0_<시각>_frames.tsv / _summary.txt

local BUF   = 0x3B00
local GATE_FD, GATE_FE = 0x03, 0x5A     -- $20FD:$20FE (HuC6280 zero page 는 $2000-)
local ZP_FD, ZP_FE     = 0x20FD, 0x20FE
local CD_READ = 0xE009
local EXPECT_GAP = 1588                 -- 무장 -> 헌사 업로드 (주행 2 회 동일)

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxtick_0_5_0_' .. STAMP

local fout = assert(io.open(BASE .. '_frames.tsv', 'w'))
fout:write('frame\tsince_arm\tmatch\tfirst16\n')
fout:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return (ok and type(v) == 'number') and v or -1 end

-- 무장: CD_READ 가 불릴 때 제로페이지의 위치 필드를 본다
local armed, armFrame = false, -1
emu.addMemoryCallback(function()
  if armed then return end
  if rd(ZP_FD) == GATE_FD and rd(ZP_FE) == GATE_FE then
    armed = true
  end
end, emu.callbackType.exec, CD_READ, CD_READ, CPU, MEM)

local frame, hits, rows = 0, 0, 0
local hitFrames = {}

emu.addEventCallback(function()
  frame = frame + 1
  if armed and armFrame < 0 then
    armFrame = frame
    say(('★f%d  게이트 무장 -- 위치 $%02X:%02X'):format(frame, GATE_FD, GATE_FE))
  end

  -- tick 이 보는 것과 같은 시점 · 같은 방법으로 $3B00 을 본다
  local ok = true
  local head = {}
  for i = 1, #SIG do
    local v = rd(BUF + i - 1)
    if i <= 8 then head[#head + 1] = ('%02X'):format(v) end
    if v ~= SIG[i] then ok = false; break end
  end
  if ok then
    hits = hits + 1
    hitFrames[#hitFrames + 1] = frame
    local since = (armFrame > 0) and (frame - armFrame) or -1
    say(('  ★f%d  지문 일치  (무장후 %s)'):format(frame, since >= 0 and since or '무장전'))
    if rows < 400 then
      rows = rows + 1
      fout:write(('%d\t%d\t1\t%s\n'):format(frame, since, table.concat(head, ' ')))
      fout:flush()
    end
  end

  if frame % 600 == 0 then
    say(('f%d  무장 %s · 프레임경계 지문 일치 %d 회')
        :format(frame, armed and ('f' .. armFrame) or '아직', hits))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  fout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  put(('프레임 %d · 무장 %s'):format(frame, armFrame > 0 and ('f' .. armFrame) or '없음'))
  put(('프레임 경계에서 지문이 맞은 횟수 %d'):format(hits))
  if hits == 0 then
    put('★ 한 프레임도 안 맞았다 -- tick 은 $3B00 지문을 볼 수 없다.')
    put('  공용 버퍼가 프레임 사이에 덮인다는 뜻 (r2 가 걸린 그것).')
    put(('  -> 타이밍(무장+%d)만으로 가거나, 다른 확인 신호를 찾아야 한다')
        :format(EXPECT_GAP))
  else
    local near = {}
    for _, f in ipairs(hitFrames) do
      local since = (armFrame > 0) and (f - armFrame) or -1
      put(('   f%d   무장후 %s'):format(f, since >= 0 and since or '무장전'))
      if since >= EXPECT_GAP - 30 and since <= EXPECT_GAP + 60 then
        near[#near + 1] = since
      end
    end
    if #near > 0 then
      put(('★ 무장+%d 근처(%s)에서 맞았다 -- tick 이 볼 수 있다.  설계 확정')
          :format(EXPECT_GAP, table.concat(near, ',')))
    else
      put(('⚠ 맞긴 했는데 무장+%d 근처가 아니다 -- 어느 화면인지 다시 봐야 한다')
          :format(EXPECT_GAP))
    end
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.5.0-tick-can-see armed -- 매 프레임 $3B00 지문 대조 · 쓰기 0 B')
say('  부팅 -> 헌사 까지만 지나면 된다 (접수처까지 안 가도 됨)')
say('  ' .. BASE .. '_frames.tsv')
