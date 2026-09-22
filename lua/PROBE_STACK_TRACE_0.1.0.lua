-- PROBE 스택추적 0.1.0 -- 폭주 직전의 **호출 사슬**을 순서대로 잡는다
--
-- 여기까지 (2026-08-19, 조이 디비전 쇼핑하기 진행불가)
-- ---------------------------------------------------------------------------
--   원본 디스크 정상 · BIOS 무관 · 0.3.9 도 죽음 -> 오늘 작업 전체 무관
--   사망 형태: PC 가 I/O 페이지($0005 · $0041)로 튄 뒤 **BRK 무한루프**
--              (HuC6280 은 BRK 가 IRQ2 벡터를 쓴다.  IRQ2 진입 236,274 회가 그 루프다)
--   기각: CD IRQ 마스크 · $2200 벡터 오염 · JMP($2200) 경로(0 회) · 레코드 손상
--   남은 질문: **최초로 튄 그 점프가 어디서 왔는가**
--
-- 왜 스택 "쓰기" 인가
-- ---------------------------------------------------------------------------
-- 지금까지는 폭주한 뒤에 스택을 **읽었다**.  그런데 BRK 루프가 계속 PC·상태를
-- 밀어 넣어서 원래 내용이 이미 0 으로 덮여 있었다 (실측: 24 바이트 전부 00).
--
-- 밀어 넣는 순간을 잡으면 안 덮인다.  그리고 **JSR 이 밀어 넣는 값이 곧
-- 복귀주소**라, 주소와 값만 적으면 호출 사슬이 복원된다 -- `emu.getState()` 를
-- 안 불러도 되므로 매 스택 쓰기마다 걸어도 느리지 않다.
--
--     JSR 은 PCH 를 먼저, PCL 을 다음에 민다 (주소가 하나씩 내려간다)
--     그래서 (높은주소=PCH, 낮은주소=PCL) 짝이 복귀주소 -1 이다
--
-- 언제 쏟나
-- ---------------------------------------------------------------------------
--   CPU 가 $0000-$1FFF 를 실행하는 첫 순간 (= 폭주 시작).  그때의 링 버퍼가
--   **폭주 직전 64 번의 푸시**이고, 뒤에서부터 읽으면 호출 사슬이다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   아무 빌드나.  조이 디비전 -> 쇼핑하기.  멈추면 파일이 이미 생겨 있다.
--   출력: C:\snatcher\dump\probe_stack_trace_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_stack_trace_0_1_0.tsv"
local mem = emu.memType.pceMemory

local STACK_LO, STACK_HI = 0x2100, 0x21FF   -- MPR1=$F8 이라 스택 페이지가 여기다
local RING = 64
local BOOT_GRACE = 180

local ring, ringPos, pushes = {}, 0, 0
local frame, fired = 0, false

-- 값만 담는다.  getState 를 안 부르는 것이 이 프로브의 요점이다.
local function push(addr, value)
  ringPos = ringPos % RING + 1
  pushes = pushes + 1
  local e = ring[ringPos]
  if e == nil then e = {}; ring[ringPos] = e end
  e.n, e.frame, e.addr, e.value = pushes, frame, addr, value
end

emu.addMemoryCallback(function(address, value)
  push(address, value)
end, emu.callbackType.write, STACK_LO, STACK_HI, emu.cpuType.pce, mem)

local function byte(a) return emu.read(a, mem) or 0 end

local function dump(reason)
  if fired then return end
  fired = true
  local file = io.open(OUT, "w")
  if file == nil then return end
  file:write("-- 스택추적 0.1.0 · 사유: " .. reason .. "\n")
  file:write(string.format("-- 프레임 %d · 총 푸시 %d\n", frame, pushes))
  local ok, s = pcall(emu.getState)
  if ok and s then
    local mpr = {}
    for i = 0, 7 do
      mpr[#mpr + 1] = string.format("%02X", s[string.format("memoryManager.mpr[%d]", i)] or 0)
    end
    file:write(string.format("-- 폭주 PC $%04X · SP $%02X · MPR %s\n",
      s["cpu.pc"] or 0, s["cpu.sp"] or 0, table.concat(mpr, " ")))
  end

  -- 시간 순으로 나열한다 (오래된 것 먼저).  마지막 몇 줄이 죽기 직전이다.
  file:write("\nn\tframe\taddr\tvalue\n")
  local seq = {}
  for i = 1, RING do
    local e = ring[(ringPos + i - 1) % RING + 1]
    if e and e.n then
      seq[#seq + 1] = e
      file:write(string.format("%d\t%d\t%04X\t%02X\n", e.n, e.frame, e.addr, e.value))
    end
  end

  -- 짝 지어 복귀주소로 복원한다.  JSR: PCH 를 높은 주소에, PCL 을 그 아래에 민다.
  file:write("\n-- 복귀주소 복원 (PCH/PCL 이 이어진 쌍만).  +1 이 실제 복귀 지점\n")
  for i = 1, #seq - 1 do
    local a, b = seq[i], seq[i + 1]
    if a.addr == b.addr + 1 then
      local target = a.value * 256 + b.value
      file:write(string.format("--   #%d f%d  $%04X  (복귀 $%04X)\n",
        a.n, a.frame, target, (target + 1) % 0x10000))
    end
  end
  file:write("\n")
  file:close()
  emu.log("★ 스택추적 덤프 (" .. reason .. ") -> " .. OUT)
end

-- 폭주 첫 순간
emu.addMemoryCallback(function()
  if frame > BOOT_GRACE then dump("폭주 -- I/O 페이지 실행") end
end, emu.callbackType.exec, 0x0000, 0x1FFF, emu.cpuType.pce, mem)

-- 수동 백업 (키 이름은 찔러보고 고른다)
local DUMP_KEYS = { "E", "e", "KeyE", "D", "Q", "R", "T" }
local dumpKey = nil
for _, name in ipairs(DUMP_KEYS) do
  local ok, v = pcall(function() return emu.isKeyPressed(name) end)
  if ok and type(v) == "boolean" then dumpKey = name break end
end

local held = false
emu.addEventCallback(function()
  frame = frame + 1
  if dumpKey then
    local ok, down = pcall(function() return emu.isKeyPressed(dumpKey) end)
    down = ok and down == true
    if down and not held then dump("수동 (" .. dumpKey .. ")") end
    held = down
  end
  emu.drawString(4, 4, string.format("스택추적 · 푸시 %d %s", pushes,
    fired and "· ★잡음" or ""), fired and 0xFF6060 or 0x80FF80, 0x80000000, 1)
  if dumpKey and not fired then
    emu.drawString(4, 14, "안 잡히면 " .. dumpKey .. " 를 누르세요", 0xFFFF80, 0x80000000, 1)
  end
end, emu.eventType.endFrame)

emu.log("PROBE 스택추적 0.1.0 -- 폭주 직전 64 번의 스택 푸시를 잡는다")
emu.log("  JSR 이 미는 값이 곧 복귀주소다.  getState 를 안 불러 느리지 않다")
emu.log("  출력: " .. OUT)
