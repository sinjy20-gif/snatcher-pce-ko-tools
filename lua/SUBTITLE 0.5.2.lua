-- SUBTITLE 0.5.2 -- safe one-shot SAT/VRAM budget audit.
-- Runs only after E6800_0E begins; reads VRAM once and writes nothing.

local OUT = "C:/snatcher/dump/subtitle_0_5_2.tsv"
local mem, vram, cpu = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.cpuType.pce
local frame, pending, done = 0, false, false
local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\ta\tb\tc\tnote\n")

local function rb(a) return emu.read(a, mem) or 0 end
local function vw(w) return (emu.read(w * 2, vram) or 0) + 256 * (emu.read(w * 2 + 1, vram) or 0) end
local function row(k,a,b,c,n) file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n",k,frame,tostring(a or ""),tostring(b or ""),tostring(c or ""),n or "")) end

emu.addMemoryCallback(function()
  if rb(0x22A6) == 0 and rb(0x22A7) == 0x68 and rb(0x22AA) == 0x0E then
    pending = true
    emu.log("SUBTITLE 0.5.2 armed: will audit one active frame")
  end
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  if not pending or done then return end
  done = true
  local s = emu.getState() or {}
  local base = s["vdc.satbBlockSrc"] or 0x1000
  row("satb", string.format("%04X",base), s["vdc.memAddrWrite"], "", "active frame")
  local used, bestStart, bestRun, runStart, run = 0, nil, 0, nil, 0
  for i = 0, 63 do
    local w = base + i * 4
    local y,x,p,a = vw(w),vw(w+1),vw(w+2),vw(w+3)
    local live = not (y == 0 and x == 0 and p == 0)
    if live then used = used + 1; row("sat",i,string.format("%04X,%04X",y,x),string.format("%04X,%04X",p,a),"used") end
  end
  for w = 0, 0x7FFF do
    if vw(w) == 0 then
      if run == 0 then runStart = w end
      run = run + 1
    else
      if run > bestRun then bestStart,bestRun = runStart,run end
      run = 0
    end
  end
  if run > bestRun then bestStart,bestRun = runStart,run end
  row("summary",used,64-used,string.format("%04X+%d",bestStart or 0,bestRun),"used/free SAT; largest zero VRAM run (words)")
  file:flush()
  emu.log(string.format("SUBTITLE 0.5.2 done: SAT used=%d, largest VRAM zero run=$%04X + %d words", used,bestStart or 0,bestRun))
end, emu.eventType.endFrame)
emu.addEventCallback(function() file:close() end, emu.eventType.scriptEnded)
emu.log("SUBTITLE 0.5.2 loaded (safe, read-only)")
