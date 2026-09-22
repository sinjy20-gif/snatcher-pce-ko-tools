-- 국장실 소환 + **누가 썼나**.  0.5.173
--
-- 왜 또 만드나 -- 0.5.172 가 한 줄도 안 남겼다
-- --------------------------------------------
-- 0.5.172 는 헤더만 쓰고 표본 0 이었다.  필터와 등록 인자는 0.5.171 과 **글자까지
-- 같은데** 안 찍혔다.  눈으로 대조해도 터질 자리가 안 보였다.
--
-- 그런데 그때 알 수 없던 것이 또 있다: **그 장면에 갔는지 여부**.  50 초만 돌렸으면
-- 타이틀에 있었어도 표본 0 이 맞다.  "프로브 고장" 과 "아직 안 감" 을 **구분할 수가
-- 없었다.**  그래서 이 판은 **단계마다 센다.**
--
--     port3      VDC 포트 3 쓰기 (레지스터 하위 상관없이)
--     reg8       그중 레지스터 선택이 BYR(8) 인 것
--     byr96      그중 값이 96 인 것          <- 0 이면 **그 장면에 안 간 것**
--     line_ok    스캔라인을 읽은 것          <- byr96 은 있는데 0 이면 ★ 프로브 잘못
--     기록       TSV 에 실제로 쓴 줄 수
--
-- ★ 설계 원칙: **0.5.171 의 동작부는 글자 그대로 둔다.**
--   증명된 `scanline()` 을 그대로 쓰고, PC/MPR 은 **따로 · 실패해도 표본을 안 버리게**
--   읽는다.  0.5.172 는 PC 읽기를 표본 경로 안에 넣어서, 그게 죽으면 소환 자료까지
--   통째로 날아가는 구조였다.  그 구조를 다시 쓰지 않는다.
--
-- 무엇을 세나 -- 에피소드 단위 (0.5.172 와 같음)
-- ----------------------------------------------
-- 세션 비율은 **안 찍는다**.  그 숫자는 측정을 언제 끊느냐로 3 배 움직인다
-- (같은 주행이 1.15% / 0.43% / 0.16% 를 전부 낸다 -- 소유자 2026-09-17).
-- 비교 단위는 **에피소드 1 회당 늦음 건수 · 무리 구성 · 활성구간 · 최악 줄**이다.
--
--     A 224833  늦음 36 · 활성 2,964f · 중간무리 44,44,47,48,48,49,49,49,49 · 최악 줄73
--     B 225046  늦음 34 · 활성 2,964f · 중간무리 44,44,47,48,48,49,49,49,49 · 최악 줄72
--     09-03 기준 늦음 33 ·                                                    최악 줄72
--
-- 무리 나누기 (2026-09-04 문서 기준 그대로)
--     줄 33~34  +1~2   렌더러가 한두 줄 미는 것 · 무해
--     줄 35~52  +3~20  ★ 안전밸브 의심
--     줄 53+    +21~   ★★ 천장이 보인다 = 소환
--
-- 쓰는 법
-- -------
--   1) Power Cycle 로 이번 판을 띄운다 (BIOS 와 CUE 둘 다 그 폴더)
--   2) 이 파일 **하나만** 연다
--   3) 600 프레임마다 단계 카운터가 찍힌다.  **byr96 이 0 이면 아직 그 장면이 아니다**
--   4) 국장실 장면을 지나간다.  늦음은 장면 앞쪽에 몰려 있다
--
-- 산출물  C:/snatcher/dump/byr_pc_0_5_173_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local BYR_REG = 0x08             -- VDC 레지스터 8 = BYR (세로 스크롤)
local WATCH_VALUE = 96           -- 그림 창 스크롤
local ON_TIME = 32               -- 여기서 쓰여야 정상
local GAP = 120                  -- 이만큼 비면 다른 에피소드 (2 초)
local MID_LO, BIG_LO = 35, 53    -- 무리 경계

local OUT = 'C:/snatcher/dump/byr_pc_0_5_173_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tep\twrite_line\tpc\tmpr7\tmpr5\tband\n') end

