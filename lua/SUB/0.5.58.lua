-- SUB 0.5.58 -- BIOS 0.4.6.35 active engine/helper overwrite 진단
-- 로드 시 정적 AC 데이터만 올리고, D000 arm 뒤에는 읽기만 한다.

local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.bin'
local INFO_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.lua'
local f = assert(io.open(ENGINE_PATH, 'rb'))
local expected = f:read('*a'); f:close()
local info = assert(dofile(INFO_PATH))

dofile('C:/snatcher/lua/SUB/0.5.51.lua')

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local SLOT, MINI = 0x1F2700, 0x1EF000
local ENGINE_AC, ENGINE_CPU = 0x1F1F00, 0x5B80
local HELPER_AC, HELPER_CTL = 0x1F1C00, 432
local TARGET, BASE = 0x003083, 0x6600
local selector = string.char(0x00,0xD0,0x0E,0x43,0x77,0x90,0x01,0x00,0x00)

local override = {}
override[info.offsets.vram_base_hi_imm] = BASE >> 8
override[info.offsets.pattern_base_lo_imm] = ((BASE >> 6) << 1) & 0xFF
override[info.offsets.pattern_attr_imm] = 0x80 | (((BASE >> 13) & 7) << 4) | 0x0F
for i = 1, #selector do override[info.offsets.selector + i - 1] = selector:byte(i) end

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function want(i) return override[i] or expected:byte(i + 1) end

local function compare(at, kind, count)
  local mismatches, first = 0, {}
  for i = 0, count - 1 do
    local got, exp = rb(at + i, kind), want(i)
    if got ~= exp then
      mismatches = mismatches + 1
      if #first < 12 then
        first[#first + 1] = string.format('+%03X:%02X/%02X', i, got, exp)
      end
    end
  end
  return mismatches, table.concat(first, ' ')
end

local frame, done = 0, false
emu.addEventCallback(function()
  frame = frame + 1
  if done or lba() ~= TARGET or rb(SLOT, AC) ~= 0xA2 then return end
  done = true
  local acBad, acFirst = compare(ENGINE_AC, AC, #expected)
  -- CPU의 ready/list/record/stage는 실행 중 변하므로 불변 코드 앞 365 B만 비교한다.
  local cpuBad, cpuFirst = compare(ENGINE_CPU, MEM, info.offsets.ready)
  local helper = {
    rb(HELPER_AC + HELPER_CTL + 4, AC), rb(HELPER_AC + HELPER_CTL + 5, AC),
    rb(HELPER_AC + HELPER_CTL + 6, AC), rb(HELPER_AC + HELPER_CTL + 7, AC),
  }
  local helperWant = { BASE & 0xFF, (BASE >> 8) & 0xFF,
                       (BASE >> 13) & 0xFF, (BASE >> 5) & 0xFF }
  local helperOK = true
  for i = 1, 4 do if helper[i] ~= helperWant[i] then helperOK = false end end

  emu.log(string.format('SUB 0.5.58 ★ D000 POST-ARM f%d', frame))
  emu.log(string.format('  AC engine 653 B mismatch %d · %s', acBad, acFirst))
  emu.log(string.format('  CPU code 365 B mismatch %d · %s', cpuBad, cpuFirst))
  emu.log(string.format('  helper ctl %02X %02X %02X %02X · expected %02X %02X %02X %02X · %s',
    helper[1],helper[2],helper[3],helper[4],
    helperWant[1],helperWant[2],helperWant[3],helperWant[4], helperOK and 'OK' or 'FAIL'))
  emu.log(string.format('SUB 0.5.58 RESULT activeEngine=%s cpuCode=%s helperBase=%s',
    acBad == 0 and 'OK' or 'OVERWRITTEN',
    cpuBad == 0 and 'OK' or 'WRONG-ENGINE', helperOK and 'OK' or 'OVERWRITTEN'))
end, emu.eventType.endFrame)

emu.log('SUB 0.5.58 loaded -- BIOS 0.4.6.35 overwrite diagnosis')
emu.log('  D000 뒤 active AC engine 653 B / CPU code / helper base 자동 비교')
