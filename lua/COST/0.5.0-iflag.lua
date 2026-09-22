-- lua/COST/0.5.0-iflag.lua   (옛 이름 PROBE_SUBTITLE_TRAFFIC_0_4_0.lua)
-- ★판번호는 COST 폴더 기준으로 다시 매겼다 (2026-09-05, 소유자 요청).
--   덤프 경로도 같이 바꿨다 -- 로그와 코드가 어긋나면 로그를 못 읽는다.
--   덤프: snatcher_tool/logs/cost_v050.tsv
--
-- PROBE_SUBTITLE_TRAFFIC 0.4.0 -- 비용 + ★인터럽트가 막혀 있나
--
-- 0.4.0 이 더 보는 것 (소유자: "이게 맞는지 어케 알아?")
-- ------------------------------------------------------
-- 0.3.1 로 arm 이 **줄 31**, 표시 구간에서 돈다는 것까지 나왔다.  거기서 내가
-- "TAI 671 B(8.9 줄)가 원자적이라 그게 범인이고, AC->AC 바이트 루프(23.6 줄)는
-- 인터럽트가 들어오니 범인이 아니다" 라고 답했다.  **그건 안 잰 가정이다.**
--
--   arm 코드 자체       SEI/CLI 를 안 쓴다 (grep 0건)
--   0.5.10 manifest     "7F4A: SEI 78 -> NOP EA only"  -- SEI 하나를 없앴다
--   0.4.6.10/11         "PHP/SEI around the bank-1 window" 스텁이 있었다
--                       ★그게 지금도 사는지 확인 못 했다
--
-- 호출자가 SEI 로 감싸고 있으면 바이트 루프도 똑같이 막는다.  그러면 차단이
-- 8.9 가 아니라 33.4 줄이고, TAI 만 쪼개는 것은 27% 짜리가 된다 (89% 가 아니라).
--
-- 그래서 arm 이 도는 그 순간의 **I 플래그**를 읽는다.  그거 하나로 갈린다.
--
--   I=0 (인터럽트 열림)   -> 바이트 루프는 안 막는다.  TAI 쪼개기가 89% 짜리다
--   I=1 (막혀 있음)       -> 전부 막는다.  쪼개기만으로는 27%.  다른 처방이 필요
--
-- ★ 0.2.0 이 틀린 것 (소유자: "이건 좀 이상한거 같다")
-- ----------------------------------------------------
--   f302 자막그리기 ... VRAM쓰기 263
--   f303 자막그리기 ... VRAM쓰기 263      <- 매 프레임 똑같이 263
--
-- 저건 **게임 것**이다 (SATB 갱신 등).  내가 VDC 데이터 포트 쓰기를 전부 세고
-- "자막그리기" 라고 라벨을 붙였다.  GFX 프로브가 같은 함정에 빠졌었고
-- (0.1.9 -> 0.1.10) 그때 **MAWR 이 우리 구간일 때만** 세는 것으로 풀었다.
-- 그 교훈을 안 가져온 것이 0.2.0 의 잘못이다.
--
-- 그리고 `시작줄 -1` 은 스캔라인 읽기가 죽은 게 아니라, 그것을 AC **쓰기**에만
-- 걸어둬서 AC 쓰기가 없는 프레임에서 안 찍힌 것이다.
--
-- 0.3.0 이 하는 일
-- ----------------
-- VDC 레지스터 선택을 **직접 따라간다**.  getState 를 콜백에서 안 부른다.
--
--   $0000 쓰기        레지스터 선택 (0 = MAWR, 2 = VWR)
--   $0002/$0003 쓰기  선택된 레지스터의 값
--                     선택이 0 이면 MAWR 그림자를 갱신한다
--                     선택이 2 이면 VRAM 쓰기 1 회 -- 그림자 주소로 우리 것인지 가른다
--
-- 우리 구간 = 자막 글리프 자리.  engine.json 의 pat_vram $7900 부터 1216 워드
-- (헬퍼가 저장/복원하는 바로 그 범위) -> $7900 ~ $7DBF.
--
--   OURS   그 안에 떨어지는 VRAM 쓰기      = 자막이 만든 비용
--   GAME   그 밖                            = 배경.  세기는 하되 따로 둔다
--
-- AC 포트도 그대로 센다 ($1A00 읽기 · $1A10 쓰기 = 엔진 적재).
-- 스캔라인은 **그 프레임의 첫 '우리 것' 이벤트**에서 한 번만 찍는다.
--
-- ⚠ 화면에 아무것도 안 그린다.  콜백은 카운터만 올린다.
--
--   dump  snatcher_tool/logs/cost_v050.tsv   ★프로브와 같은 판번호

