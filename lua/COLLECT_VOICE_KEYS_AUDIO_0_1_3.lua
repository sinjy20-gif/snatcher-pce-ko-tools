-- ADPCM/CD-DA voice collection only.  No text, UI, subtitle or VRAM writes.
-- ADPCM: logs sector + (readAddress + length) end + rate, then dumps the RAM span.
--
-- 0.1.3 -- 긴 음성이 8.2 초에서 잘리던 것을 고친다 (2026-09-01)
-- ---------------------------------------------------------------------------
-- 0.1.2 는 재생이 **시작되는 순간** RAM 을 한 번 떴다.  그런데 ADPCM RAM 은
-- 64 KB 뿐이고 게임은 재생하면서 계속 채워 넣는다(스트리밍).  그래서 한 판
-- 분량인 8.19 초까지만 담기고 나머지는 통째로 빠졌다.
--
--     실측: 클립 990 개 중 120 개가 모자랐다 (합계 11.8 분).
--           잘린 것은 전부 정확히 8.18~8.19 초 = 64 KB 한 판.
--           그중 대사 12 건 -- 해리의 무기 설명, 메탈기어의 분석 보고 같은 긴 대사.
--     소리만 잘린 게 아니라 그 소리로 뜬 **일본어 전사도 앞 8 초치뿐**이었다.
--
-- 이 판은 재생 내내 writeAddress 를 따라가며 **새로 채워진 만큼 이어붙인다.**
-- 16 kHz 면 프레임당 약 133 B 라 비용이 없다.
--
-- ★ 파일 이름은 안 바뀐다.  이름은 내용 지문이 아니라 **키**(sector+끝주소+rate)라
--   더 떠도 같은 이름이다.  짧은 클립은 0.1.2 와 바이트가 같아 `existing_key` 로
--   지나간다 -- 이미 모은 것이 "처음 보는 것" 이 되지 않는다.
--   (0.1.2 의 `expanded_key` 경로가 원래 이 성장을 상정하고 있었다)

local MEM=emu.memType.pceMemory
local ADPCM=emu.memType.pceAdpcmRam
local OUT="C:/snatcher/snatcher_tool/logs/voice_key_events_raw_v012.tsv"
local CLIPS="C:/snatcher/snatcher_tool/logs/voice_clips_v012_fresh/"
local RAM_SIZE=0x10000
local CDDA_GRACE=12
local session=(os and os.date) and os.date("%Y%m%d_%H%M%S") or "session"
local seq,wasPlaying,active=0,false,nil
-- 0.1.3 스트리밍 누적: acc=조각들 · accCursor=다음에 읽을 자리 · accLost=놓친 바이트
local acc,accCursor,accBytes,accLost=nil,0,0,0
local cdda,cddaPrev,cddaLast=nil,nil,nil
local occurrences={}

local HEADER="event_type\tevent_id\tsequence\tframe\taudio_type\tkey_text\tkey_hex\tread_address\twrite_address\tend_address\taudio_length\tplayback_rate\tsector\tclip_file\tduration_frames\toccurrence\tstatus\n"

local function number(s,key)
  local v=s[key]; return type(v)=="number" and math.floor(v) or 0
end
local function ensureHeader()
  local f=io.open(OUT,"rb"); local empty=f==nil
  if f then empty=(f:seek("end") or 0)==0; f:close() end
  if not empty then return true end
  f=io.open(OUT,"ab"); if not f then emu.log("VOICE ERROR opening "..OUT); return false end
  f:write(HEADER); f:close(); return true
