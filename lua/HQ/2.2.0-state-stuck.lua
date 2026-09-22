-- ★ HQ 2.2.0 -- STATE 가 왜 **02 에서 굳는가**
--
-- 왜 이 판인가
-- ------------
-- §43 실측(0.5.11 · dump/hq_2_1_0_returngate_20260906_192614.tsv):
--
--     frame  8077  트랙 3 무장.  STATE 00 -> 01 -> 02
--     frame 10199  게임 pc=$8D8B 가 $5B83 <- B1.  무장 +35.37 초.  서명 소멸
--     frame 10200~ 상주부가 망가진 자리를 1,524 회 더 부른다
--     frame 12791  로그 끝 (무장 +78.6 초).  ★STATE 는 아직 02
--
-- 곡은 66.95 초짜리인데 STATE 가 02 에서 안 나간다.  그래서 3 도 0 도 안 오고,
-- 반납 판정(`$FCD1`)은 **판정할 기회조차 못 얻는다**.  §42-4 의 서명 게이트는
-- 죽은 기전이 아니라 **그다음 지뢰**다 -- STATE 를 고쳐야 거기 닿는다.
--
-- 즉 지금의 첫 도미노는 이것이다:
--
--     ★ 35.37 초 이후 스케줄러는 어디까지 돌고, 어디서 되돌아 나가는가?
--
-- 이 판이 재는 것
-- --------------
--   ① 스케줄러 진입($ECF9)이 계속 도는가 -- 초당 횟수
--   ② 종료 경로 네 자리에 들어오는가
--        cdda_finished $EF0B · cdda_state3 $EF15 · cdda_stopped $EF03 · cdda_wait_stop $EEF0
--        (+ cdda_due $EE15 · cdda_drained $EE87 · cdda_skip $EEE8)
--   ③ ready($5CC6) 에 누가 쓰는가 -- pc 전수.  +326 은 손상 범위(+1~+33) **밖**이다
--   ④ record_ptr($5CC7) · stage($5D69) 가 35.37 초 뒤에도 움직이는가
--   ⑤ $5B83 손상 시각 (기준점)
--
-- 판정
--   $EF0B 에 들어오는데 STATE 를 안 쓴다     -> 종료 판정 안에서 되돌아 나간다.  그 분기가 범인
--   $EF0B 에 아예 안 들어온다                 -> 그 앞(due/drained)에서 막힌다
--   $ECF9 조차 안 돈다                        -> 스케줄러가 통째로 안 불린다.  훅 쪽 문제
--   ready 를 망가진 pc(=$5Bxx)가 쓴다         -> 손상된 코드가 변수를 오염시킨다
--
-- ★ 판을 새로 굽지 않는다.  build/patch/0.5.11 그대로.
--
-- 쓰는 법
--     ① build/patch/0.5.11 로 Power Cycle
--     ② 이 파일 하나만 로드
--     ③ 트랙 3 을 국장실까지.  ★멈춰도 곡이 확실히 끝나고 30 초는 더 둔다
--
-- 산출  dump/hq_2_2_0_statestuck_<시각>.tsv
--
-- ⚠ 화면에 아무것도 안 그린다.
-- ⚠ 필터를 안 건다 (§40-3).  잦은 것은 **세어서** 초당 한 줄로 접는다.

local VERSION = '2.2.0'
local MEM = emu.memType.pceMemory

local STATE_AT = 0x7FDF
local CD_RAW   = 0x26F9
local SIG_AT   = 0x5B83
local SIG_OK   = 0xAD

-- 렌더러 슬롯 변수 (전부 손상 범위 +1~+33 **밖**이다.  멀쩡해야 정상)
local READY    = 0x5CC6        -- +326
local RECPTR   = 0x5CC7        -- +327
local STAGE    = 0x5D69        -- +489

-- 스케줄러 (뱅크 A · build/patch/0.5.11/cdda_scheduler.json 의 labels)
local SITES = {
  { 0xECF9, 'SCHED'      },    -- scheduler_cdda   매 프레임 진입
  { 0xEE15, 'DUE'        },    -- cdda_due
  { 0xEE87, 'DRAINED'    },    -- cdda_drained
  { 0xEEE8, 'SKIP'       },    -- cdda_skip
  { 0xEEF0, 'WAIT_STOP'  },    -- cdda_wait_stop
  { 0xEF03, 'STOPPED'    },    -- cdda_stopped
  { 0xEF0B, 'FINISHED'   },    -- cdda_finished   ★종료 판정
  { 0xEF15, 'STATE3'     },    -- cdda_state3
}

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_statestuck_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tstate\tcd_raw\tsig\tready\trecptr\tstage\tpc\tdetail\n')

local function rb(at) return emu.read(at, MEM) or 0 end
local function pcOf()
  local s = emu.getState() or {}
  return s['cpu.pc'] or 0
end

