-- PROBE_SUB_RENDER_ORDER 0.1.0 -- native subtitle와 게임 sprite 조립 순서 읽기 전용
-- E6800_0E 한 번만 요약한다. $601E/$606F/$6463 호출과 $7900 VWR 쓰기를 프레임별 기록.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/probe_sub_render_order_0_1_0_%s.tsv', os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
f:write('frame\tstate\thook_601e\thook_606f\tpush_6463\tpat_writes\tphase\n')
local frame, armed, post = 0, false, 0
local n601e, n606f, npush, pat = 0, 0, 0, 0
local vdcReg, mawrLo, mawr = 0, 0, 0

local function flush(phase)
  if not armed then return end
  local state = emu.read(0x7FDF, MEM) or 0xFF
  f:write(string.format('%d\t%02X\t%d\t%d\t%d\t%d\t%s\n', frame, state, n601e, n606f, npush, pat, phase)); f:flush()
  emu.log(string.format('RENDER ORDER f=%d state=%02X 601E=%d 606F=%d push=%d pat=%d %s', frame,state,n601e,n606f,npush,pat,phase))
end

emu.addMemoryCallback(function() n601e=n601e+1 end, emu.callbackType.exec, 0x601E, 0x601E, emu.cpuType.pce, CPU)
emu.addMemoryCallback(function() n606f=n606f+1 end, emu.callbackType.exec, 0x606F, 0x606F, emu.cpuType.pce, CPU)
emu.addMemoryCallback(function() npush=npush+1 end, emu.callbackType.exec, 0x6463, 0x6463, emu.cpuType.pce, CPU)
emu.addMemoryCallback(function(address,value)
  if address==0 then vdcReg=value or 0
  elseif address==2 and vdcReg==0 then mawrLo=value or 0
  elseif address==3 and vdcReg==0 then mawr=mawrLo|((value or 0)<<8)
  elseif address==3 and vdcReg==2 and armed and mawr>=0x7900 and mawr<0x7DC0 then pat=pat+1 end
end, emu.callbackType.write, 0, 3, emu.cpuType.pce, CPU)
emu.addMemoryCallback(function()
  local st=emu.getState(); local ending=((st['cdrom.adpcm.readAddress'] or 0)+(st['cdrom.adpcm.adpcmLength'] or 0))%0x10000
  if ending==0x6800 and (st['cdrom.adpcm.playbackRate'] or -1)==0x0E then armed=true;post=0;emu.log('RENDER ORDER armed') end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)
emu.addEventCallback(function()
  flush(post>0 and ('post_'..post) or 'active')
  if armed and (emu.getState()['cdrom.adpcm.playing']~=true) then post=post+1; if post>12 then armed=false end end
  frame=frame+1;n601e,n606f,npush,pat=0,0,0,0
end,emu.eventType.startFrame)
emu.addEventCallback(function()f:close()end,emu.eventType.scriptEnded)
emu.log('PROBE_SUB_RENDER_ORDER 0.1.0 loaded -- 완전 읽기 전용')
emu.log('  output: '..OUT)
