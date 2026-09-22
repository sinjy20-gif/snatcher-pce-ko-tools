-- PROBE 오프닝 스프라이트 0.1.0 -- 자막 POC 예산을 잰다
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- 자막 POC 에 남은 미지수는 둘뿐이다 (앵커 1·2 는 0.1.1 에서 확보).
--
--     VRAM 에 패턴 576 B 를 놓을 빈 자리가 있나
--     SAT 64 엔트리 중 오프닝이 안 쓰는 것이 몇 개인가
--
-- 이 둘이 나오면 POC 예산이 확정되고, 그 예산을 빌더가 감사하게 만들 수 있다.
-- (지금 AC 256 KB 와 케이브 64 B 는 예약돼 있지만 VRAM·SAT 은 아직 아무것도 없다.)
--
-- 확보된 것
-- ---------------------------------------------------------------------------
--     프레임 훅   $2202 -> $40A4   IRQ1(VDC).  MPR2=$68 상주
--     오프닝 t0   CD_PLAY <- $60E4
--     시계        CD_SUBQ <- $6119  (실제로 돈다)
--
-- 이 프로브가 하는 일
-- ---------------------------------------------------------------------------
--   1  getState 의 VDC 관련 키를 통째로 한 번 찍는다 -- SATB 주소를 어디서 얻는지
--      모르므로 먼저 확인한다.  키 이름을 몰라 헛도는 것이 이 프로젝트의 단골 함정이다
--   2  SAT 64 엔트리를 여러 시점에 떠서 살아 있는 것을 센다
--   3  VRAM 의 0 연속 구간 지도 -- 576 B 를 놓을 자리
--
-- SAT 은 VRAM 안에 있고 주소는 VDC 레지스터 $13 (SATB) 이 정한다.
-- Yuna 는 $7F00 을 썼다.  스내처 값은 아래에서 실측한다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   오프닝이 끝까지 돌게 두고 Stop.  약 133 초.

local OUT = "C:\\snatcher\\dump\\probe_opening_sprite_0_1_0.tsv"
local mem  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local SHOTS = { [300]=true, [1100]=true, [1500]=true, [2500]=true, [4000]=true, [6000]=true }
local SAT_FALLBACK = 0x7F00      -- Yuna 값.  실측이 나오면 그것을 쓴다

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\ta\tb\tc\tnote\n")
local frame, rows, dirty = 0, 0, false
local dumpedKeys = false
local satbAddr = nil

local function row(kind, a, b, c, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n",
    kind, frame, tostring(a or ""), tostring(b or ""), tostring(c or ""), note or ""))
  dirty = true
end

-- VRAM 은 워드 단위다.  Mesen 의 pceVideoRam 은 바이트 주소로 읽힌다
local function vword(w) return (emu.read(w*2, VRAM) or 0) + (emu.read(w*2+1, VRAM) or 0)*256 end

local function st()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

-- 1) getState 키 정찰.  SATB 를 어디서 얻는지 모르므로 이름을 직접 본다
local function dumpKeys(s)
  if s == nil then return end
  local names = {}
  for k, v in pairs(s) do
    local lk = string.lower(k)
    if string.find(lk, "vdc") or string.find(lk, "sat") or string.find(lk, "sprite")
       or string.find(lk, "vram") or string.find(lk, "video") then
      names[#names+1] = k
    end
  end
  table.sort(names)
  for _, k in ipairs(names) do
    local v = s[k]
    if type(v) ~= "table" then
      row("key", k, tostring(v), "", "getState 키")
      if string.find(string.lower(k), "sat") and type(v) == "number" and v > 0 then
        satbAddr = v
      end
    end
  end
  row("key", "(총)", #names, "", "VDC/SAT/VRAM 관련 키 개수")
end

-- 2) SAT 64 엔트리.  엔트리 = 4 워드 (y, x, pattern, attr)
local function dumpSAT(base)
  local live, firstFree, runFree, bestRun = 0, nil, 0, 0
  for i = 0, 63 do
    local w = base + i*4
    local y, x, pat, attr = vword(w), vword(w+1), vword(w+2), vword(w+3)
    local used = not (y == 0 and x == 0 and pat == 0)
    -- 화면 밖(y=0 또는 y>=256)은 꺼둔 슬롯으로 본다
    if used and y ~= 0 and y < 0x100 then
      live = live + 1
      runFree = 0
    else
      if firstFree == nil then firstFree = i end
      runFree = runFree + 1
      if runFree > bestRun then bestRun = runFree end
    end
    if i < 8 or used then
      row("sat", i, string.format("y=%d x=%d", y, x),
          string.format("pat=%04X attr=%04X", pat, attr), used and "사용" or "빈칸")
    end
  end
  row("satsum", live, 64 - live, bestRun,
      string.format("살아있는 %d / 빈 %d / 연속 빈칸 최대 %d (자막은 16 개 필요)", live, 64-live, bestRun))
end

-- 3) VRAM 0 연속 구간.  576 B = 288 워드 를 놓을 자리를 찾는다
local function vramMap()
  local NEED = 288
  local runStart, run, best, bestAt = nil, 0, 0, nil
  local total = 0x8000                     -- 64 KB = 32,768 워드
  for w = 0, total-1 do
    if vword(w) == 0 then
      if run == 0 then runStart = w end
      run = run + 1
      if run > best then best = run; bestAt = runStart end
    else
      if run >= NEED then
        row("vfree", string.format("$%04X", runStart), run, run*2,
            string.format("워드 $%04X 부터 %d 워드(%d B) 비어 있음", runStart, run, run*2))
      end
      run = 0
    end
  end
  if run >= NEED then
    row("vfree", string.format("$%04X", runStart), run, run*2,
        string.format("워드 $%04X 부터 %d 워드(%d B) 비어 있음 (끝까지)", runStart, run, run*2))
  end
  row("vsum", string.format("$%04X", bestAt or 0), best, best*2,
      string.format("가장 큰 빈 구간 $%04X · %d 워드 = %d B (필요 576 B)", bestAt or 0, best, best*2))
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not dumpedKeys and frame == 120 then
    dumpedKeys = true
    dumpKeys(s)
  end
  if SHOTS[frame] then
    local base = satbAddr or SAT_FALLBACK
    row("shot", string.format("$%04X", base), satbAddr and "실측" or "기본값", "",
        "SATB 주소")
    dumpSAT(base)
    vramMap()
  end
  if dirty then file:flush(); dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- 프레임 %d · 총 %d 행\n", frame, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 오프닝 스프라이트 0.1.0 -- 자막 POC 의 VRAM·SAT 예산을 잰다")
emu.log("  오프닝을 끝까지 두고 Stop")
emu.log("  key 행    = getState 의 VDC 관련 키 (SATB 주소를 어디서 얻나)")
emu.log("  satsum 행 = SAT 64 개 중 몇 개가 비어 있나 (자막에 16 개 필요)")
emu.log("  vsum 행   = VRAM 최대 빈 구간 (패턴 576 B 를 놓을 자리)")
emu.log("  출력: " .. OUT)
