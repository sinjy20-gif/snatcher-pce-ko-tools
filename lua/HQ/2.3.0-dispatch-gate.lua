-- ★ HQ 2.3.0 -- 스케줄러 호출 판정($5E1E) 과 ready 를 되돌리는 범인
--
-- 왜 이 판인가
-- ------------
-- §44 실측(0.5.11 · dump/hq_2_2_0_statestuck_20260906_193404.tsv):
--
--     64.95초  SCHED=56  DRAINED=55  FINISHED=1
--     65.95초  SCHED=9   FINISHED=9
--     66.95초~ ★(스케줄러 진입 0)  -- 로그 끝까지 50 초 내내 0
--
-- STATE 가 02 에서 굳는 이유는 "종료 판정이 틀렸다" 보다 한 칸 앞이었다 --
-- **스케줄러가 아예 안 불린다.**
--
-- 구워진 0.5.11 BIOS 에서 `JSR $ECF9` 는 딱 한 곳이고, 조건이 이것이다:
--
--     $F3BA  AD 1E 5E   LDA $5E1E      ★슬롯 +670 = 매체 지문
--     $F3BD  C9 CD      CMP #$CD
--     $F3BF  F0 06      BEQ $F3C7
--     $F3C1  4C 40 FA   JMP $FA40      ADPCM 경로 -- 스케줄러를 안 부른다
--     $F3C7  20 F9 EC   JSR $ECF9      ★CD-DA 스케줄러
--
-- 즉 우리 제어 판정 셋이 **전부 게임에게 빌려준 671 B 안**에 있다:
--
--     $5B80 == $53   상주부 매직            (+0)
--     $5B83 == $AD   671 B 반납 판정        (+3)    ← 35.37 초에 죽는 것을 봤다 (§43)
--     $5E1E == $CD   스케줄러 호출 판정     (+670)  ← 이 판이 잰다
--
-- ⚠ §40-2 는 "$5BA2 이후 638 B 는 한 번도 안 건드린다" 였다.  그러니 $5E1E 가
--   깨진다면 **그 측정과 모순**이다 (그 판은 무장~손상 구간만 봤을 수 있다).
--   모순이 나오면 §40-2 쪽 창을 다시 의심할 것.  둘 중 하나는 틀렸다.
--
-- 이 판이 재는 것
-- --------------
--   ① $5E1E 쓰기 전수 (옛값 -> 새값 · pc)        44-5 를 가른다
--   ② $F3BA 진입 -- 그때의 $5E1E 값               판정의 입력.  초당 한 줄로 접는다
--   ③ $F3C1 진입 -- ADPCM 경로로 샜다             스케줄러를 안 부른 그 순간
--   ④ ready($5CC6) 쓰기 전수 (옛값 -> 새값 · pc)  ★44-3 의 자체 모순
--   ⑤ $EF0B 진입마다 그때의 ready 값              BEQ 가 왜 안 걸리나
--
-- 판정
--   $5E1E 가 65.5 초쯤 $CD 를 잃는다      -> 44-5 확정.  판정을 슬롯 밖으로
--   $5E1E 는 $CD 인데 $F3BA 가 안 불린다   -> 디스패처 자체가 안 돈다.  더 앞을 볼 것
--   ready 를 되돌리는 pc 가 나온다         -> 44-3 이 닫힌다
--
-- ★ 판을 새로 굽지 않는다.  build/patch/0.5.11 그대로.
--
-- 쓰는 법
--     ① build/patch/0.5.11 로 Power Cycle
--     ② 이 파일 하나만 로드
--     ③ 트랙 3 을 국장실까지.  ★곡이 끝나고 30 초는 더 둔다 (60~70 초 구간이 본론)
--
-- 산출  dump/hq_2_3_0_dispatchgate_<시각>.tsv
--
-- ⚠ 화면에 아무것도 안 그린다.  ⚠ 필터를 안 건다 (§40-3).

local VERSION = '2.3.0'
local MEM = emu.memType.pceMemory

local STATE_AT = 0x7FDF
local CD_RAW   = 0x26F9
local SIG_AT   = 0x5B83        -- 반납 판정 (+3)
local MEDIA_AT = 0x5E1E        -- ★스케줄러 호출 판정 (+670)
local MEDIA_OK = 0xCD
local MAGIC_AT = 0x5B80        -- 상주부 매직 (+0)
local READY    = 0x5CC6        -- +326

local DISPATCH = 0xF3BA        -- LDA $5E1E
local TO_ADPCM = 0xF3C1        -- JMP $FA40  (스케줄러를 안 부른다)
local CALL_SCH = 0xF3C7        -- JSR $ECF9
local FINISHED = 0xEF0B        -- cdda_finished
local STATE3   = 0xEF15        -- cdda_state3

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_dispatchgate_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tstate\tcd_raw\tmedia\tsig\tready\tpc\tdetail\n')

