-- LOAD_SUBTITLE_NATIVE 0.8.1 -- 정상 0.7 종료 순서를 보존한 native trigger 검증판
-- BIOS는 AC 명령함만 쓰고, helper/renderer 실행은 다음 게임 $601E에 맡긴다.

local MEM,AC,VRAM,CPU=emu.memType.pceMemory,emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam,emu.memType.cpu
local PACK_AT,AC_HELPER,AC_RENDERER=0x1C0000,0x1F1C00,0x1F1F00
local RESIDENT,HOOK,MAILBOX_AC=0x7F49,0x601E,0x1F03F0
local ENGINE,AC_BACKUP=0x5B80,0x1F0400
local VRAM_AT,VRAM_BYTES,SATB_AT=0x7900*2,2432,0x1000*2
local TAIL_LO,TAIL_HI=0x5E20,0x5E3F
local KEY={0x78,0x30,0x00,0x00,0x68,0x0E}

local PACK_PATH='C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local RES_PATH='C:/snatcher/build/cutscene_subs/resident_controller_native_0_8_1.bin'
local H_PATH='C:/snatcher/build/cutscene_subs/resident_helper_slot_native_0_8_1.bin'
local R_PATH='C:/snatcher/build/cutscene_subs/resident_renderer_slot_native_0_8_1.bin'
local H_STATUS=174
local E_READY,E_COUNT,E_SELECTOR,E_ELAPSED,E_RECORD=364,365,366,455,461

local function slurp(path)
  local f=assert(io.open(path,'rb'),'cannot open '..path)
  local d=f:read('*a'); f:close(); local t={}
  for i=1,#d do t[i]=d:byte(i) end
  return t
