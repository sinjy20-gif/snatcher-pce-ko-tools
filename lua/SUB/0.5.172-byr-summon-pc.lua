-- 국장실 소환을 **누가 · 어느 장면에서** 늦추는가.  0.5.172
--
-- 0.5.171 이 못 한 것 (소유자 2026-09-17 지적)
-- --------------------------------------------
-- ① **세션 비율이 측정 종료 시점에 좌우된다.**
--    같은 주행에서 1.15% -> 0.43% -> 0.16% 가 전부 나온다.  늦음은 장면 앞쪽
--    2,964 프레임에만 몰려 있고 그 뒤로는 정시 표본만 쌓이기 때문이다.
--    그래서 이 판은 **세션 비율을 아예 안 찍는다.**
--
-- ② **장면도 PC 도 안 봤다.**  BYR=96 이면 어디서 쓰였든 다 셌다.
--    실제로 224833/225046 두 주행에서 줄126 한 건이 본 장면보다 7,658 프레임
--    앞, 완전히 따로 떨어진 곳에서 나왔다.  같은 사건인지 알 수 없었다.
--    그래서 이 판은 **쓴 PC 와 MPR 을 같이 적는다.**
--
-- 무엇을 세나 -- 에피소드 단위
-- ----------------------------
--     에피소드   BYR=96 이 이어서 쓰이는 구간 (그림 창이 열려 있는 동안).
--                프레임이 GAP 이상 비면 끊는다.  실측상 창이 열려 있으면
--                **프레임당 정확히 1 건**이므로 표본 수 = 창이 열려 있던 프레임 수다.
--     활성구간   그 에피소드 안에서 첫 늦음 ~ 마지막 늦음.
--                이 길이는 두 주행에서 **둘 다 2,964 프레임**으로 같았다.
--
-- 두 주행 비교 (분모 함정 없이)
-- -----------------------------
--     A 224833  늦음 36 · 활성 2,964f · 중간무리 [44,44,47,48,48,49,49,49,49] · 최악 줄73
--     B 225046  늦음 34 · 활성 2,964f · 중간무리 [44,44,47,48,48,49,49,49,49] · 최악 줄72
--     오프셋 +9,864 프레임으로 34/36 이 **같은 자리에서** 재현.
--
--     -> 무작위 마감 놓침이 아니라 장면 진행에 붙은 **결정론적 사건**이다.
--     -> 2026-09-03 기준판(늦음 33 · 최악 줄72)과 건수·크기가 사실상 같다.
--
-- 무리 나누기 (2026-09-04 문서 기준 그대로)
-- -----------------------------------------
--     줄 33~34    +1~2    렌더러가 한두 줄 미는 것 · 무해
--     줄 35~52    +3~20   ★ 안전밸브 의심 무리
--     줄 53+      +21~    ★★ 천장이 보인다 = 소환
--
-- 쓰는 법
-- -------
--   1) Power Cycle 로 이번 판을 띄운다 (BIOS 와 CUE 둘 다 그 폴더)
--   2) 이 파일 **하나만** 연다
--   3) 국장실 장면을 **처음부터** 지나간다.  늦음은 장면 앞쪽에 몰려 있다
--   4) 에피소드가 끝나면 그 자리에서 요약이 찍힌다
--
-- ⚠ 판을 바꿔 비교할 때는 **같은 세이브 · 같은 지점부터** 돌려야 한다.
--   활성구간 길이와 무리 구성이 비교 단위다.  세션 비율이 아니다.
--
-- 산출물  C:/snatcher/dump/byr_pc_0_5_172_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local BYR_REG = 0x08             -- VDC 레지스터 8 = BYR (세로 스크롤)
local WATCH_VALUE = 96           -- 그림 창 스크롤
local ON_TIME = 32               -- 여기서 쓰여야 정상
local GAP = 120                  -- 이만큼 비면 다른 에피소드 (2 초)
local MID_LO, BIG_LO = 35, 53    -- 무리 경계

local OUT = 'C:/snatcher/dump/byr_pc_0_5_172_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tep\twrite_line\tpc\tmpr7\tmpr5\tband\n') end

-- state 키는 판마다 이름이 다르다.  한 번만 찾아 두고 쓴다
local K_LINE, K_PC
local function probe(s)
  if K_LINE == nil then
    K_LINE = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then K_LINE = k break end
    end
  end
  if K_PC == nil then
    K_PC = false
    for _, k in ipairs({ 'cpu.pc', 'pc', 'cpu.PC' }) do
      if type(s[k]) == 'number' then K_PC = k break end
    end
  end
end

local function sample()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1, -1, -1, -1 end
  probe(s)
  local line = K_LINE and s[K_LINE] or -1
  local pc   = K_PC and s[K_PC] or -1
  local m7 = s['memoryManager.mpr[7]'] or s['mpr[7]'] or -1
  local m5 = s['memoryManager.mpr[5]'] or s['mpr[5]'] or -1
  return math.floor(line or -1), math.floor(pc or -1) & 0xFFFF,
         math.floor(m7 or -1), math.floor(m5 or -1)
