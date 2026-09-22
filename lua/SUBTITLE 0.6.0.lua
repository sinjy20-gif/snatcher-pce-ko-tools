-- SUBTITLE 0.6.0 -- passive crash-timeline probe for the UI POC.
-- Records only: AD_PLAY keys, IRQ1 vector transitions, and execution entering
-- the borrowed $5B80-$5FFF range.  It performs no emulated writes.
local OUT="C:/snatcher/dump/subtitle_0_6_0.tsv"
local mem,cpu=emu.memType.pceMemory,emu.cpuType.pce
local frame,execs,lastVec,lastPlay=0,0,"",""
local f=assert(io.open(OUT,"w")); f:write("kind\tframe\ta\tb\tc\tnote\n")
local function rb(a) return emu.read(a,mem) or 0 end
local function row(k,a,b,c,n) f:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n",k,frame,tostring(a or ""),tostring(b or ""),tostring(c or ""),n or "")); f:flush() end
local function key() return string.format("E%02X%02X_%02X",rb(0x22A7),rb(0x22A6),rb(0x22AA)) end
emu.addMemoryCallback(function()
  row("ad-play",key(),string.format("%02X",rb(0x22A6)),"","F61A executed")
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,cpu)
emu.addMemoryCallback(function(addr)
  execs=execs+1
  if execs<=12 then row("borrow-exec",string.format("%04X",addr or 0x5B80),execs,"","engine range executed") end
end,emu.callbackType.exec,0x5B80,0x5FFF,emu.cpuType.pce,cpu)
emu.addEventCallback(function()
  frame=frame+1
  local vec=string.format("%02X%02X",rb(0x2203),rb(0x2202))
  if vec~=lastVec then row("irq1",vec,execs,"","IRQ1 vector transition"); lastVec=vec end
  local p=(emu.getState() or {})["cdrom.adpcm.playing"]==true and "playing" or "idle"
  if p~=lastPlay then row("adpcm",p,key(),"","state transition"); lastPlay=p end
end,emu.eventType.endFrame)
emu.addEventCallback(function() f:close() end,emu.eventType.scriptEnded)
emu.log("SUBTITLE 0.6.0 loaded (passive UI-POC crash timeline)")
