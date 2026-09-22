-- PROBE_SUB_SATB_RESIDUE 0.1.0 -- native POC 종료 뒤에 남는 자막 SATB 슬롯만 읽는다.
-- $7900 VRAM 복원은 이미 byte-exact로 통과한 뒤의 2차 측정이다. 쓰기 없음.

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local SAT, STATE = 0x2000, 0x7FDF
local OUT = string.format('C:/snatcher/dump/probe_sub_satb_residue_0_1_0_%s.tsv', os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
f:write('phase\tframe\tstate\tslots\n')

local function slotList()
  local out = {}
  for slot = 0, 63 do
    local at = SAT + slot * 8
    local y = (emu.read(at, VRAM) or 0) | ((emu.read(at + 1, VRAM) or 0) << 8)
    local x = (emu.read(at + 2, VRAM) or 0) | ((emu.read(at + 3, VRAM) or 0) << 8)
    local pat = (emu.read(at + 4, VRAM) or 0) | ((emu.read(at + 5, VRAM) or 0) << 8)
    local attr = (emu.read(at + 6, VRAM) or 0) | ((emu.read(at + 7, VRAM) or 0) << 8)
    if pat >= 0x03C4 and pat <= 0x03E9 then
      out[#out + 1] = string.format('%02d:y%04X,x%04X,p%04X,a%04X', slot, y, x, pat, attr)
    end
  end
  return #out == 0 and '-' or table.concat(out, '|')
end

local frame, armed, active, restored = 0, false, false, false
local scheduled = {}
local function report(phase)
  local slots = slotList()
  local state = emu.read(STATE, MEM) or 0xFF
  f:write(string.format('%s\t%d\t%02X\t%s\n', phase, frame, state, slots)); f:flush()
  emu.log(string.format('SATB RESIDUE %s f=%d state=%02X %s', phase, frame, state, slots))
end

emu.addMemoryCallback(function()
  local st = emu.getState()
  local ending = ((st['cdrom.adpcm.readAddress'] or 0) + (st['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if ending == 0x6800 and (st['cdrom.adpcm.playbackRate'] or -1) == 0x0E then
    armed, active, restored, scheduled = true, false, false, {}
    report('AD_PLAY_PRE')
  end
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if not armed then return end
  local state = emu.read(STATE, MEM) or 0xFF
  if not active and state == 2 then
    active = true; report('ACTIVE')
  elseif active and not restored and state == 0 then
    restored = true; report('RESTORE_FIRST')
    for _, d in ipairs({1, 2, 8, 30, 120}) do scheduled[frame + d] = 'POST_' .. d end
  end
  local label = scheduled[frame]
  if label then scheduled[frame] = nil; report(label) end
end, emu.eventType.startFrame)

emu.addEventCallback(function() f:close() end, emu.eventType.scriptEnded)
emu.log('PROBE_SUB_SATB_RESIDUE 0.1.0 loaded -- 완전 읽기 전용')
emu.log('  E6800_0E 종료 후 자막 패턴($03C4-$03E9)이 남은 정확한 슬롯/좌표를 기록한다')
emu.log('  output: ' .. OUT)
