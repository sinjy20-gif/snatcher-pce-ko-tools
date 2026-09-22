-- PROBE 크래시감시 0.1.4 -- 조이 디비전 "쇼핑하기" 즉시 정지를 잡는다
--
-- 0.1.0 이 왜 실패했나
-- ---------------------------------------------------------------------------
-- RESET 벡터에 훅을 걸어놨는데 **부팅 자체가 리셋 벡터를 탄다.**  그래서 켜자마자
-- 프레임 0 · 기록 0 으로 덤프가 나가버리고, `fired` 플래그 때문에 정작 멈췄을 때는
-- 아무것도 안 남았다.
--
--     -- 사유: RESET 벡터 진입 / 프레임 0 · 총 기록 0 / PC $E0F3 · SP $00
--
-- $E0F3 은 RESET 벡터의 목적지다 (BIOS 부팅 진입).  즉 "게임이 죽어서"가 아니라
-- "게임이 시작해서" 찍힌 것이다.
--
-- 0.1.4 에서 바꾼 것
-- ---------------------------------------------------------------------------
--   1. 부팅 무시    프레임 180(3초) 이전의 리셋은 안 찍는다
--   2. 수동 덤프    **F1 을 누르면 그 순간 링 버퍼를 쏟는다**
--                   이번 증상은 리셋이 아니라 **정지**라 자동 감지가 안 걸릴 수 있다.
--                   화면이 멈추면 F6 을 누르면 된다
--   3. 여러 번 가능  덤프해도 계속 돈다.  누를 때마다 파일이 갱신된다
--   4. IRQ 상태 기록 이번 건의 핵심이다.  세이브스테이트에서 이렇게 나왔다:
--                     activeIrqs $1C · enabledIrqs $00  -> CD 인터럽트가 떠 있는데
--                     전부 마스크됨.  게임이 영원히 안 깨어난다
--                   $1802(허용) · $1803(상태) 를 매 기록마다 같이 남긴다
--
-- 무엇을 남기나
-- ---------------------------------------------------------------------------
--   최근 40 건의 헬퍼/프리로더 통과 지점과 그때의 슬롯·레코드 주소·PC·SP,
--   그리고 CD IRQ 레지스터.  멈추기 직전에 **우리 코드가 돌고 있었는지**가 곧
--   판정이다.
--
--     우리 헬퍼가 직전에 돌았다      -> 우리 쪽을 먼저 판다
--     한참 전에 끝났고 게임만 돌았다  -> 원작/CD 타이밍 쪽
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   조이 디비전에서 "쇼핑하기" 를 누른다.  멈추면 **F1**.
--   출력: C:\snatcher\dump\probe_crash_watch_0_1_4.tsv

local OUT = "C:\\snatcher\\dump\\probe_crash_watch_0_1_4.tsv"
local mem = emu.memType.pceMemory

local HELPER, LOOKUP, COPY, MISS = 0xBCD2, 0xBD5F, 0xBE0E, 0xBE55
local PRELOAD, LOADED, FAILED    = 0x5E40, 0x5F3B, 0x5FB4
local SCRATCH  = 0xBFE0
local PACK_ID  = SCRATCH + 8
local REC_LO, REC_MID, REC_HI = SCRATCH + 9, SCRATCH + 10, SCRATCH + 11
local SLOT_LO  = 0x7FEF
local ZP       = 0x2000
local IRQ_MASK, IRQ_STAT = 0x1802, 0x1803

local RING, BOOT_GRACE = 40, 180
local ring, ringPos, frame, total, dumps = {}, 0, 0, 0, 0

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end
local function cpu()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function push(tag)
  local s = cpu()
  ringPos = ringPos % RING + 1
  total = total + 1
  ring[ringPos] = {
    n = total, frame = frame, tag = tag,
    slot = word(SLOT_LO), pack = byte(PACK_ID),
    rec = byte(REC_HI) * 65536 + byte(REC_MID) * 256 + byte(REC_LO),
    pc = s and s["cpu.pc"] or 0, sp = s and s["cpu.sp"] or 0,
    mask = byte(IRQ_MASK), stat = byte(IRQ_STAT),
  }
end

for _, h in ipairs({ { HELPER, "helper" }, { LOOKUP, "lookup" }, { COPY, "copy" },
                     { MISS, "miss" }, { PRELOAD, "preload" }, { LOADED, "loaded" },
                     { FAILED, "failed" } }) do
  emu.addMemoryCallback(function() push(h[2]) end,
    emu.callbackType.exec, h[1], h[1], emu.cpuType.pce, mem)
end