end

local selReg, byr = 0, 0
local frame = 0
local lastFrame = -99999
local epNo = 0
local seenAny = false          -- 한 번이라도 BYR=96 을 봤는가
local ep = nil                   -- 지금 에피소드

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

local function report(e, why)
  if not e or e.samples == 0 then return end
  local span = e.last - e.first + 1
  emu.log(string.format(
    '0.5.172 [ep%d %s] 프레임 %d~%d (%d) · 표본 %d · ★늦음 %d '
      .. '(작음 %d · 중간 %d · ★큼 %d) · 최악 줄%d',
    e.no, why, e.first, e.last, span, e.samples, e.late,
    e.small, e.mid, e.big, e.worst))
  if e.late > 0 then
    local win = e.lastLate - e.firstLate + 1
    emu.log(string.format(
      '          활성구간 %d~%d = %d 프레임 · 그 뒤 %d 프레임은 늦음 0',
      e.firstLate, e.lastLate, win, e.last - e.lastLate))
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
    -- 늦게 쓴 PC 는 누구인가.  이것이 "같은 사건인가" 를 가른다
    local pl = {}
    for key, n in pairs(e.pcs) do pl[#pl + 1] = { key = key, n = n } end
    table.sort(pl, function(a, b) return a.n > b.n end)
    local pt = {}
    for i = 1, math.min(#pl, 6) do
      pt[#pt + 1] = string.format('%s x%d', pl[i].key, pl[i].n)
    end
    emu.log('          ★ 늦게 쓴 PC: ' .. table.concat(pt, '  '))
  end
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  if selReg ~= BYR_REG then return end
  if port == 2 then byr = (byr & 0xFF00) | value return end
  if port ~= 3 then return end
  byr = (byr & 0x00FF) | (value << 8)
  if (byr & 0x01FF) ~= WATCH_VALUE then return end

  local line, pc, m7, m5 = sample()
  if line < 0 then return end

  if ep == nil or (frame - lastFrame) >= GAP then
    report(ep, '끝')
    ep = newEp(frame)
  end
  lastFrame = frame
  seenAny = true
  ep.last = frame
  ep.samples = ep.samples + 1

  local band = bandOf(line)
  if band ~= 'ok' then
    ep.late = ep.late + 1
    if ep.firstLate < 0 then ep.firstLate = frame end
    ep.lastLate = frame
    if line > ep.worst then ep.worst = line end
    ep.hist[line] = (ep.hist[line] or 0) + 1
    if band == 'small' then
      ep.small = ep.small + 1
    elseif band == 'mid' then
      ep.mid = ep.mid + 1
      ep.midList[#ep.midList + 1] = tostring(line)
    else
      ep.big = ep.big + 1
      ep.bigList[#ep.bigList + 1] = tostring(line)
    end
    -- ★ CPU $E000-$FFFF 는 뱅크가 둘이다 (MPR7 $00 원본 / $01 우리).
    --   주소만 적으면 누구 코드인지 못 가른다
    local key
    if pc >= 0xE000 then
      key = string.format('$%04X/m7=%02X', pc, m7 & 0xFF)
    else
      key = string.format('$%04X', pc)
    end
    ep.pcs[key] = (ep.pcs[key] or 0) + 1
  end

  if out then
    out:write(string.format('%d\t%d\t%d\t%04X\t%02X\t%02X\t%s\n',
                            frame, ep.no, line, pc, m7 & 0xFF, m5 & 0xFF, band))
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 ~= 0 then return end
  if out then out:flush() end
  if ep == nil then
    -- ⚠ 에피소드가 **끝난 뒤**에도 여기로 온다.  그때는 표본이 없는 게 아니라
    --   이미 위에서 [ep N 끝] 로 보고한 것이다.  문구를 갈라 둔다
    if seenAny then
      emu.log(string.format('0.5.172 %df · 에피소드 %d 개 보고 끝 · 지금은 창이 닫혀 있다',
                            frame, epNo))
    else
      emu.log(string.format('0.5.172 %df · 아직 BYR=%d 를 한 번도 안 봤다 -- 판정 불가',
                            frame, WATCH_VALUE))
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

emu.log('SUB 0.5.172-byr-summon-pc  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log('  0.5.171 과 달리 **세션 비율을 안 찍는다** -- 그 숫자는 언제 끊느냐로 바뀐다')
emu.log('  대신 에피소드마다: 늦음 건수 · 무리 구성 · 활성구간 · ★늦게 쓴 PC')
emu.log('  원본 BIOS 대조군: 줄 32 가 100.00% · 예외 0 (2026-09-03)')
emu.log('  비교 기준 A/B(2026-09-16): 늦음 36/34 · 활성 2,964f · 최악 줄73/72')
emu.log('  -> ' .. OUT)
