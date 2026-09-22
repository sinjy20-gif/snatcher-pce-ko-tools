-- Active subtitle POC 0.1.0
-- Registered ADPCM only:
--   save $5B80-$5FFF to AC $1C0000 -> install IRQ1 chain stub -> draw subtitle
--   -> restore RAM/vector byte-exactly when playback ends.

local EVENTS = "C:/snatcher/snatcher_tool/translation/voice_events.tsv"
local SUBS   = "C:/snatcher/snatcher_tool/translation/voice_subtitles.tsv"
local FONT   = "C:/snatcher/build/bios_font/galmuri_ks_2350.bin"
local FONTMAP= "C:/snatcher/build/bios_font/galmuri_ks_2350.tsv"
local OUT    = "C:/snatcher/dump/poc_subtitle_active_0_1_0.tsv"
local LO, HI, SIZE, AC_BASE = 0x5B80, 0x5FFF, 0x480, 0x1C0000
local IRQV, SUB_BOTTOM, ADVANCE, MAX_CHARS = 0x2202, 140, 12, 20
local mem, cpu, ac = emu.memType.pceMemory, emu.memType.cpu, emu.memType.pceArcadeCardRam

local function readTsv(path)
  local f = assert(io.open(path, "rb"), "cannot open " .. path)
  local text = f:read("a"); f:close(); text = text:gsub("^\239\187\191", "")
  local h, rows = nil, {}
  for line in text:gmatch("[^\r\n]+") do
    local fields = {}; for v in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields+1]=v end
    if not h then h={}; for i,n in ipairs(fields) do h[n]=i end else rows[#rows+1]=fields end
  end
  return h, rows
end
local function get(h,r,n) return r[h[n]] or "" end
local function chars(s)
  local out={}; for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out+1]=c end
  return out
end
local function endKey(fp)
  local r,l,rate=fp:match("^ADPCM_(%x+)_(%x+)_(%x+)$"); if not r then return nil end
  local finish=(tonumber(r,16)+tonumber(l,16))%0x10000
  return finish==0xFFFF and fp or string.format("E%04X_%02X",finish,tonumber(rate,16))
end

local eh,er=readTsv(EVENTS); local sh,sr=readTsv(SUBS)
local keyById, textByKey={},{}
for _,r in ipairs(er) do
  if get(eh,r,"audio_type")=="ADPCM" then keyById[get(eh,r,"event_id")]=endKey(get(eh,r,"fingerprint")) end
end
for _,r in ipairs(sr) do
  local key=keyById[get(sh,r,"event_id")]
  if key and get(sh,r,"ko_text")~="" then textByKey[key]=get(sh,r,"ko_text") end
end

-- Galmuri 16x16 bitmap font used by the proven company display POC.
local ff=assert(io.open(FONT,"rb")); local font=ff:read("a"); ff:close()
local mf=assert(io.open(FONTMAP,"rb")); local mt=mf:read("a"); mf:close()
local offsets={}
for line in mt:gmatch("[^\r\n]+") do
  local _,off,ch=line:match("^(%d+)\t(%x+)\t([^\t]+)\t")
  if off and ch then offsets[ch]=tonumber(off,16) end
end
local cache={}
local function bitmap(ch)
  if cache[ch]~=nil then return cache[ch] or nil end
  local off=offsets[ch]; if not off then cache[ch]=false; return nil end
  local rows={}
  for y=0,15 do
    local v=(font:byte(off+y*2+1) or 0)*256+(font:byte(off+y*2+2) or 0)
    rows[y]={}; for x=0,15 do rows[y][x]=((v>>(15-x))&1)==1 end
  end
  cache[ch]=rows; return rows
end
local function drawGlyph(rows,ox,oy)
  for y=0,15 do for x=0,15 do if rows[y][x] then
    local px=ox+x-1
    for dy=-1,1 do for dx=-1,1 do if dx~=0 or dy~=0 then
      emu.drawPixel(px+dx,oy+y+dy,0xFF000000,2)
    end end end
  end end end
  for y=0,15 do for x=0,15 do if rows[y][x] then
    emu.drawPixel(ox+x-1,oy+y,0xFFFFFF,2)
  end end end
