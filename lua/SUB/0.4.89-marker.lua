-- SUB 0.4.89-marker -- 0.4.48 와이프가 물고 갈 PATCHED 표식.
--
-- 0.4.82-fixedbase-patched-marker 와 같은 일을 하되, count_ok 와 base 를
-- 하드코딩하지 않고 표에서 읽는다.  (재무장 엔진에서 count_ok 는 +118 로
-- 그대로지만, 엔진을 또 고쳤을 때 조용히 어긋나는 것을 막는다.)
--
-- count_ok 는 키가 실제로 매치되어 엔진이 돈 경우에만 지난다.  parent(0.4.48)가
-- 이 로그를 받아 이전 자막 슬롯만 먼저 와이프한다.
-- VRAM 주소 · allocator · renderer 에는 손대지 않는다.  쓰기 0 B.

dofile('C:/snatcher/lua/SUB/0.4.89-stage.lua')

local info = assert(rawget(_G, 'SUB_REARM_INFO'), '0.4.89-controller 가 먼저 와야 한다')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local COUNT_OK = info.engine_lo + info.offsets.count_ok
emu.addMemoryCallback(function()
  -- key-base wrapper가 현재 음성에 선택한 주소를 내보낸다. 없으면 기존 엔진
  -- 기본 주소를 유지하므로 0.4.89 단독 경로의 동작은 바뀌지 않는다.
  local base = rawget(_G, 'SUB_VOICE_CURRENT_BASE') or info.pat_vram
  emu.log(string.format('SUB 0.4.89-vdc-rearm PATCHED base=$%04X', base))
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.log(string.format('SUB 0.4.89-marker armed -- count_ok $%04X · base $%04X',
                      COUNT_OK, info.pat_vram))
