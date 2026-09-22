-- SUB 0.4.39-inspect -- 0.4.38 정지 상태 읽기 전용 덤프
-- 게임/VRAM/엔진을 수정하지 않는다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE = 0x5B80
local SELECTOR = ENGINE + 345
local READY = ENGINE + 343
local MINI = 0x1EF000

local function bytes(at, count, kind)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', emu.read(at + i, kind) or 0)
  end
  return table.concat(t, ' ')
end

emu.log('SUB 0.4.39 INSPECT -- READ ONLY')
local ok, machine = pcall(emu.getState)
local pc = ok and machine and (machine['cpu.pc'] or 0) or 0
local sp = ok and machine and (machine['cpu.sp'] or 0) or 0
emu.log(string.format('  CPU pc=$%04X sp=$%02X', pc, sp))
emu.log(string.format('  magic=%s ready=%02X state=%02X',
  bytes(ENGINE, 3, MEM), emu.read(READY, MEM) or 0, emu.read(0x7FDF, MEM) or 0))
emu.log('  CPU selector: ' .. bytes(SELECTOR, 9, MEM))
for n = 0, 4 do
  emu.log(string.format('  MINI #%d: %s', n + 1, bytes(MINI + n * 13, 13, AC)))
end
