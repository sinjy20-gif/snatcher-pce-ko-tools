-- SUB 0.5.7 -- VRAM 백업/복원 반복 횟수만 19 -> 1 로 줄인다
--
-- 0.5.6 이 왜 멈췄나
-- ---------------------------------------------------------------------------
-- 진입부를 꼬리($5C29)로 점프시켜 두 루프를 통째로 건너뛰었더니 화면이 멈췄다.
-- 원래 복원 경로의 끝은 이렇다:
--
--     $5C24  A9 02        LDA #$02
--     $5C26  8D 2E 5C     STA $5C2E      ← 상태 플래그
--     $5C29  9C 80 5B     STZ $5B80
--     $5C2C  60           RTS
--
-- $5C29 로 뛰면 **$5C2E 에 상태를 안 쓰고 돌아온다.**  스텁이 그 플래그를
-- 기다리면 영원히 안 온다.  건너뛰기는 상태 전이를 깨뜨린다.
--
-- 이 판
-- ---------------------------------------------------------------------------
-- 흐름과 플래그를 하나도 안 건드리고 **반복 횟수만** 줄인다.
--
--     $5BAC  +$02C  A2 13  LDX #$13   ->  A2 01     백업 19 회 -> 1 회
--     $5C08  +$088  A9 13  LDA #$13   ->  A9 01     복원 19 회 -> 1 회
--
-- 두 바이트다 (AC 이미지의 +$02D, +$089).  전송량이 1/19 이 되고
-- 나머지 코드 경로는 완전히 동일하다.
--
-- 판정
--     번쩍임이 크게 줄면   ★ 이 루프가 원인 확정.  줄일 대상이 정해진다
--     그대로면             이 루프 밖이다 (스텁의 320/671 B 복사 등)
--
-- ⚠ 이 판은 VRAM 을 19 칸 중 1 칸만 백업/복원한다.  어차피 대상 주소가
--   $7900 이라 지금도 자막 자리($1600)를 안 지키고 있으므로, 새로 깨지는 것은
--   없다.  판정은 번쩍임만 본다.
--
-- ★ patched 가 0 이면 판정하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local AC = emu.memType.pceArcadeCardRam
local HELPER_AT = 0x1F1C00

-- (AC 주소, 원본 값, 바꿀 값, 이름)
local SPOTS = {
  { HELPER_AT + 0x02D, 0x13, 0x01, 'backup LDX' },
  { HELPER_AT + 0x089, 0x13, 0x01, 'restore LDA' },
}

local patched, restored, sawOrig = 0, 0, false

emu.addEventCallback(function()
  for _, s in ipairs(SPOTS) do
    local at, orig, want, name = s[1], s[2], s[3], s[4]
    local v = emu.read(at, AC) or -1
    if v == orig then
      sawOrig = true
      emu.write(at, want, AC)
      patched = patched + 1
      if patched <= 6 or patched % 20 == 0 then
        emu.log(string.format('SUB 0.5.7 ★ PATCH #%d · $%06X %s  $%02X -> $%02X',
                              patched, at, name, orig, want))
      end
    elseif v ~= want then
      -- 원본도 우리 값도 아니면 이미지가 아직 안 올라왔거나 다른 것이다.
      restored = restored + 1
    end
  end
  emu.drawString(4, 74, string.format('0.5.7 patched:%d 미확인:%d 원본봄:%s',
                 patched, restored, tostring(sawOrig)),
                 patched > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.7-backup-count-1 armed -- 백업/복원 반복 19 -> 1')
emu.log(string.format('  AC $%06X+$02D (LDX) · +$089 (LDA) 를 $13 -> $01', HELPER_AT))
emu.log('  ★ 흐름/플래그는 그대로다.  0.5.6 처럼 멈추지 않아야 한다')
emu.log('  ★ patched 가 0 이면 판정하지 말 것')
