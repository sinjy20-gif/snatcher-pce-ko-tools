-- SUB 0.5.78 -- CD-DA 임대 생명주기 전체를 잰다 (0.4.6.51 판정용)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.4.6.49/50/51 을 가설만으로 세 번 넘겼다.  그만한다.
-- 0.4.6.51 의 성패는 **질문 하나**로 갈린다.
--
--     resident 가 AC 이미지를 CPU $5B80 으로 복사한 뒤,
--     렌더러의 elapsed 가 2188 인가 0 인가
--
--     2188 이면  파종이 살아남았다 -> 첫 줄이 즉시 -> 설계대로
--     0 이면     또 덮였다         -> 자막이 36 초 밀린다 -> 0.4.6.50 과 동일
--
-- 그 외에 이번 설계가 기대는 가정들도 같이 잰다.  전부 아직 안 본 것들이다.
--
--     A  시계 자리 $1F2720 을 우리 말고 누가 쓰는가        (한 번도 확인 안 함)
--     B  cdda_start 가 언제 켜지고 elapsed 가 제대로 도는가
--     C  임대가 정확히 elapsed 2188 에 일어나는가
--     D  임대 창(2188~2683) 동안 게임이 $7900 에 쓰는가    (잔여 노출)
--     E  STATE 전이 0 -> 1 -> 2 -> 3 이 언제 일어나는가
--
-- 무엇을 안 하나
-- ---------------------------------------------------------------------------
-- ★ 게임을 한 바이트도 안 고친다.  순수 관측이다.
-- ★ 화면에 아무것도 안 그린다.
--
-- 어떻게 돌리나
--     Power Cycle 뒤 이 파일 하나만 로드
--     BIOS  build/patch/0.4.6.51/Syscard3_galmuri_0.4.6.51.pce
--     CUE   같은 폴더 [KO].cue
--     스킵하지 말고 CD-DA 를 끝까지 재생 -> ACT1 까지 진행
--
-- 산출물  dump/cdda_lease_0_5_78_<시각>.tsv  +  로그 요약

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local AC   = emu.memType.pceArcadeCardRam
local CPU  = emu.cpuType.pce

-- 우리 시계 (0.4.6.50 부터: 매직 2 B + elapsed u16)
local CLOCK      = 0x1F2720
local MAGIC_LO, MAGIC_HI = 0x5A, 0xA5

-- 슬롯 $5B80 은 helper 와 renderer 가 번갈아 쓴다.  서명으로 가른다.
local SLOT       = 0x5B80
local HELPER_SIG = { 0xAD, 0x30, 0x5D, 0xD0 }   -- $5B83: LDA $5D30 / BNE
local HELPER_ENTRY = 0x5B83
local CTL_CMD    = 0x5D30
local CTL_LO, CTL_HI = 0x5D34, 0x5D35

-- renderer 내부 (engine json: timer 602 · elapsed 669 · threshold_low 666)
local R_TIMER    = SLOT + 602                   -- $5DDA · 첫 opcode SEC($38)
local R_ELAPSED  = SLOT + 669                   -- $5E1D lo · $5E1E hi
local R_THRESH   = SLOT + 666

local STATE      = 0x7FDF
local CDDA_BASE  = 0x7900
local SPAN_BYTES = 19 * 128                     -- 2,432 B

local THRESHOLDS = { 2188, 2435, 2683 }

local frame = 0
local rows = {}
local log1 = {}

