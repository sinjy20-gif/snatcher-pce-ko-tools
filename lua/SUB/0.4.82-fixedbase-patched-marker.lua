-- 0.4.82의 내부 child. 0.4.58 고정 $1600 경로에서만 PATCHED 표식을 낸다.
-- 0.4.48 와이프가 이전 조각 슬롯을 지우는 시점을 만들기 위한 표식이며,
-- VRAM 주소/allocator/renderer에는 손대지 않는다.

dofile('C:/snatcher/lua/SUB/0.4.58-controller-stage.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local COUNT_OK = 0x5B80 + 118

emu.addMemoryCallback(function()
  -- COUNT_OK는 키가 매치되어 AC renderer가 실제로 실행된 경우에만 지난다.
  -- parent(0.4.48)가 이 로그를 받아 이전 $1600 자막 슬롯만 먼저 와이프한다.
  emu.log('SUB 0.4.82-fixedbase-wipe PATCHED base=$1600')
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.log('SUB 0.4.82 fixed-$1600 marker armed -- allocator/ping-pong write 0 B')
