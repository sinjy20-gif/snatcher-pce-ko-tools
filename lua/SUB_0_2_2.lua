-- SUB 0.2.2 -- allocator test. Load this file only (0.2.1 is retained).
-- Same two-fragment E6800_0E test, but measures at glyph_done / $6527 instead
-- of startFrame so it observes the upload and the SATB push themselves.
local MEM,VRAM,AC,CPU=emu.memType.pceMemory,emu.memType.pceVideoRam,emu.memType.pceArcadeCardRam,emu.memType.cpu
local E,RB,GD,PUSH_DONE,STATE=0x5B80,0x5BA6,0x5CB6,0x6527,0x7FDF
local AH,AR,N,TARGET=0x1F1C00,0x1F1F00,1216,0x6800
local KEY={0x78,0x30,0,0,0x68,0x0E}
local active,started,pending,current,parts=false,false,nil,nil,0
local saved,measure={},{ }
local function get(path)local f=assert(io.open(path,'rb'),'cannot open '..path);local d=f:read('*a');f:close();return d end
local H=get('C:/snatcher/build/cutscene_subs/subtitle_vram_helper.bin')
local R=get('C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin')
local function rb(a)return emu.read(a,VRAM)or 0 end
local function wb(a,v)emu.write(a,v,VRAM)end
local function put(a,s)for i=1,#s do emu.write(a+i-1,s:byte(i),AC)end end
local function poke(s,p,v)return s:sub(1,p-1)..string.char(v)..s:sub(p+1)end
local function snap(b)local t={};for w=b,b+N-1 do local a=w*2;t[#t+1]=rb(a);t[#t+1]=rb(a+1)end;saved[b]=t end
local function restore(b)local t=saved[b];if not t then return false end;for w=b,b+N-1 do local a,i=w*2,(w-b)*2+1;wb(a,t[i]);wb(a+1,t[i+1])end;return true end
local function satb(b)
 local lo,n=(b>>5)&0xFFFF,0
 for s=0,63 do local a=0x2000+s*8+4;local p=rb(a)|(rb(a+1)<<8);if p>=lo and p<lo+38 then n=n+1 end end
 return n
end
local function blank(b)for w=b,b+N-1 do local a=w*2;if rb(a)~=0 or rb(a+1)~=0 then return false end end;return true end
local function choose()for b=0x6000,0x7B00,0x100 do if blank(b)and satb(b)==0 then return b end end end
local function used(b)local n=0;for a=b*2,(b+N)*2-1 do if rb(a)~=0 then n=n+1 end end;return n end
local function first(b)
 local h=poke(poke(H,42,b>>8),134,b>>8);local r=poke(poke(R,168,b>>8),277,(b>>5)&255)
 put(AH,h);put(AR,r);for i=1,6 do emu.write(AR+365+i,KEY[i],AC)end
end
local function running(b)emu.write(E+167,b>>8,MEM);emu.write(E+276,(b>>5)&255,MEM)end
local function finish(why)
 if current and restore(current)then emu.log(string.format('SUB 0.2.2 RESTORE: $%04X (%s)',current,why))end
 active,started,pending,current,parts,saved,measure=false,false,nil,nil,0,{},{ }
end
emu.addMemoryCallback(function()
 local s=emu.getState();local ending=((s['cdrom.adpcm.readAddress']or 0)+(s['cdrom.adpcm.adpcmLength']or 0))%0x10000
 if ending~=TARGET or(s['cdrom.adpcm.playbackRate']or-1)~=0x0E then return end
 finish('new voice');pending=choose();if not pending then emu.log('SUB 0.2.2 SKIP: safe 19-glyph block 없음');return end
 first(pending);active=true;emu.log(string.format('SUB 0.2.2 START: first=$%04X',pending))
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function()
 if not active or parts>=2 then return end
 if current then restore(current)end;local b=pending or choose();pending=nil
 if not b then emu.log('SUB 0.2.2 SKIP: safe 19-glyph block 없음');return end
 if not saved[b]then snap(b)end;running(b);current,parts,started=b,parts+1,true;measure={part=parts,base=b,up=false,push=false}
 emu.log(string.format('SUB 0.2.2 ALLOC #%d: $%04X (blank + SATB-free)',parts,b))
end,emu.callbackType.exec,RB,RB,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function()
 if measure and not measure.up then measure.up=true;emu.log(string.format('SUB 0.2.2 UPLOAD #%d: VRAM=%d/2432',measure.part,used(measure.base)))end
end,emu.callbackType.exec,GD,GD,emu.cpuType.pce,CPU)
emu.addMemoryCallback(function()
 if measure and measure.up and not measure.push then measure.push=true;emu.log(string.format('SUB 0.2.2 SATB #%d: refs=%d',measure.part,satb(measure.base)))end
end,emu.callbackType.exec,PUSH_DONE,PUSH_DONE,emu.cpuType.pce,CPU)
emu.addEventCallback(function()if active and started and(emu.read(STATE,MEM)or 0)==0 then finish('voice end')end end,emu.eventType.startFrame)
emu.log('SUB 0.2.2 loaded -- allocator + upload/SATB measurement / 이 파일 하나만 사용')
