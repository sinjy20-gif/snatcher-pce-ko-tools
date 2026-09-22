-- VERIFY_ADPCM_REUSE 0.2.0 -- 671 B 엔진 재사용 + CD-DA 상태 충돌 실측
--
-- 0.1.0 에서 바뀐 것
--   · 대상이 0.6.1 이다 (rc3 + $EEE1 2바이트). $F671/$F697/$F6F4 는 동일.
--   · cpu_cache 저장/복원($FC7A/$FCDF)을 같이 센다. 이건 엔진 재사용과
--     다른 기능이다 -- ADPCM 엔진이 $5B80 을 쓰기 전에 거기 있던 게임
--     데이터를 AC 로 대피시키고 되돌리는 쪽이다.
--   · ★ CD-DA 상태 충돌을 본다. 아래 "왜" 참고.
--   · 출력 경로가 0.1.0 과 다르다. 로그와 코드가 짝이 맞아야 한다.
--
-- 화면에는 아무것도 그리지 않는다.
--
-- 왜 -- 새로 생긴 위험
-- --------------------
-- $FCDF 복원은 $5B80-$5E1E 671 B 를 통째로 되쓴다. 그 안에 CD-DA 상태
-- $5E1A(state) 와 $5E1B(무장 트랙) 이 들어 있다 (CD-DA cache_data 는
-- $5CF3-$5E19, 상태는 $5E1A-$5E1F. 전부 엔진 구간 안이다).
--
-- 0.6.1 은 자막이 떨어져도 트랙이 끝날 때까지 안 내려간다. 트랙 20 기준
-- state==2 가 약 4.2 초 더 유지된다. 그 늘어난 창 안에서 ADPCM 이 시작해
-- 복원이 돌면 CD-DA 상태가 지워진다. 예전에는 창이 좁아 안 드러났을 수 있다.
--
-- 판정
-- ----
--   REUSE > 0                 671 B 복사를 실제로 생략하고 있다
--   REUSE == 0 · COPY > 0     매번 전체 복사. 재사용이 안 걸린다
--   ready == 0                ADPCM 무장 지점을 안 지났거나 대상 빌드가 아니다
--   CDDA_STOMP > 0            ★ 복원이 살아있는 CD-DA 상태를 덮었다
--
-- 쓰는 법
--   1) 0.6.1 BIOS + [KO] CUE 로 Power Cycle.
--   2) 이 스크립트 하나만 켠다. 상태를 바꾸는 Lua 는 같이 올리지 않는다.
--   3) ADPCM 대사가 연속되는 장면(국장실 등)을 지난다.
--   4) CD-DA 트랙 직후에 ADPCM 이 나오는 장면도 지난다.
--   5) ★ 반드시 Stop 한다. Stop 해야 TSV 가 닫힌다.
--
-- 산출물  C:/snatcher/dump/adpcm_reuse_0_2_0_<시각>.tsv

local VERSION = '0.2.0'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/adpcm_reuse_0_2_0_' .. STAMP .. '.tsv'

-- dispatcher (엔진 재사용)
local ARM_FOUND = 0xF5B9
local COPY      = 0xF697   -- 서명 불일치 -> 671 B 전체 복사
local READY     = 0xF6F4   -- 복사 뒤 또는 서명 일치 직행

-- cpu_cache (게임 데이터 대피/복귀) -- 엔진 재사용과 다른 기능
local CACHE_SAVE    = 0xFC7A
local CACHE_RESTORE = 0xFCDF

-- CD-DA 사설 상태 (엔진 구간 $5B80-$5E1E 안에 들어있다)
local CDDA_STATE = 0x5E1A
local CDDA_TRACK = 0x5E1B

local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\tarms\tcopies\treuses\thead6\tcdda_state\tcdda_trk\tnote\n')

local frame = 0
local arms, copies, reuses, ready = 0, 0, 0, 0
local saves, skips, restores, stomps = 0, 0, 0, 0
local pendingCopy = false
local rows = 0

local function rb(a) return emu.read(a, MEM) or 0 end

local function hx(a, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(a + i)) end
  return table.concat(t, '')
end

local function say(m) emu.log(m); print(m) end

-- 뱅크 매핑이 다른 순간에 같은 주소를 밟을 수 있다. 코드 바이트가
-- 실제로 거기 있을 때만 센다. 0.1.0 에서 가져온 방어다.
local function candidateMapped()
  return hx(0xF671, 12) == 'AD001AC941D01FAD001AC944'
end

