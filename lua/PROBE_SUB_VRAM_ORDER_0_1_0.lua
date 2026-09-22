-- PROBE_SUB_VRAM_ORDER 0.1.0 -- native subtitle POC의 VRAM/SATB 순서 읽기 전용 측정
-- 대상: 현재 0.4.5.9 subtitle collection의 E6800_0E 고정 selector.
-- 어떤 메모리도 쓰지 않는다. 자막이 뜨는 한 번을 재현한 뒤 Stop으로 닫는다.

local MEM, VRAM, AC, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam,
                                emu.memType.pceArcadeCardRam, emu.memType.cpu
local PAT_WORD, PAT_WORDS = 0x7900, 1216
local PAT, PAT_BYTES = PAT_WORD * 2, PAT_WORDS * 2
local SAT, SAT_BYTES = 0x1000 * 2, 512
local AC_PAT = 0x1F0400
local STATE = 0x7FDF
local OUT = string.format('C:/snatcher/dump/probe_sub_vram_order_0_1_0_%s.tsv', os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
f:write('kind\tframe\tstate\tplaying\tpat_diff_pre\tpat_diff_ac\tsat_changed_slots\tours\tword_from\tword_to\twrites\tnote\n')

local function snapshot(kind, at, n)
  local t = {}
  for i = 0, n - 1 do t[i] = emu.read(at + i, kind) or 0 end
  return t
end
local function diff(a, b, n)
  local d = 0
  for i = 0, n - 1 do if a[i] ~= b[i] then d = d + 1 end end
  return d
end
local function changedSlots(a, b)
  local out = {}
  for slot = 0, 63 do
    local off, changed = slot * 8, false
    for i = 0, 7 do if a[off + i] ~= b[off + i] then changed = true; break end end
    if changed then out[#out + 1] = string.format('%02d', slot) end
  end
  return #out == 0 and '-' or table.concat(out, ',')
end
local function ours(sat)
  local n = 0
  for slot = 0, 63 do
    local off = slot * 8 + 4
    local pat = (sat[off] or 0) | ((sat[off + 1] or 0) << 8)
    if pat >= 0x03C4 and pat <= 0x03E9 then n = n + 1 end
  end
  return n
end

local frame, armed, started, ended = 0, false, false, false
local basePat, baseSat = nil, nil
local frameWrites, minWord, maxWord = 0, nil, nil
local vdcReg, mawrLo, mawr = 0, 0, 0
local scheduled = {}

local function sample(kind, note)
  if not basePat then return end
  local pat = snapshot(VRAM, PAT, PAT_BYTES)
  local sat = snapshot(VRAM, SAT, SAT_BYTES)
  local ac = snapshot(AC, AC_PAT, PAT_BYTES)
  local state = emu.read(STATE, MEM) or 0xFF
  local playing = emu.getState()['cdrom.adpcm.playing'] == true and 1 or 0
  f:write(string.format('%s\t%d\t%02X\t%d\t%d\t%d\t%s\t%d\t%s\t%s\t%d\t%s\n',
    kind, frame, state, playing, diff(basePat, pat, PAT_BYTES), diff(ac, pat, PAT_BYTES),
    changedSlots(baseSat, sat), ours(sat),
    minWord and string.format('%04X', minWord) or '-', maxWord and string.format('%04X', maxWord) or '-',
    frameWrites, note or ''))
  f:flush()
  emu.log(string.format('VRAM ORDER %s f=%d state=%02X pre=%d ac=%d sat=%s ours=%d write=%s-%s/%d',
    kind, frame, state, diff(basePat, pat, PAT_BYTES), diff(ac, pat, PAT_BYTES),
    changedSlots(baseSat, sat), ours(sat), minWord and string.format('%04X', minWord) or '-',
    maxWord and string.format('%04X', maxWord) or '-', frameWrites))
end

-- VDC data 포트는 읽기만 관측한다. VWR high-byte write 한 번을 VRAM word 한 번으로 센다.
emu.addMemoryCallback(function(address, value)
  if address == 0 then
    vdcReg = value or 0
  elseif address == 2 and vdcReg == 0 then
    mawrLo = value or 0
  elseif address == 3 and vdcReg == 0 then
    mawr = mawrLo | ((value or 0) << 8)
  elseif address == 3 and vdcReg == 2 and armed and mawr >= PAT_WORD and mawr < PAT_WORD + PAT_WORDS then
    frameWrites = frameWrites + 1
    if not minWord or mawr < minWord then minWord = mawr end
    if not maxWord or mawr > maxWord then maxWord = mawr end
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  local st = emu.getState()
  local ending = ((st['cdrom.adpcm.readAddress'] or 0) + (st['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if ending == 0x6800 and (st['cdrom.adpcm.playbackRate'] or -1) == 0x0E then
    armed, started, ended = true, false, false
    basePat, baseSat = snapshot(VRAM, PAT, PAT_BYTES), snapshot(VRAM, SAT, SAT_BYTES)
    frameWrites, minWord, maxWord = 0, nil, nil
    scheduled = {}
    sample('AD_PLAY_PRE', 'F61A 실행 직전')
  end
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if not armed then return end
  local state = emu.read(STATE, MEM) or 0xFF
  if not started and state == 2 then
    started = true
    sample('RENDERER_FIRST', 'renderer active 첫 프레임')
    for _, delay in ipairs({1, 2, 8, 30, 120}) do scheduled[frame + delay] = 'ACTIVE_' .. delay end
  elseif started and not ended and state == 0 then
    ended = true
    sample('RESTORE_FIRST', 'resident state 0 첫 프레임')
    for _, delay in ipairs({1, 2, 8, 30, 120}) do scheduled[frame + delay] = 'POST_' .. delay end
  end
  local label = scheduled[frame]
  if label then sample(label, 'scheduled sample'); scheduled[frame] = nil end
  frameWrites, minWord, maxWord = 0, nil, nil
end, emu.eventType.startFrame)

emu.addEventCallback(function() f:close() end, emu.eventType.scriptEnded)
emu.log('PROBE_SUB_VRAM_ORDER 0.1.0 loaded -- 완전 읽기 전용')
emu.log('  E6800_0E 한 번에서 $7900-$7DBF write 순서 · AC 백업 · SATB 변경 슬롯을 기록한다')
emu.log('  output: ' .. OUT)
