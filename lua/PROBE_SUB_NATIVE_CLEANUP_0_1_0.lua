-- PROBE_SUB_NATIVE_CLEANUP 0.1.0 -- 읽기 전용 종료 잔류 측정
-- 먼저 순정 Galmuri BIOS에서 단독 실행, 다음 판에는 native loader보다 먼저 실행한다.

local MEM,CPU,VRAM,AC=emu.memType.pceMemory,emu.memType.cpu,
                         emu.memType.pceVideoRam,emu.memType.pceArcadeCardRam
local PAT,PAT_N=0x7900*2,2432
local SAT,SAT_N=0x1000*2,512
local RAM,RAM_N=0x5B80,671
local AC_PAT,AC_CPU,AC_SAT=0x1F0400,0x1F0E00,0x1F1100
local OUT=string.format('C:/snatcher/dump/probe_sub_native_cleanup_0_1_0_%s.tsv',os.date('%Y%m%d_%H%M%S'))
local f=assert(io.open(OUT,'w'))
f:write('phase\tframe\tplaying\tsatb_src\tsat_pending\tsat_running\trepeat_sat\tpat_hash\tsat_hash\tram_hash\tinternal_hash\tac_pat_hash\tac_sat_hash\tac_cpu_hash\tours\tpat_diff\tsat_diff\tram_diff\tinternal_diff\tdvssr_writes\tsat_vram_writes\tnote\n')

local spriteMem,spriteName=nil,''
for name,value in pairs(emu.memType or {}) do
  local n=string.lower(tostring(name))
  if n:find('sprite') or n:find('satb') then spriteMem=value; spriteName=tostring(name); break end
end

local function bytes(at,n,kind)
  local t={}; for i=0,n-1 do t[i]=emu.read(at+i,kind) or 0 end; return t
end
local function hash(t,n)
  local h=2166136261
  for i=0,n-1 do h=((h ~ (t[i] or 0))*16777619)&0xFFFFFFFF end
  return h
end
local function countdiff(a,b,n)
  if not a or not b then return -1 end
  local d=0; for i=0,n-1 do if a[i]~=b[i] then d=d+1 end end; return d
end
local function ours(sat)
  local n=0
  -- pattern word is entry bytes +4/+5. Subtitle range is $3C4-$3E9.
  for e=0,63 do
    local o=e*8+4; local p=(sat[o] or 0)|((sat[o+1] or 0)<<8)
    if p>=0x03C4 and p<=0x03E9 then n=n+1 end
  end
  return n
end

local base=nil
local baseFrame=-1
local statCaptured=false
local frame=0
local dvssrWrites,satWrites=0,0
local vdcReg,mawrLo,mawr=0,0,0
local scheduled={}

local function capture(label,note,setbase)
  local st=emu.getState()
  local p=bytes(PAT,PAT_N,VRAM); local s=bytes(SAT,SAT_N,VRAM); local r=bytes(RAM,RAM_N,MEM)
  local im=nil
  if spriteMem~=nil then im=bytes(0,SAT_N,spriteMem) end
  local ap=bytes(AC_PAT,PAT_N,AC); local as=bytes(AC_SAT,SAT_N,AC); local ar=bytes(AC_CPU,RAM_N,AC)
  if setbase or base==nil then base={p=p,s=s,r=r,im=im} end
  if setbase then baseFrame=frame; statCaptured=false end
  local playing=st['cdrom.adpcm.playing']==true and 1 or 0
  local src=st['vdc.satbBlockSrc']; if type(src)~='number' then src=-1 end
  local pending=st['vdc.satbTransferPending']; local running=st['vdc.satbTransferRunning']
  local repeatv=st['vdc.repeatSatbTransfer']
  f:write(string.format('%s\t%d\t%d\t%04X\t%s\t%s\t%s\t%08X\t%08X\t%08X\t%08X\t%08X\t%08X\t%08X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n',
    label,frame,playing,src&0xFFFF,tostring(pending),tostring(running),tostring(repeatv),
    hash(p,PAT_N),hash(s,SAT_N),hash(r,RAM_N),im and hash(im,SAT_N) or 0,
    hash(ap,PAT_N),hash(as,SAT_N),hash(ar,RAM_N),ours(s),
    countdiff(base.p,p,PAT_N),countdiff(base.s,s,SAT_N),countdiff(base.r,r,RAM_N),
    im and countdiff(base.im,im,SAT_N) or -1,dvssrWrites,satWrites,note or ''))
  f:flush()
  emu.log(string.format('CLEAN %s f=%d src=%04X ours=%d diff pat=%d sat=%d ram=%d internal=%d',
    label,frame,src&0xFFFF,ours(s),countdiff(base.p,p,PAT_N),countdiff(base.s,s,SAT_N),
    countdiff(base.r,r,RAM_N),im and countdiff(base.im,im,SAT_N) or -1))
end

-- VDC 포트 관측만 한다. 어떤 메모리에도 쓰지 않는다.
emu.addMemoryCallback(function(address,value)
  if address==0 then vdcReg=value or 0; if vdcReg==0x13 then dvssrWrites=dvssrWrites+1 end
  elseif address==2 and vdcReg==0 then mawrLo=value or 0
  elseif address==3 and vdcReg==0 then mawr=mawrLo|((value or 0)<<8)
  elseif (address==2 or address==3) and vdcReg==2 and mawr>=0x1000 and mawr<=0x10FF then
    satWrites=satWrites+1
  end
end,emu.callbackType.write,0x0000,0x0003,emu.cpuType.pce,CPU)

emu.addMemoryCallback(function()
  local st=emu.getState()
  local ending=((st['cdrom.adpcm.readAddress'] or 0)+(st['cdrom.adpcm.adpcmLength'] or 0))%0x10000
  if ending==0x6800 and
     (st['cdrom.adpcm.playbackRate'] or -1)==0x0E then
    capture('AD_PLAY_PRE','E6800_0E 실행 직전',true)
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addMemoryCallback(function()
  if base and not statCaptured and frame>baseFrame+30 then
    local st=emu.getState()
    if st['cdrom.adpcm.playing']~=true then
      statCaptured=true; capture('AD_STAT_PRE','F6EF 종료 경로 실행 직전',false)
    end
  end
end,emu.callbackType.exec,0xF6EF,0xF6EF,emu.cpuType.pce,CPU)

local was=false
emu.addEventCallback(function()
  frame=frame+1
  local playing=emu.getState()['cdrom.adpcm.playing']==true
  if base and playing and not was then capture('PLAYING_1','재생 감지 첫 프레임',false) end
  if base and not playing and was then
    capture('FALL_0','playing 하강 첫 프레임',false)
    for _,d in ipairs({1,2,8,30,120}) do scheduled[frame+d]='POST_'..d end
  end
  local label=scheduled[frame]
  if label then scheduled[frame]=nil; capture(label,'종료 후 프레임',false) end
  was=playing
end,emu.eventType.startFrame)

emu.addEventCallback(function() f:close() end,emu.eventType.scriptEnded)
emu.log('PROBE_SUB_NATIVE_CLEANUP 0.1.0 loaded -- 읽기 전용')
emu.log('  내부 Sprite/SAT 메모리: '..(spriteName~='' and spriteName or '노출 없음'))
emu.log('  출력: '..OUT)
