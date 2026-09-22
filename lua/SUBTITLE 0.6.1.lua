-- SUBTITLE 0.6.1 -- passive byte-level IRQ1-vector write trace for UI POC.
local OUT="C:/snatcher/dump/subtitle_0_6_1.tsv"
local mem,cpu=emu.memType.pceMemory,emu.cpuType.pce
local frame,n=0,0
local f=assert(io.open(OUT,"w")); f:write("kind\tframe\tlo\thi\tcount\tnote\n")
local function rb(a) return emu.read(a,mem) or 0 end
local function row(k,note)
  f:write(string.format("%s\t%d\t%02X\t%02X\t%d\t%s\n",k,frame,rb(0x2202),rb(0x2203),n,note)); f:flush()
end
emu.addMemoryCallback(function()
  n=n+1; row("irq1-write","write to $2202/$2203")
end,emu.callbackType.write,0x2202,0x2203,emu.cpuType.pce,cpu)
emu.addEventCallback(function() frame=frame+1 end,emu.eventType.endFrame)
emu.addEventCallback(function() f:close() end,emu.eventType.scriptEnded)
row("load","initial IRQ1 vector")
emu.log("SUBTITLE 0.6.1 loaded (passive IRQ1 vector write trace)")
