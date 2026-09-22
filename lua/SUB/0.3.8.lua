-- SUB 0.3.8 -- 0.3.5 allocator의 "안전 블록 없음" 가드 실동작 검사
-- 이 파일 하나만 실행한다. 디스크/AC/VRAM에는 직접 쓰지 않는다.

SUB_ALLOCATOR_VERSION = '0.3.8'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = 0x6800
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local ENGINE, COUNT_OK, GLYPH_DONE, PUSH, STATE = 0x5B80, 0x5C0B, 0x5CB6, 0x5CBB, 0x7FDF
local N = 19 * 0x40
local guardArmed, glyphDone, pushed, checked = false, false, false, 0

local function v8(a) return emu.read(a, VRAM) or 0 end
local function m8(a) return emu.read(a, MEM) or 0 end
local function rw(word)
  local a = word * 2
  return v8(a) | (v8(a + 1) << 8)
end

local function mark(used, first, count)
  if first < 0 or first > 0x7FFF then return end
  local last = math.min(first + count - 1, 0x7FFF)
  for w = first, last do used[w] = true end
end

local function dim(v, fallback)
  v = tonumber(v)
  if v == 32 or v == 64 or v == 128 then return v end
  return fallback
end

-- 0.3.5와 같은 BAT+SATB 판정이다. 내용이 0인지 여부는 보지 않는다.
local function safeBase()
  local used = {}
  local ok, s = pcall(emu.getState)
  if not ok or not s then s = {} end
  local columns = dim(s['vdc.hvReg.columnCount'], 64)
  local rows = dim(s['vdc.hvReg.rowCount'], 64)
  local entries = math.min(columns * rows, 0x1000)

  local seen = {}
  for i = 0, entries - 1 do
    local p = rw(i) & 0x07FF
    if not seen[p] then
      seen[p] = true
      mark(used, p * 0x10, 0x10)
    end
  end

  for slot = 0, 63 do
    local a = 0x2000 + slot * 8
    local y = v8(a) | (v8(a + 1) << 8)
    local x = v8(a + 2) | (v8(a + 3) << 8)
    local p = v8(a + 4) | (v8(a + 5) << 8)
    local attr = v8(a + 6) | (v8(a + 7) << 8)
    if y ~= 0 or x ~= 0 or p ~= 0 or attr ~= 0 then
      local width = ((attr & 0x0100) ~= 0) and 2 or 1
      local hc = (attr >> 12) & 3
      local height = (hc == 0) and 1 or ((hc == 1) and 2 or 4)
      mark(used, (p & 0x07FF) << 5, width * height * 0x40)
    end
  end

  for base = 0x6000, 0x7B00, 0x100 do
    local free = true
    for w = base, base + N - 1 do
      if used[w] then free = false; break end
    end
    if free then return base end
  end
  return nil
end

-- allocator callback 다음에 등록되므로, 같은 count_ok에서 allocator 판단 뒤 상태를 본다.
emu.addMemoryCallback(function()
  checked = checked + 1
  guardArmed, glyphDone, pushed = safeBase() == nil, false, false
  local actual = (m8(ENGINE + 167) << 8) & 0x7FFF
  if guardArmed then
    emu.log(string.format('SUB 0.3.8 GUARD #%d: 안전 블록 없음 · 실제 목적지=$%04X · 이후 업로드 감시',
                          checked, actual))
  else
    emu.log(string.format('SUB 0.3.8 ALLOC #%d: 안전 블록 있음 · 실제 목적지=$%04X', checked, actual))
  end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if guardArmed then
    glyphDone = true
    emu.log('SUB 0.3.8 ★ GUARD FAIL: 안전 블록이 없는데 GLYPH_DONE까지 실행됨')
  end
end, emu.callbackType.exec, GLYPH_DONE, GLYPH_DONE, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if guardArmed then
    pushed = true
    emu.log('SUB 0.3.8 ★ GUARD FAIL: 안전 블록이 없는데 SATB PUSH까지 실행됨')
  end
end, emu.callbackType.exec, PUSH, PUSH, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  if guardArmed and m8(STATE) == 0 then
    if not glyphDone and not pushed then
      emu.log('SUB 0.3.8 ★ GUARD PASS: 안전 블록 없음 · 글리프/SATB 생성 0')
    else
      emu.log(string.format('SUB 0.3.8 GUARD RESULT: FAIL glyph=%s push=%s',
                            tostring(glyphDone), tostring(pushed)))
    end
    guardArmed = false
  end
end, emu.eventType.startFrame)

emu.log('SUB 0.3.8 loaded -- allocator guard audit / 이 파일 하나만 사용')
emu.log('  합격: 안전 블록 없음 뒤 GUARD PASS · 실패: GLYPH_DONE 또는 SATB PUSH')
