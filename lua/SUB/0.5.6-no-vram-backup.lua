-- SUB 0.5.6 -- 죽은 VRAM 백업/복원을 건너뛰고 증상이 사라지는지 본다
--
-- 무엇을 찾았나 (0.5.5 + 디스어셈)
-- ---------------------------------------------------------------------------
-- 상주 헬퍼 320 B ($1F1C00 -> $5B80) 안에 VRAM 백업/복원이 들어 있다.
--
--     $5B83  LDA $5C2D              "이미 백업했나" 플래그
--     $5BA4  ST0 #$01 ST1 #$00 ST2 #$79     MARR = $7900   ← 읽기 주소
--     $5BAC  LDX #$13                       19 회
--     $5BAE  TAI $0002 -> $5C2F, $0080      VDC -> RAM 버퍼
--     $5BB5  TIN $5C2F -> $1A00, $0080      RAM 버퍼 -> AC
--
--     $5C00  ST0 #$00 ST1 #$00 ST2 #$79     MAWR = $7900   ← 쓰기 주소
--     $5C0E  LDA $1A00 / STA $5C2F,X / INX / CPX #$80 / BNE
--                                            ★ 128 B 를 한 바이트씩
--     $5C19  TIA $5C2F -> $0002, $0080      버퍼 -> VDC
--     $5C20  DEC $15 / BNE                  19 회
--
-- 버그 셋
--   ① $7900 하드코딩.  PAT_VRAM 은 $1600 이다.  **아무것도 안 지키고 있다**
--   ② 복원이 바이트 루프.  2,432 B x ~20 사이클 ≈ 107 줄 (실측 134 줄)
--   ③ 조각마다 돈다.  가드 플래그가 헬퍼 이미지 안이라 재복사될 때마다 초기화된다
--
-- 이 판
-- ---------------------------------------------------------------------------
-- 헬퍼 진입부 3 바이트를 꼬리로 점프시켜 두 루프를 통째로 건너뛴다.
--
--     $5B83   AD 2D 5C  LDA $5C2D   ->   4C 29 5C  JMP $5C29
--                                        ($5C29 = STZ $5B80 / RTS)
--
-- AC 이미지($1F1C00)의 같은 자리를 고치므로, 스텁이 조각마다 다시 복사해도
-- 패치가 따라간다.  디스크는 굽지 않는다.  매 프레임 3 바이트만 확인한다.
--
-- ★ 디스크 선적재가 AC 를 되돌리므로 계속 확인해야 한다.  patched 횟수가
--   화면에 뜬다.  0 이면 패치가 안 걸린 것이니 판정하지 말 것.
--
-- 판정
--     번쩍임이 사라지면   ★ 죽은 백업/복원이 원인 확정.
--                         고치는 길은 "주소를 $1600 으로" 가 아니라
--                         **아무도 안 쓰는 base 를 골라 복원 자체를 없애는 것**이다
--                         (올바른 백업/복원도 같은 2.4 KB 를 옮긴다)
--     남으면              이 루틴 밖에 또 있다.  스텁의 320/671 B 복사가 남는다
--
-- ⚠ 이 판은 $1600 을 쓰는 장면에서 원래 그림을 되돌리지 않는다.  지금도
--   $7900 을 되돌리고 있어서 어차피 안 되돌리고 있었지만, 판정은 번쩍임만 본다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local AC = emu.memType.pceArcadeCardRam

local HELPER_AT = 0x1F1C00          -- build_subtitle_native_poll_bios_0_8_4.py
local AT = HELPER_AT + 0x03         -- 진입부 LDA $5C2D
local WANT = { 0x4C, 0x29, 0x5C }   -- JMP $5C29
local ORIG = { 0xAD, 0x2D, 0x5C }   -- LDA $5C2D

local patched, restored, seenOrig = 0, 0, false

local function readAt()
  local a = emu.read(AT + 0, AC) or -1
  local b = emu.read(AT + 1, AC) or -1
  local c = emu.read(AT + 2, AC) or -1
  return a, b, c
end

emu.addEventCallback(function()
  local a, b, c = readAt()
  if a == ORIG[1] and b == ORIG[2] and c == ORIG[3] then
    seenOrig = true
    if patched > 0 then restored = restored + 1 end
  end
  if a ~= WANT[1] or b ~= WANT[2] or c ~= WANT[3] then
    for i = 1, 3 do emu.write(AT + i - 1, WANT[i], AC) end
    patched = patched + 1
    if patched <= 5 or patched % 20 == 0 then
      emu.log(string.format('SUB 0.5.6 ★ HELPER PATCH #%d · $%06X = 4C 29 5C (JMP $5C29)',
                            patched, AT))
    end
  end
  emu.drawString(4, 74, string.format('0.5.6 helper patched:%d 되돌림:%d 원본확인:%s',
                 patched, restored, tostring(seenOrig)),
                 patched > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.6-no-vram-backup armed -- 헬퍼의 VRAM 백업/복원을 건너뛴다')
emu.log(string.format('  AC $%06X 를 매 프레임 확인해 4C 29 5C 로 유지한다', AT))
emu.log('  ★ patched 가 0 이면 패치가 안 걸린 것이다.  판정하지 말 것')
emu.log('  원본확인=true 면 디스크가 되돌리는 것도 실제로 본 것이다')
