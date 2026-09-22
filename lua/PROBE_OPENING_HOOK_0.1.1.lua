-- PROBE 오프닝훅 0.1.1 -- BIOS 진입점에서 잡는다.  0.1.0 이 0 건이었다
--
-- 0.1.0 이 왜 빈손이었나
-- ---------------------------------------------------------------------------
-- $C021 / $C0E4 에 걸었는데 11,902 프레임 동안 한 번도 안 걸렸다.  주소를 고정으로
-- 본 것이 틀렸다.  대사 장면의 MPR 은 `FF F8 68 6A 74 75 76 00` 이라 $C000 에는
-- 뱅크 $76 이 걸려 있고, 오프닝은 다른 오버레이를 올린다.  NOTES 의
-- "ISO 0x07F800 = $C000" 은 특정 적재 문맥에서만 맞는 값이다 -- disasm_huc6280 의
-- 주석이 경고한 "같은 바이트, 틀린 페이지" 함정에 그대로 빠졌다.
--
-- 그래서 0.1.1 은 **BIOS 진입점**에 건다.  $E000-$FFFF 는 MPR7=$00 으로 항상
-- 고정이므로 뱅크 문맥과 무관하다.  CD-DA 재생은 반드시 여기를 지난다.
--
--     $E012  CD_PLAY     오프닝 트랙 재생.  이것의 호출자가 시퀀서다
--     $E015  CD_SEARCH   ($C098 이 쓰는 것)
--     $E018  CD_PAUSE
--     $E01B  CD_STAT
--     $E01E  CD_SUBQ     M:S:F 시계
--     $E02D  CD_FADE
--
-- 고친 것 셋
-- ---------------------------------------------------------------------------
--   1  훅 자리       $C021 고정 -> BIOS 진입점 (뱅크 문맥 무관)
--   2  복귀주소 산술  JSR 은 (JSR주소 + 2) 를 민다.  따라서 호출자 = 밀린값 - 2.
--                    0.1.0 은 -4 로 계산했다 (틀림)
--   3  벡터표        3 바이트가 아니라 **2 바이트** 엔트리다.  0.1.0 의 값을
--                    복원하면 E2 E8 E2 E8... = 전부 $E8E2 (BIOS 기본).  게다가
--                    프레임 60 은 오프닝 시작 전이라 의미가 없었다.  이제 여러 번 뜬다
--
-- 프레임 훅은 어떻게 찾나
-- ---------------------------------------------------------------------------
-- 벡터표만 믿지 않는다.  매 프레임 끝에서 PC 를 표본해 히스토그램을 만든다.
-- 오프닝 동안 CPU 가 어디서 도는지가 그대로 드러나고, MPR 이 같이 찍히므로
-- 어느 뱅크의 코드인지도 나온다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   타이틀에서 오프닝 데모가 시작되게 두고 끝까지 (약 133 초).  스스로 안 멈춘다.
--   Stop 을 눌러야 파일이 닫힌다.

local OUT = "C:\\snatcher\\dump\\probe_opening_hook_0_1_1.tsv"
local mem = emu.memType.pceMemory

local BIOS = {
  [0xE012] = "CD_PLAY",   [0xE015] = "CD_SEARCH", [0xE018] = "CD_PAUSE",
  [0xE01B] = "CD_STAT",   [0xE01E] = "CD_SUBQ",   [0xE02D] = "CD_FADE",
}

local ZP, STACK = 0x2000, 0x2100
local VEC_LO, VEC_HI = 0x2200, 0x2217
local VEC_FRAMES = { [30]=true, [300]=true, [900]=true, [1800]=true, [3600]=true, [6000]=true }

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tentry\tcaller\tvalue\tmpr\tnote\n")

local frame, rows, dirty = 0, 0, false
local seenCall = {}      -- "entry:caller" -> count
local callOrder = {}
local pcHist = {}        -- pc -> count
local pcMpr  = {}        -- pc -> 마지막 mpr 문자열
local totalCalls = 0

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end