local OUT = "C:/snatcher/snatcher_tool/logs/cost_v050.tsv"

local VDC_SEL  = 0x0000
local VDC_LO   = 0x0002
local VDC_HI   = 0x0003
local AC_READ  = 0x1A00
local AC_WRITE = 0x1A10
local STATE    = 0x7FDF

local OURS_LO  = 0x7900              -- pat_vram (engine.json)
local OURS_HI  = 0x7900 + 1216       -- 헬퍼가 저장/복원하는 범위 끝
-- ★ SATB.  자막 한 줄을 띄우는 일은 여기 몇 칸 쓰는 것이 전부다 -- 팩이 펜 위치를
--   빌드 때 미리 계산해 두므로 런타임은 밀어넣기만 한다 (build_subtitle_pack 설명).
--   소유자 관측: "실제로는 자막 나올때는 또 안나옴".  그것을 숫자로 보이게 한다.
local SATB_LO  = 0x1000
local SATB_HI  = 0x1100

local cpu = emu.memType.cpu

local sel      = -1                  -- 지금 선택된 VDC 레지스터
local mawr     = 0                   -- MAWR 그림자
local ours, game, satb, acr, acw = 0, 0, 0, 0, 0
local frame, arms = 0, 0
local last_state = -1
local line_at = -1
local rows, gaps = {}, {}
local last_busy = nil
local sum = { ours = 0, game = 0, satb = 0, acr = 0, acw = 0 }
local busy = 0

local function say(m) emu.log(m); print(m) end

