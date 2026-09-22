-- SUB 0.5.191 -- VDC 를 우리가 얼마나·어디서 붙잡는가  ★순수 관측 · 쓰기 0 B
--
-- 왜 이걸 재나 -- AC 가설이 반증됐다 (2026-09-08)
-- ---------------------------------------------------------------------------
-- `notpl` 시험판으로 AC 읽기를 **정확히 반으로** 줄였다:
--
--     0.6.2   버스트 rd = 2,201  = 11 x 200 + 1
--     notpl   버스트 rd = 1,145  = 11 x 104 + 1     (실측, 예측치 일치)
--
-- 그런데 **화면상 흔들림은 그대로다.**  그러면 "AC 접촉이 활성 구간을 먹어서
-- 스크롤 폴링을 밀어낸다" 는 주범이 아니다.
--
-- 그리고 우리는 지금까지 **AC 만 셌다.**  흔들림은 VDC/스크롤 문제인데 정작
-- VDC 는 한 번도 안 셌다.  레코드를 찾은 뒤 하는 일 -- **글리프를 VRAM 에
-- 올리는 것** -- 은 VDC 포트를 직접 붙잡으므로 스크롤 갱신과 같은 자원을 다툰다.
--
-- 무엇을 세나
-- ---------------------------------------------------------------------------
-- `$0000-$0003` 쓰기를 레지스터 선택 래치로 갈라서 센다.
--
--     MAWR($00) 주소 설정      몇 번 자리를 잡았나 = 전송 덩어리 수
--     VWR ($02) VRAM 데이터    ★ 글리프 업로드 바이트.  진짜 비용 후보
--     BXR ($07) · BYR($08)     게임이 스크롤을 다시 얹는 것
--     RCR ($06) · CR($05)      래스터 분할
--     그 외                     기타
--
-- 그리고 **첫 VDC 접촉 ~ 마지막 VDC 접촉의 스캔라인**을 같이 남긴다.
-- ⚠ 0.5.186 의 `min_line/max_line` 을 "점유"로 읽은 것은 **틀렸다.**  거기엔
--   매 프레임 도는 상시 폴링이 섞여 시작점이 끌려갔다.  그래서 이 판은
--   **VWR 만의 첫/끝 줄**을 따로 낸다 -- 그것이 글리프 업로드의 실제 폭이다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     vwr 가 크고 vwr_span 이 10~12 줄을 넘는다   -> ★ 범인은 글리프 업로드
--     vwr 가 작다                                 -> VDC 도 무죄.  다른 데를 판다
--     byr/rcr 쓰기가 그 프레임만 줄이 밀린다       -> 밀림의 직접 증거
--
-- 쓰는 법
--   1) 이것만 로드 (0.5.186 등은 끄고).  정상 속도
--   2) 메뉴 띄우고 가만히 3 초        -> 바닥값
--   3) 커서를 한 칸씩.  특히 **"본다"에 올려놓고** R 을 누른다
--   4) Stop -> _summary.txt
--
-- 산출물  C:/snatcher/dump/vdc_0_5_191_<시각>_frames.tsv / _summary.txt

local SAMPLE  = 64        -- 프레임당 스캔라인을 뜰 최대 접근 수 (VWR 은 따로 셈)
local REPORT  = 120
local BIG     = 200       -- 이만큼 넘는 VWR 프레임을 화면에 알린다

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/vdc_0_5_191_' .. STAMP

local fout = assert(io.open(BASE .. '_frames.tsv', 'w'))
fout:write('frame\tmark\tmawr\tvwr\tbxr\tbyr\trcr\tcr\tother\t' ..
           'vwr_first\tvwr_last\tvwr_span\tall_first\tall_last\n')
fout:flush()

local function say(m) emu.log(m); print(m) end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- 프레임 누적
local cnt = { mawr = 0, vwr = 0, bxr = 0, byr = 0, rcr = 0, cr = 0, other = 0 }
local vwrFirst, vwrLast = -1, -1
local allFirst, allLast = -1, -1
local smp = 0
local selReg = 0

-- VWR 은 프레임당 1,400 회까지 온다.  거기서 매번 emu.getState() 를 부르면
-- 에뮬이 기어간다 (0.5.191 첫 판 실측 -- 소유자: "겁나 느리네").
-- 폭만 알면 되므로 **첫 회와 이후 VWR_STEP 회마다** 한 번씩만 줄을 본다.
-- 끝 줄이 최대 STEP-1 회만큼 이르게 잡힐 수 있는데, 200 줄짜리 폭에서
-- 그 오차는 무시할 만하다.
local VWR_STEP = 16

