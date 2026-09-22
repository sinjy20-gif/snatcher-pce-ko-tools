-- SUB 0.5.21 -- SEI 창을 구간별로 쪼개 어디가 시간을 먹는지 본다 (쓰기 0 B)
--
-- 여기까지 (§7-G)
-- ---------------------------------------------------------------------------
--     RCR=135 이 쓰이는 줄  =  창이 닫히는 줄 + 1     표본 18, 예외 0
--     RCR 은 비교 레지스터가 하나뿐 -> 분할은 반드시 연쇄.  미리 예약 불가
--     목표 숫자: **창 < 113 줄** (창 시작 22, 분할선 135)
--
-- 실측된 창 폭
--     idle           0~1 줄      안전
--     조각 렌더      63~95 줄    안전
--     음성 시작     120 줄       135 놓침
--     음성 끝/무자막 171~174 줄  135 · 148 둘 다 놓침
--
-- ★ 모순 -- 이것이 이 판이 묻는 것
-- ---------------------------------------------------------------------------
-- 0.5.17 이 복사 두 개(448+671 B)를 Lua 로 걷어냈는데 **증상이 남았다.**
-- 복사가 창의 주된 무게였다면 그때 113 줄 아래로 떨어져 나았어야 한다.
--     -> 창을 채우는 것은 복사가 아니다.  무엇인가?
--
-- 그리고 **자막이 없는 프레임**(매직 검사에서 바로 탈출)이 171 줄이다.
-- 그 경로는 이것뿐이다:
--     $7F4F JSR $FEC4  ·  $7F58 select_helper  ·  $7F5B copy_helper 448 B
--     $7F5E 매직 검사 실패 -> $7F85 탈출
-- 448 B 루프로는 171 줄이 안 나온다 (바이트당 174 사이클).
--     -> 무언가 **기다리고 있다.**  유력 후보는 JSR $FEC4
--
-- 이 답이 수정 방향을 가른다
--     창이 "일" 로 차 있으면    렌더를 프레임에 걸쳐 쪼갠다      (비쌈)
--     창이 "대기" 로 차 있으면  대기를 SEI 밖으로 뺀다           (쌈)
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- 상주부의 각 지점을 지날 때의 스캔라인을 찍어 **구간별 줄 수**를 낸다.
-- 프레임 경계를 넘는 창이 있으므로 되감김(+262)을 보정한다.
--
-- 읽는 법
--     BIOS 가 크면        JSR $FEC4 를 SEI 밖으로 빼는 것이 1 순위
--     copy 가 크면        0.5.17 결과와 모순 -> 둘 중 하나가 틀렸다.  재검
--     render 가 크면      렌더 분할이 필요하다.  §6 로는 부족
--
-- ★ 어느 구간도 안 잡히면 판정 불가.  ★ 오염 감지되면 판정 무효.
-- 읽기 전용이다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.17-reviewed.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local NOP = 0xEA
-- 0..262가 실제로 관측된다. 끝값을 포함하므로 한 프레임은 263줄이다.
local LINES_PER_FRAME = 263

-- 상주 컨트롤러 디스어셈 (resident_controller_native_poll_0_8_4)
local SITES = {
  { at = 0x7F49, name = 'PHP 창시작' },
  { at = 0x7F4F, name = 'BIOS $FEC4' },
  { at = 0x7F58, name = 'select' },
  { at = 0x7F5B, name = 'copy_helper 448' },
  { at = 0x7F5E, name = '매직검사' },
  { at = 0x7F6C, name = 'helper save' },
  { at = 0x7F6F, name = 'copy_rend 671' },
  { at = 0x7F7D, name = 'helper restore' },
  { at = 0x7F82, name = 'renderer' },
  { at = 0x7F85, name = 'PLP 창끝' },
}

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/window_decompose_0_5_21_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tseq\tsite\tline\tdelta_from_prev\n') end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- 교차 오염 가드
local FOREIGN = {
  { at = 0x7F4A, name = '0.5.16 SEI off' },
  { at = 0x7F5B, name = '0.5.17/18 copy offload' },
  { at = 0x7F6F, name = '0.5.17/18 copy offload' },
}
local dirty = false
local function checkForeign()
  if dirty then return end
  for _, f in ipairs(FOREIGN) do
    if (emu.read(f.at, MEM) or -1) == NOP then
      dirty = true
      emu.log(string.format('SUB 0.5.21 ★★ 오염 감지 -- $%04X 가 NOP (%s 잔재)', f.at, f.name))
      emu.log('   Power Cycle 하고 이 파일만 다시 로드할 것.  지금 판정은 무효다')
      return
    end
  end