local function put(fmt, ...)
  local s = string.format(fmt, ...)
  log1[#log1 + 1] = s
  emu.log(s)
end

local function rd(a, t) return emu.read(a, t or MEM) or -1 end

local function clock()
  local lo, hi = rd(CLOCK, AC), rd(CLOCK + 1, AC)
  local on = (lo == MAGIC_LO and hi == MAGIC_HI)
  local el = (rd(CLOCK + 3, AC) << 8) | (rd(CLOCK + 2, AC) & 0xFF)
  return on, el, lo, hi
end

local function slotIsHelper()
  for i = 1, #HELPER_SIG do
    if rd(HELPER_ENTRY + i - 1) ~= HELPER_SIG[i] then return false end
  end
  return true
end

local function slotIsRenderer() return rd(R_TIMER) == 0x38 end

local function rElapsed()
  return ((rd(R_ELAPSED + 1) & 0xFF) << 8) | (rd(R_ELAPSED) & 0xFF)
end

-- ===========================================================================
-- A. 시계 자리를 우리 말고 누가 쓰는가
-- ===========================================================================
local prevRaw = { -1, -1, -1, -1 }
local foreignWrites, ourStarts, magicKills = 0, 0, 0
local firstForeign = nil

-- ===========================================================================
-- C/E. 임대와 STATE
-- ===========================================================================
local prevState, prevOn = -1, false
local startFrame, armFrame, armElapsed = nil, nil, nil
local seedSeen, seedFrame = nil, nil
local stateAt = {}

-- ===========================================================================
-- D. 임대 창 동안 게임이 $7900 에 쓰는가
-- ===========================================================================
local leaseOpen, leaseOpenFrame = false, nil
local gameWrites, gameWritePCs = 0, {}

-- ★ 임대 중이 아니어도 **항상** 센다.
--   임대 판정이 실패해도 "재는 데 실패한 것" 과 "정말 안 쓰는 것" 을 구분할 수
--   있어야 한다.  0 이 나왔을 때 그것이 답인지 프로브의 무능인지 알아야 한다.
local totalWrites = 0
emu.addMemoryCallback(function(addr)
  totalWrites = totalWrites + 1
  if not leaseOpen then return end
  gameWrites = gameWrites + 1
  if gameWrites <= 40 then
    local ok, st = pcall(emu.getState)
    local pc = (ok and st and st.cpu and st.cpu.pc) or -1
    gameWritePCs[#gameWritePCs + 1] = string.format("%df:$%04X@pc$%04X", frame, addr, pc)
  end
end, emu.callbackType.write, CDDA_BASE * 2, CDDA_BASE * 2 + SPAN_BYTES - 1, CPU, VRAM)

-- ===========================================================================
-- ★ 핵심 측정 -- 실행 지점 앵커
--
-- $5E1D 는 MPR2($4000-$5FFF) 다.  endFrame 에서 그냥 읽으면 그 순간 다른 뱅크가
-- 걸려 있을 수 있고, 그러면 남의 뱅크 값을 보고 엉뚱한 결론을 낸다.
-- (예전 $7F4A "진동" 오작동이 정확히 이 실수였다.)
--
-- $5DDA 는 renderer 의 timer 첫 opcode 다.  거기서 실행 중이라면 그 8 KB 페이지가
-- 확실히 renderer 다.  $5E1D 도 같은 페이지이므로 뱅킹 의심이 없다.
-- 그래서 핵심 질문은 **여기서만** 답한다.
-- ===========================================================================
emu.addMemoryCallback(function()
  if seedSeen ~= nil then return end
  local re = rElapsed()
  seedSeen, seedFrame = re, frame
  local t1, t2, t3 = rd(R_THRESH), rd(R_THRESH + 1), rd(R_THRESH + 2)
  put("0.5.78 ★★★ %df  renderer timer 최초 진입 · elapsed=%d ($%04X) hi=$%02X",
      frame, re, re, (re >> 8) & 0xFF)
  put("            문턱표 low = %02X %02X %02X  (기대 8C 83 7B)", t1, t2, t3)
  if t1 ~= 0x8C or t2 ~= 0x83 or t3 ~= 0x7B then
    put("            ★★ 문턱표가 기대와 다르다 -- 이 슬롯은 CD-DA renderer 가 아니다")
    put("               아래 판정은 믿지 말 것")
  elseif re >= THRESHOLDS[1] - 4 and re <= THRESHOLDS[1] + 4 then
    put("            ==> ★파종 성공.  hi-$08=%d 로 첫 줄이 즉시 뜬다",
        ((re >> 8) & 0xFF) - 8)
  else
    put("            ==> ★파종 실패.  자막이 %d 프레임(%.1f 초) 밀린다",
        THRESHOLDS[1] - re, (THRESHOLDS[1] - re) / 60)
  end
end, emu.callbackType.exec, R_TIMER, R_TIMER, CPU, MEM)

-- helper 진입: 백업/복원이 언제 어느 자리에 일어나는가
local helperHits = {}
emu.addMemoryCallback(function()
  if not slotIsHelper() then return end
  local cmd = rd(CTL_CMD)
  local base = ((rd(CTL_HI) & 0xFF) << 8) | (rd(CTL_LO) & 0xFF)
  if #helperHits < 24 then
    helperHits[#helperHits + 1] =
      string.format("%df cmd=%d base=$%04X", frame, cmd, base)
  end
  -- ★ 임대 창을 여기서 연다/닫는다.  STATE($7FDF) 는 MPR3 라 endFrame 폴링이
  --   다른 뱅크를 볼 수 있다.  helper 실행 지점은 뱅킹이 확실하므로 여기가 안전하다.
  if base == CDDA_BASE then
    if cmd == 0 then
      if not leaseOpen then
        leaseOpen = true
        leaseOpenFrame = frame
        put("0.5.78 ★ %df  임대 창 열림 (helper 백업 · base $%04X)", frame, base)
      end
    else
      if leaseOpen then
        leaseOpen = false
        put("0.5.78 ★ %df  임대 창 닫힘 (helper 복원) · 창 길이 %d 프레임", frame,
            leaseOpenFrame and (frame - leaseOpenFrame) or -1)
        put("            ★ 이 창 동안 게임이 $%04X 대역에 쓴 횟수 = %d",
            CDDA_BASE, gameWrites)
        if gameWrites > 0 then
          put("            ==> 이 자리는 임대 구간에 **비어있지 않다.**")
          put("                복원이 게임이 그린 것을 덮는다 -> ACT1 깨짐")
        else
          put("            ==> 이 창 동안은 아무도 안 썼다.  범인은 다른 데 있다")
        end
      end
    end
  end
end, emu.callbackType.exec, HELPER_ENTRY, HELPER_ENTRY, CPU, MEM)

-- ===========================================================================
-- 매 프레임 관측
-- ===========================================================================
emu.addEventCallback(function()
  frame = frame + 1

  -- A. 시계 자리 원시 감시
  local raw = { rd(CLOCK, AC), rd(CLOCK + 1, AC), rd(CLOCK + 2, AC), rd(CLOCK + 3, AC) }
  local changed = false
  for i = 1, 4 do if raw[i] ~= prevRaw[i] then changed = true end end

  local on, el = clock()

  if changed and prevRaw[1] ~= -1 then
    local wasOn = (prevRaw[1] == MAGIC_LO and prevRaw[2] == MAGIC_HI)
    if (not wasOn) and on then
      ourStarts = ourStarts + 1
      startFrame = startFrame or frame
      put("0.5.78 ★ %df  시계 켜짐 (매직 등장) -- CD-DA 시작 감지", frame)
    elseif wasOn and (not on) then
      magicKills = magicKills + 1
      put("0.5.78 · %df  매직 파괴 (임대 시작 또는 포기) · 그때 elapsed=%d",
          frame, (prevRaw[4] << 8) | prevRaw[3])
    elseif (not wasOn) and (not on) then
      -- 매직도 아닌데 값이 변한다 = 우리가 아닌 누군가가 이 자리를 쓴다
      foreignWrites = foreignWrites + 1
      if not firstForeign then
        firstForeign = string.format(
          "%df  %02X %02X %02X %02X -> %02X %02X %02X %02X",
          frame, prevRaw[1], prevRaw[2], prevRaw[3], prevRaw[4],
          raw[1], raw[2], raw[3], raw[4])
        put("0.5.78 ★★ %df  시계 자리를 우리가 아닌 것이 건드린다  %s",
            frame, firstForeign)
      end
    end
  end
  prevRaw = raw

  -- E. STATE 전이
  local st = rd(STATE)
  if st ~= prevState then
    stateAt[#stateAt + 1] = string.format("%df  state %s -> %s  (elapsed=%s)",
      frame, prevState < 0 and "?" or string.format("%02X", prevState),
      string.format("%02X", st), on and tostring(el) or "-")
    if st == 1 then
      armFrame, armElapsed = frame, el
      leaseOpen = true
      put("0.5.78 ★ %df  STATE=1 임대 시작 · 우리 시계 elapsed=%d  (기대 %d)",
          frame, el, THRESHOLDS[1])
    elseif st == 3 then
      leaseOpen = false
      put("0.5.78 · %df  STATE=3 반납", frame)
    end
    prevState = st
  end

  -- 추이 기록용 보조 관측.  판정은 위의 실행 앵커가 한다 (뱅킹 때문).
  if slotIsRenderer() then
    local re = rElapsed()
    if #rows < 4000 then
      rows[#rows + 1] = string.format("%d\t%d\t%d\t%02X\trenderer",
                                      frame, on and el or -1, re, st)
    end
  elseif #rows < 4000 and (on or st ~= 0) then
    rows[#rows + 1] = string.format("%d\t%d\t\t%02X\t%s",
      frame, on and el or -1, st, slotIsHelper() and "helper" or "?")
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local name = string.format("dump/cdda_lease_0_5_78_%s.tsv", os.date("%Y%m%d_%H%M%S"))
  local f = io.open(name, "w")
  if f then
    f:write("frame\tclock_elapsed\trenderer_elapsed\tstate\tslot\n")
    for _, r in ipairs(rows) do f:write(r, "\n") end
    f:close()
  end

  put("")
  put("======== 0.5.78 요약 ========")
  put("A  시계 자리를 우리가 아닌 것이 건드림 : %d 회%s", foreignWrites,
      firstForeign and ("  첫 사례 " .. firstForeign) or "  (없음 = 자리 안전)")
  put("B  시계 켜짐 %d 회 · 매직 파괴 %d 회 · 첫 시작 %s",
      ourStarts, magicKills, startFrame and (startFrame .. "f") or "없음")
  put("C  임대 시작 %s · 그때 우리 elapsed=%s (기대 %d)",
      armFrame and (armFrame .. "f") or "없음",
      armElapsed and tostring(armElapsed) or "-", THRESHOLDS[1])
  put("★  renderer timer 최초 진입 시 elapsed = %s  (기대 %d)",
      seedSeen and tostring(seedSeen) or "renderer 가 한 번도 안 실림",
      THRESHOLDS[1])
  put("D  $7900 대역 VRAM 쓰기 : 임대 창 안 %d 회 / 전체 %d 회", gameWrites, totalWrites)
  if totalWrites == 0 then
    put("     ★★ 전체가 0 이다.  게임이 정말 안 쓰는 것이 아니라")
    put("        VRAM 쓰기 콜백이 안 잡혔을 수 있다.  이 항목은 판정 불가")
  elseif gameWrites > 0 then
    put("     ==> ★ 임대 구간에 게임이 이 자리를 쓴다.  $7900 은 빈 자리가 아니다")
    put("         복원이 게임이 그린 것을 덮는다.  안전자리 표를 따라야 한다")
  else
    put("     ==> 임대 구간에는 아무도 안 썼다.  ACT1 파손의 범인은 다른 데 있다")
  end
  for i = 1, math.min(#gameWritePCs, 10) do put("     %s", gameWritePCs[i]) end
  put("E  STATE 전이")
  for _, s in ipairs(stateAt) do put("     %s", s) end
  put("   helper 진입")
  for _, h in ipairs(helperHits) do put("     %s", h) end
  put("저장 : %s  (%d 행)", name, #rows)
end, emu.eventType.scriptEnded)

emu.log("SUB 0.5.78-cdda-lease-lifecycle armed -- 순수 관측 · 게임 무수정")
emu.log("  ★ 핵심 질문: renderer 적재 직후 elapsed 가 2188 인가 0 인가")
emu.log("  CD-DA 를 스킵하지 말고 끝까지 재생한 뒤 ACT1 까지 진행하세요")