local function bump(key, isVwr)
  cnt[key] = cnt[key] + 1
  if isVwr then
    local n = cnt.vwr
    if n == 1 or n % VWR_STEP == 0 then
      local ln = scanline()
      if ln >= 0 then
        if vwrFirst < 0 then vwrFirst = ln end
        vwrLast = ln
        if allFirst < 0 then allFirst = ln end
        allLast = ln
      end
    end
    return
  end
  if smp >= SAMPLE then return end
  smp = smp + 1
  local ln = scanline()
  if ln >= 0 then
    if allFirst < 0 then allFirst = ln end
    allLast = ln
  end
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; bump('other', false); return end
  if port ~= 2 and port ~= 3 then bump('other', false); return end
  if     selReg == 0x00 then bump('mawr', false)
  elseif selReg == 0x02 then bump('vwr', true)
  elseif selReg == 0x07 then bump('bxr', false)
  elseif selReg == 0x08 then bump('byr', false)
  elseif selReg == 0x06 then bump('rcr', false)
  elseif selReg == 0x05 then bump('cr', false)
  else                       bump('other', false) end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

-- R 키
local KEY = nil
for _, n in ipairs({ 'R', 'r', 'KeyR' }) do
  local ok, v = pcall(function() return emu.isKeyPressed(n) end)
  if ok and type(v) == 'boolean' then KEY = n break end
end
local held, marks = false, 0

local frame = 0
local gv, gm, maxVwr, maxFrame, maxSpan = 0, 0, 0, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local down = false
  if KEY then down = (emu.isKeyPressed(KEY) == true) end
  local mark = (down and not held) and 1 or 0
  held = down
  if mark == 1 then marks = marks + 1; say(('  ── 표식 #%d  f%d'):format(marks, frame)) end

  local span = (vwrFirst >= 0) and (vwrLast - vwrFirst) or -1
  local total = cnt.mawr + cnt.vwr + cnt.bxr + cnt.byr + cnt.rcr + cnt.cr + cnt.other
  if total > 0 or mark == 1 then
    fout:write(('%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n'):format(
      frame, mark, cnt.mawr, cnt.vwr, cnt.bxr, cnt.byr, cnt.rcr, cnt.cr, cnt.other,
      vwrFirst, vwrLast, span, allFirst, allLast))
    fout:flush()
  end
  gv = gv + cnt.vwr; gm = gm + cnt.mawr
  if cnt.vwr > maxVwr then maxVwr, maxFrame, maxSpan = cnt.vwr, frame, span end
  if cnt.vwr >= BIG then
    say(('★ f%d  VWR %d B · MAWR %d · 폭 %d 줄 (%d~%d)')
        :format(frame, cnt.vwr, cnt.mawr, span, vwrFirst, vwrLast))
  end

  cnt = { mawr = 0, vwr = 0, bxr = 0, byr = 0, rcr = 0, cr = 0, other = 0 }
  vwrFirst, vwrLast, allFirst, allLast, smp = -1, -1, -1, -1, 0

  if frame % REPORT == 0 then
    say(('f%d  누적 VWR %d · MAWR %d  (최대 VWR %d @f%d, 폭 %d 줄)')
        :format(frame, gv, gm, maxVwr, maxFrame, maxSpan))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  fout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  put(('프레임 %d · 표식 %d'):format(frame, marks))
  put(('누적 VWR %d B · MAWR %d 회'):format(gv, gm))
  put(('한 프레임 최대 VWR %d B (f%d) · 그때 폭 %d 줄'):format(maxVwr, maxFrame, maxSpan))
  put('')
  put('판정')
  put('  VWR 이 크고 폭이 10~12 줄을 넘으면 -> 글리프 업로드가 범인')
  put('  VWR 이 작으면 -> VDC 도 무죄.  AC 반증과 합쳐 다른 데를 판다')
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.191-vdc-cost armed -- VDC 포트 $0000-$0003 계수 · 쓰기 0 B')
say('  ★ AC 를 반으로 줄여도 흔들림이 그대로였다.  이번엔 VDC 를 센다')
say('  메뉴에서 커서 이동 · "본다"에 올려놓고 R')
say('  ' .. BASE .. '_frames.tsv')