local function emit(kind, note)
  out:write(string.format('%d\t%s\t%d\t%d\t%d\t%s\t%02X\t%02X\t%s\n',
    frame, kind, arms, copies, reuses, hx(0x5B80, 6),
    rb(CDDA_STATE), rb(CDDA_TRACK), note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end

-- ---- 엔진 재사용 분기 ------------------------------------------------------

emu.addMemoryCallback(function()
  if candidateMapped() then arms = arms + 1 end
end, emu.callbackType.exec, ARM_FOUND, ARM_FOUND, CPU, MEM)

emu.addMemoryCallback(function()
  if not candidateMapped() then return end
  pendingCopy = true
  copies = copies + 1
end, emu.callbackType.exec, COPY, COPY, CPU, MEM)

emu.addMemoryCallback(function()
  if not candidateMapped() then return end
  ready = ready + 1
  if pendingCopy then
    pendingCopy = false
    emit('COPY', '서명 불일치 -> 671B 전체 복사')
    say(string.format('f%-7d COPY   arm=%d COPY=%d REUSE=%d', frame, arms, copies, reuses))
  else
    reuses = reuses + 1
    emit('REUSE', '서명 일치 -> 671B 복사 생략')
    say(string.format('f%-7d REUSE  arm=%d COPY=%d REUSE=%d', frame, arms, copies, reuses))
  end
end, emu.callbackType.exec, READY, READY, CPU, MEM)

-- ---- cpu_cache 저장/복원 ---------------------------------------------------
--
-- $FC7A 는 $5B83 == $AD 이면 저장을 건너뛴다. 한 바이트짜리 판정이라
-- 게임 데이터의 그 자리가 우연히 $AD 면 오판한다. 실제로 나는지 본다.

emu.addMemoryCallback(function()
  local head = hx(0x5B80, 6)
  local willSkip = (rb(0x5B83) == 0xAD)
  -- ADPCM 엔진의 머리 6바이트. 앞 3바이트 "SUB" 는 CD-DA 엔진도 같다.
  local isAdpcmEngine = (head == '535542ADF95C')
  if willSkip then
    skips = skips + 1
    if not isAdpcmEngine then
      emit('CACHE_SKIP', '★오판 의심: $5B83=AD 인데 머리가 ADPCM 엔진이 아니다')
      say(string.format('f%-7d CACHE_SKIP  ★오판 의심  head=%s', frame, head))
    else
      emit('CACHE_SKIP', '엔진 상주 -> 저장 생략 (정상)')
    end
  else
    saves = saves + 1
    emit('CACHE_SAVE', '게임 데이터 671B 를 AC 로 대피')
  end
end, emu.callbackType.exec, CACHE_SAVE, CACHE_SAVE, CPU, MEM)

emu.addMemoryCallback(function()
  restores = restores + 1
  local st = rb(CDDA_STATE)
  -- state==2 는 CD-DA 자막이 살아서 그려지는 중이라는 뜻이다.
  -- 복원은 $5B80-$5E1E 를 되쓰므로 $5E1A/$5E1B 가 같이 지워진다.
  if st == 2 then
    stomps = stomps + 1
    emit('RESTORE', '★CDDA_STOMP: state=2 인데 복원이 $5E1A/$5E1B 를 덮는다')
    say(string.format('f%-7d RESTORE  ★CDDA_STOMP  state=%02X trk=%02X',
      frame, st, rb(CDDA_TRACK)))
  else
    emit('RESTORE', '게임 데이터 671B 복귀')
  end
end, emu.callbackType.exec, CACHE_RESTORE, CACHE_RESTORE, CPU, MEM)

-- ---- 프레임 -----------------------------------------------------------------

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say(string.format('끝  프레임 %d', frame))
  say(string.format('  엔진   arm=%d ready=%d  COPY=%d  REUSE=%d', arms, ready, copies, reuses))
  say(string.format('  캐시   SAVE=%d  SKIP=%d  RESTORE=%d', saves, skips, restores))
  say(string.format('  충돌   CDDA_STOMP=%d', stomps))
  if ready == 0 then
    say('  판정 불가: ADPCM 무장 지점을 안 지났거나 대상 빌드가 아니다')
  elseif reuses == 0 then
    say('  재사용 0회: 서명이 유지되지 않는다. 최적화가 안 걸리고 있다')
  else
    say('  재사용 확인: 671B 복사를 실제로 생략했다')
  end
  if stomps > 0 then
    say('  ★ 복원이 살아있는 CD-DA 상태를 덮은 사례가 있다. 0.6.1 이 상태를')
    say('     더 오래 유지하므로 이 창이 넓어졌다. 그림/자막 이상과 대조할 것')
  end
  out:write('#\n')
  out:write(string.format('# frames=%d arm=%d ready=%d copy=%d reuse=%d save=%d skip=%d restore=%d stomp=%d\n',
    frame, arms, ready, copies, reuses, saves, skips, restores, stomps))
  out:close()
  say('-> ' .. OUT)
end, emu.eventType.scriptEnded)

say('VERIFY_ADPCM_REUSE ' .. VERSION .. ' -- 화면 표시 없음, 대상 0.6.1')
say('  코드 매핑 확인: ' .. (candidateMapped() and 'YES' or '아직 아님'))
say('  COPY / REUSE 가 ADPCM 대사마다 한 줄씩 찍힌다')
say('  ★ 로 시작하는 줄이 나오면 알려줄 것')
say('-> ' .. OUT)
