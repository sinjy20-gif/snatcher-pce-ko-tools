-- PROBE 캐시충돌 0.1.0 -- **게임이 우리 캐시 영역을 읽는가**
--
-- 지금까지 묻은 가설 (2026-08-19, 조이 디비전 쇼핑하기 진행불가)
-- ---------------------------------------------------------------------------
--   원본 디스크 정상            -> 우리 것
--   JP 원본 BIOS 로도 죽음       -> BIOS·글리프 무관
--   0.3.9 도 죽음               -> 오늘 작업 전체 무관
--   벽 안 눌러도 죽음            -> 조건부 UI 확장 무관
--   JMP($2200) 0 회             -> IRQ2 훅 벡터 무관 ($2200 오염은 폭주의 결과)
--   FAILED★ 0 회                -> 조회 실패 경로 무관
--   뱅크창 인터럽트 5회 -> 0회    -> 보호는 먹었으나 **여전히 죽음**.  이것도 무관
--
--   남은 사실: 죽는 순간 렌더러 원문 포인터가 $A001 이고(정상은 $34xx/$36xx),
--             우리 프리로더는 그것을 정상적으로 **거부하고 빠져나왔다**.
--             그 직후 CPU 가 I/O 페이지로 뛴다.
--
-- 이번 가설 -- 메모리 충돌
-- ---------------------------------------------------------------------------
-- 우리 캐시는 $5B80-$5E3F 다.  프리로더 주석이 스스로 경고한다:
--
--     A failed open-addressing lookup still overwrites $5B80-$5E3F
--
-- 상점 화면이 그 영역을 **자기 용도로** 쓰고 있다면, 우리가 덮어쓴 뒤 게임이
-- 거기서 포인터를 읽어 $A001 같은 쓰레기를 얻는 그림이 성립한다.
--
-- 어떻게 가리나
-- ---------------------------------------------------------------------------
-- $5B80-$5E3F 를 **읽는** 주체를 우리와 게임으로 나눈다.  PC 를 매번 읽으면
-- 느리므로(캐시 읽기는 잦다) 우리 코드 구간 진입/이탈에 훅을 걸어 Lua 플래그로
-- 표시하고, 플래그가 꺼져 있을 때의 읽기를 "게임이 읽었다" 로 센다.
--
--     우리 것으로 치는 구간
--       $5E40-$5FFF  프리로더      (진입 $5E40 · 이탈 $5FE6 done)
--       $7F88-$7F9B  트램펄린      (진입 $7F88 · 이탈 $7F9B RTS)
--       헬퍼는 트램펄린 안에서만 돈다
--
-- 게임 읽기가 0 이면 이 가설도 기각이다.  0 이 아니면 **어느 주소를 읽는지**가
-- 다음 단서가 된다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   조이 디비전 -> 쇼핑하기.  죽으면 파일이 이미 생겨 있다.
--   출력: C:\snatcher\dump\probe_cache_share_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_cache_share_0_1_0.tsv"
local mem = emu.memType.pceMemory

local CACHE_LO, CACHE_HI = 0x5B80, 0x5E3F
local PRELOAD_IN, PRELOAD_OUT = 0x5E40, 0x5FE6
local TRAMP_IN, TRAMP_OUT = 0x7F88, 0x7F9B

local RING, BOOT_GRACE = 60, 180
local ring, ringPos = {}, 0
local frame, ours, theirs, fired = 0, 0, 0, false
local inOurs = 0

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\taddr\tn\tnote\n")
local dirty = false

local function enter() inOurs = inOurs + 1 end
local function leave() if inOurs > 0 then inOurs = inOurs - 1 end end

emu.addMemoryCallback(enter, emu.callbackType.exec, PRELOAD_IN, PRELOAD_IN, emu.cpuType.pce, mem)
emu.addMemoryCallback(leave, emu.callbackType.exec, PRELOAD_OUT, PRELOAD_OUT, emu.cpuType.pce, mem)
emu.addMemoryCallback(enter, emu.callbackType.exec, TRAMP_IN, TRAMP_IN, emu.cpuType.pce, mem)
emu.addMemoryCallback(leave, emu.callbackType.exec, TRAMP_OUT, TRAMP_OUT, emu.cpuType.pce, mem)

emu.addMemoryCallback(function(address)
  if inOurs > 0 then
    ours = ours + 1
    return
  end
  theirs = theirs + 1
  ringPos = ringPos % RING + 1
  local e = ring[ringPos]
  if e == nil then e = {}; ring[ringPos] = e end
  e.n, e.frame, e.addr = theirs, frame, address
end, emu.callbackType.read, CACHE_LO, CACHE_HI, emu.cpuType.pce, mem)

local function dump(reason)
  if fired then return end
  fired = true
  file:write(string.format("-- 사유: %s · 프레임 %d\n", reason, frame))
  file:write(string.format("-- 캐시 읽기: 우리 %d · **게임 %d**\n\n", ours, theirs))
  local ok, s = pcall(emu.getState)
  if ok and s then
    file:write(string.format("-- 폭주 PC $%04X · SP $%02X\n\n", s["cpu.pc"] or 0, s["cpu.sp"] or 0))
  end
  file:write("n\tframe\taddr\n")
  for i = 1, RING do
    local e = ring[(ringPos + i - 1) % RING + 1]
    if e and e.n then
      file:write(string.format("%d\t%d\t%04X\n", e.n, e.frame, e.addr))
    end
  end
  file:flush()
  emu.log("★ 캐시충돌 덤프 (" .. reason .. ") · 게임 읽기 " .. theirs .. " 회")
end

emu.addMemoryCallback(function()
  if frame > BOOT_GRACE then dump("폭주 -- I/O 페이지 실행") end
end, emu.callbackType.exec, 0x0000, 0x1FFF, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("캐시 읽기 · 우리 %d · 게임 %d", ours, theirs),
    theirs > 0 and 0xFF6060 or 0x80FF80, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not fired then
    file:write(string.format("\n-- 정지 시점 · 캐시 읽기: 우리 %d · 게임 %d\n", ours, theirs))
    if theirs == 0 then
      file:write("-- 판정: 게임은 우리 캐시를 안 읽는다.  메모리 충돌 가설 기각\n")
    else
      file:write("-- 판정: 게임이 우리 캐시를 읽는다.  주소 목록이 단서다\n")
    end
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 캐시충돌 0.1.0 -- 게임이 $5B80-$5E3F 를 읽는지 센다")
emu.log("  화면의 '게임 N' 이 0 이 아니면 우리 캐시와 겹쳐 쓰고 있는 것")
emu.log("  출력: " .. OUT)
