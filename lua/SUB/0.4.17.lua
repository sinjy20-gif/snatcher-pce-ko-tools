-- SUB 0.4.17 -- controller-only A/B
--
-- 네이티브 자막 컨트롤러와 BIOS $FEC4 상태 전환은 그대로 실행하되,
-- backup / draw / restore 세 작업을 모두 건너뛴다.
--
-- 0.4.16(backup만 ON)에서 정지했으므로 이 판이 통과하면 VRAM backup이
-- 단독 범인이다. 이 판도 정지하면 bulk copy가 아니라 컨트롤러 진입/상태 전환이
-- 범인이다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local START_PATCH = 0x7F6C
local START_EXPECT = {0x20, 0x83, 0x5B}  -- JSR $5B83 (helper backup)
local START_SKIP = {0x80, 0x04, 0xEA}    -- BRA $7F72 / NOP (go to INC state)

local RESTORE_PATCH = 0x7F7A
local RESTORE_EXPECT = {0xEE, 0x2D, 0x5C}
local RESTORE_SKIP = {0x80, 0x09, 0xEA}

local AFTER_START_SKIP = 0x7F72
local ENTRY = 0x5B83
local HELPER_ENTRY = 0xAD
local RTS = 0x60

local installed = false
local entryBlocked = false
local failed = false

local function match(at, bytes)
  for i = 1, #bytes do
    if (emu.read(at + i - 1, MEM) or 0) ~= bytes[i] then return false end
  end
  return true
end

local function put(at, bytes)
  for i = 1, #bytes do emu.write(at + i - 1, bytes[i], MEM) end
end

local function patch(at, expected, replacement, name)
  if match(at, replacement) then return true end
  if not match(at, expected) then
    failed = true
    emu.log('SUB 0.4.17 FAIL: ' .. name .. ' bytes mismatch')
    return false
  end
  put(at, replacement)
  if not match(at, replacement) then
    failed = true
    emu.log('SUB 0.4.17 FAIL: ' .. name .. ' patch did not stick')
    return false
  end
  return true
end

installed = patch(START_PATCH, START_EXPECT, START_SKIP, 'backup skip') and
            patch(RESTORE_PATCH, RESTORE_EXPECT, RESTORE_SKIP, 'restore skip')

-- copy_helper까지는 정상 실행된다. backup 호출을 건너뛰고 $7F72에 도착한 순간
-- RAM의 helper entry도 RTS로 바꿔 active 프레임의 JSR $5B83을 무해하게 만든다.
emu.addMemoryCallback(function()
  if entryBlocked or failed then return end
  local op = emu.read(ENTRY, MEM) or 0
  if op ~= HELPER_ENTRY then
    failed = true
    emu.log(string.format('SUB 0.4.17 FAIL: helper entry=$%02X, expected $AD', op))
    return
  end
  emu.write(ENTRY, RTS, MEM)
  entryBlocked = (emu.read(ENTRY, MEM) or 0) == RTS
  if entryBlocked then
    emu.log('SUB 0.4.17 ★ CONTROLLER ONLY: backup/draw/restore 모두 0회')
    emu.log('  자막이 안 뜨는 것이 정상. 008FA4 통과 여부만 확인')
  end
end, emu.callbackType.exec, AFTER_START_SKIP, AFTER_START_SKIP, CPU, MEM)

emu.addEventCallback(function()
  if failed then
    emu.drawString(4, 4, '0.4.17 FAIL - STOP', 0xFF4040, 0x000000)
  elseif not entryBlocked then
    emu.drawString(4, 4, '0.4.17 WAIT SUBTITLE START', 0xFFFFFF, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if match(START_PATCH, START_SKIP) then put(START_PATCH, START_EXPECT) end
  if match(RESTORE_PATCH, RESTORE_SKIP) then put(RESTORE_PATCH, RESTORE_EXPECT) end
  if entryBlocked and (emu.read(ENTRY, MEM) or 0) == RTS then
    emu.write(ENTRY, HELPER_ENTRY, MEM)
  end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.17 loaded -- controller ON, backup/draw/restore OFF')
