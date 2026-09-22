-- SUBTITLE 0.5.6 -- read-only SAT audit across three E6800_0E voices.
local OUT = "C:/snatcher/dump/subtitle_0_5_6.tsv"
local mem, vram = emu.memType.pceMemory, emu.memType.pceVideoRam
local frame, voice, active, sawPlaying, done = 0, 0, false, false, false
local seen, firstSeen, lastSeen = {}, {}, {}
local file = assert(io.open(OUT, "w")); file:write("kind\tframe\ta\tb\tc\tnote\n")
local function rb(a) return emu.read(a, mem) or 0 end
local function vw(w) return (emu.read(w*2, vram) or 0) + 256*(emu.read(w*2+1, vram) or 0) end
local function match() return rb(0x22A6)==0 and rb(0x22A7)==0x68 and rb(0x22AA)==0x0E end
local function row(k,a,b,c,n) file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n",k,frame,tostring(a or ""),tostring(b or ""),tostring(c or ""),n or "")) end
local function sample(s)
  local base=s["vdc.satbBlockSrc"] or 0x1000
  for i=0,63 do
    local w=base+i*4; local y,x,p=vw(w),vw(w+1),vw(w+2)
    if not(y==0 and x==0 and p==0) then
      if not seen[i] then firstSeen[i]=frame end
      seen[i],lastSeen[i]=true,frame
    end
  end
end
local function report(s)
  local used=0
  for i=0,63 do if seen[i] then used=used+1; row("sat-ever",i,firstSeen[i],lastSeen[i],"used during one of 3 voices") end end
  local bestStart,bestRun,runStart,run=nil,0,nil,0
  for w=0,0x7FFF do
    if vw(w)==0 then if run==0 then runStart=w end; run=run+1
    else if run>bestRun then bestStart,bestRun=runStart,run end; run=0 end
  end
  if run>bestRun then bestStart,bestRun=runStart,run end
  row("summary",used,64-used,string.format("%04X+%d",bestStart or 0,bestRun),"SAT used-ever/free-ever across 3 voices; largest zero VRAM run")
  file:flush(); emu.log(string.format("SUBTITLE 0.5.6 done: voices=3 SAT used-ever=%d, free-ever=%d, VRAM=$%04X + %d",used,64-used,bestStart or 0,bestRun))
end
emu.addEventCallback(function()
  frame=frame+1; if done then return end
  local s=emu.getState() or {}; local playing=s["cdrom.adpcm.playing"]==true
  if not active and match() and playing then
    voice=voice+1; active,sawPlaying=true,true
    row("start",voice,s["vdc.satbBlockSrc"],"","E6800_0E voice")
    emu.log("SUBTITLE 0.5.6 armed voice "..voice)
  end
  if not active then return end
  sample(s)
  if sawPlaying and not playing then
    row("end",voice,"","","voice ended")
    active=false
    if voice>=3 then report(s); done=true end
  end
end,emu.eventType.endFrame)
emu.addEventCallback(function() file:close() end,emu.eventType.scriptEnded)
emu.log("SUBTITLE 0.5.6 loaded (safe, read-only 3-voice SAT audit)")
