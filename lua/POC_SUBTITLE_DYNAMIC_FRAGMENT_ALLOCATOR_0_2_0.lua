-- Dynamic subtitle VRAM allocator POC 0.2.0.
--
-- 0.1.0은 ADPCM 시작(F61A)에서 한 번만 자리를 골랐다.
-- 이 판은 renderer의 rebuild($5BA6) 직전에 매 조각마다
--   이전 자리 복원 -> 현재 장면의 빈 19글자 블록 탐색 -> 새 자리 백업
--   -> renderer의 VRAM/pattern 즉시값 교체
-- 순서로 수행한다. Lua-only 검증판이며 최종 디스크 빌드에는 아직 넣지 않는다.

local MEM, VRAM, AC, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam,
                              emu.memType.pceArcadeCardRam, emu.memType.cpu
local ENGINE, REBUILD, STATE = 0x5B80, 0x5BA6, 0x7FDF
local AC_HELPER, AC_RENDERER = 0x1F1C00, 0x1F1F00
local N, FIRST_TARGET = 19 * 0x40, 0x6800
local active, started, firstBase, currentBase, pendingBase, rebuilds = false, false, nil, nil, nil, 0
local saved = {}

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end
local HELPER = readFile('C:/snatcher/build/cutscene_subs/subtitle_vram_helper.bin')
local RENDERER = readFile('C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin')
local KEY = {0x78, 0x30, 0x00, 0x00, 0x68, 0x0E}

local function poke(s, pos, value)
  return s:sub(1, pos - 1) .. string.char(value) .. s:sub(pos + 1)
end
local function put(at, data)
  for i = 1, #data do emu.write(at + i - 1, data:byte(i), AC) end
end
local function prepareFirst(base)
  -- helper 41/133, renderer 167/276 are binary zero-based offsets.
  local h = poke(poke(HELPER, 42, base >> 8), 134, base >> 8)
  local r = poke(poke(RENDERER, 168, base >> 8), 277, (base >> 5) & 0xFF)
  put(AC_HELPER, h); put(AC_RENDERER, r)
  for i = 1, 6 do emu.write(AC_RENDERER + 365 + i, KEY[i], AC) end
end

local function rb(addr) return emu.read(addr, VRAM) or 0 end
local function wb(addr, value) emu.write(addr, value, VRAM) end

local function snapshot(base)
  local data = {}
  for word = base, base + N - 1 do
    local at = word * 2
    data[#data + 1] = rb(at)
    data[#data + 1] = rb(at + 1)
  end
  saved[base] = data
end

local function restore(base)
  local data = saved[base]
  if not data then return false end
  for word = base, base + N - 1 do
    local at, i = word * 2, (word - base) * 2 + 1
    wb(at, data[i]); wb(at + 1, data[i + 1])
  end
  return true
end

local function satbUses(base)
  local pat0 = (base >> 5) & 0xFFFF
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8 + 4
    local pat = rb(at) | (rb(at + 1) << 8)
    if pat >= pat0 and pat < pat0 + 38 then return true end
  end
  return false
end

local function blank(base)
  for word = base, base + N - 1 do
    local at = word * 2
    if rb(at) ~= 0 or rb(at + 1) ~= 0 then return false end
  end
  return true
end

local function choose()
  -- 0x100-word aligned: pattern word high bits stay constant, low byte만 교체한다.
  for base = 0x6000, 0x7B00, 0x100 do
    if blank(base) and not satbUses(base) then return base end
  end
  return nil
end

local function patchRenderer(base)
  -- renderer binary offset 167 = VDC MAWR high, 276 = list pattern low.
  -- CPU address is zero-based offset from $5B80.
  emu.write(ENGINE + 167, base >> 8, MEM)
  emu.write(ENGINE + 276, (base >> 5) & 0xFF, MEM)
end

local function reset(reason)
  -- native helper가 원래 $7900만 복원하므로, Lua가 고른 블록은 첫 조각이든
  -- 후속 조각이든 여기서 반드시 원본으로 되돌린다.
  if currentBase and restore(currentBase) then
    emu.log(string.format('DYNAMIC FRAGMENT restore $%04X (%s)', currentBase, reason))
  end
  active, started, firstBase, currentBase, pendingBase, rebuilds, saved = false, false, nil, nil, nil, 0, {}
end

emu.addMemoryCallback(function()
  local st = emu.getState()
  local endAddr = ((st['cdrom.adpcm.readAddress'] or 0) +
                   (st['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if endAddr ~= FIRST_TARGET or (st['cdrom.adpcm.playbackRate'] or -1) ~= 0x0E then return end
  reset('new voice')
  pendingBase = choose()
  if not pendingBase then
    emu.log('DYNAMIC FRAGMENT START SKIP: safe 19-glyph block 없음')
    return
  end
  -- helper도 같은 블록을 먼저 백업해야 종료 복귀가 고정 $7900에 남지 않는다.
  prepareFirst(pendingBase)
  active = true
  emu.log(string.format('DYNAMIC FRAGMENT armed: first $%04X · rebuild마다 allocator 실행', pendingBase))
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if not active then return end
  -- 이 0.4.1 시험 엔진은 두 번째 조각 이후에도 같은 rebuild를 반복한다.
  -- selector 영역은 list 버퍼와 겹쳐서 비교값으로 쓸 수 없으므로, 이 2조각
  -- 고정 POC에서는 두 번만 allocator를 실행한다.
  if rebuilds >= 2 then return end
  -- 첫 rebuild 직전에는 native helper가 이미 첫 블록을 백업했다.
  -- 이후 조각부터는 여기서 이전 블록을 먼저 되돌린다.
  if currentBase then restore(currentBase) end
  local base = pendingBase or choose()
  pendingBase = nil
  if not base then
    emu.log(string.format('DYNAMIC FRAGMENT SKIP #%d: safe 19-glyph block 없음', rebuilds + 1))
    return
  end
  if not saved[base] then snapshot(base) end
  patchRenderer(base)
  started = true
  rebuilds = rebuilds + 1
  if not firstBase then firstBase = base end
  currentBase = base
  emu.log(string.format('DYNAMIC FRAGMENT #%d: $%04X selected (blank + SATB-free)', rebuilds, base))
end, emu.callbackType.exec, REBUILD, REBUILD, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  if active and started and (emu.read(STATE, MEM) or 0) == 0 then reset('voice end') end
end, emu.eventType.startFrame)

emu.log('POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR 0.2.0 loaded -- rebuild-hook Lua POC')
emu.log('  renderer $5BA6 직전마다 19글자 VRAM 블록을 재선정한다')
