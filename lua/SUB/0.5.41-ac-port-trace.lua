-- SUB 0.5.41 -- BIOS 의 AC 포트 접근을 그 순간에 잡는다 (읽기 전용)
--
-- 어디까지 왔나 (0.5.40 · BUILD $74 확인됨)
-- ---------------------------------------------------------------------------
--     lba 00306B / 003078 / 003083   LBA 추출은 정확 (표에 실재하는 값)
--     9 단계                          이분 검색이 정상 깊이로 돈다
--     고정 4B  FF FF FF               ★ **고정 주소**에서도 FF
--
-- 고정 주소에서도 FF 이므로 `mid*9` 주소 계산도 자동증가도 아니다.
-- **BIOS 가 AC 를 아예 못 읽는다.**
--
-- ★ 그리고 "AC 되읽기 OK" 는 안심의 근거가 못 된다
--     Lua 는 `pceArcadeCardRam` 으로 에뮬레이터 내부 RAM 을 직접 읽는다.
--     **포트를 거치지 않는다.**  그래서 그 성공은 "데이터가 거기 있다" 만 증명하고
--     포트 경로에 대해서는 아무것도 말해 주지 않는다.
--     -> 포트 경로가 도는지 자체를 한 번도 확인한 적이 없다.
--
-- 남은 가설 둘과 가르는 법
-- ---------------------------------------------------------------------------
--     (a) 문맥   그 순간 AC 포트에 안 닿는다 (MPR 등)
--     (b) 설정   닿긴 하는데 포트가 기대한 상태가 아니다
--                (base $1A02-04 · 증가 $1A07 · 제어 $1A09)
--
--     읽기 콜백이 **안 걸리면**  접근이 AC 에 도달조차 안 한다      -> (a)
--     읽기 콜백이 **걸리면**    도달은 한다.  값이 FF 면 설정 문제  -> (b)
--
-- 쓰기도 같이 본다.  우리 BIOS 가 base 를 **세우기는 하는지**가 (b) 의 핵심이다.
-- 세우지도 않고 읽으면 남이 남긴 주소에서 읽는 것이므로 FF 가 당연하다.
--
-- ★ `$1A00` 을 우리가 읽지 않는다.  자동증가가 있어 읽는 순간 포인터가 움직인다.
--   콜백은 관찰만 하므로 안전하고, 값은 콜백 인자로 받는다.
--
-- 무엇을 찍나
-- ---------------------------------------------------------------------------
--     포트 · 읽기/쓰기 · 값 · PC · 그 순간의 MPR0~MPR7
--     같은 (포트, 종류, PC) 조합은 몇 번만 찍고 나머지는 센다
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.
--     BIOS  build/patch/0.4.7.4-lba-probe/Syscard3_galmuri_0.4.7.4-lba-probe.pce
--     CUE   build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue   (그대로)
--
-- ★ 화면에 아무것도 그리지 않는다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local AC = emu.memType.pceArcadeCardRam

local PORT_LO, PORT_HI = 0x1A00, 0x1A0F
local INDEX_AT = 0x1F2400            -- 0.5.40 이 표를 올리는 자리

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/ac_port_trace_0_5_41_' .. STAMP .. '.txt'
local out = io.open(OUT, 'w')

local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function pcNow(s)
  if not s then return -1 end
  for _, k in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[k]) == 'number' then return math.floor(s[k]) & 0xFFFF end
  end
  return -1
end

local function mprNow(s)
  local t = {}
  for i = 0, 7 do
    local v = s and (s['cpu.mpr[' .. i .. ']'] or s['mpr' .. i]
                     or s['memoryManager.mpr[' .. i .. ']'])
    t[#t + 1] = type(v) == 'number' and string.format('%02X', v) or '??'
  end
  return table.concat(t, ' ')
end

local reads, writes = 0, 0
local seen, shown = {}, 0
local firstRead = nil

local function note(kind, address, value)
  local s = st()
  local pc = pcNow(s)
  local port = address & 0xFFFF
  if kind == 'R' then reads = reads + 1 else writes = writes + 1 end
  if kind == 'R' and not firstRead then firstRead = true end

  local sig = string.format('%s$%04X@%04X', kind, port, pc)
  seen[sig] = (seen[sig] or 0) + 1
  if seen[sig] <= 3 and shown < 60 then
    shown = shown + 1
    local line = string.format(
      'SUB 0.5.41 %s $%04X = $%02X  PC $%04X  MPR %s',
      kind == 'R' and '읽기' or '쓰기', port, value & 0xFF, pc, mprNow(s))
    emu.log(line)
    if out then out:write(line .. '\n'); out:flush() end
  end
end

emu.addMemoryCallback(function(address, value) note('R', address, value or 0) end,
  emu.callbackType.read, PORT_LO, PORT_HI, CPU, MEM)
emu.addMemoryCallback(function(address, value) note('W', address, value or 0) end,
  emu.callbackType.write, PORT_LO, PORT_HI, CPU, MEM)

-- 표가 실제로 AC 에 있는지 한 번만 확인한다 (직접 접근 -- 포트 경로가 아니다)
local t = {}
for i = 0, 8 do t[#t + 1] = string.format('%02X', emu.read(INDEX_AT + i, AC) or 0) end
emu.log('SUB 0.5.41 AC 직접읽기(포트 아님) $1F2400 = ' .. table.concat(t, ' '))
emu.log('  ★ 이 값은 "데이터가 거기 있다" 만 말한다.  포트 경로와 무관하다')

local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 then
    emu.log(string.format('SUB 0.5.41 %df · 포트 읽기 %d · 쓰기 %d · 조합 %d',
      frame, reads, writes, (function() local n = 0
        for _ in pairs(seen) do n = n + 1 end; return n end)()))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emu.log(string.format('SUB 0.5.41 끝 -- 포트 읽기 %d · 쓰기 %d', reads, writes))
  if reads == 0 then
    emu.log('  ★★ 읽기 0 -- 접근이 AC 포트에 도달조차 안 한다  => 가설 (a) 문맥')
  else
    emu.log('  ★★ 읽기가 잡힌다 -- 도달은 한다.  값과 MPR 을 볼 것  => 가설 (b) 설정')
  end
  if writes == 0 then
    emu.log('  ★ 쓰기 0 -- base($1A02-04)를 **세우지도 않고** 읽는다.  FF 가 당연하다')
  end
  if out then out:close() end
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.41-ac-port-trace armed -- $1A00-$1A0F 읽기·쓰기를 그 순간에 잡는다')
emu.log('  ★ $1A00 을 우리가 읽지 않는다 (자동증가 보호).  콜백 인자만 쓴다')
emu.log('  판정: 읽기 0 = (a) 문맥 · 읽기 있음 = (b) 설정')
emu.log('  로그: ' .. OUT)
