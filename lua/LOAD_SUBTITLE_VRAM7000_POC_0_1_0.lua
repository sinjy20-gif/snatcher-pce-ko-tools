-- $7000 helper/renderer만 AC에 교체하는 일회성 POC. 팩/디스크/BIOS는 건드리지 않는다.
local AC=emu.memType.pceArcadeCardRam
local function load(path,at)
 local f=assert(io.open(path,'rb')); local d=f:read('*a'); f:close()
 for i=1,#d do emu.write(at+i-1,d:byte(i),AC) end
 return #d
end
local h=load('C:/snatcher/build/cutscene_subs/subtitle_vram_helper_vram7000.bin',0x1F1C00)
local r=load('C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc_vram7000.bin',0x1F1F00)
local key={0x78,0x30,0,0,0x68,0x0E}
for i=1,6 do emu.write(0x1F1F00+366+i-1,key[i],AC) end
emu.log(string.format('SUBTITLE VRAM7000 POC PASS: helper %d B, renderer %d B -> AC only',h,r))