end
local pack,resident,helper,renderer=slurp(PACK_PATH),slurp(RES_PATH),slurp(H_PATH),slurp(R_PATH)
assert(#resident==150 and #helper==320 and #renderer==671,'0.8.1 payload size mismatch')

assert(emu.read(0xF61A,MEM)==0x20 and emu.read(0xF61B,MEM)==0xC4 and emu.read(0xF61C,MEM)==0xFE,
       '0.8.1 BIOS가 아니다: Syscard3_galmuri_sub_native_0_8_1.pce로 전원 재시작할 것')
assert(emu.read(0xF6EF,MEM)==0x20 and emu.read(0xF6F0,MEM)==0xE7 and emu.read(0xF6F1,MEM)==0xFE,
       '0.8.1 BIOS AD_STAT 훅이 아니다')

for i=1,#pack do emu.write(PACK_AT+i-1,pack[i],AC) end
for i=1,#helper do emu.write(AC_HELPER+i-1,helper[i],AC) end
for i=1,#renderer do emu.write(AC_RENDERER+i-1,renderer[i],AC) end
for i=1,6 do emu.write(AC_RENDERER+E_SELECTOR+i-1,KEY[i],AC) end
emu.write(MAILBOX_AC,0,AC)

local function p8(o) return pack[o+1] end
local function p16(o) return p8(o)|(p8(o+1)<<8) end
local function p32(o) return p16(o)|(p16(o+2)<<16) end
local P={count=p16(14),index=p32(16),records=p32(26),chars=p32(38),stride=p8(42),cell=p8(35)}
local expected={}
for i=0,P.count-1 do
  local at,same=P.index+i*P.stride,true
  for k=0,5 do if p8(at+k)~=KEY[k+1] then same=false; break end end
  if same then expected[#expected+1]={frame=p16(at+7),rec=p32(at+9)} end
end
assert(#expected==2 and expected[2].frame==120,'target pack entries changed')

local function text_at(rec)
  local at,out=P.records+rec,''
  for i=0,p8(at)-1 do
    local cell=at+6+i*P.cell
    out=out..utf8.char(p16(P.chars+p16(cell)*2))
  end
  return out
end
local function loaded_text()
  local n,out=emu.read(ENGINE+E_COUNT,MEM) or 0,''
  if n>19 then return '<invalid count '..n..'>' end
  for i=0,n-1 do
    local at=ENGINE+E_RECORD+6+i*4
    local id=(emu.read(at,MEM) or 0)|((emu.read(at+1,MEM) or 0)<<8)
    out=out..utf8.char(p16(P.chars+id*2))
  end
  return out
end
local function ours()
  local n=0
  for e=0,63 do
    local at=SATB_AT+e*8+4
    local p=(emu.read(at,VRAM) or 0)|((emu.read(at+1,VRAM) or 0)<<8)
    if p>=0x03C4 and p<=0x03E9 then n=n+1 end
  end
  return n
end

local installed=false
local function controller_present()
  if not(emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0x49 and emu.read(HOOK+2,MEM)==0x7F) then return false end
  for i=1,#resident do if emu.read(RESIDENT+i-1,MEM)~=resident[i] then return false end end
  return true
end
local function install_when_ready()
  if controller_present() then installed=true; return true end
  installed=false
  local old=emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0xA0 and
            emu.read(HOOK+2,MEM)==0x7F and emu.read(0x7FA0,MEM)==0x08
  if not old then return false end
  local outside=0
  for a=0x7F49,0x7FDF do
    if not(a>=0x7FA0 and a<=0x7FBF) and (emu.read(a,MEM) or 0)~=0xFF then outside=outside+1 end
  end
  if outside~=0 then emu.log('★ resident 설치 중지: 151 B 불일치 '..outside); return false end
  for i=1,#resident do emu.write(RESIDENT+i-1,resident[i],MEM) end
  emu.write(RESIDENT+#resident,0xFF,MEM)
  emu.write(HOOK,0x20,MEM); emu.write(HOOK+1,0x49,MEM); emu.write(HOOK+2,0x7F,MEM); emu.write(HOOK+3,0xEA,MEM)
  installed=true
  emu.log('★ 오버레이 A 감지 · native ordered resident 150 B 설치')
  return true
end

local frame=0
local active,endSeen,restoreSeen=false,false,false
local checkStart,inspect1,inspect2=0,0,0
local basePat,baseTail=nil,nil
local function snapshot()
  basePat={}; for i=0,VRAM_BYTES-1 do basePat[i]=emu.read(VRAM_AT+i,VRAM) or 0 end
  baseTail={}; for a=TAIL_LO,TAIL_HI do baseTail[a]=emu.read(a,MEM) or 0 end
end
local function diffPat()
  local n=0; for i=0,VRAM_BYTES-1 do if (emu.read(VRAM_AT+i,VRAM) or 0)~=basePat[i] then n=n+1 end end; return n
end
local function diffTail()
  local n=0; for a=TAIL_LO,TAIL_HI do if (emu.read(a,MEM) or 0)~=baseTail[a] then n=n+1 end end; return n
end
local function inspect(part)
  local actual,wanted=loaded_text(),text_at(expected[part].rec)
  local ready=emu.read(ENGINE+E_READY,MEM) or 0
  local elapsed=emu.read(ENGINE+E_ELAPSED,MEM) or 0
  emu.log(string.format('  자체검사 %d/2 · elapsed=%d · ready=%d · "%s"',part,elapsed,ready,actual))
  if ready==1 and actual==wanted then emu.log('  ★ NATIVE ORDERED TIMED PASS') end
end

emu.addMemoryCallback(function()
  if not installed or active then return end
  if (emu.read(0x22A6,MEM) or 0)==0 and (emu.read(0x22A7,MEM) or 0)==0x68 and
     (emu.read(0x22AA,MEM) or 0)==0x0E then
    snapshot(); active=true; endSeen=false; restoreSeen=false
    checkStart,inspect1,inspect2=frame+1,frame+8,frame+128
    emu.log(string.format('[%d] BIOS AD_PLAY · AC 명령 1만 기록',frame))
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addMemoryCallback(function()
  if active and not endSeen and (emu.read(MAILBOX_AC,AC) or 0)==2 then
    endSeen=true
    emu.log(string.format('[%d] BIOS AD_STAT · AC 명령 3만 기록 · resident 직접 호출 0',frame))
  end
end,emu.callbackType.exec,0xF6EF,0xF6EF,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1; install_when_ready()
  local state=emu.read(MAILBOX_AC,AC) or 255
  if active and checkStart>0 and frame>=checkStart then
    if state==2 then
      checkStart=0
      emu.log(string.format('  ★ NATIVE ORDERED START PASS · state=2 · magic=%02X %02X %02X',
        emu.read(ENGINE,MEM) or 0,emu.read(ENGINE+1,MEM) or 0,emu.read(ENGINE+2,MEM) or 0))
    elseif frame>checkStart+4 then emu.log('  ★ START FAIL · state='..state); checkStart=0 end
  end
  if active and inspect1>0 and frame>=inspect1 then inspect1=0; inspect(1) end
  if active and inspect2>0 and frame>=inspect2 then inspect2=0; inspect(2) end
  if active and endSeen and not restoreSeen and state==0 and (emu.read(ENGINE+H_STATUS,MEM) or 0)==2 then
    restoreSeen=true
    emu.log(string.format('  restore helper 완료 · 패턴 diff=%d/2432 · ours=%d · tail=%d/32',diffPat(),ours(),diffTail()))
  elseif active and restoreSeen and ours()==0 then
    local pat,tail=diffPat(),diffTail()
    emu.log(string.format('  게임 SATB 재생성 · ours=0 · 패턴 diff=%d/2432 · tail=%d/32',pat,tail))
    if pat==0 and tail==0 then emu.log('  ★ NATIVE 0.8.1 PASS: 0.7 종료 순서와 UI 복귀 경로 일치') end
    active,endSeen,restoreSeen,basePat,baseTail=false,false,false,nil,nil
  end
end,emu.eventType.startFrame)

emu.log('LOAD_SUBTITLE_NATIVE 0.8.1 loaded')
emu.log(string.format('  pack %d B · helper 303/320 B · renderer %d B · resident %d B',#pack,#renderer,#resident))
emu.log('  BIOS는 AC 명령만 기록 · resident 직접 호출/CPU/SATB 강제 복원 없음')
