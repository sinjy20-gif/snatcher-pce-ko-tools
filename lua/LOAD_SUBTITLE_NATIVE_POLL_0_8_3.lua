-- LOAD_SUBTITLE_NATIVE_POLL 0.8.3 -- BIOS 훅/AC mailbox 없는 native 판정 POC

local MEM,AC,VRAM,CPU=emu.memType.pceMemory,emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam,emu.memType.cpu
local PACK_AT,AC_HELPER,AC_RENDERER=0x1C0000,0x1F1C00,0x1F1F00
local RESIDENT,HOOK,ENGINE,STATE=0x7F49,0x601E,0x5B80,0x7FDF
local KEY={0x78,0x30,0x00,0x00,0x68,0x0E}
local H_STATUS,E_SELECTOR=174,366

local function slurp(path)
  local f=assert(io.open(path,'rb'),'cannot open '..path); local d=f:read('*a'); f:close(); local t={}
  for i=1,#d do t[i]=d:byte(i) end; return t
end
local pack=slurp('C:/snatcher/build/cutscene_subs/subtitle_pack.bin')
local resident=slurp('C:/snatcher/build/cutscene_subs/resident_controller_native_poll_0_8_3.bin')
local helper=slurp('C:/snatcher/build/cutscene_subs/resident_helper_slot_native_poll_0_8_3.bin')
local renderer=slurp('C:/snatcher/build/cutscene_subs/resident_renderer_slot_native_poll_0_8_3.bin')
assert(#resident==151 and #helper==320 and #renderer==671,'0.8.3 payload size mismatch')

-- ADPCM 훅은 원본 그대로, $FEC4에는 LDA $7FDF로 시작하는 판정 루틴만 있어야 한다.
assert(emu.read(0xF61A,MEM)==0x8D and emu.read(0xF61B,MEM)==0x0D and emu.read(0xF61C,MEM)==0x18,
       '0.8.3 BIOS가 아니다: AD_PLAY가 원본이 아님')
assert(emu.read(0xF6EF,MEM)==0xAD and emu.read(0xF6F0,MEM)==0x0C and emu.read(0xF6F1,MEM)==0x18,
       '0.8.3 BIOS가 아니다: AD_STAT이 원본이 아님')
assert(emu.read(0xFEC4,MEM)==0xAD and emu.read(0xFEC5,MEM)==0xDF and emu.read(0xFEC6,MEM)==0x7F,
       '0.8.3 BIOS poll routine 지문 불일치')

for i=1,#pack do emu.write(PACK_AT+i-1,pack[i],AC) end
for i=1,#helper do emu.write(AC_HELPER+i-1,helper[i],AC) end
for i=1,#renderer do emu.write(AC_RENDERER+i-1,renderer[i],AC) end
for i=1,6 do emu.write(AC_RENDERER+E_SELECTOR+i-1,KEY[i],AC) end

local installed=false
local reportedDiscResident=false
local function present()
  if not(emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0x49 and emu.read(HOOK+2,MEM)==0x7F) then return false end
  for i=1,#resident do if emu.read(RESIDENT+i-1,MEM)~=resident[i] then return false end end
  return true
end
local function install()
  if present() then
    installed=true
    if not reportedDiscResident then
      reportedDiscResident=true
      emu.log('★ 디스크 native poll resident 151 B 확인 · Lua CPU 코드 설치 0 B')
    end
    return true
  end
  local old=emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0xA0 and
            emu.read(HOOK+2,MEM)==0x7F and emu.read(0x7FA0,MEM)==0x08
  if not old then return false end
  local outside=0
  for a=0x7F49,0x7FDF do
    if not(a>=0x7FA0 and a<=0x7FBF) and (emu.read(a,MEM) or 0)~=0xFF then outside=outside+1 end
  end
  if outside~=0 then emu.log('★ 0.8.3 resident 설치 중지: 151 B 불일치 '..outside); return false end
  for i=1,#resident do emu.write(RESIDENT+i-1,resident[i],MEM) end
  emu.write(HOOK,0x20,MEM); emu.write(HOOK+1,0x49,MEM); emu.write(HOOK+2,0x7F,MEM); emu.write(HOOK+3,0xEA,MEM)
  emu.write(STATE,0,MEM); installed=true
  emu.log('★ 오버레이 A 감지 · native poll resident 151 B 설치 · idle AC 접근 0')
  return true
end

local function ours()
  local n=0
  for e=0,63 do
    local at=0x1000*2+e*8+4
    local p=(emu.read(at,VRAM) or 0)|((emu.read(at+1,VRAM) or 0)<<8)
    if p>=0x03C4 and p<=0x03E9 then n=n+1 end
  end
  return n
end

local frame=0
local targetSeen,active,restored=false,false,false
emu.addMemoryCallback(function()
  if not installed then return end
  if (emu.read(0x22A6,MEM) or 0)==0 and (emu.read(0x22A7,MEM) or 0)==0x68 and
     (emu.read(0x22AA,MEM) or 0)==0x0E then
    targetSeen=true
    emu.log(string.format('[%d] E6800_0E AD_PLAY 관측 · Lua 명령 쓰기 0',frame))
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1; install()
  if not installed then return end
  local state=emu.read(STATE,MEM) or 255
  if targetSeen and not active and state==2 then
    active=true
    emu.log(string.format('  ★ NATIVE POLL START PASS · state=2 · magic=%02X %02X %02X',
      emu.read(ENGINE,MEM) or 0,emu.read(ENGINE+1,MEM) or 0,emu.read(ENGINE+2,MEM) or 0))
  end
  if active and not restored and state==0 and (emu.read(ENGINE+H_STATUS,MEM) or 0)==2 then
    restored=true
    emu.log(string.format('  NATIVE POLL RESTORE · helper status=2 · ours=%d',ours()))
  elseif restored and ours()==0 then
    emu.log('  ★ NATIVE POLL 0.8.3 CLEANUP PASS · 게임 SATB ours=0')
    targetSeen,active,restored=false,false,false
  end
end,emu.eventType.startFrame)

emu.log('LOAD_SUBTITLE_NATIVE_POLL 0.8.3 loaded')
emu.log(string.format('  pack %d B · helper 303/320 B · renderer %d B · resident %d B',#pack,#renderer,#resident))
emu.log('  BIOS AD_PLAY/AD_STAT 훅 0 · AC mailbox 0 · idle AC 포트 접근 0')
