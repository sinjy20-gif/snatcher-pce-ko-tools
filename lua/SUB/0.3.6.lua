-- SUB 0.3.6 -- 0.3.5 allocator + 선택 직후/프레임 끝 SATB 겹침 측정

SUB_ALLOCATOR_VERSION = '0.3.6'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = 0x6800
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local ENGINE, COUNT_OK, STATE = 0x5B80, 0x5B80 + 139, 0x7FDF
local N, SATB = 19 * 0x40, 0x2000
local frame, armed, last = 0, false, ''

local function m8(a) return emu.read(a, MEM) or 0 end
local function v8(a) return emu.read(a, VRAM) or 0 end
local function overlaps(a0, a1, b0, b1) return a0 <= b1 and b0 <= a1 end

local function satRefs(base)
  local out = {}
  for slot = 0, 63 do
    local at = SATB + slot * 8
    local y = v8(at) | (v8(at + 1) << 8)
    local x = v8(at + 2) | (v8(at + 3) << 8)
    local pattern = v8(at + 4) | (v8(at + 5) << 8)
    local attr = v8(at + 6) | (v8(at + 7) << 8)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local width = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local first = (pattern & 0x07FF) << 5
      local final = first + width * height * 0x40 - 1
      if overlaps(base, base + N - 1, first, final) then
        out[#out + 1] = string.format('%02d:y%03X,x%03X,w%04X-%04X,p%X,a%04X',
          slot, y, x, first, final, attr & 0x0F, attr)
      end
    end
  end
  return out
end

local function report(tag, force)
  local base = (m8(ENGINE + 167) << 8) & 0x7FFF
  local refs = satRefs(base)
  local sig = string.format('$%04X %s', base, table.concat(refs, '|'))
  if force or sig ~= last then
    emu.log(string.format('SUB 0.3.6 %s f=%d base=$%04X refs=%d %s',
      tag, frame, base, #refs, table.concat(refs, ' | ')))
    last = sig
  end
end

-- allocator의 count_ok callback 뒤에 등록된다. 선택 직후 아직 게임이 더 그리기 전.
emu.addMemoryCallback(function()
  armed = true
  report('COUNT_OK', true)
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if armed then
    report('FRAME_END', false)
    if m8(STATE) == 0 then armed = false; last = '' end
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.3.6 ready -- count_ok 직후와 frame end의 SATB 겹침 비교')
