-- SUB 0.3.26 -- inspect reception VRAM uploader whose post-fetch PC is $71FB.
-- Load at reception, then open/redraw the action menu once.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/sub_0_3_26_source_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))
local done = false
local reg, mawr, inc, low = 0, 0, 1, nil

local function byte(at) return emu.read(at, MEM) or 0 end
local function hex(at, count)
  local t = {}
  for i = 0, count - 1 do t[#t + 1] = string.format('%02X', byte(at + i)) end
  return table.concat(t, ' ')
end

local function save_source(instruction, reason)
  if done then return true end
  local code = {}
  for i = 0, 6 do code[i] = byte(instruction + i) end
  local src = code[1] | (code[2] << 8)
  local dst = code[3] | (code[4] << 8)
  local len = code[5] | (code[6] << 8)
  local s = emu.getState() or {}
  local mpr = {}
  for i = 0, 7 do mpr[#mpr + 1] = string.format('%02X', s['cpu.mpr' .. i] or 0) end

  done = true
  local f = assert(io.open(OUT, 'w'))
  f:write('field\tvalue\n')
  f:write(string.format('reason\t%s instruction=%04X\n', reason, instruction))
  f:write(string.format('code_%04x\t%s\n', instruction, hex(instruction, 16)))
  f:write(string.format('decoded\top=%02X src=%04X dst=%04X len=%04X\n',
    code[0], src, dst, len))
  f:write('mpr\t' .. table.concat(mpr, ' ') .. '\n')
  f:write(string.format('registers\tA=%02X X=%02X Y=%02X SP=%02X\n',
    s['cpu.a'] or 0, s['cpu.x'] or 0, s['cpu.y'] or 0, s['cpu.sp'] or 0))
  local dumpLen = math.min(len > 0 and len or 0x200, 0x800)
  f:write(string.format('source_%04x\t%s\n', src, hex(src, dumpLen)))
  f:close()
  emu.log(string.format('SUB 0.3.26 SOURCE PASS: op=%02X src=$%04X dst=$%04X len=$%04X',
    code[0], src, dst, len))
  emu.log('  output: ' .. OUT)
  return true
end

emu.addMemoryCallback(function(_, value)
  reg = (value or 0) & 0x1F
end, emu.callbackType.write, 0x0000, 0x0000, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(_, value)
  low = value or 0
end, emu.callbackType.write, 0x0002, 0x0002, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(_, value)
  local word = ((value or 0) << 8) | (low or 0)
  low = nil
  if reg == 0x00 then mawr = word; return end
  if reg == 0x05 then
    local selector = (word >> 11) & 3
    inc = ({[0]=1,[1]=32,[2]=64,[3]=128})[selector] or 1
    return
  end
  if reg ~= 0x02 then return end
  local at = mawr
  mawr = (mawr + inc) & 0xFFFF
  if done or at < 0x1600 or at > 0x16FF then return end

  local current = emu.getState() or {}
  local pc = current['cpu.pc'] or current['cpu.programCounter'] or current['pc'] or 0
  if pc ~= 0x71FB then return end

  -- During a HuC6280 block transfer the exposed PC is already seven bytes
  -- past the opcode.  The writer trace reported $71FB, so decode $71F4.
  local instruction = 0x71F4
  local code = {}
  for i = 0, 6 do code[i] = byte(instruction + i) end
  if code[0] ~= 0x73 and code[0] ~= 0xC3 and code[0] ~= 0xD3 and
     code[0] ~= 0xE3 and code[0] ~= 0xF3 then return end
  save_source(instruction, 'VDC writer post-PC 71FB')
end, emu.callbackType.write, 0x0003, 0x0003, emu.cpuType.pce, MEM)

-- Once the menu is already visible it does not upload the 512-byte pattern
-- again.  At its renderer entry, search the currently mapped upload routine
-- for a HuC6280 block transfer whose destination is VDC data port $0002 and
-- whose length is $0200 bytes.
emu.addMemoryCallback(function()
  if done then return end
  for at = 0x71C0, 0x7210 - 6 do
    local op = byte(at)
    if (op == 0x73 or op == 0xC3 or op == 0xD3 or op == 0xE3 or op == 0xF3) and
       byte(at + 3) == 0x02 and byte(at + 4) == 0x00 and
       byte(at + 5) == 0x00 and byte(at + 6) == 0x02 then
      save_source(at, 'reception renderer scan')
      return
    end
  end
  emu.log('SUB 0.3.26 SOURCE WAIT: mapped $71C0-$7210 has no VDC $0200 transfer')
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

emu.log('SUB 0.3.26 loaded -- reception uploader post-PC $71FB source audit / read-only')
emu.log('  접수처 액션 메뉴를 열거나 커서를 움직일 것')
