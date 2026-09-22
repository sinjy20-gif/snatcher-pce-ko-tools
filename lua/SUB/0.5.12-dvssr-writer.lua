-- SUB 0.5.12 -- DVSSR(SATB 주소)을 쓰는 코드가 어디이며 값을 어디서 가져오나 (쓰기 0 B)
--
-- 왜
-- ---------------------------------------------------------------------------
-- 복원 직전에 우리 SATB 슬롯을 비워야 하는데(0.5.10 으로 확인), 헬퍼가 SATB 주소를
-- 알아야 한다.  그런데:
--
--     · VDC 레지스터는 **되읽기가 안 된다.**  DVSSR($13)은 쓰기 전용이다
--     · 헬퍼는 매번 AC 에서 새로 복사되므로 자기 안에 기억해도 초기화된다
--     · $1000 으로 박는 것은 위험하다.  0.4.90 이 $0700 도 본 적이 있다
--
-- 그런데 **게임도 DVSSR 을 못 읽는다.**  그러므로 게임은 SATB 주소를 어딘가
-- RAM 에 들고 있다가 그것을 DVSSR 에 쓴다.  그 RAM 변수를 찾으면 헬퍼는
-- `LDA abs` 두세 바이트로 읽으면 된다.
--
-- 이 판은 그 변수를 직접 찾지 않는다.  **쓰는 코드의 PC 를 잡는다.**
-- 그 자리를 디스어셈하면 값을 어디서 가져오는지 소스에 그대로 보인다
-- ("주소가 아니라 루틴을 찾는다").
--
-- 무엇을 찍나
-- ---------------------------------------------------------------------------
--     selReg 가 $13 인 상태에서 $0002(lo) / $0003(hi) 에 쓰기가 일어날 때
--       · PC · 값 · 조립된 DVSSR 워드 · 프레임
--     같은 (PC, 값) 은 한 번만 찍고 횟수만 센다
--
-- 읽는 법
--     PC 가 한두 곳이면 그 루틴 하나만 뜯으면 된다
--     값이 여러 개면 장면마다 SATB 가 옮겨 다닌다는 뜻이므로 RAM 변수가 반드시 있다
--     PC 가 $E000 이상이면 BIOS 안이고, 그 아래면 게임 코드다
--
-- ★ 적중 0 이면 판정하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  여러 장면을 돌아다닐수록 좋다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/dvssr_writer_0_5_12_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tpc\tport\tvalue\tdvssr\tcount\n') end

local PC_KEY
local function pc()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({'cpu.pc', 'pc', 'cpu.PC'}) do
      if type(s[k]) == 'number' then PC_KEY = k; break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local selReg, dvssr = 0, 0
local hits = 0
local seen, order = {}, {}
local frame = 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if selReg ~= 0x13 then return end
  if port == 2 then dvssr = (dvssr & 0xFF00) | value
  elseif port == 3 then dvssr = (dvssr & 0x00FF) | (value << 8)
  else return end

  hits = hits + 1
  local p = pc()
  local sig = string.format('%04X|%d|%02X', p & 0xFFFF, port, value)
  if not seen[sig] then
    seen[sig] = { n = 0, pc = p, port = port, value = value, frame = frame }
    order[#order + 1] = sig
    emu.log(string.format(
      'SUB 0.5.12 ★ %df · PC $%04X · port $%04X <- $%02X · DVSSR = $%04X',
      frame, p & 0xFFFF, port, value, dvssr & 0x7FFF))
  end
  seen[sig].n = seen[sig].n + 1
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 and #order > 0 then
    emu.log(string.format('SUB 0.5.12 요약 · 적중 %d · 서로 다른 (PC,값) %d 종',
                          hits, #order))
    for _, sig in ipairs(order) do
      local e = seen[sig]
      emu.log(string.format('   PC $%04X  port $%04X <- $%02X   x%d',
                            e.pc & 0xFFFF, e.port, e.value, e.n))
    end
    if out then
      out:write(string.format('%d\t-\t-\t-\t%04X\t%d\n', frame, dvssr & 0x7FFF, hits))
      for _, sig in ipairs(order) do
        local e = seen[sig]
        out:write(string.format('%d\t%04X\t%d\t%02X\t%04X\t%d\n',
                                e.frame, e.pc & 0xFFFF, e.port, e.value,
                                dvssr & 0x7FFF, e.n))
      end
      out:flush()
    end
  end
  emu.drawString(4, 84, string.format('0.5.12 DVSSR 적중 %d · 종류 %d · 현재 $%04X · pc키 %s',
                 hits, #order, dvssr & 0x7FFF, tostring(PC_KEY)),
                 hits > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.12-dvssr-writer armed -- DVSSR($13) 쓰기의 PC 를 잡는다')
emu.log('  ★ 적중 0 이면 판정하지 말 것 · 여러 장면을 돌아다닐수록 좋다')
emu.log('  로그: ' .. OUT)
