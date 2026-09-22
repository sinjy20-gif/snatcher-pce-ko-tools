-- PROBE 가나폰트 0.1.3 -- 글리프가 **BIOS 폰트인가 게임 데이터인가**
--
-- 0.1.2 가 남긴 의문
-- ---------------------------------------------------------------------------
-- $69C2 진입 후 64 개 읽기를 떴는데 $8000-$DFFF (게임 데이터 뱅크 74/75/76) 읽기가
-- **0 건**이었다.  전부 $6xxx 코드 페치와 제로페이지였다.
--
-- 그렇다면 글리프가 게임 데이터에 없을 수 있다.  후보는 시스템 카드의 BIOS 폰트다 --
-- §8-N 이 이미 `$E060 (EX_GETFNT)` 를 언급해 뒀다.
--
-- **이 구분이 프로젝트의 갈림길이다.**
--
--   BIOS 폰트라면      글리프가 시스템 카드 ROM 에 있다.  디스크로 못 고친다.
--                     -> 가나 그림 갈아끼우기 불가.  다른 길을 찾아야 한다
--   게임 데이터라면    디스크에 있다.  그림만 바꾸면 코드 수정 0 으로 끝난다
--
-- 무엇을 잡나
-- ---------------------------------------------------------------------------
--   bios    $E060 (EX_GETFNT) 진입.  이것이 찍히면 BIOS 폰트다.  결론 확정
--   biosjsr $E000-$FFFF 어디로든 들어가는 실행.  EX_GETFNT 말고 다른 진입점 대비
--   read    $8000-$FFFF 읽기만.  코드 페치가 아닌 데이터가 어디서 오는지
--           (0.1.2 는 $6xxx 코드 페치에 예산을 다 썼다)
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   인명검색 자판에서 키를 몇 개 누르거나, 일본어 대사가 나오는 아무 장면이나.
--   5 초면 충분하다.  그 다음 Stop.
--   **bios 행이 하나라도 있으면 그것으로 답이 난 것이다.**

local OUT = "C:\\snatcher\\dump\\probe_kana_font_bios.tsv"
local mem = emu.memType.pceMemory

local FONT_ENTRY = 0x69C2
local EX_GETFNT  = 0xE060
local ZP         = 0x2000
local READS_MAX  = 300
local SAMPLES_MAX = 8

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tchar\tseq\taddr\tvalue\tmpr\tnote\n")

local frame, rows, dirty = 0, 0, false
local arming, readsSeen, curChar, samples = false, 0, "", 0
local seen = {}
local biosHits = 0

local function byte(a) return emu.read(a, mem) or 0 end

local function mprText()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return "-" end
  local out = {}
  for slot = 0, 7 do
    local v = s[string.format("memoryManager.mpr[%d]", slot)]
    if v == nil then v = s[string.format("mpr[%d]", slot)] end
    out[#out + 1] = string.format("%02X", v or 0)
  end
  return table.concat(out, " ")
end

local function row(kind, ch, seq, addr, value, mpr, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%s\t%d\t%04X\t%02X\t%s\t%s\n",
    kind, frame, ch or "", seq or 0, addr or 0, value or 0, mpr or "", note or ""))
  dirty = true
end

-- ★ 결정적 훅.  BIOS 폰트 루틴에 들어가는가
emu.addMemoryCallback(function()
  biosHits = biosHits + 1
  if biosHits <= 20 then
    row("bios", curChar, biosHits, EX_GETFNT, 0, mprText(),
        "EX_GETFNT 진입 -- 글리프가 시스템 카드 ROM 에 있다는 뜻")
  end
end, emu.callbackType.exec, EX_GETFNT, EX_GETFNT, emu.cpuType.pce, mem)

-- 데이터 읽기.  코드 페치가 몰리는 $6xxx 는 아예 안 본다.
emu.addMemoryCallback(function(address, value)
  if not arming then return end
  readsSeen = readsSeen + 1
  row("read", curChar, readsSeen, address, value, "", "")
  if readsSeen >= READS_MAX then arming = false end
end, emu.callbackType.read, 0x8000, 0xFFFF, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  if samples >= SAMPLES_MAX then return end
  local key = string.format("%02X %02X", byte(ZP + 0xF9), byte(ZP + 0xF8))
  if seen[key] then return end
  seen[key] = true
  samples = samples + 1
  curChar = key
  readsSeen = 0
  arming = true
  row("enter", key, 0, FONT_ENTRY, 0, mprText(), "$69C2 진입")
end, emu.callbackType.exec, FONT_ENTRY, FONT_ENTRY, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush(); dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  row("summary", "", biosHits, 0, 0, "",
      biosHits > 0
        and "EX_GETFNT 가 불렸다 -> BIOS 폰트.  디스크로 글리프를 못 고친다"
        or  "EX_GETFNT 가 한 번도 안 불렸다 -> 글리프는 게임 쪽에 있다")
  file:write(string.format("-- 표본 %d 문자 · BIOS 진입 %d 회 · 총 %d 행\n",
    samples, biosHits, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 가나폰트 0.1.3 -- 글리프가 BIOS 폰트인가 게임 데이터인가")
emu.log("  자판이든 일본어 대사든 5 초면 충분.  Stop 하면 summary 가 답을 준다")
emu.log("  bios 행이 하나라도 찍히면 시스템 카드 ROM 이라는 뜻이다")
emu.log("  출력: " .. OUT)
