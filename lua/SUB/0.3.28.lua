-- SUB 0.3.28 -- compare skip/no-skip resource-load descriptors.
-- Read-only.  Load before Power Cycle, run to reception UI, then Stop.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/sub_0_3_28_load_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
f:write('frame\tseq\tevent\tpc\tptr\t26f0_26f8\tzp_f8_ff\tdescriptor\n')
f:flush()

local frame, seq = 0, 0

local function byte(at)
  return emu.read(at & 0xFFFF, MEM) or 0
end

local function hex(at, count)
  local t = {}
  for i = 0, count - 1 do t[#t + 1] = string.format('%02X', byte(at + i)) end
  return table.concat(t, ' ')
end

local function record(event, pc)
  seq = seq + 1
  local ptr = byte(0x5E) | (byte(0x5F) << 8)
  f:write(string.format('%d\t%d\t%s\t%04X\t%04X\t%s\t%s\t%s\n',
    frame, seq, event, pc, ptr,
    hex(0x26F0, 9), hex(0x00F8, 8), hex(ptr, 16)))
  f:flush()
  emu.log(string.format('SUB 0.3.28 %s #%d ptr=$%04X state=%s zp=%s',
    event, seq, ptr, hex(0x26F0, 9), hex(0x00F8, 8)))
end

emu.addMemoryCallback(function()
  record('REQUEST_6184', 0x6184)
end, emu.callbackType.exec, 0x6184, 0x6184, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  record('BIOS_CALL_629C', 0x629C)
end, emu.callbackType.exec, 0x629C, 0x629C, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  record('BIOS_E033', 0xE033)
end, emu.callbackType.exec, 0xE033, 0xE033, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  record('RESET_5451', 0x5451)
end, emu.callbackType.exec, 0x5451, 0x5451, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  f:close()
  emu.log('SUB 0.3.28 saved: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.3.28 loaded -- skip/no-skip load descriptor audit / read-only')
emu.log('  Power Cycle -> 접수처 액션 UI -> Stop')
emu.log('  output: ' .. OUT)
