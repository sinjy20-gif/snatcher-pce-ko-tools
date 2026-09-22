-- SUB 0.5.106 -- 빌린 $5B80-$5E1E 를 **모든 음성마다** 돌려준다
--
-- 0.5.105 가 왜 한 번만 먹었나
-- ---------------------------------------------------------------------------
--   · `$F798`(자막 arm)은 오프닝 CD-DA 에서 한 번만 걸린다
--   · 되돌린 직후 상주부가 헬퍼를 다시 복사해 넣으면 `ours()` 가 참이 되어
--     다음 arm 에서는 뜨지도 못한다
--   -> 첫 음성 하나만 덮고 나머지는 전부 무방비였다
--
-- 그래서 트리거를 버린다
-- ---------------------------------------------------------------------------
--   슬롯이 **우리 것이 아닐 때** 매 프레임 671 B 그림자를 갱신한다.
--   슬롯이 우리 것이 되는 순간 그림자는 **빌리기 직전의 게임 데이터**로 얼어붙는다.
--   반납되면 그 그림자를 되쓴다.  트리거도, 음성 종류도, 횟수도 안 따진다.
--
--   비용: 안 빌린 동안만 671 읽기/프레임 (~40k/s).  빌린 동안은 0.
--
-- 되돌리는 시점
-- ---------------------------------------------------------------------------
--   ★ PC 가 슬롯 밖일 때만 쓴다.  `$7FDF <- 0` 을 쓰는 것은 슬롯 안에서 도는
--     렌더러라, 그 자리에서 덮으면 실행 중인 코드가 데이터로 바뀌어
--     BIOS 화면으로 튕긴다 (0.5.105 노스킵 실측).
--
-- 판정: 노스킵 · 자막 중간 스킵 · 자막 전 스킵 · 접수처 · ADPCM 대사
-- ★ 게임 코드 무수정.

local LOAD_077 = true       -- ★ 처방이 먹으면 false 로 바꿔 0.5.77 없이도 되는지 본다
if LOAD_077 then dofile('C:/snatcher/lua/SUB/0.5.77-refresh-cdda-backup.lua') end

local TAG = 'SUB 0.5.106'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local LO, HI = 0x5B80, 0x5E1E
local SIZE = HI - LO + 1                 -- 671 B
local STATE, OPENING_SKIP = 0x7FDF, 0x8411
local CTL_STATUS = 0x5D31                -- 헬퍼 -> 상주부 (1 저장함 · 2 복원함)
local HEARTBEAT = 600
local WAIT_MAX = 120

local frame, shadow, fresh = 0, {}, false
local wasOurs, pending, waited = false, nil, 0
local borrows, gives, skippedPC = 0, 0, 0

local function rb(at) return emu.read(at, MEM) or 0 end
local function say(fmt, ...) emu.log(TAG .. ' · ' .. string.format(fmt, ...)) end

-- 이 환경 A 규약: emu.getState() 는 평평한 키다 ('cpu.pc').
local function getPC()
  local st = emu.getState()
  local v = st and (st['cpu.pc'] or st.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

-- 슬롯이 우리 것인가: 헬퍼 entry 서명 AD 30 5D (읽기 3회)
local function ours()
  return rb(0x5B83) == 0xAD and rb(0x5B84) == 0x30 and rb(0x5B85) == 0x5D
end

local function give(why, pc)
  if not fresh then
    say('%df 되돌릴 그림자가 없다 (%s)', frame, why); return
  end
  local diff = 0
  for i = 0, SIZE - 1 do
    if rb(LO + i) ~= shadow[i] then diff = diff + 1 end
    emu.write(LO + i, shadow[i], MEM)
  end
  gives = gives + 1
  say('%df 되돌림 #%d (%s · PC=$%04X · %d프레임 대기) -- 바뀌어 있던 바이트 %d/%d',
      frame, gives, why, pc, waited, diff, SIZE)
end

local function requestGive(why) pending, waited = why, 0 end

emu.addEventCallback(function()
  frame = frame + 1
  local o = ours()

  -- ★ 되돌리기가 예약돼 있으면 그림자를 절대 갱신하지 않는다.
  --    갱신이 pending 처리보다 먼저 도는 바람에 오염된 메모리로 그림자를
  --    갈아치우고 그걸 되써서 아무 일도 안 일어났다 (0.5.106 첫 판 버그).
  if not o and not pending then
    for i = 0, SIZE - 1 do shadow[i] = rb(LO + i) end     -- 그림자 갱신
    fresh = true
    if wasOurs then say('%df 슬롯 반납됨 -- 그림자 갱신 재개', frame) end
  elseif not wasOurs then
    borrows = borrows + 1
    say('%df 슬롯 점유 #%d -- 그림자 얼림 (%d B)', frame, borrows, SIZE)
  end
  wasOurs = o
  if frame % HEARTBEAT == 0 then
    say('%df 상태 -- 슬롯 %s · 그림자 %s · 점유 %d · 되돌림 %d%s', frame,
        o and '우리것' or '게임것', fresh and '있음' or '없음', borrows, gives,
        pending and (' · 보류 ' .. pending) or '')
  end

  if pending then
    local pc = getPC()
    if pc >= LO and pc <= HI then
      waited = waited + 1
      skippedPC = skippedPC + 1
      if waited >= WAIT_MAX then
        say('%df ★ %d 프레임 대기해도 PC 가 슬롯 안 (PC=$%04X) -- 포기',
            frame, WAIT_MAX, pc)
        pending = nil
      end
    else
      local why = pending
      pending = nil
      give(why, pc)
    end
  end
end, emu.eventType.endFrame)

emu.addMemoryCallback(function(_, value)
  if value == 0 then requestGive('state -> 0') end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

-- ★ 엔진 종류를 안 가리는 반납 신호.  $7FDF/$8411 은 오프닝 전용이라
--   ADPCM 대사에서는 한 번도 안 걸렸다.  status=2 는 헬퍼가 "복원했다" 고
--   직접 보고하는 값이라 CD-DA·ADPCM 모두에서 온다.
emu.addMemoryCallback(function(_, value)
  if value == 0x02 then requestGive('status=2 (복원함)') end
end, emu.callbackType.write, CTL_STATUS, CTL_STATUS, CPU, MEM)

emu.addMemoryCallback(function()
  say('%df SKIP@8411 state=$%02X · 슬롯 %s', frame, rb(STATE), ours() and '우리것' or '게임것')
  requestGive('skip $8411')
end, emu.callbackType.exec, OPENING_SKIP, OPENING_SKIP, CPU, MEM)

emu.addEventCallback(function()
  say('끝 -- 점유 %d회 · 되돌림 %d회 · PC 때문에 미룬 프레임 %d', borrows, gives, skippedPC)
end, emu.eventType.scriptEnded)

say('loaded -- $%04X-$%04X (%d B) · 트리거 없음 · 0.5.77 %s',
    LO, HI, SIZE, LOAD_077 and '같이' or '없이')
say('판정: 노스킵 · 중간 스킵 · 자막 전 스킵 · 접수처 · ADPCM 대사')
