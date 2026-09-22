-- SUB 0.5.104 -- 게임이 스킵 직후 우리 엔진 바이트를 자기 데이터로 읽는가
--
-- 왜 여기인가
-- ---------------------------------------------------------------------------
-- 0.5.103 'cancel' 이 깨졌다.  반납(restore+wipe)을 아예 안 시켜도 깨진다.
-- 그러면 파손은 반납이 아니라 **그 전에** 났다.
--
-- Lua 로 취소할 수 없는 것이 하나 남는다 -- 상주부($7FA0)가 매 프레임
-- helper/renderer 를 `$5B80-$5E1E` 로 복사한다.  그 671 B 는 게임의
-- **스크립트 VM 데이터 스택**이고, 오프닝 스킵 목적지 `$8411` 은 바로 그
-- VM 이 도는 장면 전환이다.  반납할 때 첫 바이트만 STZ 로 지우고 원래
-- 내용은 안 돌려준다.
--
--   게임이 스킵 뒤 그 자리를 읽으면 -> 우리 엔진 바이트를 자기 데이터로 읽는다
--   그러면 "게임이 그리긴 그렸는데 엉뚱한 것을 그렸다" 가 설명되고,
--   화면 자원(VRAM·BAT·SATB·팔레트·VDC)이 전부 멀쩡한 것도 같이 설명된다
--
-- 판정
-- ---------------------------------------------------------------------------
--   읽는다     원인 확정.  빌리기 전에 671 B 를 AC 에 떠 두었다가 반납할 때
--              되돌린다 ($1F0E00 AC_CPU_CACHE_BACKUP 이 이미 예약돼 있다)
--   안 읽는다  CPU RAM 도 지워진다.  다음은 ADPCM/CD-ROM 레지스터와 BIOS 작업 RAM
--
-- ★ 가볍다: `$8411` 에 들어간 뒤에만 콜백을 걸고 WINDOW 프레임 뒤 뗀다.
--   자리별 첫 적중만 기록한다 (§5-3: 필터가 기록까지 막으면 안 된다).
--   PC 조회는 기록할 때만 한다 (§5-6: 뜨거운 경로의 getState 는 1 fps).
-- ★ 게임 코드 무수정 · 아무것도 안 쓴다 (읽기 전용)

-- ★★ 0.5.77 은 반드시 같이 올린다 -- 진단 부하가 아니라 **하중을 받는 부품**이다.
--    빼면 0.4.6.48 맨몸이 되어 노스킵·중간 스킵까지 전부 깨진다 (실측).
--    안 그린 케이스에서만 diff=0 이라 무해할 뿐, 그린 케이스에서는 일을 한다.
dofile('C:/snatcher/lua/SUB/0.5.77-refresh-cdda-backup.lua')

local TAG = 'SUB 0.5.104'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local OPENING_SKIP = 0x8411
local LO, HI = 0x5B80, 0x5E1E          -- 671 B.  엔진 슬롯 = 게임 VM 스택
local TRACK, STATE, SIG = 0x26F9, 0x7FDF, 0x5DDA
local CDDA_TRACK, CDDA_SIG = 0x11, 0x38
local WINDOW, MAX_LOG = 600, 40        -- 스킵 뒤 600 프레임만 · 40 자리까지 기록

local frame, armed, ref, live = 0, nil, nil, false
local seen, logged, total, byGame, byOurs = {}, 0, 0, 0, 0

local function rb(at) return emu.read(at, MEM) or 0 end
local function say(fmt, ...) emu.log(TAG .. ' · ' .. string.format(fmt, ...)) end

-- 이 환경 A 규약: emu.getState() 는 **평평한 키**다 ('cpu.pc').  s.pc 는 nil 일 수 있다.
local function getPC()
  local st = emu.getState()
  local v = st and (st['cpu.pc'] or st.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

local function disarm(why)
  if not live then return end
  live = false
  -- removeMemoryCallback 은 이 저장소에 전례가 없다.  없으면 플래그로만 끈다.
  if ref then pcall(emu.removeMemoryCallback, ref, emu.callbackType.read, LO, HI, CPU, MEM) end
  ref, armed = nil, nil
  say('%df 해제 (%s) -- 읽기 %d회 · 기록한 자리 %d', frame, why, total, logged)
  if byGame == 0 then
    say('  ★ 게임 PC 로 읽은 적 없다 -- CPU RAM 도 지워진다')
  else
    say('  ★★ 게임(PC 가 슬롯 밖)이 %d 자리를 읽었다 -- 원인 확정', byGame)
  end
end

-- ⚠ §5-6: 읽기마다 getState() 를 부르면 1 fps 가 된다.  여기는 게임 VM 스택이라
--    미친 듯이 읽힌다.  그래서 **자리별 첫 적중** 에서만 PC 를 조회한다 (최대 40회).
local function onRead(addr)
  if not live then return end
  total = total + 1
  if seen[addr] or logged >= MAX_LOG then return end
  seen[addr] = true
  logged = logged + 1
  local pc = getPC()
  local ours = (pc >= LO and pc <= HI)
  if ours then byOurs = byOurs + 1 else byGame = byGame + 1 end
  say('%df READ $%04X  pc=$%04X %s  val=$%02X',
      frame, addr, pc, ours and '(우리)' or '★게임', rb(addr))
end

emu.addEventCallback(function()
  frame = frame + 1
  if armed and frame >= armed then disarm('창 끝') end
end, emu.eventType.endFrame)

emu.addMemoryCallback(function()
  if armed then return end
  local track, state, sig = rb(TRACK) & 0x7F, rb(STATE), rb(SIG)
  say('%df SKIP@8411 track=$%02X state=$%02X sig=$%02X · cmd=$%02X status=$%02X',
      frame, track, state, sig, rb(0x5D30), rb(0x5D31))
  if track ~= CDDA_TRACK or sig ~= CDDA_SIG then
    say('  CD-DA 가 아니다 -- 안 건다'); return
  end
  armed, live = frame + WINDOW, true
  ref = emu.addMemoryCallback(onRead, emu.callbackType.read, LO, HI, CPU, MEM)
  say('  ★ $%04X-$%04X 읽기 감시 시작 (%d 프레임)', LO, HI, WINDOW)
end, emu.callbackType.exec, OPENING_SKIP, OPENING_SKIP, CPU, MEM)

emu.addEventCallback(function() disarm('스크립트 종료') end, emu.eventType.scriptEnded)

say('loaded -- 읽기 전용 · 개입 없음')
say('판정: 오프닝 뜨자마자(자막 전) 스킵 -> 게임이 $5B80-$5E1E 를 읽는가')
