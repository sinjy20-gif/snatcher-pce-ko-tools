-- PROBE 아레나 0.1.3 -- 스크립트 VM 데이터 스택의 최대 깊이 (찢어짐 제거판)
--
-- 0.1.2 에서 바뀐 것 -- ★ 측정이 틀렸다
-- ---------------------------------------------------------------------------
-- 0.1.2 는 $2025/$2026 을 **따로 읽었다.**  그런데 포인터 갱신은
--
--     LDA $25 / CLC / ADC #$01 / STA $25     <- 하위 먼저
--     LDA $26 / ADC #$00       / STA $26     <- 상위 나중
--
-- 두 명령으로 나뉜다.  그 사이에 읽으면 (새 하위 + 옛 상위) 라는 있지도 않은
-- 주소가 나온다.  0.1.2 로그의
--
--     BASE lowered to $5B01 / $5B00     스택 바닥 $5B80 아래.  불가능하다
--     $5D09 -> $5DFF 한 걸음에 246 B    스택이 그렇게 뛸 리 없다
--
-- 이 둘이 그 증거다.  그래서 "LEFT 65 B" 는 믿을 수 없다.
--
-- 이 판은 **쓰기 콜백이 넘겨주는 값 자체**를 상위 바이트로 쓴다.  상위가
-- 쓰이는 순간 하위는 이미 갱신돼 있으므로, 이 조합만이 항상 정합한다.
-- 프레임 폴링은 찢어짐의 출처라 **peak 판정에서 뺐다.**
--
-- 무엇을 재는 것인가 (2026-08-20 에 정정된 이해)
-- ---------------------------------------------------------------------------
-- $25/$26 은 범프 할당기가 아니라 **스크립트 VM 의 데이터 스택 포인터**다.
--
--     $8D7A  push       PHA / ptr+1 / PLA / STA ($25)
--     $8D8B  push X     PHA / ptr+1 / PLA / TXA / STA ($25)
--     $8D9E  pop X      LDA ($25) / PHA / ptr-1 / PLA / TAX
--     $8DB0  pop        LDA ($25) / PHA / ptr-1 / PLA
--
-- $4880 이 바닥을 깔고(우리 판은 $5B80), 푸시하면 올라가고 팝하면 내려간다.
-- $8203 의 LDA $25 / SBC #$N / STA ($7E) 는 할당이 아니라 스택 프레임의
-- 지역변수 접근이다.  따라서 PEAK 는 "할당량" 이 아니라 **최대 스택 깊이**다.
--
-- 위험 조건은 그대로다: 포인터가 $5E40 을 넘으면 프리로더 첫 바이트가 죽는다.
-- 쇼핑 크래시 때 실측값이 $5E43 이었다.
--
-- 새 최고 깊이가 나오면 호출자 PC 와 씬 뱅크(MPR4/5/6)도 같이 찍는다.
-- 어느 화면이 깊이 파는지 로그만 보고 알 수 있게 하기 위해서다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   빌드: build\\patch\\0.4.5.3
--   수집기와 동시에 켜도 된다.  ★ 전원 투입부터.
--   출력: C:\\snatcher\\dump\\probe_arena_0_1_3.tsv

local OUT = "C:\\snatcher\\dump\\probe_arena_0_1_3.tsv"
local mem = emu.memType.pceMemory

local PTR_LO  = 0x2025
local PTR_HI  = 0x2026
local FLOOR   = 0x5B80       -- $4880 이 깐 바닥.  고정이다.  내리지 않는다
local PRELOAD = 0x5E40       -- 프리로더 첫 바이트.  넘으면 죽는다
local STACK   = 0x2100
local WARN    = 64

local file = assert(io.open(OUT, "w"))
file:write("frame\ttop\tdepth\tgap\tcaller\tmpr4\tmpr5\tmpr6\n")

local frame, peak, dirty, warned = 0, 0, false, false

local function byte(a) return emu.read(a, mem) or 0 end

local function context()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return 0, 0, 0, 0 end
  local sp = s["cpu.sp"] or 0
  local caller = (byte(STACK + ((sp + 2) % 256)) * 256
                  + byte(STACK + ((sp + 1) % 256)) + 1) % 0x10000
  return caller, s["memoryManager.mpr[4]"] or 0,
                 s["memoryManager.mpr[5]"] or 0,
                 s["memoryManager.mpr[6]"] or 0
end

-- ★ value = 지금 $2026 에 쓰이는 상위 바이트.  하위는 이미 갱신돼 있다.
--   이 조합만 항상 정합하다.  따로 읽으면 찢어진다.
emu.addMemoryCallback(function(address, value)
  local top = (value % 256) * 256 + byte(PTR_LO)
  if top <= peak then return end
  peak = top
  local depth, gap = top - FLOOR, PRELOAD - top
  local caller, m4, m5, m6 = context()
  file:write(string.format("%d\t%04X\t%d\t%d\t%04X\t%02X\t%02X\t%02X\n",
    frame, top, depth, gap, caller, m4, m5, m6))
  dirty = true
  emu.log(string.format("PEAK $%04X  depth %4d B  LEFT %4d B  caller $%04X  mpr4/5/6 %02X %02X %02X  frame %d",
    top, depth, gap, caller, m4, m5, m6, frame))
  if gap <= WARN and not warned then
    warned = true
    emu.log("  *** WARNING: " .. gap .. " B namassda.  jigeum hwamyeoni eodiinji jeogeojusipsio ***")
  end
  if gap <= 0 then
    emu.log("  *** STACK REACHED $5E40 -- preloader is being destroyed right now ***")
  end
end, emu.callbackType.write, PTR_HI, PTR_HI, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("\n-- 최고 깊이 $%04X · 바닥 $%04X · 깊이 %d B · 프레임 %d\n",
    peak, FLOOR, peak - FLOOR, frame))
  file:write(string.format("-- 프리로더 $5E40 까지 남은 여유 %d B\n", PRELOAD - peak))
  if peak == 0 then
    file:write("-- panjeong bulga: 0 gon = $2026 sseugi ga han beonto an japhyeossda\n")
  elseif peak >= PRELOAD then
    file:write("-- 판정: ★ 스택이 프리로더에 닿는다.  bank $68 밖으로 빼야 한다 (§15.9)\n")
  elseif PRELOAD - peak <= WARN then
    file:write("-- 판정: ★ 여유가 64 B 이하다.  화면 하나 차이다.  §15.9 로 가야 한다\n")
  else
    file:write("-- 판정: 여유가 있다.  단 돌아본 범위 안에서만 참이다\n")
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE areana 0.1.3 -- script VM data stack choedae gipi (tearing jegeo)")
emu.log("  0.1.2 ui $5B00/$5B01/$5DFF neun jjijeojin gapsieossda.  i pani jeonghwakhada")
emu.log("  chulryeok: " .. OUT)