local function dump(reason)
  dumps = dumps + 1
  -- ★ 덤프마다 별도 파일.  0.1.3 에서 수동 덤프가 폭주 자동감지분을
  -- 덮어써서 정작 필요한 스택을 잃었다.  같은 실수를 반복하지 않는다.
  local path = OUT:gsub("%.tsv$", "_" .. dumps .. ".tsv")
  local file = io.open(path, "w")
  if file == nil then return end
  local s = cpu()
  file:write("-- 크래시 감시 0.1.4 · 사유: " .. reason .. "\n")
  file:write(string.format("-- 프레임 %d · 총 기록 %d · 덤프 %d 회째\n", frame, total, dumps))
  if s then
    local mpr = {}
    for i = 0, 7 do
      mpr[#mpr + 1] = string.format("%02X", s[string.format("memoryManager.mpr[%d]", i)] or 0)
    end
    file:write(string.format("-- PC $%04X · SP $%02X · A $%02X · MPR %s\n",
      s["cpu.pc"] or 0, s["cpu.sp"] or 0, s["cpu.a"] or 0, table.concat(mpr, " ")))
  end
  file:write(string.format("-- CD IRQ  허용($1802) $%02X · 상태($1803) $%02X\n",
    byte(IRQ_MASK), byte(IRQ_STAT)))
  file:write(string.format("-- ZP $03/$04 = $%04X (렌더러 원문 포인터)\n\n", word(ZP + 3)))
  if s then
    local sp = s["cpu.sp"] or 0
    local st = {}
    for k = 1, 24 do
      st[#st + 1] = string.format("%02X", byte(0x2100 + ((sp + k) % 256)))
    end
    file:write("-- stack(SP+1..24B): " .. table.concat(st, " ") .. "\n")
    file:write("--   2 bytes LE = return address chain\n\n")
  end
  file:write("n\tframe\ttag\tslot\tpack\trec\tpc\tsp\tirq허용\tirq상태\n")
  for i = 1, RING do
    local e = ring[(ringPos + i - 1) % RING + 1]
    if e then
      file:write(string.format("%d\t%d\t%s\t%04X\t%02X\t%06X\t%04X\t%02X\t%02X\t%02X\n",
        e.n, e.frame, e.tag, e.slot, e.pack, e.rec, e.pc, e.sp, e.mask, e.stat))
    end
  end
  file:close()
  emu.log("★ 덤프 " .. dumps .. " 회째 (" .. reason .. ") -> " .. path)
end

-- 부팅 리셋은 무시한다.  0.1.0 이 여기서 헛발질했다
local resetVector = byte(0xFFFE) + byte(0xFFFF) * 256
if resetVector > 0 and resetVector < 0xFFFF then
  emu.addMemoryCallback(function()
    if frame > BOOT_GRACE then dump("RESET 벡터 진입 (부팅 아님)") end
  end, emu.callbackType.exec, resetVector, resetVector, emu.cpuType.pce, mem)
end

-- ★ 폭주 감지.  0.1.1 실측에서 PC 가 $0005 였다 -- I/O 페이지다.
-- CPU 가 $0000-$1FFF 를 실행하면 그 순간이 사망 지점이므로 즉시 찍는다.
local runaway = false
emu.addMemoryCallback(function()
  if runaway or frame <= BOOT_GRACE then return end
  runaway = true
  dump("폭주 -- I/O 페이지 실행")
end, emu.callbackType.exec, 0x0000, 0x1FFF, emu.cpuType.pce, mem)

-- 덤프 키.  이름을 추측하지 않는다 -- 후보를 찔러보고 **불리언을 돌려준 것**만 쓴다.
-- (2026-08-19: "0"·"Minus" 같은 이름은 Mesen 에서 Invalid key name 으로 프레임마다
--  터졌다.  F1 은 로드스테이트라 소유자가 다른 키를 원했다.)
local DUMP_KEYS = { "E", "e", "KeyE", "D", "d", "Q", "q", "R", "T", "G", "H" }
local dumpKey = nil
for _, name in ipairs(DUMP_KEYS) do
  local ok, v = pcall(function() return emu.isKeyPressed(name) end)
  if ok and type(v) == "boolean" then dumpKey = name break end
end

local held = false
emu.addEventCallback(function()
  frame = frame + 1
  local ok, down = false, false
  if dumpKey then ok, down = pcall(function() return emu.isKeyPressed(dumpKey) end) end
  down = ok and down == true
  if down and not held then dump("수동 (" .. tostring(dumpKey) .. ")") end
  held = down

  emu.drawString(4, 4, string.format("크래시 감시 0.1.4 · 기록 %d · 덤프 %d", total, dumps),
    0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, "멈추면 F6 을 누르세요", 0xFFFF80, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.log("PROBE 크래시감시 0.1.4 -- 부팅 리셋 무시 · F1 로 수동 덤프")
emu.log("  덤프 키: " .. tostring(dumpKey) .. "  (없으면 폭주 자동감지만 동작)")
emu.log("  출력: " .. OUT)
