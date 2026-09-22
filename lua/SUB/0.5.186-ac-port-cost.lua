-- SUB 0.5.186 -- $1A00 Arcade Card 포트를 우리가 얼마나·어디서 쓰는가
--
-- ★순수 관측 · 쓰기 0 B
--
-- 왜 이걸 재나 -- 소유자가 Event Viewer 에서 찾아냈다 (2026-09-08)
-- ---------------------------------------------------------------------------
-- 폐공장에서 UI 를 부르면 `$1A00` **Register (R)** 이 줄 100~101 에 무더기로
-- 찍힌다.  PC 는 $BCD7 · $BCDE · $BCE5 · $BD86 · $BD8C · $BD92 · $BD98 ·
-- $BDAE · $BE2D ...  화면 중앙 활성 표시 구간이다.
--
-- ★★ 이게 왜 결정적인가
--     Snatcher 는 Super CD-ROM² 타이틀이고 **게임 코드에 AC 의 존재가 없다.**
--     실측으로 확인돼 있다 -- 3 분/90 회, `$1A00-$1AFF` 포트 접근 **0 회**
--     (memory: arcade_card_2mb_available).
--     따라서 저기 찍히는 접근은 **전부 우리 것이다.**  예외가 없다.
--
-- 그리고 소유자 관측과 정확히 맞는다
--     "원래는 이 정도가 아니었는데 자막 넣고 심해졌다"   <- AC 는 우리가 들여왔다
--     "여기저기 다 흔들린다"                            <- UI/대사 어디서나 쓴다
--     "대사 출력 후 다시 UI 부를 때 이만큼 쓰고"        <- 부를 때마다 또 쓴다
--
-- 소유자 가설 -- 이 판이 재려는 것
--     "UI 가 이동 때마다 처음부터 다시 그려지는 걸까?  커서 1 칸 올라가면 다시?"
--
--     매 프레임 쓴다        -> 상시 부하.  vblank 로 옮기거나 캐시해야 한다
--     이동할 때만 폭발한다  -> ★전체 재그리기.  바뀐 줄만 그리면 대부분 사라진다
--
-- 무엇을 남기나
-- ---------------------------------------------------------------------------
--   프레임마다   접근 수(읽기/쓰기) · 표본으로 뜬 스캔라인 분포 · PC 상위
--   60 프레임마다 한 줄 요약
--   활성/블랭크 구분이 핵심이다.  블랭크에서 쓰면 공짜에 가깝고,
--   활성 표시 구간에서 쓰면 그 줄의 래스터 분할 IRQ 를 밀어낸다.
--
-- ⚠ 접근이 프레임당 수천이면 전수로 PC/스캔라인을 뜨면 에뮬이 기어간다.
--   그래서 **개수는 전수로 세고, PC·스캔라인은 프레임당 SAMPLE 개만** 뜬다.
--
-- 쓰는 법
--   1) 이것만 로드하고 정상 속도로 논다
--   2) 메뉴를 띄운 채 **가만히 둔다** (5 초)      -> 상시 부하가 있나
--   3) 커서를 한 칸씩 천천히 올린다/내린다        -> 이동마다 터지나
--   4) 대사 한 번 태우고 다시 UI 를 부른다        -> 호출마다 터지나
--   각 구간에서 R 키를 눌러 표식을 남기면 나중에 구간을 가를 수 있다
--
-- 산출물  C:/snatcher/dump/acport_0_5_186_<시각>_frames.tsv   프레임별
--         C:/snatcher/dump/acport_0_5_186_<시각>_pc.tsv       PC 별 합계
--         C:/snatcher/dump/acport_0_5_186_<시각>_lines.tsv    스캔라인별 합계

local SAMPLE   = 48      -- 프레임당 PC/스캔라인을 뜰 최대 접근 수
local REPORT   = 60      -- 이만큼마다 화면 요약
local VBLANK   = 240     -- 이 줄 이상이면 블랭크로 본다 (PCE 는 대략 242~262)

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/acport_0_5_186_' .. STAMP

local fout = assert(io.open(BASE .. '_frames.tsv', 'w'))
fout:write('frame\tmark\trd\twr\ttotal\tsmp\tactive\tblank\tmin_line\tmax_line\ttop_pc\n')
fout:flush()

local function say(m) emu.log(m); print(m) end

local LINE_KEY, PC_KEY
local function state()
  local ok, s = pcall(emu.getState)
  return (ok and type(s) == 'table') and s or nil
end
local function pick(s, keys, cache)
  if cache == nil then
    for _, k in ipairs(keys) do if type(s[k]) == 'number' then return k end end
    return false
  end
  return cache