-- ★ 0.5.171 에서 **글자 그대로** 가져온 것.  이 부분은 손대지 않는다
local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- PC/MPR 은 **곁가지**다.  실패해도 -1 을 주고 표본은 그대로 남긴다
local PC_KEY
local function extras()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1, -1, -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc', 'cpu.PC' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  local pc = -1
  if PC_KEY ~= false then
    local v = s[PC_KEY]
    if type(v) == 'number' then pc = math.floor(v) end
  end
  local m7 = s['memoryManager.mpr[7]']
  if type(m7) ~= 'number' then m7 = s['mpr[7]'] end
  if type(m7) ~= 'number' then m7 = -1 else m7 = math.floor(m7) end
  local m5 = s['memoryManager.mpr[5]']
  if type(m5) ~= 'number' then m5 = s['mpr[5]'] end
  if type(m5) ~= 'number' then m5 = -1 else m5 = math.floor(m5) end
  return pc, m7, m5
end

local selReg, byr = 0, 0
local frame = 0
local lastFrame = -99999
local epNo = 0
local seenAny = false
local ep = nil

-- ★ 단계 카운터.  "고장" 과 "아직 안 감" 을 가르는 것이 이 다섯 줄이다
local c_port3, c_reg8, c_byr96, c_lineok, c_written = 0, 0, 0, 0, 0

local function newEp(at)
  epNo = epNo + 1
  return { no = epNo, first = at, last = at, samples = 0,
           late = 0, small = 0, mid = 0, big = 0,
           firstLate = -1, lastLate = -1, worst = -1,
           hist = {}, pcs = {}, midList = {}, bigList = {} }
end

local function bandOf(line)
  if line <= ON_TIME then return 'ok' end
  if line < MID_LO then return 'small' end
  if line < BIG_LO then return 'mid' end
  return 'BIG'
end

local function hex4(v)
  if v < 0 then return '----' end
  return string.format('%04X', v & 0xFFFF)
end

local function hex2(v)
  if v < 0 then return '--' end
  return string.format('%02X', v & 0xFF)
end

