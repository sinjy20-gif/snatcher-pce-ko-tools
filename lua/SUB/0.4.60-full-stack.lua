-- SUB 0.4.60-full-stack -- 검증된 controller+stage+allocator+wipe 결합판
--
-- 0.4.59 정상 체인 위에 0.4.48 fragment/end wipe만 추가한다.
-- record-Y 보정과 MISS legacy suppression은 없다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

SUB_FRAGMENT_WIPE_VERSION = '0.4.60-wipe'
SUB_FRAGMENT_WIPE_CHILD =
  'C:/snatcher/lua/SUB/0.4.59-controller-stage-allocator.lua'

dofile('C:/snatcher/lua/SUB/0.4.48-fragment-wipe.lua')

SUB_FRAGMENT_WIPE_VERSION = nil
SUB_FRAGMENT_WIPE_CHILD = nil

emu.log('SUB 0.4.60-full-stack armed -- controller + stage + allocator + wipe')
emu.log('  MISS 무개입 · KEY matched-only · fragment/end SATB wipe')
emu.log('  미카 3조각/종료 진행과 WIPE/restore 로그 확인')
