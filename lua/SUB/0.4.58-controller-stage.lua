-- SUB 0.4.58-controller-stage -- controller + stage 재무장 분리시험
--
-- 0.4.57에 조각 전환 직전 stage 루틴 복원만 추가한다.
-- allocator / wipe / record-Y 보정 / MISS suppression은 여전히 없다.
-- 고정 VRAM $1600. Power Cycle 뒤 이 파일 하나만 실행할 것.

dofile('C:/snatcher/lua/SUB/0.4.57-controller-only.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local ENGINE, ENTRY = 0x5B80, 0x5B83
local READY, STAGE = 0x5CD7, 0x5D77
local ENGINE_PATH = rawget(_G, 'SUB_CONTROLLER_ENGINE_PATH') or
                    'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local engine = readFile(ENGINE_PATH)
local at = assert(engine:find('\x60', 504, true), 'stage RTS not found')
assert(at - 504 < 64, 'stage RTS is outside expected range')
local routine = engine:sub(504, at)
local magic, jsr = engine:sub(1, 3), engine:sub(9, 11)

local function matches(address, want)
  for i = 1, #want do
    if (emu.read(address + i - 1, MEM) or -1) ~= want:byte(i) then return false end
  end
  return true
end

local rearmed, skipped = 0, 0
emu.addMemoryCallback(function()
  if (emu.read(READY, MEM) or 0xFF) ~= 0 then return end
  if not matches(ENGINE, magic) or not matches(ENGINE + 8, jsr) then
    skipped = skipped + 1
    return
  end
  if matches(STAGE, routine) then return end
  for i = 1, #routine do emu.write(STAGE + i - 1, routine:byte(i), MEM) end
  rearmed = rearmed + 1
  emu.log(string.format('SUB 0.4.58 ★ STAGE REARM #%d · $%04X %d B',
                        rearmed, STAGE, #routine))
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 34,
    string.format('0.4.58 STAGE rearm:%d skip:%d', rearmed, skipped),
    0xFFD060, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.58-controller-stage armed -- controller + STAGE REARM ONLY')
emu.log('  NO allocator / NO wipe / NO Y fix / fixed VRAM $1600')
emu.log('  미카 3조각 완료와 이후 게임 진행 여부 확인')
