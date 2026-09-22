-- PROBE_SUB_NATIVE_ORDER 0.1.0 -- 읽기 전용 종료 호출 순서 측정
-- 0.7.0-r1 정상판에서 AD_STAT / playing 하강 / $601E / resident의 순서를 잰다.

local MEM,CPU,VRAM,AC=emu.memType.pceMemory,emu.memType.cpu,
                         emu.memType.pceVideoRam,emu.memType.pceArcadeCardRam
local OUT=string.format('C:/snatcher/dump/probe_sub_native_order_0_1_0_%s.tsv',os.date('%Y%m%d_%H%M%S'))
local f=assert(io.open(OUT,'w'))
f:write('seq\tframe\tevent\tplaying\tstate_7fdf\tmailbox_ac\tmagic\thelapsed\tready\tours\tsatb_src\tnote\n')

local frame,seq=0,0
local armed=false
local sawPlaying=false
local fallFrame=-1
local endingWindow=false

local function rd(at,kind)
  local v=emu.read(at,kind)
  return type(v)=='number' and v or 0
end

local function ours()
  local n=0
  for e=0,63 do
    local o=0x1000*2+e*8+4
    local p=rd(o,VRAM)|(rd(o+1,VRAM)<<8)
    if p>=0x03C4 and p<=0x03E9 then n=n+1 end
  end
  return n
end

local function emit(event,note)
  if not armed then return end
  seq=seq+1
  local st=emu.getState()
  local playing=st['cdrom.adpcm.playing']==true and 1 or 0
  local src=st['vdc.satbBlockSrc']; if type(src)~='number' then src=-1 end
  local m=string.format('%02X %02X %02X',rd(0x5B80,MEM),rd(0x5B81,MEM),rd(0x5B82,MEM))
  local line=string.format('%d\t%d\t%s\t%d\t%02X\t%02X\t%s\t%d\t%d\t%d\t%04X\t%s\n',
    seq,frame,event,playing,rd(0x7FDF,MEM),rd(0x1F03F0,AC),m,
    rd(0x5B80+0xB0,MEM),rd(0x5B80+0xB1,MEM),ours(),src&0xFFFF,note or '')
  f:write(line); f:flush()
  emu.log(string.format('ORDER %02d f=%d %-14s play=%d state=%02X magic=%s ours=%d',
    seq,frame,event,playing,rd(0x7FDF,MEM),m,ours()))
end

emu.addMemoryCallback(function()
  local st=emu.getState()
  local ending=((st['cdrom.adpcm.readAddress'] or 0)+(st['cdrom.adpcm.adpcmLength'] or 0))%0x10000
  if ending==0x6800 and (st['cdrom.adpcm.playbackRate'] or -1)==0x0E then
    armed=true; sawPlaying=false; fallFrame=-1; endingWindow=false
    emit('AD_PLAY_PRE','E6800_0E')
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addMemoryCallback(function()
  if armed and sawPlaying and emu.getState()['cdrom.adpcm.playing']~=true then
    endingWindow=true
    emit('AD_STAT_PRE','BIOS AD_STAT 종료 경로 진입')
  end
end,
  emu.callbackType.exec,0xF6EF,0xF6EF,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function() if endingWindow then emit('HOOK_601E','$601E 실행 직전') end end,
  emu.callbackType.exec,0x601E,0x601E,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function() if endingWindow then emit('RESIDENT_7F49','$7F49 실행 직전') end end,
  emu.callbackType.exec,0x7F49,0x7F49,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function() if endingWindow then emit('ENGINE_5B80','$5B80 실행 직전') end end,
  emu.callbackType.exec,0x5B80,0x5B80,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1
  if not armed then return end
  local playing=emu.getState()['cdrom.adpcm.playing']==true
  if playing and not sawPlaying then sawPlaying=true; emit('FRAME_PLAY_1','재생 첫 프레임') end
  if sawPlaying and not playing and fallFrame<0 then
    fallFrame=frame; emit('FRAME_FALL_0','playing 하강 프레임')
  elseif fallFrame>=0 then
    local d=frame-fallFrame
    if d<=4 then emit('FRAME_POST_'..d,'종료 후 프레임') end
    if d>=5 then emit('MEASURE_END','측정 종료'); armed=false end
  end
end,emu.eventType.startFrame)

emu.addEventCallback(function() f:close() end,emu.eventType.scriptEnded)
emu.log('PROBE_SUB_NATIVE_ORDER 0.1.0 loaded -- 읽기 전용')
emu.log('  E6800_0E 종료 전후의 AD_STAT / $601E / resident 호출 순서를 기록한다')
emu.log('  출력: '..OUT)
