-- SUB 0.3.7 -- opening preload deferral disc verifier (read-only)
--
-- Target pair:
--   build/patch/0.4.5.9-subtitle-deferred/*.cue
--   build/bios_font/Syscard3_galmuri_0_4_5_9_subtitle_deferred.pce
--
-- This script writes nothing.  It verifies that the on-disc $66E5 hook calls
-- BIOS gate $FFA0 before reception, and changes to JSR $5E40 only when the
-- reception action-menu pointer $3499/$349A appears.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local HOOK, GATE, PRELOAD = 0x66E5, 0xFFA0, 0x5E40
local frame = 0
local gateCalls, preloadCalls = 0, 0
local gateSeen, armRequested, armedSeen = false, false, false
local preloadBeforeArm = false
local lastHook, lastGatePtr, lastPreloadPtr = '', -1, -1

local function b(at) return emu.read(at, MEM) or 0 end
local function ptr() return b(0x3471) | (b(0x3472) << 8) end
local function hookBytes()
  return string.format('%02X %02X %02X', b(HOOK), b(HOOK + 1), b(HOOK + 2))
end
local function hookKind()
  local x = hookBytes()
  if x == '20 A0 FF' then return 'GATE', x end
  if x == '20 40 5E' then return 'ARMED', x end
  return 'OTHER', x
end

local function reportHook(force)
  local kind, bytes = hookKind()
  local sig = kind .. ':' .. bytes
  if force or sig ~= lastHook then
    emu.log(string.format('SUB 0.3.7 HOOK f=%d %s [%s]', frame, kind, bytes))
    lastHook = sig
  end
  if kind == 'GATE' then gateSeen = true end
  if kind == 'ARMED' then
    if not armedSeen then
      armedSeen = true
      if armRequested and not preloadBeforeArm then
        emu.log(string.format(
          'SUB 0.3.7 PASS: reception에서만 무장 · gate=%d preload=%d',
          gateCalls, preloadCalls))
      elseif preloadBeforeArm then
        emu.log('SUB 0.3.7 FAIL: 접수처 무장 전에 프리로더가 실행됨')
      else
        emu.log('SUB 0.3.7 WARN: ARM 요청 관측 없이 훅이 이미 무장됨')
      end
    end
  end
end

-- The BIOS gate is mapping-independent and only exists in the paired BIOS.
emu.addMemoryCallback(function()
  gateCalls = gateCalls + 1
  gateSeen = true
  local p = ptr()
  if p == 0x3499 or p == 0x349A then
    if not armRequested then
      armRequested = true
      emu.log(string.format(
        'SUB 0.3.7 ARM_REQUEST f=%d ptr=$%04X gate_calls=%d',
        frame, p, gateCalls))
    end
  elseif p ~= lastGatePtr then
    emu.log(string.format(
      'SUB 0.3.7 BYPASS f=%d ptr=$%04X gate_calls=%d',
      frame, p, gateCalls))
    lastGatePtr = p
  end
end, emu.callbackType.exec, GATE, GATE, emu.cpuType.pce, CPU)

-- Ignore unrelated code that happens to map at $5E40 before our $66E5 gate
-- appears.  Once the gate is present, any early call is a real failure.
emu.addMemoryCallback(function()
  local kind = hookKind()
  if not gateSeen and kind == 'OTHER' then return end
  preloadCalls = preloadCalls + 1
  if not armRequested and kind ~= 'ARMED' then
    preloadBeforeArm = true
    emu.log(string.format(
      'SUB 0.3.7 FAIL_PRELOAD_EARLY f=%d ptr=$%04X hook=[%s]',
      frame, ptr(), hookBytes()))
  else
    local p = ptr()
    if preloadCalls <= 3 or p ~= lastPreloadPtr then
    emu.log(string.format(
      'SUB 0.3.7 PRELOAD f=%d ptr=$%04X count=%d hook=[%s]',
        frame, p, preloadCalls, hookBytes()))
      lastPreloadPtr = p
    end
  end
end, emu.callbackType.exec, PRELOAD, PRELOAD, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  reportHook(false)
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  emu.log(string.format(
    'SUB 0.3.7 END: gate=%d preload=%d arm_request=%s armed=%s early=%s',
    gateCalls, preloadCalls, tostring(armRequested), tostring(armedSeen),
    tostring(preloadBeforeArm)))
end, emu.eventType.scriptEnded)

emu.log('SUB 0.3.7 loaded -- deferred preload verifier / 완전 읽기 전용')
emu.log('  NEW GAME 시작 전에 켜고 접수처 액션 UI까지 진행할 것')
emu.log('  정상: BYPASS -> ARM_REQUEST(ptr=$3499/$349A) -> PRELOAD -> PASS')
