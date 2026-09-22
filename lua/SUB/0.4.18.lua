-- SUB 0.4.18 -- read-only $180D / subtitle-state / $20F5 timeline
--
-- 0.4.14(pass)와 0.4.17(fail)의 실제 차이는 bulk 작업이 아니라 resident active
-- 상태에서 BIOS $FEF7가 매 프레임 LDA $180D를 실행하는지 여부다. 이 프로브는
-- 정상 0.4.6.10 코드를 한 바이트도 고치지 않고 그 순서만 기록한다.
--
-- 사용: 모든 다른 SUB Lua를 Stop -> 앞 세이브 -> 이 Lua 하나만 실행.
-- 출력: C:\snatcher\dump\probe_subtitle_180D_timeline_0418.tsv

local OUT = 'C:/snatcher/dump/probe_subtitle_180D_timeline_0418.tsv'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local RING_MAX = 4096

local frame = 0
local seq = 0
local ring = {}
local dumped = false
local waitFrame = -1
local waitCount = 0
local e6b6Frame = -1
local lastPlaying = false

local function byte(a) return emu.read(a & 0xFFFF, MEM) or 0 end

local function number(s, k)
  local v = s[k]
  return type(v) == 'number' and v or 0
end

local function add(tag, address, value)
  local ok, s = pcall(emu.getState)
  s = ok and s or {}
  local read = number(s, 'cdrom.adpcm.readAddress')
  local len = number(s, 'cdrom.adpcm.adpcmLength')
  seq = seq + 1
  ring[#ring + 1] = {
    seq=seq, frame=frame, tag=tag, address=address or 0,
    pc=number(s,'cpu.pc'), sp=number(s,'cpu.sp'), a=number(s,'cpu.a'),
    x=number(s,'cpu.x'), y=number(s,'cpu.y'), p=number(s,'cpu.p'),
    value=type(value)=='number' and (value & 0xFF) or 0x100,
    sub=byte(0x7FDF), f4=byte(0x20F4), f5=byte(0x20F5), f6=byte(0x20F6),
    mask=byte(0x1802), irq=byte(0x1803),
    playing=s['cdrom.adpcm.playing']==true and 1 or 0,
    sector=number(s,'cdrom.scsi.sector'), finish=(read+len)&0xFFFF,
    rate=number(s,'cdrom.adpcm.playbackRate'),
  }
  if #ring > RING_MAX then table.remove(ring, 1) end
end

local function dump(reason)
  if dumped then return end
  dumped = true
  local f = io.open(OUT, 'w')
  if not f then emu.log('SUB 0.4.18 cannot open '..OUT); return end
  f:write('# SUB 0.4.18 read-only timeline\n')
  f:write('# reason='..reason..' frame='..frame..' events='..#ring..'\n')
  f:write('seq\tframe\ttag\taddress\tpc\tsp\ta\tx\ty\tp\tvalue\tsub_state\t20F4\t20F5\t20F6\tirq_mask\tirq_status\tadpcm_playing\tsector\tfinish\trate\n')
  for _,e in ipairs(ring) do
    local value=e.value==0x100 and '--' or string.format('$%02X',e.value)
    f:write(string.format('%d\t%d\t%s\t$%04X\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t%s\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t%d\t$%06X\t$%04X\t$%02X\n',
      e.seq,e.frame,e.tag,e.address,e.pc,e.sp,e.a,e.x,e.y,e.p,value,
      e.sub,e.f4,e.f5,e.f6,e.mask,e.irq,e.playing,e.sector,e.finish,e.rate))
  end
  f:close()
  emu.log('SUB 0.4.18 ★ timeline dump -> '..OUT..' ('..reason..')')
end

local points = {
  {0x7F49,'CONTROLLER_ENTER'}, {0x7F85,'CONTROLLER_RETURN'},
  {0xFEC4,'CAVE_ENTER'}, {0xFEE7,'STATUS_START_EXEC'},
  {0xFEF7,'STATUS_ACTIVE_EXEC'}, {0x5B83,'ENGINE_ENTRY'},
}
for _,p in ipairs(points) do
  emu.addMemoryCallback(function() add(p[2],p[1]) end,
    emu.callbackType.exec,p[1],p[1],CPU,MEM)
end

-- 실제 $180D read value와 호출 PC를 기록한다. 다른 VDC/AC/RAM은 감시하지 않는다.
emu.addMemoryCallback(function(address,value) add('STATUS_180D_READ',address,value) end,
  emu.callbackType.read,0x180D,0x180D,CPU,MEM)
emu.addMemoryCallback(function(address,value) add('SUB_STATE_WRITE',address,value) end,
  emu.callbackType.write,0x7FDF,0x7FDF,CPU,MEM)
emu.addMemoryCallback(function(address,value) add('20F5_WRITE',address,value) end,
  emu.callbackType.write,0x20F5,0x20F5,CPU,MEM)

-- $E6B6의 폭주 read는 프레임당 하나만, $E736은 앞 4개와 256번째만 남긴다.
emu.addMemoryCallback(function()
  if e6b6Frame ~= frame then e6b6Frame=frame; add('20F5_READ_E6B6',0x20F5) end
end,emu.callbackType.exec,0xE6B6,0xE6B6,CPU,MEM)
emu.addMemoryCallback(function()
  if waitFrame ~= frame then waitFrame,waitCount=frame,0 end
  waitCount=waitCount+1
  if waitCount<=4 or waitCount==256 then add('IRQ_WAIT_E736',0xE736,waitCount&0xFF) end
  if waitCount==256 then dump('E736 x256 in one frame') end
end,emu.callbackType.exec,0xE736,0xE736,CPU,MEM)

emu.addEventCallback(function()
  frame=frame+1
  local ok,s=pcall(emu.getState); s=ok and s or {}
  local playing=s['cdrom.adpcm.playing']==true
  if playing~=lastPlaying then add(playing and 'VOICE_START' or 'VOICE_END',0) end
  lastPlaying=playing
  local okKey,down=pcall(function() return emu.isKeyPressed('E') end)
  if okKey and down then dump('manual E') end
end,emu.eventType.endFrame)

emu.addEventCallback(function() if not dumped then dump('script stopped') end end,
  emu.eventType.scriptEnded)

emu.log('SUB 0.4.18 loaded -- READ ONLY $180D/state/$20F5 timeline')
emu.log('  다른 SUB Lua 없이 정상 실패판을 재현할 것')
