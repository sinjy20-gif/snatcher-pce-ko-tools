-- SUB 0.4.31 -- 전체 음성 자막의 콘솔 6 B 키 연결 / Lua 실증판
--
-- 기준 디스크: 0.4.6.11. 디스크는 굽지 않는다.
-- 새 v6 팩과 엔진을 AC RAM에 올린 뒤, 실제 ADPCM의
--   end u16 + rate u8 + RAM[end/4,end/2,5*end/8]
-- 키가 팩에 있을 때만 네이티브 자막 gate를 연다.
-- 자막이 없는 음성/효과음은 CPU·VRAM·gate를 전혀 건드리지 않는다.

local MEM = emu.memType.pceMemory
local APCM = emu.memType.pceAdpcmRam
local AC = emu.memType.pceArcadeCardRam
local CPU = emu.cpuType.pce

local PACK_AT, ENGINE_AT = 0x1C0000, 0x1F1F00
local ENGINE_CPU, STATE, GATE, GATE_RET = 0x5B80, 0x7FDF, 0xFEC4, 0xFF0F
local SELECTOR = rawget(_G, 'SUB_VOICE_SELECTOR') or 383
local NEXT_SELECTOR = rawget(_G, 'SUB_VOICE_NEXT_SELECTOR') or 463
local TARGET_END, TARGET_RATE = 0x6800, 0x0E
local VERSION = rawget(_G, 'SUB_VOICE_KEY_VERSION') or '0.4.31'
local MINI_INDEX = rawget(_G, 'SUB_VOICE_MINI_INDEX')
local MINI_COUNT = rawget(_G, 'SUB_VOICE_MINI_COUNT')
local COUNT_OK = rawget(_G, 'SUB_VOICE_COUNT_OK')
local LUA_TIMER = rawget(_G, 'SUB_VOICE_LUA_TIMER') == true
local READY_OFFSET = rawget(_G, 'SUB_VOICE_READY_OFFSET')
local NO_NEXT_SELECTOR = rawget(_G, 'SUB_VOICE_NO_NEXT_SELECTOR') == true
local AUDIT = rawget(_G, 'SUB_VOICE_AUDIT') == true
local SUPPRESS_LEGACY_GATE = rawget(_G, 'SUB_VOICE_SUPPRESS_LEGACY_GATE') == true
-- 진단용 대체 엔진은 길이/매직이 원본과 같을 수 있다. 그 경우 표본 몇 바이트
-- 비교만으로는 AC의 이전 엔진을 구별 못 하므로 처음 한 번 강제 적재한다.
local FORCE_ENGINE_UPLOAD = rawget(_G, 'SUB_VOICE_FORCE_ENGINE_UPLOAD') == true
-- 이분용. true 면 gate fingerprint를 안 써서 엔진이 한 번도 안 돈다 (자막 없음).
local NO_GATE = rawget(_G, 'SUB_VOICE_NO_GATE') == true
-- 키별 VRAM 표 wrapper의 선택 훅. false를 돌려주면 해당 키는 이번 실험에서
-- 자막 gate를 열지 않는다. 표에 없는 음성을 고정 $1600로 되돌리지 않는다.
local SELECT_BASE = rawget(_G, 'SUB_VOICE_SELECT_BASE')
-- native LBA dispatcher가 AC 슬롯에 써 준 6 B runtime key를 입력으로 쓸 수 있다.
-- nil이면 기존 ADPCM RAM 표본 경로를 그대로 유지한다.
local NATIVE_SLOT = rawget(_G, 'SUB_VOICE_NATIVE_SLOT')
-- 동결 기준 재현처럼 pack/engine이 반드시 같은 세대여야 하는 경우에만 caller가
-- 경로를 지정한다. 기본 현행 경로는 그대로 유지한다.
local PACK_PATH = rawget(_G, 'SUB_VOICE_PACK_PATH') or
                  'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local ENGINE_PATH = rawget(_G, 'SUB_VOICE_ENGINE_PATH') or
                    'C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin'
local ENGINE_BYTES = rawget(_G, 'SUB_VOICE_ENGINE_BYTES') or 669

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local function u16(data, at)
  return data:byte(at + 1) | (data:byte(at + 2) << 8)
end

local function u32(data, at)
  return u16(data, at) | (u16(data, at + 2) << 16)
end

local function hex(data)
  local out = {}
  for i = 1, #data do out[#out + 1] = string.format('%02X', data:byte(i)) end
  return table.concat(out)
end

local function put(at, data, kind)
  for i = 1, #data do emu.write(at + i - 1, data:byte(i), kind) end
end

