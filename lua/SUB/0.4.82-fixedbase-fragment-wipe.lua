-- SUB 0.4.82 -- 검증된 고정 $1600 controller/stage + 전환/종료 와이프.
--
-- 구성: 0.4.58 + 0.4.48. allocator, ping-pong, record-Y 보정은 넣지 않는다.
-- 새 조각이 시작되기 직전 이전 자막 SATB 슬롯만 지우고, 음성 종료에도 지운다.
-- Power Cycle 뒤 이 파일 하나만 실행한다.

SUB_FRAGMENT_WIPE_VERSION = '0.4.82-fixedbase-wipe'
SUB_FRAGMENT_WIPE_CHILD = 'C:/snatcher/lua/SUB/0.4.82-fixedbase-patched-marker.lua'

dofile('C:/snatcher/lua/SUB/0.4.48-fragment-wipe.lua')

SUB_FRAGMENT_WIPE_VERSION = nil
SUB_FRAGMENT_WIPE_CHILD = nil

emu.log('SUB 0.4.82-fixedbase-fragment-wipe armed')
emu.log('  fixed VRAM $1600 · controller + stage + fragment/end wipe')
emu.log('  allocator / ping-pong / restore 없음 · 미카 3조각과 종료 뒤 진행만 확인')
