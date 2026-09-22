-- ★ HQ 2.1.0 -- 671 B 반납이 **취소되는가**
--
-- 왜 이 판인가
-- ------------
-- §42(정적)가 소스와 구워진 ROM 바이트로 이렇게 말한다:
--
--     671 B 를 게임에 돌려주는 판정이 `$5B83 == $AD` 하나다.
--     그런데 게임이 방을 바꾸며 쓰는 33 B ($5B81~$5BA1) 안에 그 $5B83 이 있다.
--     -> 방이 바뀌면 서명이 사라지고, 트랙이 끝나도 **복원이 영영 안 온다.**
--
-- 구워진 0.5.11 ROM 에서 확인된 바이트 (0.5.10 도 같다):
--     $FC7A  start_sub      AD 83 5B  C9 AD  F0 23     서명 있으면 스냅샷 안 뜬다
--     $FCD1  maybe_restore  AD 83 5B  C9 AD  D0 03     서명 없으면 ★복원 건너뜀
--                           20 DF FC                   JSR $FCDF = restore 671 B
--
-- 그리고 상주부(151 B @ $7F49)는 STATE=02 인 동안 `$7F82 JSR $5B83` 을
-- **매직 검사 없이** 매 프레임 부른다.  매직 검사는 무장 경로($7F5E)에만 있다.
--
-- 이 판이 재는 것 -- 넷을 한 판에
-- --------------------------------
--   ① $5B83 이 언제 $AD 가 아니게 되는가 (쓴 pc 와 함께)
--   ② 트랙이 끝나고 STATE 3->0 뒤에 restore($FCDF)가 **도는가 안 도는가**
--   ③ maybe_restore($FCD1)에 들어온 순간의 $5B83 실제값 = 판정의 입력
--   ④ 상주부 $7F82 가 서명이 깨진 뒤에도 $5B83 을 부르는가 (§42-3)
--
-- 판정
--   ①이 36 초쯤 일어나고 ②가 안 돈다        -> ★§42-4 확정.  반납이 취소된다
--   ②가 도는데도 국장실이 깨진다             -> §42-4 는 죽는다.  ④/재배치 쪽만 남는다
--   트랙 17 에서 ①이 없고 ②가 돈다           -> 대조군 성립 (§35-5 의 미해결이 닫힌다)
--
-- ★ 판을 새로 굽지 않는다.  build/patch/0.5.11 그대로 잰다.
--
-- 쓰는 법
--     ① build/patch/0.5.11 로 Power Cycle
--     ② 이 파일 하나만 로드
--     ③ 트랙 3 (본부 복귀 -> 접수처 -> 국장실) 을 그냥 진행한다.
--        국장실에서 멈춰도 그대로 20 초쯤 더 둔다 -- ②가 늦게 올 수 있다
--     ④ 대조군으로 오프닝(트랙 17)도 한 판 더 뜨면 좋다
--
-- 산출  dump/hq_2_1_0_returngate_<시각>.tsv
--
-- ⚠ 화면에 아무것도 안 그린다 (드로잉은 판정을 가린다).
-- ⚠ 필터를 안 건다.  §40-3 에서 필터 때문에 목록이 두 번 비었다.
--    조건은 거르지 말고 **열로 남긴다.**

local VERSION = '2.1.0'
local MEM = emu.memType.pceMemory

local SLOT_LO   = 0x5B80
local SIG_AT    = 0x5B83        -- 반납 판정이 보는 그 바이트
local SIG_OK    = 0xAD          -- 헬퍼/렌더러 entry 첫 바이트 (LDA)
local MAGIC_AT  = 0x5B80        -- 'S' = $53.  상주부 무장 경로가 보는 매직
local STATE_AT  = 0x7FDF
local CD_RAW    = 0x26F9

-- BIOS 뱅크 $01 (CPU $E000-$FFFF).  patch_bios_cpu_cache.py 가 낸 자리
local START_SUB = 0xFC7A
local MAYBE_RES = 0xFCD1
local RESTORE   = 0xFCDF

-- 상주부 (resident_controller_native_poll_0_8_5 @ $7F49)
local RES_ARM   = 0x7F6C        -- STATE=1 경로의 JSR $5B83
local RES_END   = 0x7F7D        -- STATE=3 경로의 JSR $5B83
local RES_PLAY  = 0x7F82        -- ★STATE=2.  매 프레임.  매직 검사 없음
local RES_RECOPY= 0x7FBB        -- 렌더러 671 B 재복사

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_returngate_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tstate\tcd_raw\tsig\tmagic\tpc\tdetail\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame     = 0
local armFrame  = nil       -- STATE 가 처음 02 가 된 프레임
local lastSig   = nil
local lastState = nil
local rows      = 0
local playCalls = 0         -- $7F82 호출 수 (프레임마다 1)
local playAfter = 0         -- 서명이 깨진 뒤의 $7F82 호출 수
local sigBroken = false
local restoreRan = 0

