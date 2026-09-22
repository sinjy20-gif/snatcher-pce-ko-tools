-- PROBE SAT SOURCE 0.1.0 -- SATB 를 매 프레임 올리는 그 루틴을 찾는다
--
-- 왜
-- ---------------------------------------------------------------------------
-- runtime_text_audit 0.2.2 의 voice_vdc 실측 (2026-08-21, 클립 68개):
--
--     SATB 재기록이 0 인 클립          0 개
--     프레임당 SATB 워드 쓰기 평균     254.1   (SATB 전체가 256 워드)
--     MAWR 대역                        사실상 전부 $10xx
--
-- 게임이 음성 구간 내내 **매 프레임 SATB 를 통째로** 다시 올린다.  그래서 자막
-- 스프라이트를 한 번 써넣는 B(클립당 1회 렌더)는 성립하지 않는다.
--
-- 그런데 매 프레임 256 워드를 올린다는 것은 그 원본이 **RAM 그림자 버퍼**에
-- 있다는 뜻이다.  그러면 VDC 를 놓고 싸울 필요가 없다 -- 그림자에 우리 엔트리를
-- 써두면 게임의 자기 업로드가 VRAM 까지 실어 나른다.  VDC 접근 0 회.
--
-- 필요한 것은 **그 복사 루틴이 읽는 RAM 주소** 하나다.  이 프로브가 그것만 잡는다.
--
-- 무엇을 잡나
-- ---------------------------------------------------------------------------
--   1. MAWR 이 $10xx 로 잡히는 순간의 PC          업로드 진입점
--   2. 그 직후 VWR($0002/$0003) 에 쓰는 명령의 PC  복사 루프 본체
--   3. 루프가 도는 동안의 zero page 포인터 후보     $20xx 중 프레임마다 증가하는 쌍
--
-- 3 번이 핵심이다.  루프가 `LDA (zp),Y` 로 읽으면 그 zp 쌍이 그림자 버퍼 주소다.
-- PC 만으로도 오프라인 역어셈블(tools/disasm_huc6280.py)로 확정할 수 있으므로
-- 둘 다 남긴다 -- 주소 하나만 알고 끝내지 않는다.
--
-- 게임을 건드리지 않는 수동 관측이다.  0.2.2 와 같이 돌려도 된다.
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS

local mem, cpu = emu.memType.pceMemory, emu.memType.cpu
local OUT = "C:\\snatcher\\dump\\probe_sat_source_0_1_0.tsv"

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
OUT = "C:\\snatcher\\dump\\probe_sat_source_" .. stamp .. ".tsv"

local frame = 0
local vdcReg, latchLo = 0, 0
local inSatb = false

-- PC 별 집계.  같은 명령이 수만 번 돌므로 표가 아니라 카운터로 센다
local mawrPc, vwrPc = {}, {}
local mawrPcN, vwrPcN = 0, 0

-- zero page 스냅샷.  루프 중에 값이 증가하는 쌍이 소스 포인터다
local zpBefore, zpDelta = nil, {}

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
  for a = 0x00, 0xFF do
    out[a] = emu.read(0x2000 + a, mem) or 0
  end
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
    local addr = value * 256 + latchLo
    inSatb = addr >= 0x1000 and addr <= 0x10FF
    if inSatb then
      if mawrPcN < 4000 then
        if bump(mawrPc, pc()) then mawrPcN = mawrPcN + 1 end
      end
      -- 루프 시작 직전의 zero page 를 떠둔다
      if zpBefore == nil then zpBefore = snapZp() end
    end
    return
  end

  if vdcReg == 0x02 and inSatb then
    if vwrPcN < 4000 then
      if bump(vwrPc, pc()) then vwrPcN = vwrPcN + 1 end
    end
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, cpu)

-- 프레임 끝에서 zero page 변화량을 센다.  업로드 루프가 쓰는 포인터는
-- 프레임마다 같은 폭으로 움직이거나, 루프 중에만 움직였다가 되돌아온다.
emu.addEventCallback(function()
  frame = frame + 1
  if zpBefore ~= nil then
    local after = snapZp()
    for a = 0x00, 0xFE do
      local b0 = zpBefore[a] + zpBefore[a + 1] * 256
      local a0 = after[a] + after[a + 1] * 256
      if a0 ~= b0 then
        local slot = zpDelta[a]
        if slot == nil then
          zpDelta[a] = { n = 1, last = a0, minv = math.min(a0, b0), maxv = math.max(a0, b0) }
        else
          slot.n = slot.n + 1
          slot.last = a0
          if a0 < slot.minv then slot.minv = a0 end
          if a0 > slot.maxv then slot.maxv = a0 end
        end
      end
    end
    zpBefore = nil
  end
  if frame % 1800 == 0 then emu.log(string.format("SAT SOURCE: %d 프레임, MAWR PC %d 종 / VWR PC %d 종", frame, mawrPcN, vwrPcN)) end
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
  emu.log("SAT SOURCE -> " .. OUT)
end

emu.addEventCallback(dump, emu.eventType.scriptEnded)

emu.log("PROBE SAT SOURCE 0.1.0 -- SATB 업로드 루틴의 PC 와 소스 포인터 후보를 잡는다")
emu.log("  -> " .. OUT)
emu.log("  대사 몇 개 지나가면 MAWR_PC / VWR_PC 가 한두 종으로 수렴한다.  그게 그 루틴이다")
