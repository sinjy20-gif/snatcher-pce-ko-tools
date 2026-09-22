-- 국장실 소환 -- **우리 arm 인가 게임 부하인가**.  0.5.175
--
-- ★★ 0.5.175 를 버린 이유 -- 뱅크 검사가 거꾸로였다
-- ---------------------------------------------------
-- 0.5.175 는 `MPR7 == $01` 일 때만 우리 게이트로 셌다.  결과가 **게이트(우리) 0 ·
-- (원본뱅크) 2,869** 였고 늦음 32 건이 전부 `g-` 로 찍혔다.  그건 "게이트가 안 돌았다"
-- 가 아니라 **필터가 전부 튕겨냈다**는 뜻이었다.  그 주행의 소득은 0 이다.
--
--     `$FEC4` 는 **BIOS 케이브**다.  원본 BIOS 에서는 `$FF` 채움이라 아무도 실행하지
--     않는 자리고, 거기에 우리 판정 루틴을 심었다 (CAVE_BYTES 280 · all FF).
--     BIOS 는 MPR7 뱅크 **$00** 으로 매핑된다 -> 우리 게이트도 $00 에서 돈다.
--     `tools/audit_bios_free_space.py` 가 못박아 뒀다: ("케이브 $FEC4", **0**, ...)
--     바로 아랫줄의 뱅크1 항목($F370 · $F760)과 대조된다.
--     그리고 이 측정을 위해 만든 `0.5.170` 은 게이트에 **뱅크 검사를 안 걸었다.**
--
-- 그래서 이 판은 **거르지 않고 적는다.**  MPR7 분포를 로그에 찍어서 내가 단정하는
-- 대신 로그가 증명하게 한다.  원본 BIOS 에서 $FEC4 는 실행될 수 없으므로, 거기서
-- 도는 것은 무엇이든 우리 코드다.
--
--
-- 0.5.175 이 답한 것 / 못 답한 것
-- -------------------------------
-- 답했다:
--   * 정시 쓰기는 "대략 줄32" 가 아니라 **정확히 줄32 하나**다 (9,728+2,420 건 종류 1).
--     원본 BIOS 대조군과 같다 -- 평소엔 완벽하고 **33 번만 튄다**.  분포가 아니라 사건이다.
--   * 쓰는 PC 는 `$4411` **하나뿐**이다.  정시도 늦음도 같은 곳.
--     늦을 때 다른 코드가 쓰는 게 아니라 게임 루틴이 **밀리는** 것이다 -- 피해자다.
--   * ★큼 사건 8 건 **전부** 직후 2 프레임이 희귀 뱅크($70 18건 / $6F 9건 중 16건)다.
--   * 늦음 33 건 전부 MPR5=$74 프레임.  $6C 9,728 건은 늦음 0.
--
-- 못 답했다:
--   ★ **그 8 건이 우리 arm 때문인가, 게임 부하인가.**
--     2026-09-04 문서는 이것을 `gate` 로 갈랐다:
--         gate=22~24 · engine=-   ★ 우리 몫 (안전밸브 의심)
--         gate=-     · engine=-   ★ 우리 게 아니다 (게임 부하) · 그때 5 건
--     "완벽히 고쳐도 gate=- 무리는 남는다" 고 적혀 있다.  지금 8 건이 어느 쪽인지
--     모르면 고칠 대상의 크기조차 모른다.
--
-- 그래서 이 판이 더하는 것 = **게이트 `$FEC4` 진입 줄**
-- -------------------------------------------------
-- 프레임마다 게이트가 몇 줄에서 들어왔는지 적고, BYR 이 늦은 프레임에 그 값을 붙인다.
--
--     gate=13~25   정상 진입.  그런데 BYR 이 늦었다면 게이트 작업이 줄32 를 **넘겨** 덮은 것
--     gate=30~80   ★ 게이트 자체가 늦게 들어왔다
--     gate=-       ★★ 그 프레임에 게이트가 **안 돌았다** = 우리 것이 아니다
--
-- ⚠ CPU $E000-$FFFF 는 뱅크가 둘이다 (MPR7 $00 원본 / $01 우리).
--   `$FEC4` 도 그 창이므로 **MPR7==$01 일 때만** 우리 게이트로 센다.
--   이 검사를 빼면 원본 BIOS 코드를 우리 것으로 세게 된다.
--
-- ★ 0.5.175 의 동작부는 **글자 그대로** 둔다.  그 판은 돌아가는 것이 확인됐다.
--   (0.5.172 는 PC 읽기를 표본 경로 **안**에 넣어서 그게 죽자 자료가 통째로 날아갔다.
--    같은 실수를 반복하지 않는다 -- 게이트도 곁가지로 붙이고 pcall 로 싼다.)
--
-- 세션 비율은 **안 찍는다**.  그 숫자는 측정을 언제 끊느냐로 3 배 움직인다.
-- 비교 단위는 에피소드 1 회당 늦음 건수 · 무리 구성 · 활성구간 · 최악 줄이다.
--
--     A 224833  늦음 36 (작음 18 · 중간 9 · ★큼 9) · 최악 줄73
--     B 225046  늦음 34 (작음 16 · 중간 9 · ★큼 9) · 최악 줄72
--     C 194158  늦음 33 (작음 16 · 중간 9 · ★큼 8) · 최악 줄73
--     09-03 기준 늦음 33                             · 최악 줄72
--
-- 쓰는 법
-- -------
--   1) Power Cycle 로 이번 판을 띄운다 (BIOS 와 CUE 둘 다 그 폴더)
--   2) 이 파일 **하나만** 연다
--   3) 국장실 장면을 지나간다.  ★큼 사건은 대략 19 초에 한 번꼴이다
--   4) 600 프레임마다 요약.  **`큼무리` 옆의 `gate=` 값이 이번 판의 소득이다**
--
-- 산출물  C:/snatcher/dump/byr_gate_0_5_175_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local BYR_REG = 0x08             -- VDC 레지스터 8 = BYR (세로 스크롤)
local WATCH_VALUE = 96           -- 그림 창 스크롤
local ON_TIME = 32               -- 여기서 쓰여야 정상
local GAP = 120                  -- 이만큼 비면 다른 에피소드 (2 초)
local MID_LO, BIG_LO = 35, 53    -- 무리 경계
local GATE = 0xFEC4              -- 우리 게이트 (BIOS 케이브 · 원본에선 $FF 채움)
-- ⚠ 뱅크로 **거르지 않는다**.  0.5.174 가 $01 로 걸러 전부 버렸다.
--   대신 본 뱅크를 세어서 로그에 찍는다 -- 실제 값이 무엇인지 자료로 남긴다

