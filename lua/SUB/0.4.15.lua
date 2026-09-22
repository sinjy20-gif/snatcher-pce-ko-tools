-- SUB 0.4.15 -- lightweight restore-only bypass
--
-- 자막 시작/출력/VRAM backup은 정상 실행하고, 음성 종료 때 helper의 VRAM
-- restore 호출만 건너뛴다.  0.4.14에서 자막 lifecycle 전체가 범인임을 확인한
-- 다음 단계 A/B 시험이다. BIOS/디스크/AC 이미지는 수정하지 않는다.
--
-- 판정
--   자막이 뜨고 다음 008FA4로 정상 진행 -> VRAM restore 경로가 범인
--   자막이 뜨고 다시 정지                -> draw/backup 쪽을 다음에 분리
--
-- 주의: restore를 일부러 생략하므로 시험 장면 뒤 VRAM에 글리프가 남을 수 있다.
-- 원인 분리용이며 정상 플레이용이 아니다.

local MEM = emu.memType.pceMemory
local PATCH = 0x7F7A
local EXPECT = {0xEE, 0x2D, 0x5C}       -- INC $5C2D (helper command=restore)
local REPLACE = {0x80, 0x09, 0xEA}      -- BRA $7F85 / NOP (skip JSR $5B83)

local installed = false
local failed = false

local function matches(bytes)
  for i = 1, #bytes do
    if (emu.read(PATCH + i - 1, MEM) or 0) ~= bytes[i] then return false end
  end
  return true
end

local function write(bytes)
  for i = 1, #bytes do emu.write(PATCH + i - 1, bytes[i], MEM) end
end

local function install()
  if installed or failed then return end
  if matches(REPLACE) then
    installed = true
    return
  end
  if not matches(EXPECT) then
    failed = true
    emu.log(string.format(
      'SUB 0.4.15 FAIL: resident restore bytes at $%04X do not match', PATCH))
    return
  end
  write(REPLACE)
  installed = matches(REPLACE)
  if installed then
    emu.log('SUB 0.4.15 ★ RESTORE BYPASS INSTALLED: draw/backup ON · restore OFF')
  else
    failed = true
    emu.log('SUB 0.4.15 FAIL: restore bypass write did not stick')
  end
end

-- 보통 세이브를 불러온 시점에 resident가 이미 있으므로 즉시 설치된다.
install()

emu.addEventCallback(function()
  if not installed and not failed then install() end
  if failed then
    emu.drawString(4, 4, '0.4.15 FAIL - STOP', 0xFF4040, 0x000000)
  elseif not installed then
    emu.drawString(4, 4, '0.4.15 WAIT RESIDENT', 0xFFFFFF, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if installed and matches(REPLACE) then write(EXPECT) end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.15 loaded -- subtitle draw/backup normal, VRAM restore bypass only')
