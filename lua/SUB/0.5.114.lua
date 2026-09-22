-- SUB 0.5.114 -- ADPCM actual voice vs native slot gate probe (read-only)
-- 0.4.6.65 Power Cycle 뒤 이 파일 하나만 로드. 키/메모리 쓰기 없음.

local TAG = 'SUB 0.5.114'
local MEM, AC, APCM = emu.memType.pceMemory, emu.memType.pceArcadeCardRam, emu.memType.pceAdpcmRam
local SLOT, STATE = 0x1F2700, 0x7FDF
local frame, last = 0, nil
local OUT = 'C:/snatcher/dump/sub/adpcm_actual_gate_0_5_114.tsv'
local f = assert(io.open(OUT, 'w'), TAG .. ': cannot open output')
f:write('frame\tkey\tfinish\trate\tslot_status\tslot_lba\tstate\n'); f:flush()

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function num(s, k) return type(s[k]) == 'number' and math.floor(s[k]) or 0 end
local function slotLba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
emu.addEventCallback(function()
  frame = frame + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s or s['cdrom.adpcm.playing'] ~= true then last = nil; return end
  local finish = (num(s, 'cdrom.adpcm.readAddress') + num(s, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
  local rate = num(s, 'cdrom.adpcm.playbackRate') & 0xFF
  local a1, a2, a3 = finish // 4, finish // 2, (finish * 5) // 8
  local key = string.format('%02X%02X%02X%02X%02X%02X', finish & 0xFF, finish >> 8, rate,
    rb(a1, APCM), rb(a2, APCM), rb(a3, APCM))
  if key == last then return end
  last = key
  local status, lb, st = rb(SLOT, AC), slotLba(), rb(STATE, MEM)
  emu.log(string.format('%s f%d key=%s finish=%04X rate=%02X slot=%02X lba=%06X state=%02X',
    TAG, frame, key, finish, rate, status, lb, st))
  f:write(string.format('%d\t%s\t%04X\t%02X\t%02X\t%06X\t%02X\n', frame, key, finish, rate, status, lb, st)); f:flush()
end, emu.eventType.endFrame)

emu.log(TAG .. ' loaded -- 실제 ADPCM 지문 + native slot/state read-only')
emu.log('  결과: ' .. OUT)
