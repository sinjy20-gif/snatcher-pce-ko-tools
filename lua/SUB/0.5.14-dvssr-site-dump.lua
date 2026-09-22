-- SUB 0.5.14 -- 게임의 DVSSR write site 주변 코드를 그대로 뜬다 (쓰기 0 B)
--
-- 여기까지
-- ---------------------------------------------------------------------------
--     0.5.12  write site 는 둘.  BIOS $E40C 경로와 게임 $42ED 경로
--     0.5.13  $2214/$2215 는 게임플레이 중 stale ($0700 인데 실제는 $1000)
--             -> BIOS shadow 는 못 쓴다.  게임 write site 를 패치해야 한다
--
-- 패치하려면 그 자리 코드를 봐야 한다 -- 끼울 틈이 있는지, 공통 호출로 뺄 수
-- 있는지.  **뱅크를 먼저 찾을 필요는 없다.**  쓰는 순간에 CPU 메모리를 읽으면
-- 그 시점에 매핑된 실제 명령 바이트가 그대로 나온다.
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
--     DVSSR($13) 쓰기가 BIOS 밖(PC < $E000)에서 일어나면 **한 번만**
--       · PC 주변 $42C0-$4320 상당 (설정 가능) 을 CPU 메모리에서 그대로 뜬다
--       · MPR 로 보이는 state 키를 찾아 같이 찍는다 (뱅크 특정용)
--     결과는 TSV 와 로그에 hex 로 남긴다.  디스어셈은 오프라인에서 한다
--
-- ★ 보고된 PC 는 명령 시작 + 2 다.  덤프 범위는 넉넉히 잡는다
-- ★ 덤프 0 회면 판정하지 말 것
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  게임이 진행되는 장면까지 간다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local BEFORE, AFTER = 0x30, 0x30      -- PC 앞뒤로 뜰 바이트 수

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/dvssr_site_0_5_14_' .. STAMP .. '.txt'

local PC_KEY
local function cpuState()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return nil end
  return s
end

local function pcOf(s)
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({'cpu.pc', 'pc', 'cpu.PC'}) do
      if s and type(s[k]) == 'number' then PC_KEY = k; break end
    end
  end
  if PC_KEY == false or not s then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local function mprList(s)
  local out = {}
  if not s then return out end
  for k, v in pairs(s) do
    if type(v) == 'number' and k:lower():find('mpr') then
      out[#out + 1] = string.format('%s=%02X', k, v & 0xFF)
    end
  end
  table.sort(out)
  return out
end

local selReg = 0
local done = false
local dumps = 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if selReg ~= 0x13 then return end
  if port ~= 2 then return end          -- lo 쓰기 한 번만 잡는다
  if done then return end

  local s = cpuState()
  local pc = pcOf(s)
  if pc < 0 or pc >= 0xE000 then return end   -- BIOS 경로는 이미 뜯었다
  done = true
  dumps = dumps + 1

  local from = (pc - BEFORE) & 0xFFFF
  local to = (pc + AFTER) & 0xFFFF
  local bytes = {}
  for at = from, to do
    bytes[#bytes + 1] = string.format('%02X', emu.read(at, MEM) or 0)
  end

  local mprs = mprList(s)
  local f = io.open(OUT, 'w')
  local header = string.format(
    'DVSSR write site dump\n보고된 PC $%04X (명령 시작은 -2 = $%04X)\n덤프 $%04X-$%04X\nMPR: %s\n\n',
    pc, (pc - 2) & 0xFFFF, from, to,
    (#mprs > 0) and table.concat(mprs, ' ') or '(state 에 mpr 키 없음)')
  emu.log('SUB 0.5.14 ★ ' .. header:gsub('\n', ' · '))

  -- 16 바이트씩 끊어서
  local lines = {}
  for i = 1, #bytes, 16 do
    local chunk = {}
    for j = i, math.min(i + 15, #bytes) do chunk[#chunk + 1] = bytes[j] end
    local line = string.format('$%04X  %s', (from + i - 1) & 0xFFFF,
                               table.concat(chunk, ' '))
    lines[#lines + 1] = line
    emu.log('   ' .. line)
  end
  if f then
    f:write(header)
    f:write(table.concat(lines, '\n'))
    f:write('\n')
    f:close()
  end
  emu.log('SUB 0.5.14 덤프 완료: ' .. OUT)
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 84, string.format('0.5.14 site 덤프 %d회 · %s',
                 dumps, done and '완료' or '대기'),
                 done and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.14-dvssr-site-dump armed -- 게임 write site 주변 코드를 한 번 뜬다')
emu.log('  ★ 덤프 0 회면 판정하지 말 것 · 게임이 진행되는 장면까지 갈 것')
emu.log('  파일: ' .. OUT)
