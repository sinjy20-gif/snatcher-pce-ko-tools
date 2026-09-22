-- VERIFY_SUBTITLE_NATIVE_POLL 0.8.4 -- 완전 읽기 전용
-- 디스크 resident와 Track24 -> AC preload, 자동 자막/복귀만 검증한다.

local MEM,AC,VRAM,CPU=emu.memType.pceMemory,emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam,emu.memType.cpu
local RESIDENT,HOOK,STATE,ENGINE=0x7F49,0x601E,0x7FDF,0x5B80
local PACK_AT,HELPER_AT,RENDERER_AT=0x1C0000,0x1F1C00,0x1F1F00
local H_STATUS=174

local function slurp(path)
  local f=assert(io.open(path,'rb'),'cannot open '..path); local d=f:read('*a'); f:close(); return d
end
local expected={
  {name='pack',at=PACK_AT,data=slurp('C:/snatcher/build/cutscene_subs/subtitle_pack.bin')},
  {name='helper',at=HELPER_AT,data=slurp('C:/snatcher/build/cutscene_subs/resident_helper_slot_native_poll_0_8_3.bin')},
  {name='renderer',at=RENDERER_AT,data=slurp('C:/snatcher/build/cutscene_subs/resident_renderer_slot_native_poll_0_8_4_r3.bin')},
}

-- BIOS ADPCM 경로는 원본이고, cave는 state FF preload 판정으로 시작한다.
assert(emu.read(0xF61A,MEM)==0x8D and emu.read(0xF61B,MEM)==0x0D and emu.read(0xF61C,MEM)==0x18,
       '0.8.4 BIOS AD_PLAY가 원본이 아니다')
assert(emu.read(0xF6EF,MEM)==0xAD and emu.read(0xF6F0,MEM)==0x0C and emu.read(0xF6F1,MEM)==0x18,
       '0.8.4 BIOS AD_STAT이 원본이 아니다')
assert(emu.read(0xFEC4,MEM)==0xAD and emu.read(0xFEC5,MEM)==0xDF and emu.read(0xFEC6,MEM)==0x7F and
       emu.read(0xFEC7,MEM)==0xC9 and emu.read(0xFEC8,MEM)==0xFF,
       '0.8.4 BIOS preload cave 지문 불일치')

local function resident_present()
  return emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0x49 and emu.read(HOOK+2,MEM)==0x7F and
         emu.read(RESIDENT,MEM)==0x08 and emu.read(RESIDENT+6,MEM)==0x20
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
local function compare(row)
  local bad=0
  for i=1,#row.data do if (emu.read(row.at+i-1,AC) or 0)~=row.data:byte(i) then bad=bad+1 end end
  return bad
end
local function ac_hex(at,n)
  local out={}
  for i=0,n-1 do out[#out+1]=string.format('%02X',emu.read(at+i,AC) or 0) end
  return table.concat(out,' ')
end
local function find_ac_magic(bytes)
  for at=0,0x200000-#bytes do
    local ok=true
    for i=1,#bytes do
      if (emu.read(at+i-1,AC) or 0)~=bytes:byte(i) then ok=false; break end
    end
    if ok then return at end
  end
  return nil
end

local frame=0
local residentSeen,preloadChecked,targetSeen,active,restored=false,false,false,false,false
emu.addMemoryCallback(function()
  if residentSeen and (emu.read(0x22A6,MEM) or 0)==0 and
     (emu.read(0x22A7,MEM) or 0)==0x68 and (emu.read(0x22AA,MEM) or 0)==0x0E then
    targetSeen=true; emu.log(string.format('[%d] E6800_0E AD_PLAY 관측 · 검증 Lua 쓰기 0 B',frame))
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1
  if not residentSeen and resident_present() then
    residentSeen=true; emu.log('★ 디스크 resident 151 B 확인 · Lua 쓰기 0 B')
  end
  if not residentSeen then return end
  local state=emu.read(STATE,MEM) or 255
  if (state==0xFE or (state>=0xF1 and state<=0xF3)) and not preloadChecked then
    local where=({[0xF1]='pack',[0xF2]='helper',[0xF3]='renderer'})[state] or 'unknown'
    preloadChecked=true; emu.log(string.format('★ TRACK24 PRELOAD FAIL: %s 적재 중 BIOS load_blob 오류 (state=%02X)',where,state))
  elseif state==0 and not preloadChecked then
    local all=0
    for _,row in ipairs(expected) do
      local bad=compare(row); all=all+bad
      emu.log(string.format('  Track24 -> AC %-8s 불일치 %d/%d B',row.name,bad,#row.data))
    end
    preloadChecked=true
    if all==0 then emu.log('★ TRACK24 NATIVE PRELOAD PASS: pack/helper/renderer byte exact · Lua 쓰기 0 B')
    else
      emu.log('★ TRACK24 NATIVE PRELOAD FAIL: 총 불일치 '..all..' B')
      for _,row in ipairs(expected) do
        emu.log(string.format('  AC $%06X actual  %s',row.at,ac_hex(row.at,16)))
        emu.log(string.format('  AC $%06X expect  %s',row.at,(row.data:sub(1,16):gsub('.',function(c)return string.format('%02X ',c:byte())end))))
      end
      local found=find_ac_magic('SNSB')
      emu.log(found and string.format('  SNSB 실제 위치 AC $%06X',found) or '  SNSB는 AC 2MiB 전체에 없음')
    end
  end
  if targetSeen and preloadChecked and not active and state==2 then
    active=true
    emu.log(string.format('★ NATIVE DISC START PASS · magic=%02X %02X %02X',
      emu.read(ENGINE,MEM) or 0,emu.read(ENGINE+1,MEM) or 0,emu.read(ENGINE+2,MEM) or 0))
  end
  if active and not restored and state==0 and (emu.read(ENGINE+H_STATUS,MEM) or 0)==2 then
    restored=true; emu.log(string.format('NATIVE DISC RESTORE · helper status=2 · ours=%d',ours()))
  elseif restored and ours()==0 then
    emu.log('★ NATIVE DISC 0.8.4 CLEANUP PASS · 게임 SATB ours=0 · 완전 Lua 쓰기 0 B')
    targetSeen,active,restored=false,false,false
  end
end,emu.eventType.startFrame)

emu.log('VERIFY_SUBTITLE_NATIVE_POLL 0.8.4 loaded -- 읽기 전용')
emu.log('  pack/helper/renderer AC 쓰기 0 · CPU 쓰기 0 · 음성 명령 쓰기 0')
