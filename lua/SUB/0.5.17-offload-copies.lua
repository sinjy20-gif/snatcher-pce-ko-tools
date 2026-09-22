-- SUB 0.5.17 -- 상주부의 복사를 Lua 로 옮겨 "비용만" 없앤다 (의미 보존 A/B)
--
-- 착상
-- ---------------------------------------------------------------------------
-- 상주부 분기 전체가 SEI 로 감싸여 있다 (디스어셈).
--
--     $7F49 PHP / $7F4A SEI ... $7F85 PLP / RTS
--
-- 그 안에서 0.5.8 이 잰 것:  복사 ≈ 43 줄 · 복원+렌더 ≈ 121 줄.
-- 래스터 분할 IRQ 가 그동안 못 뜬다.
--
-- 이걸 확인하는 방법 둘 중,
--
--     (a) SEI 를 NOP 으로      효과를 없앤다.  IRQ 가 AC 포트 접근 중에 끼어들어
--                              **다른 결함**이 생길 수 있다.  판정이 흐려진다
--     (b) 일을 Lua 로 옮긴다   **비용만** 없앤다.  Lua 쓰기는 에뮬레이션 사이클을
--                              안 먹으므로 결과 상태는 동일하고 시간만 0 이 된다
--
-- (b) 가 낫다.  의미를 안 바꾸고 "창이 길어서 그런가" 만 묻는다.
--
-- 무엇을 옮기나
-- ---------------------------------------------------------------------------
--     $7F5B  JSR $7FA2   copy_helper    448 B   -> NOP x3, Lua 가 대신 옮긴다
--     $7F6F  JSR $7FBB   copy_renderer  671 B   -> NOP x3, Lua 가 대신 옮긴다
--
-- 두 복사는 AC -> $5B80 바이트 루프다 (AC 포트가 고정 소스라 블록 전송 불가).
-- Lua 는 AC RAM 을 직접 읽어 CPU RAM 에 쓰므로 같은 결과가 된다.
--
--   · copy_helper 를 건너뛰어도 AC 주소는 헬퍼의 save 경로가 $1F1F00 으로
--     다시 세우므로 copy_renderer 에 영향이 없다
--   · Lua 복사는 NOP 자리에서 하므로 뒤따르는 매직 검사($7F5E)보다 앞이다
--
-- SUB_OFFLOAD 로 범위를 좁힐 수 있다:  'both'(기본) · 'helper' · 'renderer'
--
-- 판정
--     번쩍임이 사라지면   ★ 창 길이가 원인.  둘 중 어느 쪽인지 'helper'/'renderer'
--                         로 한 번 더 좁힌다
--     그대로면            복사는 아니다.  남은 무게는 helper 의 저장/복원과
--                         렌더러 실행이다 (다음 단계에서 이관)
--
-- ★ patched 가 0 이면 판정하지 말 것 -- 주소가 이 빌드와 다르다.
-- ⚠ 진단용이다.  출하 코드가 아니다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.17-reviewed.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

local MODE = rawget(_G, 'SUB_OFFLOAD') or 'both'

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local AC = emu.memType.pceArcadeCardRam

local ENGINE = 0x5B80
-- 상주부의 두 JSR (resident_controller_native_poll_0_8_4.json + 디스어셈)
local SITES = {
  helper   = { at = 0x7F5B, orig = { 0x20, 0xA2, 0x7F }, src = 0x1F1C00, len = 448 },
  renderer = { at = 0x7F6F, orig = { 0x20, 0xBB, 0x7F }, src = 0x1F1F00, len = 671 },
}
local NOP = 0xEA

local active = {}
if MODE == 'both' or MODE == 'helper' then active[#active + 1] = 'helper' end
if MODE == 'both' or MODE == 'renderer' then active[#active + 1] = 'renderer' end

local patched, copies = 0, 0

-- ★ 교차 오염 가드.  Mesen 은 스크립트를 다시 로드해도 RAM 을 초기화하지 않는다.
-- 0.5.16 의 SEI->NOP 이 남은 채로 이 판을 돌리면 판정이 오염된다
-- (2026-08-30 실제로 당했다.  §2-4 "0.5.17 결과 철회" 참조).
local SEI_AT = 0x7F4A
local dirty = false
local function checkForeign()
  if dirty then return end
  if (emu.read(SEI_AT, MEM) or -1) == NOP then
    dirty = true
    emu.log('SUB 0.5.17 ★★ 오염 감지 -- $7F4A 가 NOP 이다 (0.5.16 SEI off 잔재)')
    emu.log('   Power Cycle 하고 이 파일만 다시 로드할 것.  지금 판정은 무효다')
  end
end

local function looksOriginal(s)
  for i = 1, 3 do
    if (emu.read(s.at + i - 1, MEM) or -1) ~= s.orig[i] then return false end
  end
  return true
end

local function looksPatched(s)
  for i = 1, 3 do
    if (emu.read(s.at + i - 1, MEM) or -1) ~= NOP then return false end
  end
  return true
end

-- Lua 가 대신 옮긴다.  에뮬레이션 사이클 0.
local function doCopy(s)
  for i = 0, s.len - 1 do
    emu.write(ENGINE + i, emu.read(s.src + i, AC) or 0, MEM)
  end
  copies = copies + 1
end

for _, name in ipairs(active) do
  local s = SITES[name]
  emu.addMemoryCallback(function() doCopy(s) end,
    emu.callbackType.exec, s.at, s.at, CPU, MEM)
end

emu.addEventCallback(function()
  checkForeign()
  for _, name in ipairs(active) do
    local s = SITES[name]
    if looksOriginal(s) then
      for i = 1, 3 do emu.write(s.at + i - 1, NOP, MEM) end
      patched = patched + 1
      if patched <= 4 then
        emu.log(string.format('SUB 0.5.17 ★ OFFLOAD %s · $%04X  JSR -> NOP x3 (%d B 를 Lua 가 옮긴다)',
                              name, s.at, s.len))
      end
    end
  end
  emu.drawString(4, 84, string.format('0.5.17 offload[%s] · patched %d · Lua 복사 %d회%s',
                 MODE, patched, copies, dirty and ' · ★오염 판정무효' or ''),
                 dirty and 0x4040FF or (patched > 0 and 0x80FF80 or 0x4040FF), 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB 0.5.17-offload-copies armed -- mode=%s', MODE))
emu.log('  상주부의 바이트 복사를 Lua 로 옮겨 **비용만** 없앤다 (상태는 동일)')
emu.log('  ★ patched 0 이면 판정 불가 · ⚠ 진단용이다')
