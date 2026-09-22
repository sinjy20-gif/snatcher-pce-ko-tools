-- SUB 0.5.105 -- 빌린 $5B80-$5E1E 를 원래 내용으로 돌려준다 (처방 시험)
--
-- 0.5.104 실측 -- 원인 확정
-- ---------------------------------------------------------------------------
--   pc=$70BF 가 $5B83, $5B84, $5B85 ... 를 **순차로** 읽는다 (블록 복사)
--   읽히는 값이 우리 헬퍼 기계어와 한 바이트도 안 틀린다
--     $5B83  AD 30 5D D0 64    LDA $5D30 / BNE      헬퍼 entry
--     $5B88  A9 00 8D 02 1A    set_ac($1F0400) 시작
--     $5BA4  03 01             ST0 #MARR
--   $5B80 = $00  <- 반납이 첫 바이트만 STZ 로 지웠다.  나머지 668 B 는 우리 코드
--
-- 즉 게임은 자기 **스크립트 VM 데이터 스택**을 읽는다고 믿고 우리 코드를 읽는다.
-- 화면 자원(VRAM·BAT·SATB·팔레트·VDC)이 전부 멀쩡했던 것도 이것으로 설명된다 --
-- 우리가 화면을 망친 게 아니라 게임이 **잘못된 재료로** 그린 것이다.
--
-- 처방
-- ---------------------------------------------------------------------------
--   빌리기 전에 671 B 를 떠 두었다가 반납할 때 되돌린다.
--   AC 자리는 이미 예약돼 있다 -- subtitle_layout.AC_CPU_CACHE_BACKUP = $1F0E00
--   ($1F0E00 ~ $1F1100 = 768 B.  671 B 가 들어간다)
--   여기서는 Lua 테이블에 떠 둔다.  네이티브 이식 때 AC 로 옮긴다.
--
-- 타이밍
--   뜨기   자막 arm $F798   -- 상주부가 슬롯을 덮기 **전**
--   되돌리기  state -> 0    -- 반납이 끝난 뒤 (첫 바이트가 STZ 된 뒤)
--   스킵    $8411 에서도 되돌린다 (state 가 0 을 안 거칠 수 있다)
--
-- 판정
--   전부 정상        -> 확정.  네이티브에 671 B 저장/복원을 넣는다
--   여전히 깨짐      -> 되돌리는 **시점**이 틀렸다.  뜨기/되돌리기 프레임을 옮겨본다
--   ★ 그리고 LOAD_077=false 로 한 번 더 -- 이게 진짜 원인이면 0.5.77 은 필요 없어진다
--
-- ★ 게임 코드 무수정.

local LOAD_077 = true       -- ★ 처방이 먹으면 false 로 바꿔서 0.5.77 없이도 되는지 본다
if LOAD_077 then dofile('C:/snatcher/lua/SUB/0.5.77-refresh-cdda-backup.lua') end

local TAG = 'SUB 0.5.105'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local LO, HI = 0x5B80, 0x5E1E
local SIZE = HI - LO + 1                 -- 671 B
local ARM, OPENING_SKIP = 0xF798, 0x8411
local STATE = 0x7FDF

local frame, held, taken, given = 0, nil, 0, 0
local pending, waited = nil, 0
local WAIT_MAX = 120                     -- 이 프레임 넘게 못 빠져나오면 포기하고 알린다

-- 이 환경 A 규약: emu.getState() 는 평평한 키다 ('cpu.pc').
local function getPC()
  local st = emu.getState()
  local v = st and (st['cpu.pc'] or st.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

local function rb(at) return emu.read(at, MEM) or 0 end
local function say(fmt, ...) emu.log(TAG .. ' · ' .. string.format(fmt, ...)) end

-- 슬롯이 우리 것인가: 헬퍼 entry 서명 AD 30 5D
local function ours()
  return rb(0x5B83) == 0xAD and rb(0x5B84) == 0x30 and rb(0x5B85) == 0x5D
end

local function take(why)
  if held then return end                -- 이미 떠 뒀다 (음성 하나에 한 번)
  if ours() then
    say('%df 뜨기 건너뜀 (%s) -- 슬롯이 이미 우리 것이다', frame, why); return
  end
  local t = {}
  for i = 0, SIZE - 1 do t[i] = rb(LO + i) end
  held, taken = t, taken + 1
  say('%df 뜸 (%s) -- %d B 보관 #%d', frame, why, SIZE, taken)
end

local function give(why)
  if not held then return end
  local diff = 0
  for i = 0, SIZE - 1 do
    if rb(LO + i) ~= held[i] then diff = diff + 1 end
    emu.write(LO + i, held[i], MEM)
  end
  given = given + 1
  say('%df 되돌림 (%s) -- 바뀌어 있던 바이트 %d/%d #%d', frame, why, diff, SIZE, given)
  held = nil
end

-- ★★ 되돌리기는 **PC 가 슬롯 밖일 때만** 한다.
--    $7FDF <- 0 을 쓰는 것은 슬롯 안에서 도는 렌더러다.  그 자리에서 덮으면
--    실행 중인 코드를 데이터로 갈아치우는 셈이라 RTS 가 쓰레기로 돌아가
--    BIOS 화면으로 튕긴다 (노스킵 실측).
--    $8411 은 게임 코드(슬롯 밖)라 즉시 해도 안전했다 -- 그래서 스킵만 통과했다.
local function requestGive(why)
  if not held then return end
  pending, waited = why, 0
end

emu.addEventCallback(function()
  frame = frame + 1
  if not pending then return end
  local pc = getPC()
  if pc >= LO and pc <= HI then
    waited = waited + 1
    if waited == 1 then
      say('%df 되돌리기 보류 -- PC=$%04X 가 슬롯 안이다', frame, pc)
    elseif waited >= WAIT_MAX then
      say('%df ★ %d 프레임을 기다려도 PC 가 슬롯 안이다 (PC=$%04X) -- 포기',
          frame, WAIT_MAX, pc)
      pending, held = nil, nil
    end
    return
  end
  local why = pending
  pending = nil
  give(string.format('%s · PC=$%04X · %d프레임 대기', why, pc, waited))
end, emu.eventType.endFrame)

emu.addMemoryCallback(function() take('arm $F798') end,
  emu.callbackType.exec, ARM, ARM, CPU, MEM)

emu.addMemoryCallback(function()
  say('%df SKIP@8411 state=$%02X · 보관 %s', frame, rb(STATE), held and '있음' or '없음')
  requestGive('skip $8411')
end, emu.callbackType.exec, OPENING_SKIP, OPENING_SKIP, CPU, MEM)

emu.addMemoryCallback(function(_, value)
  if value == 0 then requestGive('state -> 0') end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addEventCallback(function()
  say('끝 -- 뜸 %d회 · 되돌림 %d회 · 미반납 %s%s', taken, given,
      held and '있음(★)' or '없음', pending and (' · 보류중 ' .. pending) or '')
end, emu.eventType.scriptEnded)

say('loaded -- $%04X-$%04X (%d B) 보존 · 0.5.77 %s', LO, HI, SIZE,
    LOAD_077 and '같이' or '없이')
say('판정: 노스킵 · 자막 중간 스킵 · 자막 전 스킵 -- 셋 다 정상인가')
