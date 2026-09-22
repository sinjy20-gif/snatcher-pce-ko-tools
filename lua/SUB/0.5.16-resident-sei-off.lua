-- SUB 0.5.16 -- 상주부의 SEI 를 끄고 번쩍임이 사라지는지 본다 (1 바이트 A/B)
--
-- 무엇을 찾았나
-- ---------------------------------------------------------------------------
-- 상주 컨트롤러($7F49-$7FDF)를 디스어셈하니 **분기 전체가 SEI 로 감싸여** 있다.
--
--     $7F49  PHP
--     $7F4A  SEI                    ★ 여기서 인터럽트를 막는다
--     $7F4F  JSR $FEC4              BIOS 판정
--     $7F58  JSR $7F87              select_helper
--     $7F5B  JSR $7FA2              copy_helper    448 B 바이트 복사
--     $7F6C  JSR $5B83              helper (저장)
--     $7F6F  JSR $7FBB              copy_renderer  671 B 바이트 복사
--     $7F7D  JSR $5B83              helper (복원)
--     $7F82  JSR $5B83              renderer 실행
--     $7F85  PLP                    ★ 여기서야 푼다
--     $7F86  RTS
--
-- 0.5.8 실측으로 그 안의 일이 얼마나 긴지도 나왔다:
--
--     자막 시작 프레임   복사 ≈ 43 스캔라인
--     조각 렌더 프레임   복원+렌더 ≈ 121 스캔라인
--
-- 즉 래스터 분할 IRQ 가 수십~백 줄 동안 못 뜬다.  그림 창의 스크롤 전환이
-- 통째로 밀리면 타일맵 위쪽이 화면으로 끌려나온다 -- 증상과 같은 모습이다.
--
-- 이것이 지금까지의 모든 실패를 한 번에 설명한다
-- ---------------------------------------------------------------------------
--     0.5.1  entry=RTS      복사가 SEI 안에서 그대로 돎        -> 남음
--     0.5.7  복원 19->1     마찬가지                            -> 남음
--     0.4.89 VDC 재무장     SEI 창 **안쪽** 세부사항일 뿐        -> 남음
--     0.5.0  팔레트 / 0.4.97 와이프   전부 같은 창 안           -> 남음
--
-- **범인은 특정 작업이 아니라 창 자체**라는 가설이다.
--
-- 이 판
-- ---------------------------------------------------------------------------
-- `$7F4A` 의 `SEI`($78) 를 `NOP`($EA) 로 덮는다.  PHP/PLP 는 그대로라 플래그
-- 균형이 유지된다.  한 바이트다.
--
--     번쩍임이 사라지면   ★ SEI 창이 원인 확정.
--                         고치는 방향은 창을 쪼개거나 VBlank 로 옮기는 것
--     그대로면            창이 아니다.  다시 안쪽을 봐야 한다
--
-- ⚠ 이것은 **진단이지 수정이 아니다.**  SEI 는 이유가 있어 있는 것이다
--   (상태 기계/AC 포트 접근의 원자성).  풀면 다른 결함이 생길 수 있다 --
--   자막이 깨지거나 멈출 수 있다.  판정은 오직 "뒷화면이 나오는가" 하나만 본다.
--
-- ★ patched 가 0 이면 판정하지 말 것 -- 주소가 이 빌드와 다르다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.17-reviewed.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM = emu.memType.pceMemory

local SEI_AT = 0x7F4A
local SEI, NOP = 0x78, 0xEA
-- 상주부가 실제로 그 자리에 있는지 확인하는 지문 (PHP · SEI · LDA #$3F)
local SIG_AT, SIG = 0x7F49, { 0x08, 0x78, 0xA9, 0x3F }

local patched, reverted, verified = 0, 0, false

-- ★ 교차 오염 가드.  Mesen 은 스크립트를 다시 로드해도 RAM 을 초기화하지 않는다.
-- 0.5.17 의 NOP 이 남은 채로 이 판을 돌리면 판정이 오염된다 (2026-08-30 실제로 당함).
local FOREIGN = { { at = 0x7F5B, name = '0.5.17 helper copy' },
                  { at = 0x7F6F, name = '0.5.17 renderer copy' } }
local dirty = false
local function checkForeign()
  if dirty then return end
  for _, f in ipairs(FOREIGN) do
    if (emu.read(f.at, MEM) or -1) == 0xEA then
      dirty = true
      emu.log('SUB 0.5.16 ★★ 오염 감지 -- $' .. string.format('%04X', f.at) ..
              ' 가 NOP 이다 (' .. f.name .. ' 잔재)')
      emu.log('   Power Cycle 하고 이 파일만 다시 로드할 것.  지금 판정은 무효다')
      return
    end
  end
end

emu.addEventCallback(function()
  -- 상주부가 올라와 있는지부터 본다.  없으면 아무것도 안 한다.
  local ok = true
  for i = 1, #SIG do
    local v = emu.read(SIG_AT + i - 1, MEM) or -1
    -- 이미 패치했으면 두 번째 바이트는 NOP 이다
    local want = SIG[i]
    if i == 2 and patched > 0 then want = NOP end
    if v ~= want then ok = false; break end
  end
  if ok then verified = true; checkForeign() end

  local cur = emu.read(SEI_AT, MEM) or -1
  if cur == SEI and verified then
    emu.write(SEI_AT, NOP, MEM)
    patched = patched + 1
    if patched > 1 then reverted = reverted + 1 end
    if patched <= 3 or patched % 50 == 0 then
      emu.log(string.format('SUB 0.5.16 ★ SEI OFF #%d · $%04X  $78 -> $EA', patched, SEI_AT))
    end
  end

  emu.drawString(4, 84, string.format('0.5.16 SEI off · patched %d · 되돌림 %d · 상주부 %s%s',
                 patched, reverted, verified and '확인' or '미확인',
                 dirty and ' · ★오염 판정무효' or ''),
                 dirty and 0x4040FF or (patched > 0 and 0x80FF80 or 0x4040FF), 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.16-resident-sei-off armed -- $7F4A SEI -> NOP')
emu.log('  ★ 진단용이다.  자막이 깨지거나 멈출 수 있다')
emu.log('  판정은 오직 "뒷화면이 나오는가" 하나만 본다')
emu.log('  ★ patched 0 이면 판정 불가 -- 주소가 이 빌드와 다르다')
