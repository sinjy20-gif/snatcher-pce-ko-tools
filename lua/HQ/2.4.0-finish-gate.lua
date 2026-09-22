-- ★ HQ 2.4.0 -- 0.5.12 A안이 실제로 STATE=3 을 쓰고 671 B 를 돌려주는가
--
-- ⚠ 이 판은 **0.5.12 전용**이다.  주소가 옮겨졌다:
--
--       cdda_state3   0.5.11 $EF15  ->  ★0.5.12 $EF1F
--       cdda_finished 0.5.11 $EF0B  ->   0.5.12 $EF0B (같다)
--       소유 표식     0.5.11 $5B83/$AD -> ★0.5.12 $5B80/$53
--
--   0.5.11 에 이 판을 걸면 STATE3 이 영영 안 찍힌다.  그때는 2.3.0 을 쓸 것.
--
-- 왜 이 판인가
-- ------------
-- 0.5.12 는 §45 의 사슬을 두 곳에서 끊었다 (인계서 §46):
--
--   ① cdda_finished 가 `ready`(슬롯 안) 대신 `part`/`count`($2100 대역) 를 본다
--        $EF0B  BD 03 21   LDA $2103,X    S_PART
--        $EF0E  DD 04 21   CMP $2104,X    S_COUNT
--        $EF11  F0 02      BEQ $EF15      part == count -> 옛 경로
--        $EF13  B0 0A      BCS $EF1F      ★part >  count -> STATE=3
--   ② 반납 소유 표식이 +3($5B83/$AD) 에서 +0($5B80/$53) 으로 갔다
--        게임이 쓰는 33 B 는 +1~+33 이라 +0 은 사정권 밖이다 (2.3.0 전수 관측)
--
-- 0.5.11 로 잰 것과 나란히 놓고 읽으면 된다:
--
--       0.5.11   FINISHED 10 회 · ready=01 전부 · ★STATE3 0 회 · RESTORE 0 회
--       0.5.12   ★STATE3 1 회가 떠야 하고 · 그 뒤 RESTORE 가 돌아야 한다
--
-- 이 판이 재는 것
-- --------------
--   ① $EF0B 진입마다 part/count/ready                판정의 입력 전부
--   ② $EF1F 진입 (STATE=3 을 쓰러 왔다)              ★본론
--   ③ STATE 전이 전부                                 02 -> 03 -> 00 이 와야 한다
--   ④ $FCD1 maybe_restore 판정 (그때의 $5B80)         새 표식이 살아 있나
--   ⑤ $FCDF restore 실행                              ★671 B 가 돌아갔나
--   ⑥ $5B80(+0) · $5B83(+3) 쓰기 전수                 +0 이 정말 안 밟히나
--   ⑦ 디스패처 $F3BA 진입 수                          창이 언제 닫히나
--
-- 판정
--   STATE3 이 뜨고 RESTORE 가 돈다      -> ★A안 성립.  국장실을 보라
--   STATE3 이 뜨는데 RESTORE 가 0       -> §42-4 의 지뢰가 남았다.  ⑥ 로그를 볼 것
--   STATE3 이 안 뜬다                    -> part/count 가 기대와 다르다.  ① 로그를 볼 것
--
-- 쓰는 법
--     ① build/patch/0.5.12 로 Power Cycle
--     ② 이 파일 하나만 로드
--     ③ 트랙 3 을 국장실까지.  곡이 끝나고 20 초는 더 둔다
--     ④ 회귀: 오프닝(트랙 17) · ADPCM D000 도 각각 한 판
--
-- 산출  dump/hq_2_4_0_finishgate_<시각>.tsv
--
-- ⚠ 화면에 아무것도 안 그린다.  ⚠ 필터를 안 건다 (§40-3 · §45-1).

local VERSION = '2.4.0'
local MEM = emu.memType.pceMemory

local STATE_AT = 0x7FDF
local CD_RAW   = 0x26F9
local OWN_AT   = 0x5B80        -- ★새 소유 표식 (+0)
local OWN_OK   = 0x53          -- 'S'
local OLD_SIG  = 0x5B83        -- 옛 표식 (+3).  게임이 죽이는 것을 보려고 같이 본다
local READY    = 0x5CC6        -- +326

-- 0.5.12 자리 (build/patch/0.5.12/cdda_scheduler.json 의 labels)
local FINISHED = 0xEF0B
local STATE3   = 0xEF1F        -- ★0.5.11 의 $EF15 가 아니다
local DRAINED  = 0xEE87
local WAITSTOP = 0xEEF0
local STOPPED  = 0xEF03

-- cpu_cache 처방 (0.5.12 도 자리는 같다)
local START_SUB = 0xFC7A
local MAYBE_RES = 0xFCD1
local RESTORE   = 0xFCDF
local DISPATCH  = 0xF3BA

-- 스케줄러 상태 ($2100 + S_*).  X 는 트랙 슬롯 색인이라 여기서는 못 읽는다 --
-- 대신 $EF0B 진입 때 실제로 비교되는 두 바이트를 X 없이 근사로 남긴다.
local S_PART_BASE  = 0x2103
local S_COUNT_BASE = 0x2104

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_finishgate_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tstate\tcd_raw\town\toldsig\tready\tpc\tdetail\n')

