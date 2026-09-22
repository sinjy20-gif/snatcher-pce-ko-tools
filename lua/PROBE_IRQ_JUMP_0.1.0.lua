-- PROBE IRQ점프 0.1.0 -- 폭주로 뛰는 그 JMP 를 현행범으로 잡는다
--
-- 여기까지 온 경위 (2026-08-19, 조이 디비전 쇼핑하기 진행불가)
-- ---------------------------------------------------------------------------
--   원본 디스크        정상        -> 우리 것이 맞다
--   BIOS 무관          JP 원본 BIOS 로도 죽는다
--   0.3.9 도 죽는다     오늘 작업(BIOS 폰트 전환) 전체가 무관.  더 오래된 층이다
--   사망 형태          PC 가 I/O 페이지($0005 · $0041)로 뛴 뒤 BRK 루프
--
--   PROBE_BADPTR_0.1.0 결과: $2200(IRQ2 점프벡터)이 0 으로 덮이는 것을 잡았지만
--   **그 쓰기의 PC 가 이미 $0005 였다** -- 폭주한 CPU 가 미는 것이라 결과다.
--
-- 그래서 무엇을 잡나
-- ---------------------------------------------------------------------------
-- BIOS 의 CD 인터럽트 핸들러가 이렇게 생겼다:
--
--     $FFF6 (IRQ2 벡터) -> $E736  BBS0 $F5,$E733
--                          $E733  JMP ($2200)     ← 게임이 후킹한 자리로 점프
--                          $E739  PHA ...          (게임 훅이 없을 때의 기본 경로)
--
-- `$E733` 을 지나는 순간의 **$2200 값**이 곧 점프 목적지다.  그 값이 $2000 미만이면
-- 그 JMP 가 곧 폭주다.  현행범으로 잡는다.
--
-- 같이 남기는 것
--   그 순간의 $F5(분기 플래그) · 스택 · MPR · 직전 20 건의 목적지 이력
--   -> "언제부터 목적지가 이상해졌는지" 가 보인다
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   아무 빌드나 (0.3.9 도 죽는다).  조이 디비전 -> 쇼핑하기.
--   출력: C:\snatcher\dump\probe_irq_jump_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_irq_jump_0_1_0.tsv"
local mem = emu.memType.pceMemory

local JMP_SITE = 0xE733      -- JMP ($2200)
local IRQ2_ENTRY = 0xE736    -- IRQ2 벡터 목적지
local VEC = 0x2200
local ZP = 0x2000

local RING = 20
local ring, ringPos = {}, 0
local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\ttarget\tf5\tsp\tmpr3\tflag\tnote\n")

local frame, hits, entries, fired, dirty = 0, 0, 0, false, false

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end
local function cpu()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function row(kind, target, flag, note)
  local s = cpu()
  file:write(string.format("%s\t%d\t%04X\t%02X\t%02X\t%02X\t%s\t%s\n",
    kind, frame, target or 0, byte(ZP + 0xF5),
    s and s["cpu.sp"] or 0,
    s and s["memoryManager.mpr[3]"] or 0, flag or "", note or ""))
  dirty = true
  return s
end

-- IRQ2 진입 자체를 센다 (게임 훅이 도는지 확인용)
emu.addMemoryCallback(function()
  entries = entries + 1
end, emu.callbackType.exec, IRQ2_ENTRY, IRQ2_ENTRY, emu.cpuType.pce, mem)

-- ★ JMP ($2200) 을 지나는 순간.  그때의 $2200 이 목적지다
emu.addMemoryCallback(function()
  hits = hits + 1
  local target = word(VEC)
  ringPos = ringPos % RING + 1
  ring[ringPos] = { frame = frame, target = target, n = hits }

  local bad = target < 0x2000
  if bad and not fired then
    fired = true
    local s = row("★현행범", target, "폭주", "이 JMP 가 I/O 페이지로 뛴다")
    if s then
      local sp = s["cpu.sp"] or 0
      local st = {}
      for k = 1, 20 do st[#st + 1] = string.format("%02X", byte(0x2100 + ((sp + k) % 256))) end
      file:write("-- 스택(SP+1..20B): " .. table.concat(st, " ") .. "\n")
      local mpr = {}
      for i = 0, 7 do
        mpr[#mpr + 1] = string.format("%02X", s[string.format("memoryManager.mpr[%d]", i)] or 0)
      end
      file:write("-- MPR " .. table.concat(mpr, " ") .. "\n")
    end
    file:write("\n-- 직전 목적지 이력 (오래된 것부터)\n")
    for i = 1, RING do
      local e = ring[(ringPos + i - 1) % RING + 1]
      if e then file:write(string.format("--   #%d f%d -> $%04X\n", e.n, e.frame, e.target)) end
    end
    file:write("\n")
    dirty = true
  end
end, emu.callbackType.exec, JMP_SITE, JMP_SITE, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("IRQ점프 감시 · JMP %d 회 · IRQ2 %d 회", hits, entries),
    0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, string.format("현재 목적지 $%04X %s", word(VEC),
    fired and "★잡음" or ""), fired and 0xFF6060 or 0xC0C0C0, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("\n-- JMP ($2200) %d 회 · IRQ2 진입 %d 회 · 마지막 목적지 $%04X\n",
    hits, entries, word(VEC)))
  if hits == 0 then
    file:write("-- ※ JMP ($2200) 을 한 번도 안 지났다.  게임이 $F5 비트0 을 안 세워\n")
    file:write("--   BIOS 기본 경로($E739)로만 갔다는 뜻 -> 폭주는 다른 데서 온다\n")
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE IRQ점프 0.1.0 -- JMP ($2200) 의 목적지를 현행범으로 잡는다")
emu.log("  목적지가 $2000 미만이 되는 순간 스택·MPR·직전 이력을 남긴다")
emu.log("  출력: " .. OUT)
