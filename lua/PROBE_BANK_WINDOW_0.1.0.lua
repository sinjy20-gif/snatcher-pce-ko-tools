-- PROBE 뱅크창 0.1.0 -- **뱅크가 바뀐 동안 인터럽트가 들어오는가**만 본다
--
-- 증명할 명제 (2026-08-19, 조이 디비전 쇼핑하기 진행불가)
-- ---------------------------------------------------------------------------
-- $7F88 트램펄린은 헬퍼를 부르려고 $A000-$BFFF 를 뱅크 $69 로 갈아끼운다:
--
--     7F88  TMA #$20        현재 뱅크 저장
--     7F8A  PHA
--     7F8B  LDA #$69
--     7F8D  TAM #$20        ★ 여기부터 $A000-$BFFF 가 우리 헬퍼다
--     7F8F  JSR $BCD2
--     7F92  STA $7FEE
--     7F95  PLA
--     7F96  TAM #$20        ★ 여기서 되돌린다
--     7F98  LDA $7FEE
--     7F9B  RTS
--
-- **SEI/CLI 가 없다.**  이 사이에 IRQ 가 들어오면 핸들러는 그 창이 게임
-- 데이터 뱅크($6C)인 줄 알고 읽는데 실제로는 헬퍼 코드가 있다.
--
-- 가설이 맞다면 여기서 IRQ 진입이 관측되어야 한다.  0 이면 가설은 틀렸다.
--
-- 왜 이 방식인가 -- 싸게 잰다
-- ---------------------------------------------------------------------------
-- IRQ 마다 `emu.getState()` 로 MPR 을 읽으면 너무 느리다 (폭주 때 IRQ2 가
-- 236,274 회 들어왔다).  대신 트램펄린 진입/복귀에 훅을 걸어 **Lua 쪽 플래그**로
-- 창을 표시하고, IRQ 훅에서는 그 플래그만 본다.  getState 호출 0 이다.
--
-- 감시하는 인터럽트 (BIOS 벡터 실측)
--     $E736  IRQ2   (CD-ROM.  HuC6280 은 BRK 도 이 벡터를 쓴다)
--     $E870  IRQ1   (VDC)
--     $E6B3  TIMER
--     $E6A9  NMI
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   조이 디비전 -> 쇼핑하기.  죽든 안 죽든 화면에 실시간으로 숫자가 뜬다.
--   출력: C:\snatcher\dump\probe_bank_window_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_bank_window_0_1_0.tsv"
local mem = emu.memType.pceMemory

local WINDOW_OPEN  = 0x7F8F   -- TAM 직후 (뱅크 바뀐 상태)
local WINDOW_CLOSE = 0x7F98   -- TAM 으로 되돌린 직후

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tirq\topen_n\tnote\n")

local frame, opens, insideHits, totalIrq = 0, 0, 0, 0
local inside, dirty = false, false
local perIrq = {}
local firstHits = 0

local function row(kind, irq, note)
  file:write(string.format("%s\t%d\t%s\t%d\t%s\n", kind, frame, irq or "", opens, note or ""))
  dirty = true
end

emu.addMemoryCallback(function()
  inside = true
  opens = opens + 1
end, emu.callbackType.exec, WINDOW_OPEN, WINDOW_OPEN, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  inside = false
end, emu.callbackType.exec, WINDOW_CLOSE, WINDOW_CLOSE, emu.cpuType.pce, mem)

local function watchIrq(addr, name)
  emu.addMemoryCallback(function()
    totalIrq = totalIrq + 1
    if inside then
      insideHits = insideHits + 1
      perIrq[name] = (perIrq[name] or 0) + 1
      if firstHits < 30 then
        firstHits = firstHits + 1
        row("★창안", name, "뱅크 교체 중에 인터럽트가 들어왔다")
      end
    end
  end, emu.callbackType.exec, addr, addr, emu.cpuType.pce, mem)
end

watchIrq(0xE736, "IRQ2")
watchIrq(0xE870, "IRQ1")
watchIrq(0xE6B3, "TIMER")
watchIrq(0xE6A9, "NMI")

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("뱅크창 %d 회 · 인터럽트 %d", opens, totalIrq),
    0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, string.format("★창 안에서 걸린 인터럽트: %d", insideHits),
    insideHits > 0 and 0xFF6060 or 0xC0C0C0, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("\n-- 뱅크 교체 %d 회 · 인터럽트 총 %d 회\n", opens, totalIrq))
  file:write(string.format("-- ★ 교체 중에 들어온 인터럽트: %d 회\n", insideHits))
  local t = {}
  for k, v in pairs(perIrq) do t[#t + 1] = string.format("%s %d", k, v) end
  table.sort(t)
  file:write("--    내역: " .. (#t > 0 and table.concat(t, " · ") or "없음") .. "\n")
  if insideHits > 0 then
    file:write("-- 판정: 가설 확정.  트램펄린에 SEI/CLI 가 필요하다\n")
  else
    file:write("-- 판정: 창 안에서는 인터럽트가 안 걸렸다.  이 가설은 기각\n")
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 뱅크창 0.1.0 -- 뱅크 교체 중 인터럽트 진입만 센다")
emu.log("  화면의 '★창 안에서 걸린 인터럽트' 가 0 이 아니면 가설 확정")
emu.log("  출력: " .. OUT)
