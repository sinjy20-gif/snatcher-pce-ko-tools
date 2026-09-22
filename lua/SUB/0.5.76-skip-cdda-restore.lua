-- SUB 0.5.76 -- CD-DA 의 VRAM 복원만 건너뛴다 (개입 시험 · 원인 확정용)
--
-- 무엇을 확정하려는가
-- ---------------------------------------------------------------------------
-- 0.5.75 두 판(스킵 / 노스킵)이 이렇게 나왔다.
--
--     helper base   스킵   1600/00/B0 유지
--                   노스킵 CD-DA 시작에 7900/03/C8 로 바뀌고 **끝나도 안 돌아옴**
--     writesGame    320    재생 중 게임이 $7900-$7DBF 에 씀
--     start->after  0      복원 후가 **CD-DA 시작 스냅샷과 완전 동일**
--     판정          STALE-RESTORE
--
-- 즉 우리가 빌린 창을 돌려주는데, 그 사이 게임이 거기 접수처 배경을 그렸고,
-- 우리가 **낡은 백업으로 그것을 덮는다.**  뒷정리를 안 한 것이 아니라
-- 하지 말았어야 할 뒷정리를 한 것이다.
--
--     ★ 그러나 "이걸 고치면 화면이 멀쩡해진다" 는 아직 증명이 없다.
--       기구를 맞게 짚고도 다른 것이 겹쳐 있을 수 있다.  그래서 막아본다.
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- 헬퍼의 **복원 본체만** 건너뛴다.  스프라이트 와이프와 상태 꼬리는 그대로 둔다.
--
--     +$06C  20 40 5C        JSR wipe_sprites     <- 살린다
--     +$06F  A9 00 8D 02 1A  VRAM 복원 본체       <- JMP $5C37 로 건너뛴다
--     +$0B7  A9 02 8D 31 5D  상태 꼬리 ($5C37)    <- 여기로 착지
--
-- ★ 0.5.6 의 교훈: 경로를 건너뛰되 **상태 플래그는 반드시 써야 한다.**
--   안 그러면 상주부가 플래그를 기다리다 멈춘다.  그래서 꼬리로 점프한다.
--
-- ★ CD-DA 일 때만 막는다.  헬퍼 제어 블록의 base 가 $7900 인 프레임에만
--   패치하고, 그 외(ADPCM)에는 원본 바이트로 되돌린다.  음성 자막의 복원은
--   건드리지 않는다.
--
-- ★ 헬퍼는 매 프레임 AC 에서 새로 복사되므로 **AC 이미지($1F1C00)** 를 고친다.
--
-- 판정 -- 오직 하나만 본다
-- ---------------------------------------------------------------------------
--     접수처 뒷배경이 멀쩡하다   -> ★ 원인 확정.  낡은 복원이 범인이다
--     여전히 깨진다              -> 복원은 범인이 아니다.  다른 것이 겹쳐 있다
--
-- 예정된 부작용
--     CD-DA 자막이 그린 글자가 화면에 남을 수 있다 (복원을 안 하므로).
--     그것은 판정 대상이 아니다.  **배경**만 본다.
--
-- ⚠ 진단용이다.  출하 코드가 아니다.
-- Power Cycle 뒤 이 파일 하나만 로드한다.
--     BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce
--     CUE   같은 폴더 [KO].cue
-- 스킵하지 말고 CD-DA 를 재생시킨 뒤 접수처까지 간다.
--
-- ★ 화면에 아무것도 그리지 않는다.

local AC = emu.memType.pceArcadeCardRam

local HELPER_AC = 0x1F1C00
local CTL = 432                       -- subtitle_layout.HELPER_CTL
local BASE_LO, BASE_HI = CTL + 4, CTL + 5

local SITE = 0x06F                    -- 복원 본체 시작
local ORIG = { 0xA9, 0x00, 0x8D }     -- LDA #$00 / STA ...
local PATCH = { 0x4C, 0x37, 0x5C }    -- JMP $5C37 (상태 꼬리)

local CDDA_LO, CDDA_HI = 0x00, 0x79   -- 0.5.75 실측: 7900/03/C8

local function rd(off) return emu.read(HELPER_AC + off, AC) or -1 end
local function wr(off, v) emu.write(HELPER_AC + off, v, AC) end

local function looks(bytes)
  for i = 1, 3 do if rd(SITE + i - 1) ~= bytes[i] then return false end end
  return true
end

local frame, patched, reverted, refused = 0, 0, 0, false
local lastBase = -1

emu.addEventCallback(function()
  frame = frame + 1

  local lo, hi = rd(BASE_LO), rd(BASE_HI)
  local base = (hi << 8) | (lo & 0xFF)
  if base ~= lastBase then
    lastBase = base
    emu.log(string.format('SUB 0.5.76 %df · helper base = $%04X', frame, base))
  end

  -- 자리가 우리가 아는 헬퍼가 아니면 아무것도 안 한다
  if not (looks(ORIG) or looks(PATCH)) then
    if not refused then
      refused = true
      emu.log('SUB 0.5.76 ★★ 헬퍼 바이트가 기대와 다르다 -- 아무것도 안 한다')
      emu.log(string.format('   +$%03X = %02X %02X %02X (기대 A9 00 8D 또는 4C 37 5C)',
                            SITE, rd(SITE), rd(SITE + 1), rd(SITE + 2)))
    end
    return
  end

  local wantPatch = (lo == CDDA_LO and hi == CDDA_HI)
  if wantPatch and looks(ORIG) then
    for i = 1, 3 do wr(SITE + i - 1, PATCH[i]) end
    patched = patched + 1
    if patched <= 3 then
      emu.log(string.format('SUB 0.5.76 ★ %df · CD-DA base 감지 -- VRAM 복원 건너뜀 #%d',
                            frame, patched))
    end
  elseif (not wantPatch) and looks(PATCH) then
    for i = 1, 3 do wr(SITE + i - 1, ORIG[i]) end
    reverted = reverted + 1
    if reverted <= 3 then
      emu.log(string.format('SUB 0.5.76 · %df · base 가 $%04X -- 원본으로 되돌림 #%d',
                            frame, base, reverted))
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emu.log(string.format('SUB 0.5.76 끝 -- 건너뜀 %d회 · 되돌림 %d회%s',
    patched, reverted, refused and ' · ★자리 불일치로 무개입' or ''))
  if patched == 0 and not refused then
    emu.log('  ★ 한 번도 안 막았다 -- CD-DA 가 재생되지 않았거나 base 가 $7900 이 아니다')
    emu.log('    판정 불가')
  end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.76-skip-cdda-restore armed -- CD-DA 의 VRAM 복원만 막는다')
emu.log('  스프라이트 와이프와 상태 꼬리는 그대로 둔다 (상주부가 안 멈추게)')
emu.log('  ★ 판정은 오직 "접수처 뒷배경이 멀쩡한가" 하나')
emu.log('  ⚠ CD-DA 자막 글자가 남을 수 있다.  그것은 판정 대상이 아니다')
