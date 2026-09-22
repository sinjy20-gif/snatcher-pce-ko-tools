-- SUB 0.5.110 -- ADPCM native key별 VRAM base 적용 측정기 (read-only)
--
-- 0.4.6.64를 Power Cycle 한 뒤 이 파일만 로드한다.
-- Track24가 올린 A9722A5F native bundle을 절대 바꾸지 않는다. 이 Lua는
-- state=$02 전이 때만 다음 넷을 대조한다.
--   1) 로컬 A972 directory의 기대 3 B
--   2) AC $1F2800의 실제 directory 3 B
--   3) active AC renderer $1F1F00의 즉치값 3 B
--   4) CPU renderer $5B80의 즉치값 3 B + helper control
--
-- 키/E 입력/CPU RAM/VRAM/AC 쓰기 없음. 음성마다 자동 TSV 한 줄씩 남긴다.

local TAG = 'SUB 0.5.110'
local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local STATE, SLOT = 0x7FDF, 0x1F2700
local DIR_AT, ENGINE_AC, ENGINE_CPU = 0x1F2800, 0x1F1F00, 0x5B80
local HELPER_CTL = 0x1F1C00 + 432 + 4
local OFF_HI, OFF_LO, OFF_ATTR = 242, 277, 282
local MAX_EVENTS = 240
local OUT = 'C:/snatcher/dump/sub/adpcm_base_apply_0_5_110.tsv'
local DIR_PATH = 'C:/snatcher/build/cutscene_subs/adpcm_native_subtitle_dir_A9722A5F.bin'

local function readFile(path)
  local f = assert(io.open(path, 'rb'), TAG .. ': cannot open ' .. path)
  local s = f:read('*a'); f:close(); return s
end

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function hex3(a, b, c) return string.format('%02X%02X%02X', a, b, c) end
local function lbaFromSlot()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end

-- directory는 LBA 오름차순 9 B. Lua 시작 때 한 번만 host file에서 색인화한다.
local raw = readFile(DIR_PATH)
assert(#raw % 9 == 0, TAG .. ': directory stride error')
local expected = {}
for at = 1, #raw, 9 do
  local lba = (raw:byte(at) << 16) | (raw:byte(at + 1) << 8) | raw:byte(at + 2)
  expected[lba] = { raw:byte(at + 6), raw:byte(at + 7), raw:byte(at + 8), at - 1 }
end

local f = assert(io.open(OUT, 'w'), TAG .. ': cannot open ' .. OUT)
f:write('frame\tlba\texpected\tdir_ac\tengine_ac\tengine_cpu\thelper\tresult\n')
f:flush()

local frame, priorState, events = 0, -1, 0
local function triplet(at, kind, offsets)
  return hex3(rb(at + offsets[1], kind), rb(at + offsets[2], kind), rb(at + offsets[3], kind))
end
local function helperValue()
  -- helper control: base low, base high, base>>13, base>>5
  return string.format('%02X%02X%02X%02X', rb(HELPER_CTL, AC), rb(HELPER_CTL + 1, AC),
    rb(HELPER_CTL + 2, AC), rb(HELPER_CTL + 3, AC))
end

emu.addEventCallback(function()
  frame = frame + 1
  local state = rb(STATE, MEM)
  if state == 2 and priorState ~= 2 and events < MAX_EVENTS then
    events = events + 1
    local lba = lbaFromSlot()
    local row = expected[lba]
    if not row then
      emu.log(string.format('%s #%d f%d LBA %06X NO-DIRECTORY', TAG, events, frame, lba))
      f:write(string.format('%d\t%06X\t-\t-\t-\t-\t-\tNO-DIRECTORY\n', frame, lba))
    else
      local want = hex3(row[1], row[2], row[3])
      local dirAc = triplet(DIR_AT + row[4] + 6, AC, {0, 1, 2})
      local engineAc = triplet(ENGINE_AC, AC, {OFF_HI, OFF_LO, OFF_ATTR})
      local engineCpu = triplet(ENGINE_CPU, MEM, {OFF_HI, OFF_LO, OFF_ATTR})
      local helper = helperValue()
      local result = (want == dirAc and want == engineAc and want == engineCpu) and 'OK' or 'MISMATCH'
      emu.log(string.format('%s #%d f%d LBA %06X want=%s dir=%s ac=%s cpu=%s helper=%s %s',
        TAG, events, frame, lba, want, dirAc, engineAc, engineCpu, helper, result))
      f:write(string.format('%d\t%06X\t%s\t%s\t%s\t%s\t%s\t%s\n',
        frame, lba, want, dirAc, engineAc, engineCpu, helper, result))
    end
    f:flush()
  end
  priorState = state
end, emu.eventType.endFrame)

emu.log(TAG .. ' loaded -- A9722A5F key별 base 적용 read-only 측정')
emu.log('  0.4.6.64 Power Cycle 뒤 이 파일 하나만 로드 · 키 입력 없음')
emu.log('  state $02마다 expected / AC dir / AC engine / CPU engine 자동 대조')
emu.log('  결과: ' .. OUT)
