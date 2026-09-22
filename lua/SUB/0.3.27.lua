-- SUB 0.3.27 -- find the real CPU source of reception VRAM $2C00-$2DFF.
-- Read-only.  Load before Power Cycle and open the reception action menu.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/sub_0_3_27_source_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))

local reg, mawr, inc, low = 0, 0, 1, nil
local armed, done, warned = false, false, false
local words, seen, writes = {}, {}, 0

local function byte(at)
  return emu.read(at & 0xFFFF, MEM) or 0
end

local function hex(at, count)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', byte(at + i))
  end
  return table.concat(t, ' ')
end

local function cpu_state()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end

local function find_exact(payload)
  local hits = {}
  local n = #payload
  for base = 0x2000, 0x10000 - n do
    local ok = true
    for i = 1, n do
      if byte(base + i - 1) ~= payload[i] then ok = false; break end
    end
    if ok then
      hits[#hits + 1] = base
      if #hits >= 16 then break end
    end
  end
  return hits
end

local function finish()
  if done or writes < 256 then return end
  done = true

  local native, swapped = {}, {}
  for i = 0, 255 do
    local w = words[i] or 0
    native[#native + 1] = w & 0xFF
    native[#native + 1] = (w >> 8) & 0xFF
    swapped[#swapped + 1] = (w >> 8) & 0xFF
    swapped[#swapped + 1] = w & 0xFF
  end
  local native_hits = find_exact(native)
  local swapped_hits = find_exact(swapped)
  local s = cpu_state()

  local f = assert(io.open(OUT, 'w'))
  f:write('field\tvalue\n')
  f:write(string.format('registers\tPC=%04X A=%02X X=%02X Y=%02X SP=%02X\n',
    s['cpu.pc'] or s['cpu.programCounter'] or 0,
    s['cpu.a'] or 0, s['cpu.x'] or 0, s['cpu.y'] or 0, s['cpu.sp'] or 0))
  local mpr = {}
  for i = 0, 7 do mpr[#mpr + 1] = string.format('%02X', s['cpu.mpr' .. i] or 0) end
  f:write('mpr\t' .. table.concat(mpr, ' ') .. '\n')
  f:write('code_7100\t' .. hex(0x7100, 0x200) .. '\n')
  f:write('zp_0000\t' .. hex(0x0000, 0x100) .. '\n')
  f:write('stack_2100\t' .. hex(0x2100, 0x100) .. '\n')
  f:write('native_hits\t')
  for _, at in ipairs(native_hits) do f:write(string.format('%04X ', at)) end
  f:write('\n')
  f:write('swapped_hits\t')
  for _, at in ipairs(swapped_hits) do f:write(string.format('%04X ', at)) end
  f:write('\n')
  local nt, st = {}, {}
  for i = 1, #native do nt[i] = string.format('%02X', native[i]) end
  for i = 1, #swapped do st[i] = string.format('%02X', swapped[i]) end
  f:write('upload_native\t' .. table.concat(nt, ' ') .. '\n')
  f:write('upload_swapped\t' .. table.concat(st, ' ') .. '\n')
  f:close()

  local function hit_text(list)
    local t = {}
    for _, at in ipairs(list) do t[#t + 1] = string.format('$%04X', at) end
    return #t > 0 and table.concat(t, ',') or '없음'
  end
  emu.log('SUB 0.3.27 CAPTURE PASS: reception $2C00-$2DFF 256 words')
  emu.log('  CPU source native=' .. hit_text(native_hits) ..
          ' · swapped=' .. hit_text(swapped_hits))
  emu.log('  output: ' .. OUT)
end

emu.addMemoryCallback(function()
  if done or armed then return end
  armed, warned = true, false
  words, seen, writes = {}, {}, 0
  emu.log('SUB 0.3.27 RECEPTION armed at $66E5')
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

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
  if not armed or done or at < 0x1600 or at > 0x16FF then return end

  local s = cpu_state()
  local pc = s['cpu.pc'] or s['cpu.programCounter'] or s['pc'] or 0
  if not warned then
    warned = true
    emu.log(string.format('SUB 0.3.27 first target write PC=$%04X word=$%04X', pc, at))
  end
  local offset = at - 0x1600
  words[offset] = word
  if not seen[offset] then
    seen[offset] = true
    writes = writes + 1
  end
  finish()
end, emu.callbackType.write, 0x0003, 0x0003, emu.cpuType.pce, MEM)

emu.log('SUB 0.3.27 loaded -- reception uploader source finder / read-only')
emu.log('  Power Cycle -> 접수처 액션 메뉴가 열릴 때까지 진행')
emu.log('  0.3.26은 중지하고 이 파일 하나만 사용할 것')
