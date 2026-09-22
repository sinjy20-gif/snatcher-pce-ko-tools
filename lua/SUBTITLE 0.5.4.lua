-- SUBTITLE 0.5.4 -- diagnostic only: record every AD_PLAY entry.
-- Read-only. Use this before any renderer measurement if 0.5.2/0.5.3 did not arm.
local OUT = "C:/snatcher/dump/subtitle_0_5_4.tsv"
local mem, cpu = emu.memType.pceMemory, emu.cpuType.pce
local frame, n = 0, 0
local f = assert(io.open(OUT,"w")); f:write("frame\ta6\ta7\taa\tkey\n")
local function rb(a) return emu.read(a,mem) or 0 end
emu.addMemoryCallback(function()
  n=n+1
  local a6,a7,aa=rb(0x22A6),rb(0x22A7),rb(0x22AA)
  local key=string.format("E%02X%02X_%02X",a7,a6,aa)
  f:write(string.format("%d\t%02X\t%02X\t%02X\t%s\n",frame,a6,a7,aa,key)); f:flush()
  emu.log("SUBTITLE 0.5.4 AD_PLAY #"..n.." "..key)
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,cpu)
emu.addEventCallback(function() frame=frame+1 end,emu.eventType.endFrame)
emu.addEventCallback(function() f:close() end,emu.eventType.scriptEnded)
emu.log("SUBTITLE 0.5.4 loaded (read-only AD_PLAY census)")