end
local function splitTsv(line)
  local cols={}; for cell in (line.."\t"):gmatch("(.-)\t") do cols[#cols+1]=cell end
  return cols
end
local function loadCurrentOccurrences()
  local f=io.open(OUT,"rb"); if not f then return 0 end
  local loaded=0
  f:read("*l")
  for line in f:lines() do
    local cols=splitTsv(line)
    if cols[1]=="START" and cols[6] and cols[6]~="" then
      occurrences[cols[6]]=(occurrences[cols[6]] or 0)+1
      loaded=loaded+1
    end
  end
  f:close()
  return loaded
end
local function loadOccurrences()
  local current=loadCurrentOccurrences()
  emu.log(string.format("  current fresh-log occurrences: %d",current))
end
local function append(kind,item,frame,status)
  local f=io.open(OUT,"ab"); if not f then emu.log("VOICE ERROR appending "..OUT); return end
  f:write(string.format("%s\t%s\t%d\t%d\t%s\t%s\t%s\t%04X\t%04X\t%04X\t%04X\t%02X\t%06X\t%s\t%d\t%d\t%s\n",
    kind,item.id,item.sequence,frame,item.audioType,item.keyText,item.keyHex,
    item.readAddress or 0,item.writeAddress or 0,item.endAddress or 0,item.length or 0,item.rate or 0,
    item.sector or 0,item.clip or "",math.max(0,frame-(item.startFrame or frame)),
    item.occurrence or 1,status or "ok"))
  f:flush(); f:close()
end

-- A new run gets a clean folder; repeated clips within that run still deduplicate.
local function fingerprint(data)
  local h=2166136261
  local step=math.max(1,math.floor(#data/512))
  for i=1,#data,step do h=(h ~ data:byte(i))*16777619%4294967296 end
  return h
end
local function readClipData(readAddress,length)
  local blocks,chunk={},{}
  for i=0,length-1 do
    chunk[#chunk+1]=string.char(emu.read((readAddress+i)%RAM_SIZE,ADPCM) or 0)
    if #chunk>=4096 then blocks[#blocks+1]=table.concat(chunk); chunk={} end
  end
  if #chunk>0 then blocks[#blocks+1]=table.concat(chunk) end
  return table.concat(blocks)
end
local function readFile(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local data=f:read("*a"); f:close(); return data
end
local function writeFile(path,data)
  local f=io.open(path,"wb"); if not f then return false end
  f:write(data); f:close(); return true
end
local function endsWith(longer,shorter)
  return #shorter<=#longer and longer:sub(#longer-#shorter+1)==shorter
end
local function dumpClipData(keyText,data)
  if ADPCM==nil or data==nil or #data<=0 then return "", "no_adpcm_ram" end
  -- One stable file per native 6-byte key.  Timing can move readAddress a few
  -- bytes; suffix-compatible captures are the same stream, so retain the
  -- longest head instead of creating another content-hash file.
  local stem="k"..keyText:sub(7)
  local name=stem..".bin"
  local path=CLIPS..name
  local old=readFile(path)
  if old then
    if old==data then return name,"existing_key" end
    if #data>#old and endsWith(data,old) then
      if not writeFile(path,data) then return "","dump_failed" end
      return name,"expanded_key"
    end
    if #old>#data and endsWith(old,data) then return name,"existing_key_tail" end
    -- Same selector but genuinely different bytes: preserve both and flag it.
    local variant=string.format("%s_v%08X.bin",stem,fingerprint(data))
    local variantPath=CLIPS..variant
    local previous=readFile(variantPath)
    if previous==data then return variant,"key_collision_existing" end
    if not writeFile(variantPath,data) then return "","dump_failed" end
    return variant,"key_collision_saved"
  end
  if not writeFile(path,data) then return "","dump_failed" end
  return name,"saved_key"
end
local function adpcmKey(sector,endAddress,rate)
  local text=string.format("ADPCM_%06X_%04X_%02X",sector,endAddress,rate)
  local hex=string.format("%02X %02X %02X %02X %02X %02X",
    sector&0xFF,(sector>>8)&0xFF,(sector>>16)&0xFF,
    endAddress&0xFF,(endAddress>>8)&0xFF,rate&0xFF)
  return text,hex
end

local function startAdpcm(s,frame)
  seq=seq+1
  local sector=number(s,"cdrom.scsi.sector")
  local writeAddress=number(s,"cdrom.adpcm.writeAddress")
  local readAddress=number(s,"cdrom.adpcm.readAddress")
  local length=number(s,"cdrom.adpcm.adpcmLength")
  local endAddress=(readAddress+length)%RAM_SIZE
  local rate=number(s,"cdrom.adpcm.playbackRate")
  local keyText,keyHex=adpcmKey(sector,endAddress,rate)
  occurrences[keyText]=(occurrences[keyText] or 0)+1
  -- 0.1.3: 여기서 뜨지 않는다.  이름만 미리 정하고 재생이 끝날 때 쓴다.
  --   이름은 키에서 나오므로 START 시점에 이미 알 수 있다.
  local clip="k"..keyText:sub(7)..".bin"
  local dumpStatus="collecting"
  acc={readClipData(readAddress,length)}
  accBytes=#acc[1]
  accCursor=(readAddress+length)%RAM_SIZE
  accLost=0
  active={id=string.format("%s_%04d",session,seq),sequence=seq,audioType="ADPCM",
    keyText=keyText,keyHex=keyHex,readAddress=readAddress,writeAddress=writeAddress,
    endAddress=endAddress,length=length,rate=rate,sector=sector,clip=clip,startFrame=frame,
    occurrence=occurrences[keyText],dumpStatus=dumpStatus}
  append("START",active,frame,dumpStatus)
  emu.log(string.format("VOICE START[%d] %s key=%s clip=%s (%s)",seq,active.id,keyText,clip,dumpStatus))
end
-- 재생 중에 새로 채워진 만큼 이어붙인다.  writeAddress 가 링버퍼를 도는 값이라
-- 차이를 모듈로로 잰다.  차이가 링의 절반을 넘으면 한 바퀴 돌아 덮인 것이므로
-- 그만큼은 잃은 것으로 세고 커서를 현재로 당긴다 (조용히 틀린 데이터를 붙이지 않는다).
local function adpcmTick(s)
  if not active or acc==nil then return end
  local w=number(s,"cdrom.adpcm.writeAddress")
  local n=(w-accCursor)%RAM_SIZE
  if n==0 then return end
  if n>RAM_SIZE//2 then
    accLost=accLost+n
    accCursor=w
    return
  end
  acc[#acc+1]=readClipData(accCursor,n)
  accBytes=accBytes+n
  accCursor=w
end

local function endAdpcm(frame,status)
  if not active then return end
  -- 마지막으로 한 번 더 훑고 파일을 쓴다
  local expected=active.clip
  local data=acc and table.concat(acc) or ""
  local clip,dumpStatus=dumpClipData(active.keyText,data)
  active.clip=clip~="" and clip or expected
  active.dumpStatus=dumpStatus
  if clip~="" and clip~=expected then
    emu.log(string.format("VOICE ★ 이름이 갈렸다 %s -> %s (키 충돌)",expected,clip))
  end
  if accLost>0 then
    emu.log(string.format("VOICE ★ 놓친 바이트 %d -- 링버퍼가 덮였다 (프레임당 폴링이 늦었다)",accLost))
  end
  emu.log(string.format("VOICE DUMP key=%s %d B (%.2f초) %s",
    active.keyText,accBytes,accBytes*2/16000,dumpStatus))
  acc,accCursor,accBytes,accLost=nil,0,0,0
  append("END",active,frame,status or "complete")
  emu.log(string.format("VOICE END[%d] key=%s duration=%.3fs",active.sequence,active.keyText,(frame-active.startFrame)/60))
  active=nil
end

local function cddaKey(sector) return string.format("CDDA_%06X",sector) end
local function cddaTick(s,frame)
  local sector=s["cdrom.audioPlayer.currentSector"]
  local function finish(status)
    if not cdda then return end
    append("END",cdda,frame,status or "complete")
    emu.log(string.format("CDDA END[%d] %06X-%06X duration=%.3fs",cdda.sequence,cdda.sector,cdda.lastSector,(frame-cdda.startFrame)/60))
    cdda=nil; cddaLast=nil
  end
  if type(sector)~="number" then
    cddaPrev=nil
    if cdda and cddaLast and frame-cddaLast>=CDDA_GRACE then finish("complete") end
    return
  end
  sector=math.floor(sector)
  if cddaPrev==nil then cddaPrev=sector; return end
  if sector~=cddaPrev then
    if not cdda then
      seq=seq+1; local key=cddaKey(sector); occurrences[key]=(occurrences[key] or 0)+1
      cdda={id=string.format("%s_%04d",session,seq),sequence=seq,audioType="CDDA",
        keyText=key,keyHex="",readAddress=sector&0xFFFF,writeAddress=(sector>>16)&0xFFFF,
        length=0,rate=0,sector=sector,clip="",startFrame=frame,lastSector=sector,
        occurrence=occurrences[key]}
      append("START",cdda,frame,"range_only")
      emu.log(string.format("CDDA START[%d] sector=%06X",seq,sector))
    else cdda.lastSector=sector end
    cddaLast=frame
  elseif cdda and cddaLast and frame-cddaLast>=CDDA_GRACE then finish("complete") end
  cddaPrev=sector
end

assert(ensureHeader(),"cannot create voice collection log")
loadOccurrences()
emu.addEventCallback(function()
  local s=emu.getState() or {}; local frame=number(s,"frameCount")
  local playing=s["cdrom.adpcm.playing"]==true
  if playing and not wasPlaying then startAdpcm(s,frame)
  elseif playing and wasPlaying then adpcmTick(s)
  elseif not playing and wasPlaying then adpcmTick(s); endAdpcm(frame,"complete") end
  wasPlaying=playing
  cddaTick(s,frame)
end,emu.eventType.endFrame)
emu.addEventCallback(function()
  local s=emu.getState() or {}; local frame=number(s,"frameCount")
  if active then endAdpcm(frame,"script_stopped") end
  if cdda then append("END",cdda,frame,"script_stopped") end
end,emu.eventType.scriptEnded)

emu.log("COLLECT_VOICE_KEYS_AUDIO 0.1.3 loaded -- 음성 전용 · 스트리밍 누적")
emu.log("  ADPCM 키 고정 이름 · 재생 내내 이어붙임(8.2초 잘림 해결) · 충돌 보존 · CDDA 섹터 범위")
emu.log("  text/UI/subtitle/VRAM writes 0 B")
emu.log("  events: "..OUT)
emu.log("  clips : "..CLIPS)