local frame, rows = 0, 0
local armFrame, dmgFrame = nil, nil
local hit = {}                 -- 이름 -> 이번 초의 진입 횟수
local total = {}               -- 이름 -> 누적
local readyPc = {}             -- ready 를 쓴 pc -> 횟수
local lastVals = nil

for _, s in ipairs(SITES) do hit[s[2]] = 0; total[s[2]] = 0 end

local function el()
  if not armFrame then return '-' end
  return string.format('%.2f', (frame - armFrame) / 60)
end

local function line(ev, pc, detail)
  rows = rows + 1
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\t%s\n',
    frame, el(), ev, rb(STATE_AT), rb(CD_RAW), rb(SIG_AT),
    rb(READY), rb(RECPTR), rb(STAGE),
    pc and string.format('%04X', pc) or '-', detail or ''))
  out:flush()
end

-- ①② 스케줄러 진입 -- 세기만 하고 초당 한 줄로 접는다
for _, s in ipairs(SITES) do
  local addr, name = s[1], s[2]
  emu.addMemoryCallback(function()
    hit[name] = hit[name] + 1
    total[name] = total[name] + 1
    -- 드문 자리는 첫 진입을 그 자리에서 남긴다 (SCHED 는 매 프레임이라 뺀다)
    if name ~= 'SCHED' and total[name] == 1 then
      line('FIRST_' .. name, addr, '이 자리에 처음 들어왔다')
    end
  end, emu.callbackType.exec, addr, addr, emu.cpuType.pce, MEM)
end

-- ③ ready 에 쓴 pc -- 전수로 센다
emu.addMemoryCallback(function(address, value)
  local pc = pcOf()
  readyPc[pc] = (readyPc[pc] or 0) + 1
  -- 손상 뒤 슬롯 안($5B80-$5E1E)에서 쓴 것은 그 자리에서 남긴다 -- 망가진 코드일 수 있다
  if dmgFrame and pc >= 0x5B80 and pc <= 0x5E1E and readyPc[pc] <= 3 then
    line('READY_W_SLOT', pc, string.format('%02X -> %02X  ★손상 뒤 슬롯 안에서 썼다',
      rb(READY), value))
  end
end, emu.callbackType.write, READY, READY, emu.cpuType.pce, MEM)

-- ④ record_ptr · stage
emu.addMemoryCallback(function(address, value)
  line('RECPTR_W', pcOf(), string.format('%02X -> %02X', rb(RECPTR), value))
end, emu.callbackType.write, RECPTR, RECPTR, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  if dmgFrame then
    line('STAGE_W', pcOf(), string.format('%02X -> %02X (손상 뒤)', rb(STAGE), value))
  end
end, emu.callbackType.write, STAGE, STAGE, emu.cpuType.pce, MEM)

-- ⑤ 손상 시각 · STATE 전이
emu.addMemoryCallback(function(address, value)
  local pc = pcOf()
  if value ~= SIG_OK and not dmgFrame and armFrame then
    dmgFrame = frame
    line('DAMAGE', pc, string.format('$5B83 <- %02X.  ★여기가 기준점', value))
  elseif value == SIG_OK and dmgFrame then
    dmgFrame = nil
    line('DAMAGE_UNDONE', pc, '서명이 되살아났다 (재복사)')
  end
end, emu.callbackType.write, SIG_AT, SIG_AT, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  local old = rb(STATE_AT)
  if old ~= value then
    line('STATE', pcOf(), string.format('%02X -> %02X', old, value))
    if value == 0x02 and rb(CD_RAW) == 0x03 and not armFrame then
      armFrame = frame
      line('ARM_T3', nil, '★트랙 3 무장.  여기서부터 elapsed 를 센다')
    end
  end
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

-- 초당 한 줄 -- 진입 횟수와 변수 현재값
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 60 ~= 0 then return end
  local parts = {}
  for _, s in ipairs(SITES) do
    local n = s[2]
    if hit[n] > 0 then parts[#parts + 1] = string.format('%s=%d', n, hit[n]) end
    hit[n] = 0
  end
  local vals = string.format('%s', table.concat(parts, ' '))
  -- 무장 전에는 조용히.  무장 뒤에는 매초 남긴다
  if armFrame then
    line('TICK', nil, (vals ~= '' and vals or '(스케줄러 진입 0)'))
  elseif vals ~= lastVals then
    line('TICK_PRE', nil, vals)
    lastVals = vals
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local t = {}
  for _, s in ipairs(SITES) do t[#t + 1] = string.format('%s=%d', s[2], total[s[2]]) end
  line('TOTALS', nil, table.concat(t, ' '))
  local r = {}
  for pc, n in pairs(readyPc) do r[#r + 1] = string.format('%04X:%d', pc, n) end
  table.sort(r)
  line('READY_WRITERS', nil, table.concat(r, ' '))
  line('SUMMARY', nil, string.format('행 %d · 무장 frame %s · 손상 frame %s',
    rows, tostring(armFrame), tostring(dmgFrame)))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' STATE 굳음 추적 -> ' .. OUT)
