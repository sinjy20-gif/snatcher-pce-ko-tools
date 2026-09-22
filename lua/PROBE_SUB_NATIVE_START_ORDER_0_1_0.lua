-- PROBE_SUB_NATIVE_START_ORDER 0.1.0 -- 읽기 전용 시작 호출 순서 측정

local MEM,AC,VRAM,CPU=emu.memType.pceMemory,emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam,emu.memType.cpu
local OUT=string.format('C:/snatcher/dump/probe_sub_native_start_order_0_1_0_%s.tsv',os.date('%Y%m%d_%H%M%S'))
local f=assert(io.open(OUT,'w'))
f:write('seq\tframe\tevent\tplaying\tlocal_7fdf\tmailbox_ac\tmagic\tours\tnote\n')

local frame,seq=0,0
local armed=false
local stopFrame=-1

local function rd(at,kind)
  local v=emu.read(at,kind); return type(v)=='number' and v or 0
end
local function ours()
  local n=0
  for e=0,63 do
    local at=0x1000*2+e*8+4
    local p=rd(at,VRAM)|(rd(at+1,VRAM)<<8)
    if p>=0x03C4 and p<=0x03E9 then n=n+1 end
  end
  return n
end
local function emit(event,note,force)
  if not armed and not force then return end
  seq=seq+1
  local playing=emu.getState()['cdrom.adpcm.playing']==true and 1 or 0
  local magic=string.format('%02X %02X %02X',rd(0x5B80,MEM),rd(0x5B81,MEM),rd(0x5B82,MEM))
  local localState,mail=rd(0x7FDF,MEM),rd(0x1F03F0,AC)
  f:write(string.format('%d\t%d\t%s\t%d\t%02X\t%02X\t%s\t%d\t%s\n',
    seq,frame,event,playing,localState,mail,magic,ours(),note or '')); f:flush()
  emu.log(string.format('START_ORDER %02d f=%d %-14s play=%d local=%02X mail=%02X magic=%s ours=%d',
    seq,frame,event,playing,localState,mail,magic,ours()))
end

emu.addMemoryCallback(function()
  local st=emu.getState()
  local ending=((st['cdrom.adpcm.readAddress'] or 0)+(st['cdrom.adpcm.adpcmLength'] or 0))%0x10000
  if ending==0x6800 and (st['cdrom.adpcm.playbackRate'] or -1)==0x0E then
    armed=true; stopFrame=frame+4
    emit('AD_PLAY_PRE','E6800_0E 실행 직전',true)
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addMemoryCallback(function() emit('HOOK_601E','$601E 실행 직전') end,
  emu.callbackType.exec,0x601E,0x601E,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function() emit('RESIDENT_7F49','$7F49 실행 직전') end,
  emu.callbackType.exec,0x7F49,0x7F49,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function() emit('ENGINE_5B80','$5B80 실행 직전') end,
  emu.callbackType.exec,0x5B80,0x5B80,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1
  if armed then
    emit('FRAME_START','프레임 시작')
    if frame>=stopFrame then emit('MEASURE_END','측정 종료'); armed=false end
  end
end,emu.eventType.startFrame)

emu.addEventCallback(function() f:close() end,emu.eventType.scriptEnded)
emu.log('PROBE_SUB_NATIVE_START_ORDER 0.1.0 loaded -- 읽기 전용')
emu.log('  AD_PLAY부터 4프레임 동안 $601E/resident/engine 순서를 기록한다')
emu.log('  출력: '..OUT)