local function rb(at) return emu.read(at, MEM) or 0 end
local function pcOf()
  local s = emu.getState() or {}
  return s['cpu.pc'] or 0
end

local frame, rows = 0, 0
local armFrame = nil
local nFin, nState3, nRestore, nDispatch = 0, 0, 0, 0
local tDispatch = 0
local ownLost = nil

local function el()
  if not armFrame then return '-' end
  return string.format('%.2f', (frame - armFrame) / 60)
end

local function line(ev, pc, detail)
  rows = rows + 1
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\t%s\n',
    frame, el(), ev, rb(STATE_AT), rb(CD_RAW), rb(OWN_AT), rb(OLD_SIG), rb(READY),
    pc and string.format('%04X', pc) or '-', detail or ''))
  out:flush()
end

-- ① 종료 판정 -- 들어올 때의 입력을 전부 남긴다
emu.addMemoryCallback(function()
  nFin = nFin + 1
  line('FINISHED', FINISHED, string.format('#%d  part~=%02X count~=%02X ready=%02X',
    nFin, rb(S_PART_BASE), rb(S_COUNT_BASE), rb(READY)))
end, emu.callbackType.exec, FINISHED, FINISHED, emu.cpuType.pce, MEM)

-- ② ★본론
emu.addMemoryCallback(function()
  nState3 = nState3 + 1
  line('STATE3', STATE3, string.format('★#%d  STATE=3 을 쓰러 왔다', nState3))
end, emu.callbackType.exec, STATE3, STATE3, emu.cpuType.pce, MEM)

for _, s in ipairs({ { DRAINED, 'DRAINED' }, { WAITSTOP, 'WAIT_STOP' }, { STOPPED, 'STOPPED' } }) do
  local addr, name = s[1], s[2]
  local seen = 0
  emu.addMemoryCallback(function()
    seen = seen + 1
    if seen == 1 then line('FIRST_' .. name, addr, '이 자리에 처음 들어왔다') end
  end, emu.callbackType.exec, addr, addr, emu.cpuType.pce, MEM)
end

-- ④⑤ 반납
emu.addMemoryCallback(function()
  line('START_SUB', START_SUB, string.format('스냅샷 판정  own=%02X (== 53 이면 건너뜀)',
    rb(OWN_AT)))
end, emu.callbackType.exec, START_SUB, START_SUB, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  local o = rb(OWN_AT)
  line('MAYBE_RESTORE', MAYBE_RES, string.format('own=%02X -> %s', o,
    (o == OWN_OK) and '★복원한다' or '건너뛴다'))
end, emu.callbackType.exec, MAYBE_RES, MAYBE_RES, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  nRestore = nRestore + 1
  line('RESTORE', RESTORE, string.format('★671 B 복원 실행 #%d', nRestore))
end, emu.callbackType.exec, RESTORE, RESTORE, emu.cpuType.pce, MEM)

-- ⑥ 표식 두 개 전수
emu.addMemoryCallback(function(address, value)
  local old = rb(OWN_AT)
  line('OWN_W', pcOf(), string.format('$5B80 %02X -> %02X%s', old, value,
    (old == OWN_OK and value ~= OWN_OK) and '  ★소유 표식을 잃었다' or ''))
  if old == OWN_OK and value ~= OWN_OK and armFrame and not ownLost then
    ownLost = frame
  end
end, emu.callbackType.write, OWN_AT, OWN_AT, emu.cpuType.pce, MEM)

local oldSigDead = false
emu.addMemoryCallback(function(address, value)
  if value ~= 0xAD and not oldSigDead and armFrame then
    oldSigDead = true
    line('OLDSIG_DEAD', pcOf(), string.format(
      '$5B83 <- %02X  (0.5.11 이면 여기서 반납이 끊겼다.  이제는 무관해야 한다)', value))
  end
end, emu.callbackType.write, OLD_SIG, OLD_SIG, emu.cpuType.pce, MEM)

-- ③ STATE
emu.addMemoryCallback(function(address, value)
  local old = rb(STATE_AT)
  if old ~= value then
    line('STATE', pcOf(), string.format('%02X -> %02X', old, value))
    if value == 0x02 and rb(CD_RAW) == 0x03 and not armFrame then
      armFrame = frame
      line('ARM_T3', nil, '★트랙 3 무장')
    end
  end
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

-- ⑦ 디스패처
emu.addMemoryCallback(function()
  nDispatch = nDispatch + 1; tDispatch = tDispatch + 1
end, emu.callbackType.exec, DISPATCH, DISPATCH, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 60 ~= 0 then return end
  if armFrame then line('TICK', nil, string.format('DISPATCH=%d', nDispatch)) end
  nDispatch = 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  line('TOTALS', nil, string.format(
    'FINISHED=%d ★STATE3=%d ★RESTORE=%d DISPATCH=%d · 무장 %s · 표식상실 %s',
    nFin, nState3, nRestore, tDispatch, tostring(armFrame), tostring(ownLost)))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' (0.5.12 전용) -> ' .. OUT)