local LINE_KEY
local function scanline()
  local ok, st = pcall(emu.getState)
  if not ok or not st then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    -- ⚠ 'scanline' 이 들어간 키를 아무거나 잡으면 vce.scanlineCount(상수)가
    --   걸린다 -- DELAY_SWEEP 0.2.0 이 그걸로 아무것도 못 쟀다.  이름을 지정한다.
    for _, k in ipairs({ 'vdc.scanline', 'vdc.vCounter', 'ppu.scanline', 'scanline' }) do
      if type(st[k]) == 'number' then LINE_KEY = k; break end
    end
    say(("  스캔라인 키: %s"):format(tostring(LINE_KEY)))
  end
  if LINE_KEY == false then return -1 end
  local v = st[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- CPU 상태 바이트.  키 이름은 코어 판마다 다르니 한 번만 찾아 기억한다.
local PS_KEY
local function iflag()
  local ok, st = pcall(emu.getState)
  if not ok or not st then return -1 end
  if PS_KEY == nil then
    PS_KEY = false
    for _, k in ipairs({ 'cpu.ps', 'cpu.status', 'cpu.p', 'cpu.flags' }) do
      if type(st[k]) == 'number' then PS_KEY = k; break end
    end
    say(("  CPU 상태 키: %s"):format(tostring(PS_KEY)))
  end
  if PS_KEY == false then return -1 end
  local v = st[PS_KEY]
  if type(v) ~= 'number' then return -1 end
  return ((v & 0x04) ~= 0) and 1 or 0      -- 6502 I 플래그 = bit 2
end

local irq_at = -1
local function mark()
  -- ★ getState 는 프레임당 한 번.  그 프레임의 첫 이벤트에서만 찍는다.
  if line_at < 0 then
    line_at = scanline()
    irq_at = iflag()
  end
end

emu.addMemoryCallback(function(addr, value)
  sel = value
end, emu.callbackType.write, VDC_SEL, VDC_SEL, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(addr, value)
  if sel == 0 then                                   -- MAWR
    if addr == VDC_LO then mawr = (mawr & 0xFF00) | value
    else mawr = (mawr & 0x00FF) | (value << 8) end
  elseif sel == 2 then                               -- VWR
    if mawr >= OURS_LO and mawr < OURS_HI then
      ours = ours + 1; mark()
    elseif mawr >= SATB_LO and mawr < SATB_HI then
      satb = satb + 1
    else
      game = game + 1
    end
    if addr == VDC_HI then mawr = (mawr + 1) & 0xFFFF end   -- 자동증가
  end
end, emu.callbackType.write, VDC_LO, VDC_HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function() acr = acr + 1 end,
  emu.callbackType.read, AC_READ, AC_READ, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function() acw = acw + 1; mark() end,
  emu.callbackType.write, AC_WRITE, AC_WRITE, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function(addr, value)
  if value == 1 and last_state ~= 1 then arms = arms + 1 end
  last_state = value
end, emu.callbackType.write, STATE, STATE, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  sum.ours = sum.ours + ours; sum.game = sum.game + game; sum.satb = sum.satb + satb
  sum.acr = sum.acr + acr;    sum.acw = sum.acw + acw

  if ours > 0 or acw > 0 then
    busy = busy + 1
    local kind = acw >= 512 and "엔진적재" or "자막VRAM"
    if last_busy then gaps[#gaps + 1] = frame - last_busy end
    last_busy = frame
    rows[#rows + 1] = { f = frame, ours = ours, game = game,
                        acr = acr, acw = acw, kind = kind, line = line_at, iflag = irq_at }
    if busy <= 40 then
      local cyc = ours * 6 + acw * 16
      say(("  f%-7d %-9s 자막VRAM %5d  AC쓰기 %5d  (SATB %3d · 게임 %4d)  %6d cyc %5.1f줄  시작줄 %4d  I=%s%s")
          :format(frame, kind, ours, acw, satb, game, cyc, cyc / 455, line_at,
                  (irq_at < 0 and "?" or (irq_at == 1 and "1★막힘" or "0")),
                  (line_at >= 0 and line_at < 242) and "  ★표시구간" or ""))
    end
  end
  ours, game, satb, acr, acw = 0, 0, 0, 0, 0
  line_at = -1; irq_at = -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "w")
  if f then
    f:write("frame\tkind\tours_vram\tgame_vram\tac_read\tac_write\tstart_line\n")
    for _, r in ipairs(rows) do
      f:write(("%d\t%s\t%d\t%d\t%d\t%d\t%d\n")
              :format(r.f, r.kind, r.ours, r.game, r.acr, r.acw, r.line))
    end
    f:close()
  end
  say("")
  say(("프레임 %d · 우리가 바쁜 프레임 %d (%.1f%%) · arm %d")
      :format(frame, busy, busy / math.max(frame, 1) * 100, arms))
  say(("자막 VRAM %d · SATB %d · 게임 VRAM %d · AC읽기 %d · AC쓰기 %d")
      :format(sum.ours, sum.satb, sum.game, sum.acr, sum.acw))
  say("")
  say("★ 자막 한 줄 출력의 값은 SATB 몇 칸이 전부다.  글리프는 arm 때 한 번 올라간다")
  say("   -> 줄일 것은 자막 쪽이 아니라 **클립 경계**에 몰려 있다")
  if #gaps > 0 then
    table.sort(gaps)
    say(("바쁜 프레임 간격  중앙값 %d · 최소 %d · 최대 %d")
        :format(gaps[#gaps // 2 + 1], gaps[1], gaps[#gaps]))
  end
  local inwin = 0
  for _, r in ipairs(rows) do
    if r.line >= 0 and r.line < 242 then inwin = inwin + 1 end
  end
  say("")
  if busy == 0 then
    say("★ 우리 것이 한 번도 안 잡혔다 -- 자막이 나오는 장면을 안 지났거나")
    say("  pat_vram 이 이 판과 다르다.  못 답한 것이니 믿지 말 것")
  else
    say(("★ 표시구간(0~241)에서 시작한 바쁜 프레임  %d / %d")
        :format(inwin, busy))
    say("   여기 걸린 것만 그림을 민다.  vblank 에 떨어진 것은 공짜다")
    local blocked, open, unknown = 0, 0, 0
    for _, r in ipairs(rows) do
      if r.iflag == 1 then blocked = blocked + 1
      elseif r.iflag == 0 then open = open + 1
      else unknown = unknown + 1 end
    end
    say("")
    say(("★ arm 순간의 인터럽트  막힘 %d · 열림 %d · 못읽음 %d")
        :format(blocked, open, unknown))
    if unknown > 0 and blocked + open == 0 then
      say("  ★CPU 상태 키를 못 찾았다 -- 판정 불가.  믿지 말 것")
    elseif blocked > open then
      say("  -> 호출자가 SEI 로 감싸고 있다.  바이트 루프도 막는다")
      say("     TAI 만 쪼개면 33.4 -> 24.5 줄 (27%).  89% 가 아니다")
    else
      say("  -> 인터럽트가 열려 있다.  바이트 루프는 래스터 IRQ 를 안 막는다")
      say("     막는 것은 TAI 8.9 줄뿐 -> 쪼개면 1.0 줄 (89%).  값어치 있다")
    end
  end
  say(("dump  %s"):format(OUT))
end, emu.eventType.scriptEnded)

say("PROBE_SUBTITLE_TRAFFIC 0.4.0 -- MAWR 을 따라가 우리 것만 센다")
say(("  우리 구간 VRAM $%04X~$%04X (pat_vram + 1216 워드)"):format(OURS_LO, OURS_HI - 1))