local function st()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function mprOf(s)
  if s == nil then return "" end
  local t = {}
  for slot = 0, 7 do
    local v = s[string.format("memoryManager.mpr[%d]", slot)]
    if v == nil then v = s[string.format("mpr[%d]", slot)] end
    t[#t + 1] = string.format("%02X", v or 0)
  end
  return table.concat(t, " ")
end

local function row(kind, entry, caller, value, mpr, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%04X\t%04X\t%s\t%s\t%s\n",
    kind, frame, entry or 0, caller or 0, value or "", mpr or "", note or ""))
  dirty = true
end

-- JSR 은 (JSR 주소 + 2) 를 민다.  스택은 $2100 한 페이지 안에서 감긴다.
local function callerFrom(s)
  local sp = s and (s["cpu.sp"] or s["sp"]) or nil
  if sp == nil then return 0 end
  local lo = byte(STACK + ((sp + 1) % 0x100))
  local hi = byte(STACK + ((sp + 2) % 0x100))
  return ((lo + hi * 256) - 2) % 0x10000
end

for addr, name in pairs(BIOS) do
  emu.addMemoryCallback(function()
    local s = st()
    local caller = callerFrom(s)
    totalCalls = totalCalls + 1
    local key = string.format("%04X:%04X", addr, caller)
    if seenCall[key] == nil then
      seenCall[key] = 0
      callOrder[#callOrder + 1] = key
      row("call", addr, caller, name, mprOf(s),
          string.format("%s 를 $%04X 가 부른다 -- 여기가 시퀀서 후보", name, caller))
    end
    seenCall[key] = seenCall[key] + 1
  end, emu.callbackType.exec, addr, addr, emu.cpuType.pce, mem)
end

emu.addEventCallback(function()
  frame = frame + 1
  -- 프레임 끝의 PC 표본.  오프닝 동안 CPU 가 어디서 도는지가 드러난다
  local s = st()
  local pc = s and (s["cpu.pc"] or s["pc"]) or nil
  if pc then
    pcHist[pc] = (pcHist[pc] or 0) + 1
    pcMpr[pc] = mprOf(s)
  end
  if VEC_FRAMES[frame] then
    -- 2 바이트 엔트리다.  3 바이트로 읽으면 어긋난다
    for a = VEC_LO, VEC_HI, 2 do
      row("vector", a, word(a), "", "", string.format("$%04X -> $%04X", a, word(a)))
    end
  end
  if dirty then file:flush(); dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  for _, key in ipairs(callOrder) do
    local e = tonumber(key:sub(1,4), 16)
    local c = tonumber(key:sub(6,9), 16)
    row("census", e, c, tostring(seenCall[key]), "",
        string.format("%s <- $%04X : %d 회", BIOS[e] or "?", c, seenCall[key]))
  end
  -- PC 히스토그램 상위.  프레임 훅을 걸 자리가 여기 있다
  local flat = {}
  for pc, n in pairs(pcHist) do flat[#flat + 1] = {pc, n} end
  table.sort(flat, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(#flat, 20) do
    row("pc", flat[i][1], 0, tostring(flat[i][2]), pcMpr[flat[i][1]],
        string.format("프레임 끝 PC $%04X 가 %d 회", flat[i][1], flat[i][2]))
  end
  file:write(string.format("-- 프레임 %d · BIOS 호출 %d 회 · 호출쌍 %d 종 · PC %d 종 · 총 %d 행\n",
    frame, totalCalls, #callOrder, #flat, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 오프닝훅 0.1.1 -- BIOS 진입점에서 잡는다 (0.1.0 은 뱅크가 안 맞아 0 건)")
emu.log("  오프닝을 끝까지 (약 133 초).  Stop 을 눌러야 파일이 닫힌다")
emu.log("  call/census 행 = CD BIOS 를 부른 코드.  거기가 오프닝 시퀀서")
emu.log("  pc 행 = 프레임 끝 PC 히스토그램.  프레임 훅 자리")
emu.log("  vector 행 = $2200-$2217 을 2 바이트로.  여러 시점에 뜬다")
emu.log("  출력: " .. OUT)
