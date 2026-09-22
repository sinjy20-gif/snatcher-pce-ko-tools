-- PROBE 나쁜포인터 0.1.0 -- **쓰레기 값을 넣은 놈**을 직접 잡는다
--
-- 왜 가설 소거를 그만두나
-- ---------------------------------------------------------------------------
-- 빌드를 갈아끼우며 좁힌 결과는 여기까지다 (2026-08-19, 조이 디비전 쇼핑하기):
--
--     원본 디스크 + JP BIOS      정상
--     0.4.5.1  + JP BIOS         죽음   -> BIOS/글리프 무관
--     0.4.5.1  + 우리 BIOS       죽음
--     0.3.9    (BIOS 이전 판)     죽음   -> 오늘 작업 전체 무관.  더 오래된 층이다
--
-- "언제부터"는 알아냈지만 "누가"는 못 알아냈다.  이제 값을 오염시킨 쓰기를
-- 직접 잡는다.
--
-- 무엇을 감시하나 -- 폭주로 이어질 수 있는 두 자리
-- ---------------------------------------------------------------------------
--   $2200/$2201   BIOS IRQ2 핸들러가 `$E733 JMP ($2200)` 로 **여기 값으로 점프**한다.
--                 오염되면 그 즉시 폭주다.  실측 폭주 PC 가 $0005 · $0041 처럼
--                 작은 값이었던 것과 앞뒤가 맞는다
--   $3471/$3472   렌더러 원문 포인터.  프리로더가 진입하자마자 $03/$04 로 읽어온다.
--                 폭주 시점에 $03/$04 = $A001 이었다 -- 정상이면 $36xx/$34xx 다
--
-- 각 쓰기마다 **누가 썼는지(PC)** 와 값, 그때의 뱅크를 남긴다.
-- 값이 이상해지는 순간(하이바이트가 $34/$36 이 아니거나, $2200 이 $2000 미만)에는
-- ★ 표시를 달고 스택까지 뜬다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   어느 빌드로 해도 된다 (0.3.9 도 죽으므로).  조이 디비전 -> 쇼핑하기.
--   출력: C:\snatcher\dump\probe_badptr_0_1_0.tsv
--
--   ※ 쓰기가 잦으면 파일이 커진다.  그래서 **값이 바뀔 때만** 기록한다.

local OUT = "C:\\snatcher\\dump\\probe_badptr_0_1_0.tsv"
local mem = emu.memType.pceMemory

local VEC_LO, VEC_HI = 0x2200, 0x2201       -- BIOS IRQ2 가 JMP ($2200)
local PTR_LO, PTR_HI = 0x3471, 0x3472       -- 렌더러 원문 포인터
local ZP = 0x2000

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\taddr\tvalue\tword\tpc\tbank\tflag\tnote\n")

local frame, rows = 0, 0
local lastVec, lastPtr = -1, -1
local dirty = false

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end
local function cpu()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function row(kind, addr, value, w, flag, note)
  local s = cpu()
  local pc = s and s["cpu.pc"] or 0
  local bank = 0
  if s and pc then
    local slot = math.floor(pc / 0x2000)
    bank = s[string.format("memoryManager.mpr[%d]", slot)] or 0
  end
  rows = rows + 1
  file:write(string.format("%s\t%d\t%04X\t%02X\t%04X\t%04X\t%02X\t%s\t%s\n",
    kind, frame, addr, value, w, pc, bank, flag or "", note or ""))
  dirty = true
  return pc, s
end

local function stackDump(s)
  if s == nil then return end
  local sp = s["cpu.sp"] or 0
  local st = {}
  for k = 1, 20 do st[#st + 1] = string.format("%02X", byte(0x2100 + ((sp + k) % 256))) end
  file:write("-- 스택(SP+1..20B): " .. table.concat(st, " ") .. "\n")
  dirty = true
end

-- IRQ2 점프 벡터
for _, a in ipairs({ VEC_LO, VEC_HI }) do
  emu.addMemoryCallback(function(address, value)
    local w = (address == VEC_LO) and (value + byte(VEC_HI) * 256)
                                  or (byte(VEC_LO) + value * 256)
    if w == lastVec then return end
    lastVec = w
    -- $2000 미만이면 I/O 페이지로 점프하게 된다 = 즉사
    local bad = (w < 0x2000)
    local pc, s = row("vec", address, value, w, bad and "★위험" or "",
      bad and "IRQ2 가 여기로 점프하면 폭주다" or "")
    if bad then stackDump(s) end
  end, emu.callbackType.write, a, a, emu.cpuType.pce, mem)
end

-- 렌더러 원문 포인터
for _, a in ipairs({ PTR_LO, PTR_HI }) do
  emu.addMemoryCallback(function(address, value)
    local w = (address == PTR_LO) and (value + byte(PTR_HI) * 256)
                                  or (byte(PTR_LO) + value * 256)
    if w == lastPtr then return end
    lastPtr = w
    local hi = math.floor(w / 256)
    local bad = not (hi == 0x34 or hi == 0x36)
    local pc, s = row("ptr", address, value, w, bad and "★이상" or "",
      bad and "정상은 $34xx/$36xx" or "")
    if bad then stackDump(s) end
  end, emu.callbackType.write, a, a, emu.cpuType.pce, mem)
end

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("나쁜포인터 감시 · 기록 %d", rows), 0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, string.format("IRQ2벡터 $%04X · 원문포인터 $%04X",
    word(VEC_LO), word(PTR_LO)), 0xC0C0C0, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("\n-- 총 %d 행 · 마지막 IRQ2벡터 $%04X · 마지막 원문포인터 $%04X\n",
    rows, word(VEC_LO), word(PTR_LO)))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 나쁜포인터 0.1.0 -- 값을 오염시킨 쓰기의 PC 를 잡는다")
emu.log("  $2200(IRQ2 점프벡터) · $3471(렌더러 원문 포인터) 감시")
emu.log("  ★ 표시가 붙은 줄이 범인 후보다.  그 줄의 pc/bank 를 보면 된다")
emu.log("  출력: " .. OUT)
