-- SUB 0.4.16 -- backup-only A/B (draw OFF, restore OFF)
--
-- 자막 시작 시 VRAM backup은 정상 실행한다. renderer가 RAM에 복사된 직후
-- entry $5B83을 RTS로 바꿔 실제 draw는 한 번도 실행하지 않는다. 종료 restore도
-- 0.4.15와 같이 건너뛴다.
--
-- 판정
--   다음 008FA4에서 정지 -> 시작 쪽 backup/컨트롤러가 범인
--   정상 진행            -> 실제 renderer draw가 범인
--
-- 원인 분리용이며 정상 플레이용이 아니다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local RESTORE_PATCH = 0x7F7A
local RESTORE_EXPECT = {0xEE, 0x2D, 0x5C}
local RESTORE_SKIP = {0x80, 0x09, 0xEA}

local AFTER_RENDERER_COPY = 0x7F72   -- INC $7FDF, JSR copy_renderer 직후
local ENGINE = 0x5B80
local ENTRY = 0x5B83
local RENDERER_ENTRY = 0xAD          -- LDA $5CEC
local RTS = 0x60

local restorePatched = false
local drawBlocked = false
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

local function installRestoreSkip()
  if match(RESTORE_PATCH, RESTORE_SKIP) then
    restorePatched = true
    return
  end
  if not match(RESTORE_PATCH, RESTORE_EXPECT) then
    failed = true
    emu.log('SUB 0.4.16 FAIL: resident restore bytes mismatch')
    return
  end
  put(RESTORE_PATCH, RESTORE_SKIP)
  restorePatched = match(RESTORE_PATCH, RESTORE_SKIP)
end

installRestoreSkip()

-- 이 시점에는 helper의 backup이 끝났고 renderer 671 B가 $5B80에 복사돼 있다.
emu.addMemoryCallback(function()
  if drawBlocked or failed then return end
  if not match(ENGINE, {0x53, 0x55, 0x42}) or
     (emu.read(ENTRY, MEM) or 0) ~= RENDERER_ENTRY then
    failed = true
    emu.log('SUB 0.4.16 FAIL: renderer was not present after copy')
    return
  end
  emu.write(ENTRY, RTS, MEM)
  drawBlocked = (emu.read(ENTRY, MEM) or 0) == RTS
  if drawBlocked then
    emu.log('SUB 0.4.16 ★ BACKUP DONE · DRAW BLOCKED · RESTORE BLOCKED')
    emu.log('  자막이 안 뜨는 것이 정상. 그대로 008FA4 통과 여부만 확인')
  else
    failed = true
    emu.log('SUB 0.4.16 FAIL: renderer RTS patch did not stick')
  end
end, emu.callbackType.exec, AFTER_RENDERER_COPY, AFTER_RENDERER_COPY, CPU, MEM)

emu.addEventCallback(function()
  if failed then
    emu.drawString(4, 4, '0.4.16 FAIL - STOP', 0xFF4040, 0x000000)
  elseif not drawBlocked then
    emu.drawString(4, 4, '0.4.16 WAIT SUBTITLE START', 0xFFFFFF, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if restorePatched and match(RESTORE_PATCH, RESTORE_SKIP) then
    put(RESTORE_PATCH, RESTORE_EXPECT)
  end
  if drawBlocked and (emu.read(ENTRY, MEM) or 0) == RTS then
    emu.write(ENTRY, RENDERER_ENTRY, MEM)
  end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.16 loaded -- backup ON, draw OFF, restore OFF')