local function el()
  if not armFrame then return '-' end
  return string.format('%.2f', (frame - armFrame) / 60)
end

local function line(ev, pc, detail)
  rows = rows + 1
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%s\t%s\n',
    frame, el(), ev, rb(STATE_AT), rb(CD_RAW), rb(SIG_AT), rb(MAGIC_AT),
    pc and string.format('%04X', pc) or '-', detail or ''))
  out:flush()
end

local function pcOf()
  local s = emu.getState() or {}
  return s['cpu.pc'] or 0
end

-- ① 서명 바이트에 누가 쓰는가 -- 전수.  거르지 않는다
emu.addMemoryCallback(function(address, value)
  local pc = pcOf()
  line('SIG_W', pc, string.format('%02X->%02X', rb(SIG_AT), value))
  if value ~= SIG_OK and not sigBroken then
    sigBroken = true
    line('SIG_BROKEN', pc, string.format('서명 소멸 %02X.  이후 복원 판정은 실패한다', value))
  elseif value == SIG_OK and sigBroken then
    sigBroken = false
    line('SIG_BACK', pc, '서명 복구 (재복사가 돌았다)')
  end
end, emu.callbackType.write, SIG_AT, SIG_AT, emu.cpuType.pce, MEM)

-- 매직('S')도 같이 본다.  상주부 무장 경로가 이걸 본다
emu.addMemoryCallback(function(address, value)
  if value ~= 0x53 then
    line('MAGIC_W', pcOf(), string.format('$5B80 <- %02X (매직 깨짐)', value))
  end
end, emu.callbackType.write, MAGIC_AT, MAGIC_AT, emu.cpuType.pce, MEM)

-- ②③ BIOS 반납 처방 -- 세 자리를 다 짚는다
emu.addMemoryCallback(function()
  line('START_SUB', START_SUB,
    string.format('스냅샷 판정.  sig=%02X (== AD 면 뜨기 건너뜀)', rb(SIG_AT)))
end, emu.callbackType.exec, START_SUB, START_SUB, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  local s = rb(SIG_AT)
  line('MAYBE_RESTORE', MAYBE_RES,
    string.format('sig=%02X -> %s', s, (s == SIG_OK) and '복원한다' or '★건너뛴다'))
end, emu.callbackType.exec, MAYBE_RES, MAYBE_RES, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  restoreRan = restoreRan + 1
  line('RESTORE', RESTORE, string.format('671 B 복원 실행 #%d', restoreRan))
end, emu.callbackType.exec, RESTORE, RESTORE, emu.cpuType.pce, MEM)

-- ④ 상주부의 슬롯 호출 세 자리
emu.addMemoryCallback(function()
  playCalls = playCalls + 1
  if sigBroken then
    playAfter = playAfter + 1
    -- 깨진 뒤 처음 · 그리고 60 프레임마다만 남긴다 (매 프레임이면 파일이 터진다)
    if playAfter == 1 or playAfter % 60 == 0 then
      line('PLAY_CALL_BROKEN', RES_PLAY,
        string.format('★서명 깨진 채 JSR $5B83.  깨진 뒤 %d 번째', playAfter))
    end
  end
end, emu.callbackType.exec, RES_PLAY, RES_PLAY, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  line('RES_ARM', RES_ARM, 'STATE=1 경로 JSR $5B83')
end, emu.callbackType.exec, RES_ARM, RES_ARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  line('RES_END', RES_END, 'STATE=3 경로 JSR $5B83 (직전에 STATE 3->0)')
end, emu.callbackType.exec, RES_END, RES_END, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  line('RECOPY', RES_RECOPY, '렌더러 671 B 재복사 -- 서명도 여기서 되살아난다')
end, emu.callbackType.exec, RES_RECOPY, RES_RECOPY, emu.cpuType.pce, MEM)

-- STATE 전이
emu.addMemoryCallback(function(address, value)
  local old = rb(STATE_AT)
  if old ~= value then
    line('STATE', pcOf(), string.format('%02X -> %02X', old, value))
    if value == 0x02 and not armFrame then armFrame = frame end
  end
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local sig = rb(SIG_AT)
  if lastSig == nil then
    lastSig = sig
    line('BOOT', nil, string.format('감시 시작.  sig=%02X', sig))
  elseif sig ~= lastSig then
    -- 쓰기 콜백이 못 잡는 경로(블록 전송 등)로 바뀌는 경우까지 잡는다
    line('SIG_CHANGED', nil, string.format('%02X -> %02X (프레임 대조)', lastSig, sig))
    lastSig = sig
  end
  local st = rb(STATE_AT)
  if lastState ~= st then
    if lastState ~= nil then
      line('STATE_SEEN', nil, string.format('%02X -> %02X (프레임 대조)', lastState, st))
    end
    lastState = st
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  line('SUMMARY', nil, string.format(
    '행 %d · $7F82 호출 %d (서명 깨진 뒤 %d) · restore 실행 %d 회',
    rows, playCalls, playAfter, restoreRan))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' 반납 게이트 -> ' .. OUT)
