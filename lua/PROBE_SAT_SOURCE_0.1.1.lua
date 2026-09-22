-- PROBE SAT SOURCE 0.1.1 -- SATB 를 매 프레임 올리는 루틴을 찾는다 (경량판)
--
-- 0.1.0 에서 바뀐 것 -- ★ 너무 느렸다
-- ---------------------------------------------------------------------------
-- 0.1.0 은 VWR 쓰기마다 `pc()` 를 불렀다.  그런데 게임은 음성 구간에 프레임당
-- 256 워드를 올린다 (0.2.2 실측 254.1).  즉 `emu.getState()` 를 **프레임당 250회
-- 넘게** 부른 셈이고, 그게 느려진 이유의 전부다.
--
-- 같은 루프가 256번 도는 것이라 PC 는 매번 같은 값이다.  **프레임당 한 번만**
-- 보면 정보가 하나도 안 줄어든다.  zero page 스냅샷도 30 프레임에 한 번으로
-- 낮췄다 -- 포인터는 프레임마다 같은 일을 반복하므로 표본이 촘촘할 필요가 없다.
--
--     getState 호출   프레임당 250+ 회  ->  2 회
--     zp 읽기         프레임당 512 회   ->  30 프레임마다 512 회
--
-- 무엇을 잡나 (0.1.0 과 동일)
-- ---------------------------------------------------------------------------
--   MAWR_PC   MAWR 이 $10xx(SATB) 로 잡히는 순간의 PC   업로드 진입점
--   VWR_PC    그 직후 데이터를 밀어넣는 명령의 PC        복사 루프 본체
--   ZP_PAIR   루프 전후로 값이 변한 zero page 쌍         그림자 버퍼 포인터 후보
--
-- 왜 이걸 찾나
-- ---------------------------------------------------------------------------
-- 매 프레임 256 워드를 올린다는 건 원본이 RAM 그림자 버퍼에 있다는 뜻이다.
-- 그 주소를 알면 자막 스프라이트를 **RAM 에 써두기만** 하면 되고, 게임의 자기
-- 업로드가 VRAM 까지 실어 나른다.  VDC 접근 0 회 -- 0.2.4 가 막힌 벽을 안 만난다.
--
-- 게임을 건드리지 않는 수동 관측이다.  0.2.2 와 같이 돌려도 된다.
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS

local mem, cpu = emu.memType.pceMemory, emu.memType.cpu

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:\\snatcher\\dump\\probe_sat_source_0_1_1_" .. stamp .. ".tsv"

local ZP_EVERY = 30              -- zero page 표본 간격 (프레임)

local frame = 0
local vdcReg, latchLo = 0, 0
local inSatb = false

-- 프레임당 한 번만 PC 를 본다.  같은 루프가 256번 도는 것이라 손실이 없다.
local sawMawrThisFrame, sawVwrThisFrame = false, false

local mawrPc, vwrPc, zpDelta = {}, {}, {}
local mawrPcN, vwrPcN = 0, 0
local zpBefore = nil

local function pc()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return 0 end
  return s["cpu.pc"] or s["cpu.programCounter"] or s["pc"] or 0
end

local function bump(tbl, key)
  local slot = tbl[key]
  if slot == nil then
    tbl[key] = { n = 1, first = frame }
    return true
  end
  slot.n = slot.n + 1
  return false
end

local function snapZp()
  local out = {}
  for a = 0x00, 0xFF do out[a] = emu.read(0x2000 + a, mem) or 0 end
  return out
end

emu.addMemoryCallback(function(address, value)
  if address == 0x0000 then
    vdcReg = value % 32
    return
  end
  if address == 0x0002 then
    latchLo = value
    return
  end
  if address ~= 0x0003 then return end

  if vdcReg == 0x00 then
    inSatb = (value == 0x10)
    if inSatb and not sawMawrThisFrame then
      sawMawrThisFrame = true
      if bump(mawrPc, pc()) then mawrPcN = mawrPcN + 1 end
      if zpBefore == nil and frame % ZP_EVERY == 0 then zpBefore = snapZp() end
    end
    return
  end

  if vdcReg == 0x02 and inSatb and not sawVwrThisFrame then
    sawVwrThisFrame = true
    if bump(vwrPc, pc()) then vwrPcN = vwrPcN + 1 end
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  sawMawrThisFrame, sawVwrThisFrame = false, false
  if zpBefore ~= nil then
    local after = snapZp()
    for a = 0x00, 0xFE do
      local b0 = zpBefore[a] + zpBefore[a + 1] * 256
      local a0 = after[a] + after[a + 1] * 256
      if a0 ~= b0 then
        local s = zpDelta[a]
        if s == nil then
          zpDelta[a] = { n = 1, last = a0, minv = math.min(a0, b0), maxv = math.max(a0, b0) }
        else
          s.n = s.n + 1
          s.last = a0
          if a0 < s.minv then s.minv = a0 end
          if a0 > s.maxv then s.maxv = a0 end
        end
      end
    end
    zpBefore = nil
  end
end, emu.eventType.endFrame)

local function dump()
  local file = io.open(OUT, "w")
  if file == nil then return end
  file:write("kind\tvalue\tcount\tfirst_frame\textra\n")
  for p, s in pairs(mawrPc) do
    file:write(string.format("MAWR_PC\t%04X\t%d\t%d\t\n", p, s.n, s.first))
  end
  for p, s in pairs(vwrPc) do
    file:write(string.format("VWR_PC\t%04X\t%d\t%d\t\n", p, s.n, s.first))
  end
  for a, s in pairs(zpDelta) do
    file:write(string.format("ZP_PAIR\t%02X\t%d\t\tlast=%04X min=%04X max=%04X\n",
      a, s.n, s.last, s.minv, s.maxv))
  end
  file:close()
  emu.log(string.format("SAT SOURCE: %d 프레임 · MAWR PC %d 종 · VWR PC %d 종 -> %s",
    frame, mawrPcN, vwrPcN, OUT))
end

-- 5분마다 저장.  Stop 을 못 눌러도 남는다
emu.addEventCallback(function()
  if frame % 18000 == 0 and frame > 0 then dump() end
end, emu.eventType.endFrame)
emu.addEventCallback(dump, emu.eventType.scriptEnded)

emu.log("PROBE SAT SOURCE 0.1.1 (경량판) -- 프레임당 getState 2회")
emu.log("  -> " .. OUT)
