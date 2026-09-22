-- Lua-only dynamic VRAM allocator POC. Native build에는 아직 반영하지 않는다.
local M,V,A,C=emu.memType.pceMemory,emu.memType.pceVideoRam,emu.memType.pceArcadeCardRam,emu.memType.cpu
local N=1216
local function used(base)
 local p0=(base>>5)&0xFFFF
 for s=0,63 do local o=0x2000+s*8+4;local p=(emu.read(o,V)or 0)|((emu.read(o+1,V)or 0)<<8);if p>=p0 and p<p0+38 then return true end end
 return false
end
local function empty(base)
 for w=base,base+N-1 do if (emu.read(w*2,V)or 0)~=0 or (emu.read(w*2+1,V)or 0)~=0 then return false end end
 return true
end
local function choose()
 for b=0x6000,0x7B00,0x100 do if empty(b) and not used(b) then return b end end
end
local function data(p) local f=assert(io.open(p,'rb'));local d=f:read('*a');f:close();return d end
local H=data('C:/snatcher/build/cutscene_subs/subtitle_vram_helper.bin')
local R=data('C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin')
local function put(at,d)for i=1,#d do emu.write(at+i-1,d:byte(i),A)end end
local function poke(s,pos,v)return s:sub(1,pos-1)..string.char(v)..s:sub(pos+1)end
emu.addMemoryCallback(function()
 local st=emu.getState();local e=((st['cdrom.adpcm.readAddress']or 0)+(st['cdrom.adpcm.adpcmLength']or 0))%0x10000
 if e~=0x6800 or (st['cdrom.adpcm.playbackRate']or -1)~=0x0E then return end
 local b=choose();if not b then emu.log('DYNAMIC VRAM SKIP: safe 19-glyph block 없음');return end
 -- diff offsets are binary zero-based (helper 41/133, renderer 167/276);
 -- Lua strings are one-based, hence 42/134 and 168/277.
 local h=poke(poke(H,42,b>>8),134,b>>8)
 local r=poke(poke(R,168,b>>8),277,(b>>5)&255)
 put(0x1F1C00,h);put(0x1F1F00,r);local k={0x78,0x30,0,0,0x68,0x0E};for i=1,6 do emu.write(0x1F1F00+365+i,k[i],A)end
 emu.log(string.format('DYNAMIC VRAM POC: $%04X selected (zero + SATB-free)',b))
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,C)
emu.log('POC_SUBTITLE_DYNAMIC_VRAM 0.1.0 loaded -- Lua AC writes only')
