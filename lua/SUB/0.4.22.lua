-- SUB 0.4.22 -- exact native-candidate test: consume fingerprint once
--
-- 영구 BIOS 수정 후보와 동일한 동작만 한다.
-- $FEC4가 genuine E6800_0E를 승인해 state=1을 쓰는 순간 $22A7을 0으로 지워
-- 그 지문을 소비 완료 처리한다. 이후 state가 0으로 돌아와도 E6800 gate가 다시
-- 맞지 않으므로 다음 ADPCM에서 false subtitle start가 발생하지 않아야 한다.
--
-- 0.4.20/0.4.21처럼 에뮬레이터의 실제 음성 키를 이용해 보호하지 않는다.
-- 이 판이 통과해야 같은 STZ $22A7 3 B를 BIOS에 넣을 수 있다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STATE = 0x7FDF
local KEY_HI = 0x22A7

local consumed = 0

emu.addMemoryCallback(function(address,value)
  local ok,s=pcall(emu.getState)
  s=ok and s or {}
  local pc=type(s['cpu.pc'])=='number' and s['cpu.pc'] or 0
  local written=type(value)=='number' and (value&0xFF) or
                (emu.read(STATE,MEM) or 0)

  -- BIOS acceptance store is $FEF3: A9 01 / $FEF5: STA $7FDF;
  -- Mesen write callback reports PC=$FEF6 immediately after that store.
  if written~=1 or pc~=0xFEF6 or consumed>0 then return end
  emu.write(KEY_HI,0,MEM)                 -- native candidate: STZ $22A7
  consumed=consumed+1
  emu.log('SUB 0.4.22 ★ E6800 fingerprint consumed: STZ $22A7')
  emu.log('  자막은 정상 표시되어야 하며 이후 008FA4 false start는 없어야 한다')
end,emu.callbackType.write,STATE,STATE,CPU,MEM)

emu.addEventCallback(function()
  if consumed>0 then
    emu.drawString(4,4,'0.4.22 FINGERPRINT CONSUMED',0x40FF40,0x000000)
  end
end,emu.eventType.endFrame)

emu.log('SUB 0.4.22 loaded -- exact native STZ $22A7 candidate')
emu.log('  genuine subtitle ON · no emulator-key guard')