end
local function lineOf(s)
  if LINE_KEY == nil then
    LINE_KEY = pick(s, {'vdc.scanline','scanline','vdc.vCounter','ppu.scanline'}, nil)
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end
local function pcOf(s)
  if PC_KEY == nil then
    PC_KEY = pick(s, {'cpu.pc','cpu.programCounter','pc','cpu.PC'}, nil)
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and (math.floor(v) & 0xFFFF) or -1
end

-- 프레임 누적
local rd, wr, smp, act, blk = 0, 0, 0, 0, 0
local minL, maxL = 9999, -1
local framePc = {}

-- 전체 누적
local totPc, totLine = {}, {}
local frame, gRd, gWr = 0, 0, 0

local function tally(isWrite)
  if isWrite then wr = wr + 1 else rd = rd + 1 end
  if smp >= SAMPLE then return end
  local s = state()
  if not s then return end
  smp = smp + 1
  local ln, pc = lineOf(s), pcOf(s)
  if ln >= 0 then
    if ln >= VBLANK then blk = blk + 1 else act = act + 1 end
    if ln < minL then minL = ln end
    if ln > maxL then maxL = ln end
    totLine[ln] = (totLine[ln] or 0) + 1
  end
  if pc >= 0 then
    framePc[pc] = (framePc[pc] or 0) + 1
    totPc[pc] = (totPc[pc] or 0) + 1
  end
end

emu.addMemoryCallback(function() tally(false) end,
  emu.callbackType.read, 0x1A00, 0x1AFF, CPU, MEM)
emu.addMemoryCallback(function() tally(true) end,
  emu.callbackType.write, 0x1A00, 0x1AFF, CPU, MEM)

-- R 키 = 구간 표식
local KEY = nil
for _, n in ipairs({ 'R', 'r', 'KeyR' }) do
  local ok, v = pcall(function() return emu.isKeyPressed(n) end)
  if ok and type(v) == 'boolean' then KEY = n break end
end
local held, marks = false, 0

emu.addEventCallback(function()
  frame = frame + 1

  local down = false
  if KEY then down = (emu.isKeyPressed(KEY) == true) end
  local mark = (down and not held) and 1 or 0
  held = down
  if mark == 1 then marks = marks + 1; say(('  ── 표식 #%d  f%d'):format(marks, frame)) end

  local total = rd + wr
  if total > 0 or mark == 1 then
    local topPc, topN = -1, 0
    for p, c in pairs(framePc) do if c > topN then topPc, topN = p, c end end
    fout:write(('%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n'):format(
      frame, mark, rd, wr, total, smp, act, blk,
      (minL == 9999) and -1 or minL, maxL,
      (topPc >= 0) and ('$%04X x%d'):format(topPc, topN) or ''))
    fout:flush()
  end

  gRd, gWr = gRd + rd, gWr + wr
  rd, wr, smp, act, blk = 0, 0, 0, 0, 0
  minL, maxL, framePc = 9999, -1, {}

  if frame % REPORT == 0 and (gRd + gWr) > 0 then
    say(('f%d  누적 읽기 %d · 쓰기 %d  (프레임당 평균 %.1f)')
        :format(frame, gRd, gWr, (gRd + gWr) / frame))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  fout:close()

  local pf = assert(io.open(BASE .. '_pc.tsv', 'w'))
  pf:write('pc\tcount\n')
  local rows = {}
  for p, c in pairs(totPc) do rows[#rows+1] = { p = p, c = c } end
  table.sort(rows, function(a, b) return a.c > b.c end)
  for _, r in ipairs(rows) do pf:write(('$%04X\t%d\n'):format(r.p, r.c)) end
  pf:close()

  local lf = assert(io.open(BASE .. '_lines.tsv', 'w'))
  lf:write('scanline\tcount\n')
  local ls = {}
  for l in pairs(totLine) do ls[#ls+1] = l end
  table.sort(ls)
  for _, l in ipairs(ls) do lf:write(('%d\t%d\n'):format(l, totLine[l])) end
  lf:close()

  say(('== 끝 · 프레임 %d · 읽기 %d · 쓰기 %d · 표식 %d =='):format(frame, gRd, gWr, marks))
  say('  ' .. BASE .. '_frames.tsv / _pc.tsv / _lines.tsv')
  for i = 1, math.min(#rows, 8) do
    say(('   PC $%04X  %d 회'):format(rows[i].p, rows[i].c))
  end
end, emu.eventType.scriptEnded)

say('SUB 0.5.186-ac-port-cost armed -- $1A00-$1AFF 전수 계수 · 쓰기 0 B')
say('  ★ 게임은 AC 를 안 쓴다 (실측 0 회).  여기 찍히는 건 전부 우리 것이다')
say('  1) 메뉴 띄운 채 가만히 5 초   2) 커서 한 칸씩   3) 대사 뒤 UI 재호출')
if KEY then say(('  %s = 구간 표식'):format(KEY)) else say('  ⚠ R 키 인식 실패 (표식만 못 씀)') end
say('  ' .. BASE .. '_frames.tsv')
