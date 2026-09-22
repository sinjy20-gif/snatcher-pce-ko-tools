-- PROBE 오프닝훅 0.1.0 -- 컷신 프레임 훅과 CD 오디오 시퀀서를 찾는다
--
-- 왜
-- ---------------------------------------------------------------------------
-- 자막 인계서 §7 의 앵커 1 번: "컷신에서 살아 있는 VSync/프레임 훅" (Yuna 의 $5284).
-- 정적 스캔으로는 못 찾는다 -- 트랙02 는 70 MB 이고 `20 21 C0` 같은 3 바이트 패턴은
-- 그래픽·ADPCM 데이터에서 수백 건씩 우연히 나온다 (NOTES 가 이미 경고한 함정).
--
-- 그래서 실행 중에 잡는다.  세 가지를 동시에 본다:
--
--   1  누가 CD 오디오 서비스를 부르는가   $C021 진입 시 스택의 복귀주소 = 호출자
--   2  그것이 프레임마다 도는가            프레임당 호출 횟수
--   3  BIOS 유저 벡터에 무엇이 걸려 있나   $2200-$2217.  VSync 훅의 자리
--
-- 드라이버 구조 (정적 확정, NOTES + 이 세션)
-- ---------------------------------------------------------------------------
--     $26F5   명령 레지스터.  FC/FD/FE 는 특수, 그 외는 트랙 번호
--     $26F6   대기 플래그.  $C059 가 INC, $C0A2 가 STZ
--     $C021   서비스 루틴 진입 (AD F6 26 = LDA $26F6).  $C0A5 에서 RTS
--     $C0E4   JSR CD_PLAY
--     $C0F6   재생 중인가 + 부산물로 SUBQ 의 M:S:F
--
-- 주의
-- ---------------------------------------------------------------------------
--   PCE 제로페이지 $2000-$20FF, 스택 페이지 $2100-$21FF.
--   $C021 을 막 실행하는 순간 스택 꼭대기에 (복귀주소 - 1) 이 있다.
--   호출한 JSR 은 그보다 2 바이트 앞이다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   타이틀에서 오프닝 데모가 시작되게 두고 10~20 초.  스스로 안 멈춘다 -- Stop 을 눌러라.

local OUT = "C:\\snatcher\\dump\\probe_opening_hook_0_1_0.tsv"
local mem = emu.memType.pceMemory

local SERVICE   = 0xC021      -- CD 오디오 서비스 진입
local WAIT_SUBQ = 0xC000      -- SUBQ 대기 루틴
local PLAY      = 0xC0E4      -- JSR CD_PLAY
local ZP        = 0x2000
local STACK     = 0x2100
local VEC_LO, VEC_HI = 0x2200, 0x2217

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\tcaller\tvalue\tmpr\tnote\n")

local frame, rows, dirty = 0, 0, false
local callers = {}          -- caller -> count
local order = {}
local perFrame = {}         -- frame -> service 호출 횟수
local playSeen = 0
local vecShot = false

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end

local function state()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function mprList(s)
  if s == nil then return "" end
  local t = {}
  for slot = 0, 7 do
    local v = s[string.format("memoryManager.mpr[%d]", slot)]
    if v == nil then v = s[string.format("mpr[%d]", slot)] end
    t[#t + 1] = string.format("%02X", v or 0)
  end
  return table.concat(t, " ")
end

local function row(kind, pc, caller, value, mpr, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%04X\t%04X\t%s\t%s\t%s\n",
    kind, frame, pc or 0, caller or 0, value or "", mpr or "", note or ""))
  dirty = true
end

-- 1) 서비스 진입 -- 스택에서 호출자를 꺼낸다
emu.addMemoryCallback(function()
  local s = state()
  local sp = s and (s["cpu.sp"] or s["sp"]) or nil
  local caller = 0
  if sp ~= nil then
    -- JSR 이 밀어 넣은 것은 (복귀주소 - 1).  실제 JSR 은 그보다 2 앞.
    -- 스택은 $2100 한 페이지 안에서 감기므로 두 바이트를 따로 접어 읽는다.
    local lo = byte(STACK + ((sp + 1) % 0x100))
    local hi = byte(STACK + ((sp + 2) % 0x100))
    caller = ((lo + hi * 256) - 1) % 0x10000      -- 복귀주소
    caller = (caller - 3) % 0x10000               -- 그 앞의 JSR 옵코드
  end
  perFrame[frame] = (perFrame[frame] or 0) + 1
  if callers[caller] == nil then
    callers[caller] = 0
    order[#order + 1] = caller
    row("caller", SERVICE, caller, string.format("$26F5=%02X $26F6=%02X", byte(0x26F5), byte(0x26F6)),
        mprList(s), "새 호출자")
  end
  callers[caller] = callers[caller] + 1
end, emu.callbackType.exec, SERVICE, SERVICE, emu.cpuType.pce, mem)

-- 2) CD_PLAY 가 실제로 나가는 순간 -- 오프닝 시작점
emu.addMemoryCallback(function()
  playSeen = playSeen + 1
  if playSeen > 4 then return end
  local s = state()
  row("play", PLAY, 0, string.format("track=%02X", byte(0x26F9)), mprList(s),
      "JSR CD_PLAY -- 오프닝이 여기서 시작한다")
end, emu.callbackType.exec, PLAY, PLAY, emu.cpuType.pce, mem)

-- 3) BIOS 유저 벡터 표.  프레임 60 쯤 한 번만
emu.addEventCallback(function()
  frame = frame + 1
  if not vecShot and frame == 60 then
    vecShot = true
    for a = VEC_LO, VEC_HI, 3 do
      row("vector", a, word(a + 1), string.format("%02X", byte(a)), "",
          string.format("$%04X: %02X %04X", a, byte(a), word(a + 1)))
    end
  end
  if dirty then file:flush(); dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  -- 호출자 인구조사
  for _, c in ipairs(order) do
    row("census", SERVICE, c, tostring(callers[c]), "",
        string.format("호출자 $%04X 가 %d 회", c, callers[c]))
  end
  -- 프레임당 호출 분포 -- 1 이면 프레임 훅이다
  local hist = {}
  for _, n in pairs(perFrame) do hist[n] = (hist[n] or 0) + 1 end
  for n, c in pairs(hist) do
    row("rate", 0, 0, tostring(n), "", string.format("프레임당 %d 회가 %d 프레임", n, c))
  end
  file:write(string.format("-- 프레임 %d · 호출자 %d 종 · CD_PLAY %d 회 · 총 %d 행\n",
    frame, #order, playSeen, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 오프닝훅 0.1.0 -- 자막 앵커 1 번(프레임 훅)을 찾는다")
emu.log("  오프닝 데모가 돌게 두고 10~20 초.  스스로 안 멈춘다 -- Stop 을 눌러라")
emu.log("  caller 행 = CD 오디오 서비스를 부른 코드.  거기가 시퀀서다")
emu.log("  rate 행 = 프레임당 호출 횟수.  1 이면 프레임 훅으로 쓸 수 있다")
emu.log("  vector 행 = BIOS 유저 벡터 $2200-$2217 에 걸린 것")
emu.log("  출력: " .. OUT)