local function rb(at) return emu.read(at, MEM) or 0 end
local function pcOf()
  local s = emu.getState() or {}
  return s['cpu.pc'] or 0
end

local frame, rows = 0, 0
local armFrame, dmgFrame = nil, nil
local nDispatch, nAdpcm, nCall = 0, 0, 0
local tDispatch, tAdpcm, tCall = 0, 0, 0
local finishedN = 0
local mediaLost = nil

local function el()
  if not armFrame then return '-' end
  return string.format('%.2f', (frame - armFrame) / 60)
end

local function line(ev, pc, detail)
  rows = rows + 1
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\t%s\n',
    frame, el(), ev, rb(STATE_AT), rb(CD_RAW), rb(MEDIA_AT), rb(SIG_AT), rb(READY),
    pc and string.format('%04X', pc) or '-', detail or ''))
  out:flush()
end

-- ① ★매체 지문 쓰기 -- 전수.  이 판의 본론이다
emu.addMemoryCallback(function(address, value)
  local old = rb(MEDIA_AT)
  line('MEDIA_W', pcOf(), string.format('%02X -> %02X%s', old, value,
    (old == MEDIA_OK and value ~= MEDIA_OK) and '  ★$CD 를 잃었다' or ''))
  if old == MEDIA_OK and value ~= MEDIA_OK and not mediaLost then
    mediaLost = frame
  end
end, emu.callbackType.write, MEDIA_AT, MEDIA_AT, emu.cpuType.pce, MEM)

-- ④ ready 쓰기 -- 전수로 값을 남긴다.  §44-3 의 모순은 값을 안 찍어서 생겼다
emu.addMemoryCallback(function(address, value)
  line('READY_W', pcOf(), string.format('%02X -> %02X', rb(READY), value))
end, emu.callbackType.write, READY, READY, emu.cpuType.pce, MEM)

-- 반납 서명 · 매직도 같이 본다 (셋이 같은 방에 산다)
emu.addMemoryCallback(function(address, value)
  local pc = pcOf()
  if value ~= 0xAD and not dmgFrame and armFrame then
    dmgFrame = frame
    line('SIG_DEAD', pc, string.format('$5B83 <- %02X  (반납 판정 소멸)', value))
  elseif value == 0xAD and dmgFrame then
    dmgFrame = nil
    line('SIG_BACK', pc, '재복사로 되살아났다')
  end
end, emu.callbackType.write, SIG_AT, SIG_AT, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  if value ~= 0x53 then
    line('MAGIC_W', pcOf(), string.format('$5B80 <- %02X', value))
  end
end, emu.callbackType.write, MAGIC_AT, MAGIC_AT, emu.cpuType.pce, MEM)

-- ②③ 디스패처 판정 -- 세고, 드문 것은 그 자리에서
emu.addMemoryCallback(function()
  nDispatch = nDispatch + 1; tDispatch = tDispatch + 1
end, emu.callbackType.exec, DISPATCH, DISPATCH, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  nAdpcm = nAdpcm + 1; tAdpcm = tAdpcm + 1
  if tAdpcm == 1 or (armFrame and tAdpcm % 300 == 0) then
    line('TO_ADPCM', TO_ADPCM,
      string.format('★스케줄러를 안 부른다.  media=%02X (기대 CD).  누적 %d',
        rb(MEDIA_AT), tAdpcm))
  end
end, emu.callbackType.exec, TO_ADPCM, TO_ADPCM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  nCall = nCall + 1; tCall = tCall + 1
end, emu.callbackType.exec, CALL_SCH, CALL_SCH, emu.cpuType.pce, MEM)

-- ⑤ 종료 판정 -- 들어올 때의 ready 를 남긴다
emu.addMemoryCallback(function()
  finishedN = finishedN + 1
  local r = rb(READY)
  line('FINISHED', FINISHED, string.format('#%d  ready=%02X -> %s',
    finishedN, r, (r == 0) and 'BEQ 성립 = STATE3 으로 간다' or '★BEQ 불성립 = STZ 로 샌다'))
end, emu.callbackType.exec, FINISHED, FINISHED, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  line('STATE3', STATE3, '★STATE=3 을 쓰러 들어왔다')
end, emu.callbackType.exec, STATE3, STATE3, emu.cpuType.pce, MEM)

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

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 60 ~= 0 then return end
  if armFrame then
    line('TICK', nil, string.format('DISPATCH=%d CALL=%d TO_ADPCM=%d',
      nDispatch, nCall, nAdpcm))
  end
  nDispatch, nCall, nAdpcm = 0, 0, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  line('TOTALS', nil, string.format(
    'DISPATCH=%d CALL=%d TO_ADPCM=%d FINISHED=%d · media 상실 frame %s · 손상 frame %s',
    tDispatch, tCall, tAdpcm, finishedN, tostring(mediaLost), tostring(dmgFrame)))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' 디스패처 판정 -> ' .. OUT)