local pack, engine = readFile(PACK_PATH), readFile(ENGINE_PATH)
assert(pack:sub(1, 4) == 'SNSB' and u16(pack, 4) == 6, 'subtitle pack is not SNSB v6')
assert(#engine == ENGINE_BYTES, 'unexpected engine size: ' .. #engine)

-- 팩 색인 자체에서 음성별 selector 순서를 만든다. TSV 싱크를 다시 계산하지 않는다.
local count, indexAt = u16(pack, 14), u32(pack, 16)
local schedule = {}
for n = 0, count - 1 do
  local at = indexAt + n * 13
  local key = pack:sub(at + 1, at + 6)
  local item = { flags = pack:byte(at + 7), start = u16(pack, at + 7),
                 raw = pack:sub(at + 1, at + 13) }
  local id = hex(key)
  schedule[id] = schedule[id] or {}
  schedule[id][#schedule[id] + 1] = item
end

-- 0.4.6.11의 선적재 결과만 시험 중 교체한다. 디스크/BIOS 파일은 무수정.
-- Power Cycle 뒤 게임 선적재가 이 내용을 다시 덮을 수 있으므로 첫 음성 gate에서
-- v6가 아니면 한 번 더 올린다. 평상시에는 비교 몇 바이트뿐이다.
local installs = 0
local function ensureInstalled()
  local packV6 = (emu.read(PACK_AT + 4, AC) or 0) == 6 and
                 (emu.read(PACK_AT + 5, AC) or 0) == 0
  -- 표본 몇 바이트만 보면 안 된다. 진단용 대체 엔진은 길이·매직·대부분의
  -- 바이트가 원본과 같고 딱 몇 바이트만 다르다 (한 글자 엔진은 +$6D 3 B).
  -- 표본에 그 자리가 없으면 AC에 원본이 남아 있어도 "일치"로 읽혀 조용히
  -- 원본이 계속 돈다. 실제로 0.4.87 두 번의 실패가 이것이었다.
  -- 631 B 전량 비교는 음성 gate당 한 번뿐이라 비용이 문제되지 않는다.
  local engineOk = true
  for offset = 0, #engine - 1 do
    if (emu.read(ENGINE_AT + offset, AC) or -1) ~= engine:byte(offset + 1) then
      engineOk = false; break
    end
  end
  if packV6 and engineOk and not FORCE_ENGINE_UPLOAD then return end
  -- 팩과 엔진을 따로 덮는다.  엔진 슬롯 $1F1F00 은 디스크 상주 렌더러 자리라
  -- 장면 전환마다 디스크 이미지로 되돌아온다.  그때마다 팩 184 KB 까지 같이
  -- 올리면 음성 하나에 18만 번의 emu.write 가 되어 실행이 눈에 띄게 느려진다.
  -- 실제로 어긋난 쪽만 쓴다.  로그의 바이트 수가 이번에 쓴 양이다 (0 = 건너뜀).
  local wrotePack, wroteEngine = 0, 0
  if not packV6 then put(PACK_AT, pack, AC); wrotePack = #pack end
  if not engineOk or FORCE_ENGINE_UPLOAD then
    put(ENGINE_AT, engine, AC); wroteEngine = #engine
  end
  FORCE_ENGINE_UPLOAD = false
  installs = installs + 1
  emu.log(string.format('SUB %s AC install #%d · pack %d B · engine %d B',
                        VERSION, installs, wrotePack, wroteEngine))
end
ensureInstalled()

local function number(state, name)
  local value = state[name]
  return type(value) == 'number' and math.floor(value) or 0
end

local function actualVoice()
  local ok, state = pcall(emu.getState)
  if not ok or not state or state['cdrom.adpcm.playing'] ~= true then return nil end
  if type(NATIVE_SLOT) == 'number' then
    if (emu.read(NATIVE_SLOT, AC) or 0) ~= 0xA1 then return nil end
    local key = string.char(
      emu.read(NATIVE_SLOT + 4, AC) or 0, emu.read(NATIVE_SLOT + 5, AC) or 0,
      emu.read(NATIVE_SLOT + 6, AC) or 0, emu.read(NATIVE_SLOT + 7, AC) or 0,
      emu.read(NATIVE_SLOT + 8, AC) or 0, emu.read(NATIVE_SLOT + 9, AC) or 0)
    return { key = key, id = hex(key), finish = 0, rate = 0 }
  end
  local finish = (number(state, 'cdrom.adpcm.readAddress') +
                  number(state, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
  local rate = number(state, 'cdrom.adpcm.playbackRate') & 0xFF
  -- 표본 자리는 이대로 **고정**한다 (build_voice_console_keys.py 와 같아야 한다).
  -- 옮겨서 충돌을 줄이려는 시도는 2026-09-02 에 실패했다 -- 버퍼 앞쪽 자리는
  -- 클립 범위 밖이라 산출이 1,211 -> 1,022 로 줄어든다.  그쪽 주석 참고.
  local a1, a2, a3 = finish // 4, finish // 2, (finish * 5) // 8
  local key = string.char(finish & 0xFF, finish >> 8, rate,
                          emu.read(a1, APCM) or 0,
                          emu.read(a2, APCM) or 0,
                          emu.read(a3, APCM) or 0)
  return { key = key, id = hex(key), finish = finish, rate = rate }
end

local function selector(key, part)
  return key .. string.char(part.flags & 0xFF,
                           part.start & 0xFF, (part.start >> 8) & 0xFF)
end

local function disabled(key)
  return key .. string.char(0, 0xFF, 0xFF)
end

local function writeInitial(where, key, parts, kind)
  put(where + SELECTOR, selector(key, parts[1]), kind)
  if not NO_NEXT_SELECTOR then
    put(where + NEXT_SELECTOR,
        parts[2] and selector(key, parts[2]) or disabled(key), kind)
  end
end

local matched, missed, held, active = 0, 0, nil, nil
local suppressedGateHigh = nil

-- 0.4.6.11/12 BIOS에는 옛 단일 E6800 gate가 남아 있다. 실제 재생 음성이
-- 팩 MISS여도 게임 RAM $22A7에 예전 $68이 남아 있으면 native gate가 state=1을
-- 만들어 버린다. gate가 판정하는 동안만 high byte를 0으로 보이고, 공통 RTS
-- 직전에 원래 값을 되돌린다. 따라서 호출자와 게임에는 값 변화가 남지 않는다.
local function suppressLegacyGate()
  if suppressedGateHigh == nil then
    suppressedGateHigh = emu.read(0x22A7, MEM) or 0
  end
  emu.write(0x22A7, 0, MEM)
end

if SUPPRESS_LEGACY_GATE then
  emu.addMemoryCallback(function()
    if suppressedGateHigh == nil then return end
    emu.write(0x22A7, suppressedGateHigh, MEM)
    suppressedGateHigh = nil
  end, emu.callbackType.exec, GATE_RET, GATE_RET, CPU, MEM)
end

local function refreshNextSelector()
  if not active or (emu.read(STATE, MEM) or 0) == 0 then return end
  local start = (emu.read(ENGINE_CPU + SELECTOR + 7, MEM) or 0) |
                ((emu.read(ENGINE_CPU + SELECTOR + 8, MEM) or 0) << 8)
  for n, part in ipairs(active.parts) do
    if part.start == start then
      active.current = n
      local nextPart = active.parts[n + 1]
      put(ENGINE_CPU + NEXT_SELECTOR,
          nextPart and selector(active.key, nextPart) or disabled(active.key), MEM)
      return
    end
  end
end

emu.addMemoryCallback(function()
  if (emu.read(STATE, MEM) or 0) ~= 0 then return end
  local voice = actualVoice()
  if not voice then return end
  local parts = schedule[voice.id]
  if not parts then
    -- FEC4는 재생 중 매 프레임 호출되므로 같은 MISS에서도 매번 가려야 한다.
    if SUPPRESS_LEGACY_GATE then suppressLegacyGate() end
    if held == voice.id then return end
    held = voice.id
    missed = missed + 1
    if AUDIT then
      emu.log(string.format('SUB %s ★ MISS #%d %s%s',
                            VERSION, missed, voice.id,
                            SUPPRESS_LEGACY_GATE and ' · legacy gate blocked' or ''))
    end
    return
  end
  if held == voice.id then return end
  held = voice.id

  if AUDIT then emu.log(string.format('SUB %s · MATCH %s', VERSION, voice.id)) end

  -- allocator가 독립적으로 모든 ADPCM 시작($F61A)을 잡으면, 자막이 없는
  -- 효과음/MISS에도 helper와 VRAM을 먼저 건드리게 된다.  키가 실제 팩에
  -- 존재한다고 확정된 이 지점에서만 opt-in allocator를 무장한다.
  local armAllocator = rawget(_G, 'SUB_ALLOCATOR_ARM_MATCHED')
  if type(armAllocator) == 'function' then armAllocator(voice.id) end

  ensureInstalled()
  if AUDIT then emu.log(string.format('SUB %s · ENGINE READY %s', VERSION, voice.id)) end

  if type(SELECT_BASE) == 'function' then
    local ok = SELECT_BASE(voice.id, 1, 'start')
    if ok == false then
      emu.log(string.format('SUB %s · MAP SKIP %s', VERSION, voice.id))
      return
    end
  end

  if MINI_INDEX then
    assert(#parts <= MINI_COUNT, 'mini index overflow: ' .. #parts)
    for n = 1, MINI_COUNT do
      put(MINI_INDEX + (n - 1) * 13,
          parts[n] and parts[n].raw or string.rep('\0', 13), AC)
    end
    if AUDIT then emu.log(string.format('SUB %s · MINI READY %s', VERSION, voice.id)) end
  end

  -- gate가 엔진을 복사하기 전에 AC 이미지의 selector를 실제 키로 바꾼다.
  writeInitial(ENGINE_AT, voice.key, parts, AC)
  if AUDIT then emu.log(string.format('SUB %s · SELECTOR READY %s', VERSION, voice.id)) end
  active = { id = voice.id, key = voice.key, parts = parts, current = 1, elapsed = 0 }

  -- 네이티브 gate 승인에만 쓰는 기존 fingerprint. 실제 selector는 위의 6 B다.
  -- SUB_VOICE_NO_GATE 이면 이 세 바이트를 안 쓴다.  그러면 엔진이 아예 안 돌아
  -- 자막도 안 나온다.  적재·색인·타이머는 그대로이므로, 화면 결함이 "우리가
  -- 그리기 때문" 인지 "우리가 적재/쓰기 때문" 인지를 가르는 이분점이다.
  if not NO_GATE then
    emu.write(0x22A6, TARGET_END & 0xFF, MEM)
    emu.write(0x22A7, TARGET_END >> 8, MEM)
    emu.write(0x22AA, TARGET_RATE, MEM)
  end
  if AUDIT then emu.log(string.format('SUB %s · GATE READY %s', VERSION, voice.id)) end
  matched = matched + 1
  emu.log(string.format('SUB %s ★ KEY #%d %s · %d조각',
                        VERSION, matched, voice.id, #parts))
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

-- endFrame까지 기다리면 한 영상 프레임 안에서 엔진 호출이 여러 번 일어날 때
-- 2->3조각 selector 공급이 늦는다. 색인 일치 직후 동기적으로 다음 것을 건다.
if COUNT_OK then
  emu.addMemoryCallback(refreshNextSelector, emu.callbackType.exec,
                        ENGINE_CPU + COUNT_OK, ENGINE_CPU + COUNT_OK, CPU, MEM)
end

emu.addEventCallback(function()
  local voice = actualVoice()
  if not voice then
    held, active = nil, nil
  elseif active and (emu.read(STATE, MEM) or 0) ~= 0 then
    if LUA_TIMER then
      active.elapsed = active.elapsed + 1
      local nextPart = active.parts[active.current + 1]
      if nextPart and active.elapsed >= nextPart.start then
        active.current = active.current + 1
        if type(SELECT_BASE) == 'function' then
          -- 엔진은 이미 $5B80에 있으므로 조각 전환에서는 CPU 이미지의
          -- 피연산자를 갱신한다. (HQ A-base 검증판은 같은 base를 재적용.)
          assert(SELECT_BASE(active.id, active.current, 'part') ~= false,
                 'mapped voice lost its VRAM base')
        end
        put(ENGINE_CPU + SELECTOR, selector(active.key, nextPart), MEM)
        emu.write(ENGINE_CPU + READY_OFFSET, 0, MEM)
        emu.log(string.format('SUB %s ★ LUA PART %d/%d at %df', VERSION,
                              active.current, #active.parts, active.elapsed))
      end
    else
      refreshNextSelector() -- 동기 callback을 못 쓰는 판의 보조 경로
    end
  end

  emu.drawString(4, 4,
    string.format('%s VOICE KEY  OK:%d MISS:%d', VERSION, matched, missed),
    0x40FF40, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB %s loaded -- v6 pack %d B · ADPCM %d조각 · %d키',
                      VERSION, #pack, count, (function() local n=0; for _ in pairs(schedule) do n=n+1 end; return n end)()))
emu.log(type(SELECT_BASE) == 'function'
  and '  key VRAM selector ON · 표 밖 음성은 자막 gate를 열지 않음'
  or '  fixed VRAM $1600 · disc/BIOS build 없음 · 자막 없는 음성은 무개입')
emu.log('  싱크 값은 pack에 들어 있는 원본 start/duration을 그대로 사용')
if MINI_INDEX then
  emu.log(string.format('  Lua mini index $%06X · 최대 %d조각 · 전체 선형검색 없음',
                        MINI_INDEX, MINI_COUNT))
end
if COUNT_OK then
  emu.log(string.format('  next-selector synchronous at engine+$%03X', COUNT_OK))
end
if LUA_TIMER then
  emu.log(string.format('  Lua frame timer ON · ready engine+$%03X · selector/list 중첩 없음',
                        READY_OFFSET))
end
