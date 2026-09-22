-- SUB 0.2.1 -- subtitle fragment allocator test (single script)
--
-- 실행: 현재 native subtitle 시험 디스크를 켠 뒤 이 파일 하나만 Load.
-- 대상: 접수처 E6800_0E 음성. 팩에 등록된 자막 조각은 정확히 2개다.
-- 이 판은 매 조각마다 빈 19글자 블록을 다시 고르고, 선택 블록의 원본을
-- Lua에서도 보관/복귀한다. 최종 native allocator 전의 검증판이다.

local MEM, VRAM, AC, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam,
                              emu.memType.pceArcadeCardRam, emu.memType.cpu
local ENGINE, REBUILD, STATE = 0x5B80, 0x5BA6, 0x7FDF
local AC_HELPER, AC_RENDERER = 0x1F1C00, 0x1F1F00
local WORDS, TARGET_END = 19 * 0x40, 0x6800
local KEY = {0x78, 0x30, 0x00, 0x00, 0x68, 0x0E}

local active, started, pendingBase, currentBase, parts, frame = false, false, nil, nil, 0, 0
local saved, measure = {}, nil

local function file(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end
local HELPER = file('C:/snatcher/build/cutscene_subs/subtitle_vram_helper.bin')
local RENDERER = file('C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin')

local function rb(a) return emu.read(a, VRAM) or 0 end
local function wb(a, v) emu.write(a, v, VRAM) end
local function poke(s, pos, v) return s:sub(1, pos - 1) .. string.char(v) .. s:sub(pos + 1) end
local function put(at, data)
  for i = 1, #data do emu.write(at + i - 1, data:byte(i), AC) end
end

local function snapshot(base)
  local t = {}
  for word = base, base + WORDS - 1 do
    local at = word * 2; t[#t + 1] = rb(at); t[#t + 1] = rb(at + 1)
  end
  saved[base] = t
end
local function restore(base)
  local t = saved[base]; if not t then return false end
  for word = base, base + WORDS - 1 do
    local at, i = word * 2, (word - base) * 2 + 1
    wb(at, t[i]); wb(at + 1, t[i + 1])
  end
  return true
end
local function satbUses(base)
  local lo = (base >> 5) & 0xFFFF
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8 + 4
    local pat = rb(at) | (rb(at + 1) << 8)
    if pat >= lo and pat < lo + 38 then return true end
  end
  return false
end
local function blank(base)
  for word = base, base + WORDS - 1 do
    local at = word * 2
    if rb(at) ~= 0 or rb(at + 1) ~= 0 then return false end
  end
  return true
end
local function choose()
  for base = 0x6000, 0x7B00, 0x100 do
    if blank(base) and not satbUses(base) then return base end
  end
end
local function patchFirst(base)
  -- helper binary offsets 41/133, renderer offsets 167/276 (zero-based).
  local h = poke(poke(HELPER, 42, base >> 8), 134, base >> 8)
  local r = poke(poke(RENDERER, 168, base >> 8), 277, (base >> 5) & 0xFF)
  put(AC_HELPER, h); put(AC_RENDERER, r)
  for i = 1, 6 do emu.write(AC_RENDERER + 365 + i, KEY[i], AC) end
end
local function patchRunning(base)
  emu.write(ENGINE + 167, base >> 8, MEM)
  emu.write(ENGINE + 276, (base >> 5) & 0xFF, MEM)
end
local function usedBytes(base)
  local n = 0
  for at = base * 2, (base + WORDS) * 2 - 1 do if rb(at) ~= 0 then n = n + 1 end end
  return n
end
local function satbCount(base)
  local lo, n = (base >> 5) & 0xFFFF, 0
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8 + 4
    local pat = rb(at) | (rb(at + 1) << 8)
    if pat >= lo and pat < lo + 38 then n = n + 1 end
  end
  return n
end
local function finish(why)
  if currentBase and restore(currentBase) then
    emu.log(string.format('SUB 0.2.1 RESTORE: $%04X (%s)', currentBase, why))
  end
  active, started, pendingBase, currentBase, parts, saved, measure = false, false, nil, nil, 0, {}, nil
end

emu.addMemoryCallback(function()
  local st = emu.getState()
  local ending = ((st['cdrom.adpcm.readAddress'] or 0) + (st['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if ending ~= TARGET_END or (st['cdrom.adpcm.playbackRate'] or -1) ~= 0x0E then return end
  finish('new voice')
  pendingBase = choose()
  if not pendingBase then emu.log('SUB 0.2.1 SKIP: safe 19-glyph block 없음'); return end
  patchFirst(pendingBase); active = true
  emu.log(string.format('SUB 0.2.1 START: first=$%04X', pendingBase))
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if not active then return end
  -- 이 시험 renderer가 둘째 조각 뒤 같은 rebuild를 반복하는 버그를 갖고 있다.
  -- 팩에서 확인한 이 음성의 실제 조각 2개만 처리한다.
  if parts >= 2 then return end
  if currentBase then restore(currentBase) end
  local base = pendingBase or choose(); pendingBase = nil
  if not base then emu.log('SUB 0.2.1 SKIP: safe 19-glyph block 없음'); return end
  if not saved[base] then snapshot(base) end
  patchRunning(base); currentBase, parts, started = base, parts + 1, true
  measure = {base = base, part = parts, due = frame + 1}
  emu.log(string.format('SUB 0.2.1 ALLOC #%d: $%04X (blank + SATB-free)', parts, base))
end, emu.callbackType.exec, REBUILD, REBUILD, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if measure and frame >= measure.due then
    emu.log(string.format('SUB 0.2.1 MEASURE #%d: VRAM=%d/2432 SATB=%d state=%02X',
      measure.part, usedBytes(measure.base), satbCount(measure.base), emu.read(STATE, MEM) or 0))
    measure = nil
  end
  if active and started and (emu.read(STATE, MEM) or 0) == 0 then finish('voice end') end
end, emu.eventType.startFrame)

emu.log('SUB 0.2.1 loaded -- allocator test / 이 파일 하나만 사용')
emu.log('  이전 POC_SUBTITLE_DYNAMIC_* 및 PROBE_SUBTITLE_FRAGMENT_* 는 중지할 것')
