-- SUB 0.5.59 -- BIOS 0.4.6.36 template restore + 실제 render path 검증

local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.bin'
local INFO_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.lua'
local f = assert(io.open(ENGINE_PATH, 'rb'))
local expected = f:read('*a'); f:close()
local info = assert(dofile(INFO_PATH))

dofile('C:/snatcher/lua/SUB/0.5.51.lua')

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                     emu.cpuType.pce
local SLOT, MINI = 0x1F2700, 0x1EF000
local ENGINE_AC, ENGINE_CPU = 0x1F1F00, 0x5B80
local HELPER_AC, HELPER_CTL = 0x1F1C00, 432
local TARGET, BASE = 0x003083, 0x6600
local selector = string.char(0x00,0xD0,0x0E,0x43,0x77,0x90,0x01,0x00,0x00)
local expectedSelector = '00D00E437790010000'
local expectedMini = '00D00E437790010000C3690000'

local override = {}
override[info.offsets.vram_base_hi_imm] = BASE >> 8
override[info.offsets.pattern_base_lo_imm] = ((BASE >> 6) << 1) & 0xFF
override[info.offsets.pattern_attr_imm] = 0x80 | (((BASE >> 13) & 7) << 4) | 0x0F
for i = 1, #selector do override[info.offsets.selector + i - 1] = selector:byte(i) end

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function want(i) return override[i] or expected:byte(i + 1) end
local function mismatch(at, kind, count)
  local n = 0
  for i = 0, count - 1 do if rb(at + i, kind) ~= want(i) then n = n + 1 end end
  return n
end
local function yn(v) return v and 'OK' or 'FAIL' end

local hits = { entry=0, count=0, glyph=0, push=0 }
for name, key in pairs({entry='entry', count='count_ok', glyph='glyph_loop', push='push'}) do
  local at = ENGINE_CPU + info.offsets[key]
  local hitName = name
  emu.addMemoryCallback(function() hits[hitName] = hits[hitName] + 1 end,
    emu.callbackType.exec, at, at, CPU, MEM)
end

local frame, armedFrame, reported = 0, nil, false
emu.addEventCallback(function()
  frame = frame + 1
  if not armedFrame and lba() == TARGET and rb(SLOT, AC) == 0xA2 then
    armedFrame = frame
    emu.log(string.format('SUB 0.5.59 D000 armed f%d · 5프레임 뒤 render 판정', frame))
  end
  if reported or not armedFrame or frame < armedFrame + 5 then return end
  reported = true

  local acBad = mismatch(ENGINE_AC, AC, #expected)
  local cpuBad = mismatch(ENGINE_CPU, MEM, info.offsets.ready)
  local helper = hex(HELPER_AC + HELPER_CTL + 4, 4, AC)
  local mini = hex(MINI, 13, AC)
  local selAC = hex(ENGINE_AC + info.offsets.selector, 9, AC)
  local selCPU = hex(ENGINE_CPU + info.offsets.selector, 9, MEM)
  local ready = rb(ENGINE_CPU + info.offsets.ready, MEM)

  emu.log(string.format('SUB 0.5.59 ★ D000 RENDER CHECK f%d', frame))
  emu.log(string.format('  active engine mismatch %d · CPU code mismatch %d', acBad, cpuBad))
  emu.log(string.format('  helper %s · mini %s · selector AC/CPU %s/%s',
    helper, mini, selAC, selCPU))
  emu.log(string.format('  hits entry=%d count_ok=%d glyph=%d push=%d ready=$%02X',
    hits.entry, hits.count, hits.glyph, hits.push, ready))
  emu.log(string.format(
    'SUB 0.5.59 RESULT engine=%s cpu=%s helper=%s mini=%s selector=%s renderPath=%s',
    yn(acBad == 0), yn(cpuBad == 0), yn(helper == '00660330'),
    yn(mini == expectedMini), yn(selAC == expectedSelector and selCPU == selAC),
    yn(hits.entry > 0 and hits.count > 0 and hits.glyph > 0 and hits.push > 0 and ready == 1)))
end, emu.eventType.endFrame)

emu.log('SUB 0.5.59 loaded -- BIOS 0.4.6.36 only')
emu.log('  safe template restore + helper base + 실제 renderer 경로 자동 판정')