end

local trace = {}
local frame, hits, reported = 0, 0, 0
local seen = {}

for _, s in ipairs(SITES) do
  -- 콜백마다 자기 site를 붙잡는다. Mesen/Lua 버전별 loop-variable capture
  -- 차이로 전부 마지막 지점(PLP)으로 기록되는 일을 막는다.
  local site = s
  emu.addMemoryCallback(function()
    hits = hits + 1
    trace[#trace + 1] = { name = site.name, line = scanline() }
  end, emu.callbackType.exec, site.at, site.at, CPU, MEM)
end

emu.addEventCallback(function()
  frame = frame + 1
  checkForeign()

  local t = trace
  trace = {}
  if #t < 2 then return end

  -- 되감김 보정: 스캔라인이 줄어들면 프레임을 넘은 것이다
  local abs, base, prev = {}, 0, t[1].line
  for i = 1, #t do
    local l = t[i].line
    if l >= 0 and prev >= 0 and l < prev then base = base + LINES_PER_FRAME end
    abs[i] = (l >= 0) and (l + base) or -1
    if l >= 0 then prev = l end
  end

  local total = (abs[#t] >= 0 and abs[1] >= 0) and (abs[#t] - abs[1]) or -1

  -- 구간 이름 서명으로 중복을 줄이되, 긴 창은 항상 보고한다
  local names = {}
  for i = 1, #t do names[#names + 1] = t[i].name end
  local sig = table.concat(names, '>')
  seen[sig] = (seen[sig] or 0) + 1

  if seen[sig] <= 2 or total >= 100 then
    if reported < 40 then
      reported = reported + 1
      local parts = {}
      for i = 2, #t do
        local d = (abs[i] >= 0 and abs[i - 1] >= 0) and (abs[i] - abs[i - 1]) or -1
        if d ~= 0 then
          -- d는 "현재 지점에 도착하기까지"의 비용이다. 화살표를 남겨야
          -- BIOS 비용을 select 비용으로 잘못 읽지 않는다.
          parts[#parts + 1] = string.format('%s→%s %d줄', t[i - 1].name, t[i].name, d)
        end
      end
      emu.log(string.format('SUB 0.5.21 %df · 창 %d줄 (줄%d 시작) · %s',
        frame, total, t[1].line,
        #parts > 0 and table.concat(parts, ' | ') or '(전 구간 0줄)'))
    end
  end

  if out then
    for i = 1, #t do
      local d = (i > 1 and abs[i] >= 0 and abs[i - 1] >= 0) and (abs[i] - abs[i - 1]) or 0
      out:write(string.format('%d\t%d\t%s\t%d\t%d\n', frame, i, t[i].name, t[i].line, d))
    end
    out:flush()
  end

  emu.drawString(4, 84, string.format('0.5.21 창분해 · 지점적중 %d · 보고 %d%s',
    hits, reported, dirty and ' · ★오염 판정무효' or ''),
    dirty and 0x4040FF or (hits > 0 and 0x80FF80 or 0x4040FF), 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.21-window-decompose armed -- SEI 창 안을 구간별 스캔라인으로 쪼갠다')
emu.log('  형식: 창 N줄 (시작줄) · 앞지점→뒤지점 d줄 ...  (0줄 구간은 생략)')
emu.log('  ★ 목표는 창 < 113 줄.  어느 구간을 깎아야 하는지가 나온다')
emu.log('  ★ 지점적중 0 이면 판정 불가')
emu.log('  로그: ' .. OUT)