local OUT = 'C:/snatcher/dump/byr_gate_0_5_175_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
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
local gateLine = -1              -- 이번 프레임 게이트 진입 줄 (-1 = 안 들어옴)
local c_gate = 0
local gate_banks = {}            -- 게이트가 돈 순간의 MPR7 분포

-- ★ 단계 카운터.  "고장" 과 "아직 안 감" 을 가르는 것이 이 다섯 줄이다
local c_port3, c_reg8, c_byr96, c_lineok, c_written = 0, 0, 0, 0, 0

local function newEp(at)
  epNo = epNo + 1
  return { no = epNo, first = at, last = at, samples = 0,
           late = 0, small = 0, mid = 0, big = 0,
           firstLate = -1, lastLate = -1, worst = -1,
           hist = {}, pcs = {}, midList = {}, bigList = {},
           gate_ran = 0, gate_none = 0 }
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
    '0.5.175 [ep%d %s] 프레임 %d~%d (%d) · 표본 %d · ★늦음 %d '
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
  emu.log(string.format(
    '          ★ 늦은 프레임 중 우리 게이트가 **돈** 것 %d · **안 돈** 것 %d'
      .. '   (안 돈 것은 우리 몫이 아니다)', e.gate_ran, e.gate_none))
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
    -- ★ 이번 판의 소득: 그 프레임에 **우리 게이트가 돌았는가 · 몇 줄에서**
    local g = gateLine >= 0 and ('g' .. gateLine) or 'g-'
    if gateLine >= 0 then ep.gate_ran = ep.gate_ran + 1
    else ep.gate_none = ep.gate_none + 1 end
    if band == 'small' then
      ep.small = ep.small + 1
    elseif band == 'mid' then
      ep.mid = ep.mid + 1
      ep.midList[#ep.midList + 1] = at .. '(' .. g .. ')'
    else
      ep.big = ep.big + 1
      ep.bigList[#ep.bigList + 1] = at .. '(' .. g .. ')'
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

-- ★ 게이트는 **곁가지**다.  여기서 터져도 BYR 기록은 안 죽는다 (0.5.172 의 교훈)
emu.addMemoryCallback(function()
  local ok, s2 = pcall(emu.getState)
  if not ok or type(s2) ~= 'table' then return end
  local m7 = s2['memoryManager.mpr[7]']
  if type(m7) ~= 'number' then m7 = s2['mpr[7]'] end
  local key = type(m7) == 'number' and string.format('$%02X', math.floor(m7) & 0xFF) or '??'
  gate_banks[key] = (gate_banks[key] or 0) + 1
  c_gate = c_gate + 1
  local at = scanline()
  if at >= 0 then gateLine = at end
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  gateLine = -1                  -- ★ 프레임마다 비운다.  게이트는 줄 13~25 에 들어오므로
                                 --   같은 프레임의 BYR 쓰기(줄32) 보다 먼저다
  if frame % 600 ~= 0 then return end
  if out then out:flush() end
  -- ★ 단계 카운터는 **항상** 찍는다.  0 이어도 찍어야 어디서 죽었는지 보인다
  emu.log(string.format(
    '0.5.175 %df · port3 %d · reg8 %d · byr96 %d · 기록 %d · 게이트 %d',
    frame, c_port3, c_reg8, c_byr96, c_written, c_gate))
  do
    local bt = {}
    for k, n in pairs(gate_banks) do bt[#bt + 1] = string.format('MPR7=%s x%d', k, n) end
    table.sort(bt)
    emu.log('          게이트가 돈 뱅크: ' .. (#bt > 0 and table.concat(bt, ' ') or '(아직 없음)')
            .. '   ← 거르지 않고 **센** 값이다')
  end
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

emu.log('SUB 0.5.175-byr-summon-pc  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log('  0.5.172 가 표본 0 이었다 -- 이 판은 **단계마다 센다**')
emu.log('    byr96 0        -> 아직 그 장면이 아니다 (프로브 문제 아님)')
emu.log('    byr96 >0 · 기록 0 -> ★ 프로브 잘못')
emu.log('  ★★ 0.5.174 는 MPR7==$01 로 걸러 게이트를 전부 버렸다 -- 이 판은 **안 거른다**')
emu.log('     $FEC4 는 BIOS 케이브($FF 채움)라 거기서 도는 것은 무엇이든 우리 코드다')
emu.log('  ★ 이번 판의 소득: 늦은 프레임에 **우리 게이트가 돌았는가** (g22 / g- )')
emu.log('      g-  = 그 프레임에 게이트가 안 돌았다 -> 우리 몫이 아니다 (게임 부하)')
emu.log('      g22 = 돌았다 -> 게이트 작업이 줄32 를 덮은 것 -> ★ 우리가 고칠 것')
emu.log('  세션 비율은 안 찍는다.  비교 단위는 에피소드당 건수 · 무리 · 활성구간')
emu.log('  원본 BIOS 대조군: 줄 32 가 100.00% · 예외 0 (2026-09-03)')
emu.log('  -> ' .. OUT)
