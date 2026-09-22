-- PROBE IRQ vs SATB 0.1.0 -- IRQ1 이 게임의 VRAM 전송 한가운데서 뜨는지 센다
--
-- 왜
-- ---------------------------------------------------------------------------
-- 0.2.3(VCE 팔레트) PASS / 0.2.4(VDC 패턴 업로드) FAIL 의 원인을 가른다.
--
-- 0.2.4 는 IRQ1 안에서 이렇게 했다:
--     ST0 #0 / ST1 $00 / ST2 $7B     MAWR = $7B00   <- VRAM 쓰기 커서를 바꾼다
--     TIA pat -> $0002, 128 B
--
-- 그런데 게임은 매 프레임 SATB 256 워드를 **여러 명령에 걸쳐** 밀어넣는다
-- (2026-08-22 정적 분석):
--
--     $600C  MAWR 세팅            여기서 커서를 잡고
--     $6500  CLX
--     $6501  LDA $00,X
--     $6503  STA $0002            <- 이 구간 내내 MAWR 을 들고 있다
--     $6509  STA $0003
--     $650C  INX
--     $650F  BNE $6501
--     $6512  DEC $17 / BMI $6527  64 회 반복
--     $6527  RTS                  <- 여기서 놓는다
--
-- 그 사이에 IRQ 가 끼어들어 MAWR 을 바꾸면, 게임이 돌아왔을 때 남은 워드가
-- 엉뚱한 VRAM 주소로 쏟아진다.  **MAWR 은 쓰기 전용이라 저장·복원이 불가능하다.**
-- 즉 임의 시점 IRQ 에서는 VRAM 을 못 만진다 -- 0.2.4 는 방법이 아니라 시점이 틀렸다.
--
-- 이 프로브는 그 가설을 재기만 한다.  게임을 안 건드린다.
--
--     겹치는 IRQ 가 있다   -> 가설 확정.  $6527 직후로 옮겨서 0.2.5 를 굽는다
--     하나도 없다          -> 원인이 다른 데 있다.  굽기 전에 다시 본다
--
-- 어떻게 재나 -- ★ IRQ 한 번당 콜백 한 번
-- ---------------------------------------------------------------------------
-- 0.1.0 계열 프로브가 느렸던 이유는 뜨거운 루프마다 getState 를 부른 것이었다.
-- 여기서는 **IRQ 진입점 한 곳**만 걸고, 끊긴 PC 를 스택에서 읽는다.
-- 6502 IRQ 는 PCH·PCL·P 순으로 밀어넣으므로 PCL 은 $2100+((SP+2)&FF) 에 있다.
-- 프레임당 IRQ 는 몇 번뿐이라 비용이 없다.
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local mem = emu.memType.pceMemory

local GAME_IRQ1 = 0x40A4     -- 게임 IRQ1 핸들러 (lifecycle POC 가 쓰는 값)
local STACK     = 0x2100

-- 위험 구간.  정적 분석에서 나온 주소다 (CD-RAM 오버레이 A).
local PUSH_LO, PUSH_HI   = 0x6500, 0x6511   -- 256 워드를 미는 안쪽 루프
local HOLD_LO, HOLD_HI   = 0x600C, 0x6527   -- MAWR 을 들고 있는 전체 구간

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:/snatcher/dump/probe_irq_vs_satb_0_1_0_" .. stamp .. ".tsv"

local frame = 0
local total, inPush, inHold, elsewhere = 0, 0, 0, 0
local firstPush, firstHold = nil, nil
local pcHist = {}            -- 끊긴 PC 분포

local function interruptedPc()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return nil end
  local sp = s["cpu.sp"] or s["cpu.stackPointer"]
  if sp == nil then return nil end
  local lo = emu.read(STACK + ((sp + 2) % 0x100), mem)
  local hi = emu.read(STACK + ((sp + 3) % 0x100), mem)
  if lo == nil or hi == nil then return nil end
  return hi * 256 + lo
end

emu.addMemoryCallback(function()
  local pc = interruptedPc()
  if pc == nil then return end
  total = total + 1
  pcHist[pc] = (pcHist[pc] or 0) + 1
  if pc >= PUSH_LO and pc <= PUSH_HI then
    inPush = inPush + 1
    if firstPush == nil then firstPush = frame end
  elseif pc >= HOLD_LO and pc <= HOLD_HI then
    inHold = inHold + 1
    if firstHold == nil then firstHold = frame end
  else
    elsewhere = elsewhere + 1
  end
end, emu.callbackType.exec, GAME_IRQ1, GAME_IRQ1, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 then
    emu.log(string.format(
      "IRQ %d  |  push루프 %d  전송구간 %d  바깥 %d  (프레임 %d)",
      total, inPush, inHold, elsewhere, frame))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "wb")
  if f == nil then emu.log("파일 열기 실패: " .. OUT); return end
  f:write("kind\tvalue\tcount\tfirst_frame\textra\n")
  f:write(string.format("TOTAL\t\t%d\t\t프레임 %d\n", total, frame))
  f:write(string.format("IN_PUSH\t%04X-%04X\t%d\t%s\tSATB 밀어넣는 루프 한가운데\n",
    PUSH_LO, PUSH_HI, inPush, firstPush and tostring(firstPush) or ""))
  f:write(string.format("IN_HOLD\t%04X-%04X\t%d\t%s\tMAWR 을 들고 있는 구간\n",
    HOLD_LO, HOLD_HI, inHold, firstHold and tostring(firstHold) or ""))
  f:write(string.format("ELSEWHERE\t\t%d\t\t안전\n", elsewhere))
  local list = {}
  for pc, n in pairs(pcHist) do list[#list + 1] = { pc = pc, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  for i = 1, math.min(#list, 60) do
    f:write(string.format("PC\t%04X\t%d\t\t\n", list[i].pc, list[i].n))
  end
  f:close()
  emu.log("PROBE IRQ vs SATB 0.1.0 -> " .. OUT)
end, emu.eventType.scriptEnded)

emu.log("PROBE IRQ vs SATB 0.1.0 시작 -- 음성 있는 장면을 지나가면 된다")