end
local function wrap(text)
  local all=chars(text); if #all<=MAX_CHARS then return {all} end
  local cut=MAX_CHARS
  for i=MAX_CHARS,math.max(1,MAX_CHARS-6),-1 do if all[i]==" " then cut=i-1; break end end
  local a,b={},{}
  for i=1,cut do a[#a+1]=all[i] end
  local start=cut+1; while all[start]==" " do start=start+1 end
  for i=start,#all do b[#b+1]=all[i] end
  return {a,b}
end
local function drawText(text)
  local lines=wrap(text)
  for li,line in ipairs(lines) do
    local width=0; for _,ch in ipairs(line) do width=width+(ch==" " and 6 or (offsets[ch] and ADVANCE or 8)) end
    local x=math.max(16,math.floor((256-width)/2)); local y=SUB_BOTTOM-16-(#lines-li)*18
    for _,ch in ipairs(line) do
      if ch==" " then x=x+6 else
        local rows=bitmap(ch)
        if rows then drawGlyph(rows,x,y); x=x+ADVANCE
        else emu.drawString(x,y+6,ch,0xFFFFFF,0xFF000000,2); x=x+8 end
      end
    end
  end
end

local file=assert(io.open(OUT,"w"))
file:write("result\tstart_frame\tend_frame\tkey\tirq_hits\tunexpected_writes\tunexpected_execs\tdiff_bytes\tnote\n")
local frame,wasPlaying,active,internal=0,false,nil,false
local function stateKey(s)
  local r,l,rate=s["cdrom.adpcm.readAddress"],s["cdrom.adpcm.adpcmLength"],s["cdrom.adpcm.playbackRate"]
  if type(r)~="number" or type(l)~="number" or type(rate)~="number" then return nil end
  local finish=(math.floor(r)+math.floor(l))%0x10000
  return finish==0xFFFF and string.format("ADPCM_%04X_%04X_%02X",r,l,rate)
    or string.format("E%04X_%02X",finish,rate)
end
local function restore(note,forced)
  if not active then return end
  internal=true
  for i=0,SIZE-1 do emu.write(LO+i,active.snap[i],mem) end
  emu.write(IRQV,active.vecLo,mem); emu.write(IRQV+1,active.vecHi,mem)
  internal=false
  local diff=0
  for i=0,SIZE-1 do if (emu.read(LO+i,mem) or 0)~=active.snap[i] then diff=diff+1 end end
  if (emu.read(IRQV,mem) or 0)~=active.vecLo or (emu.read(IRQV+1,mem) or 0)~=active.vecHi then diff=diff+2 end
  local pass=not forced and active.badWrite==0 and active.badExec==0 and active.irqHits>0 and diff==0
  file:write(string.format("%s\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\n",
    pass and "PASS" or "FAIL",active.start,frame,active.key,active.irqHits,
    active.badWrite,active.badExec,diff,note or "")); file:flush()
  emu.log(string.format("SUB ACTIVE %s %s irq=%d writes=%d execs=%d diff=%d",
    pass and "PASS" or "FAIL",active.key,active.irqHits,active.badWrite,active.badExec,diff))
  active=nil
end
local function install(key,text)
  local snap={}
  for i=0,SIZE-1 do local v=emu.read(LO+i,mem) or 0; snap[i]=v; emu.write(AC_BASE+i,v,ac) end
  local vl,vh=emu.read(IRQV,mem) or 0,emu.read(IRQV+1,mem) or 0
  active={key=key,text=text,start=frame,snap=snap,vecLo=vl,vecHi=vh,irqHits=0,badWrite=0,badExec=0}
  internal=true
  for i=0,SIZE-1 do emu.write(LO+i,0xEA,mem) end -- install image (NOP fill)
  emu.write(LO,0x4C,mem); emu.write(LO+1,vl,mem); emu.write(LO+2,vh,mem) -- JMP old IRQ1
  emu.write(IRQV,LO&0xFF,mem); emu.write(IRQV+1,(LO>>8)&0xFF,mem)
  internal=false
  emu.log(string.format("SUB ACTIVE START %s: RAM installed, IRQ $%02X%02X -> $%04X -> old",
    key,vh,vl,LO))
end

emu.addMemoryCallback(function(address)
  if active and not internal then active.badWrite=active.badWrite+1; restore("unexpected game write",true) end
end,emu.callbackType.write,LO,HI,emu.cpuType.pce,cpu)
emu.addMemoryCallback(function(address)
  if active then
    if address==LO then active.irqHits=active.irqHits+1
    else active.badExec=active.badExec+1; restore(string.format("unexpected exec $%04X",address),true) end
  end
end,emu.callbackType.exec,LO,HI,emu.cpuType.pce,cpu)
emu.addEventCallback(function()
  frame=frame+1
  local ok,s=pcall(emu.getState); if not ok or not s then return end
  local playing=s["cdrom.adpcm.playing"]==true
  if playing and not wasPlaying then local key=stateKey(s); if key and textByKey[key] then install(key,textByKey[key]) end
  elseif not playing and wasPlaying then restore("normal playback end",false) end
  wasPlaying=playing
  if active then drawText(active.text) end
end,emu.eventType.endFrame)
emu.addEventCallback(function() restore("script stopped",true); file:close() end,emu.eventType.scriptEnded)

emu.log("POC_SUBTITLE_ACTIVE 0.1.0 loaded")
emu.log("  registered ADPCM only; active RAM overwrite + real IRQ chain + timed display")
emu.log("  any unexpected access triggers immediate restore")