local function report(e, why)
  if not e or e.samples == 0 then return end
  emu.log(string.format(
    '0.5.173 [ep%d %s] 프레임 %d~%d (%d) · 표본 %d · ★늦음 %d '
      .. '(작음 %d · 중간 %d · ★큼 %d) · 최악 줄%d',
    e.no, why, e.first, e.last, e.last - e.first + 1, e.samples, e.late,
    e.small, e.mid, e.big, e.worst))
  if e.late == 0 then return end
  emu.log(string.format(
    '          활성구간 %d~%d = %d 프레임 · 그 뒤 %d 프레임은 늦음 0',
    e.firstLate, e.lastLate, e.lastLate - e.firstLate + 1, e.last - e.lastLate))
  local parts = {}
  for line, n in pairs(e.hist) do
    parts[#parts + 1] = { line = line, txt = string.format('줄%d x%d', line, n) }
  end
  table.sort(parts, function(a, b) return a.line < b.line end)
  local t = {}
  for _, p in ipairs(parts) do t[#t + 1] = p.txt end
  emu.log('          분포: ' .. table.concat(t, ' '))
  emu.log('          중간무리 ' .. table.concat(e.midList, ',')
          .. '   ★큼무리 ' .. table.concat(e.bigList, ','))
  local pl = {}
  for key, n in pairs(e.pcs) do pl[#pl + 1] = { key = key, n = n } end
  table.sort(pl, function(a, b) return a.n > b.n end)
  local pt = {}
  for i = 1, math.min(#pl, 6) do
    pt[#pt + 1] = string.format('%s x%d', pl[i].key, pl[i].n)
  end
  if #pt > 0 then emu.log('          ★ 늦게 쓴 PC: ' .. table.concat(pt, '  ')) end
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  -- ★ port3 은 **레지스터 상관없이** 센다.  이게 0 이면 콜백 자체가 안 도는 것이고,
  --   그건 "장면에 안 갔다" 와 전혀 다른 진단이다
  if port == 3 then c_port3 = c_port3 + 1 end
  if selReg ~= BYR_REG then return end
  if port == 2 then
    byr = (byr & 0xFF00) | value
    return
  end
  if port ~= 3 then return end
  c_reg8 = c_reg8 + 1
  byr = (byr & 0x00FF) | (value << 8)
  if (byr & 0x01FF) ~= WATCH_VALUE then return end
  c_byr96 = c_byr96 + 1
  local at = scanline()
  if at < 0 then return end
  c_lineok = c_lineok + 1

  -- ★ 여기서부터가 0.5.172 에서 새로 넣은 부분.  터지면 표본이 통째로 날아가므로
  --   pcall 로 싸고, 실패해도 소환 기록은 남긴다
  local okx, pc, m7, m5 = pcall(extras)
  if not okx then pc, m7, m5 = -1, -1, -1 end

  if ep == nil or (frame - lastFrame) >= GAP then
    report(ep, '끝')
    ep = newEp(frame)
  end
  lastFrame = frame
  seenAny = true
  ep.last = frame
  ep.samples = ep.samples + 1

  local band = bandOf(at)
  if band ~= 'ok' then
    ep.late = ep.late + 1
    if ep.firstLate < 0 then ep.firstLate = frame end
    ep.lastLate = frame
    if at > ep.worst then ep.worst = at end
    ep.hist[at] = (ep.hist[at] or 0) + 1
    if band == 'small' then
      ep.small = ep.small + 1
    elseif band == 'mid' then
      ep.mid = ep.mid + 1
      ep.midList[#ep.midList + 1] = tostring(at)
    else
      ep.big = ep.big + 1
      ep.bigList[#ep.bigList + 1] = tostring(at)
    end
    -- ★ CPU $E000-$FFFF 는 뱅크가 둘이다 (MPR7 $00 원본 / $01 우리).
    --   주소만 적으면 누구 코드인지 못 가른다
    local key = hex4(pc)
    if pc >= 0xE000 then key = key .. '/m7=' .. hex2(m7) end
    ep.pcs[key] = (ep.pcs[key] or 0) + 1
  end

  if out then
    out:write(string.format('%d\t%d\t%d\t%s\t%s\t%s\t%s\n',
                            frame, ep.no, at, hex4(pc), hex2(m7), hex2(m5), band))
    c_written = c_written + 1
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 ~= 0 then return end
  if out then out:flush() end
  -- ★ 단계 카운터는 **항상** 찍는다.  0 이어도 찍어야 어디서 죽었는지 보인다
  emu.log(string.format(
    '0.5.173 %df · port3 %d · reg8 %d · byr96 %d · line_ok %d · 기록 %d',
    frame, c_port3, c_reg8, c_byr96, c_lineok, c_written))
  if c_port3 == 0 then
    emu.log('          -> ★★ port3 0 = 콜백이 아예 안 돈다 (장면 문제가 아니다)')
  elseif c_byr96 == 0 then
    emu.log('          -> byr96 0 = **아직 그 장면이 아니다** (프로브 문제 아님)')
  elseif c_written == 0 then
    emu.log('          -> ★ byr96 은 있는데 기록 0 = **프로브 잘못이다**')
  end
  if ep == nil then
    if seenAny then
      emu.log(string.format('          에피소드 %d 개 보고 끝 · 지금은 창이 닫혀 있다', epNo))
    end
    return
  end
  if (frame - lastFrame) >= GAP then
    report(ep, '끝')
    ep = nil
    return
  end
  report(ep, '진행중')
end, emu.eventType.endFrame)

emu.log('SUB 0.5.173-byr-summon-pc  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log('  0.5.172 가 표본 0 이었다 -- 이 판은 **단계마다 센다**')
emu.log('    byr96 0        -> 아직 그 장면이 아니다 (프로브 문제 아님)')
emu.log('    byr96 >0 · 기록 0 -> ★ 프로브 잘못')
emu.log('  세션 비율은 안 찍는다.  비교 단위는 에피소드당 건수 · 무리 · 활성구간')
emu.log('  원본 BIOS 대조군: 줄 32 가 100.00% · 예외 0 (2026-09-03)')
emu.log('  -> ' .. OUT)
