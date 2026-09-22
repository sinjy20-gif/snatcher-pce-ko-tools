-- LOAD_SUBTITLE_NATIVE 0.8.0-r4
-- 초기 적재 전용 + 읽기 전용 검증. 음성 시작/종료 명령은 0.8 BIOS가 쓴다.

local MEM,AC,VRAM,CPU=emu.memType.pceMemory,emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam,emu.memType.cpu
local PACK_AT,AC_HELPER,AC_RENDERER=0x1C0000,0x1F1C00,0x1F1F00
local RESIDENT,HOOK,STATE=0x7F49,0x601E,0x1A10
local MAILBOX_AC=0x1F03F0
local ENGINE,AC_BACKUP=0x5B80,0x1F0400
local CPU_CACHE_BYTES,CPU_CACHE_AC=671,0x1F0E00
local VRAM_AT,VRAM_BYTES=0x7900*2,2432
local SATB_AT,SATB_BYTES,SATB_AC=0x1000*2,512,0x1F1100
local TAIL_LO,TAIL_HI=0x5E20,0x5E3F
local KEY={0x78,0x30,0x00,0x00,0x68,0x0E}

local PACK_PATH='C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local RES_PATH='C:/snatcher/build/cutscene_subs/resident_controller_0_7.bin'
local H_PATH='C:/snatcher/build/cutscene_subs/resident_helper_slot_0_7.bin'
local R_PATH='C:/snatcher/build/cutscene_subs/resident_renderer_slot_0_7.bin'
local H_STATUS=302
local E_READY,E_COUNT,E_SELECTOR,E_ELAPSED,E_RECORD=364,365,366,455,461

local function slurp(path)
  local f=assert(io.open(path,'rb'),'cannot open '..path)
  local d=f:read('*a'); f:close(); local t={}
  for i=1,#d do t[i]=d:byte(i) end
  return t
end
local pack,resident,helper,renderer=slurp(PACK_PATH),slurp(RES_PATH),slurp(H_PATH),slurp(R_PATH)
assert(#resident<=151 and #helper==512 and #renderer==671,'0.8 payload size mismatch')

-- 새 BIOS가 실제로 매핑됐는지 먼저 확인한다.
assert(emu.read(0xF61A,MEM)==0x20 and emu.read(0xF61B,MEM)==0xC4 and emu.read(0xF61C,MEM)==0xFE,
       '0.8-r3 BIOS가 아니다: Syscard3_galmuri_sub_native_0_8_r3.pce를 선택하고 재시작할 것')
assert(emu.read(0xF6EF,MEM)==0x20 and emu.read(0xF6F0,MEM)==0xF9 and emu.read(0xF6F1,MEM)==0xFE,
       string.format('0.8-r3 BIOS AD_STAT 훅이 아니다: 현재 %02X %02X %02X / 기대 20 F9 FE',
         emu.read(0xF6EF,MEM) or 0,emu.read(0xF6F0,MEM) or 0,emu.read(0xF6F1,MEM) or 0))

-- 이 아래가 Lua의 유일한 데이터 쓰기 단계다.
for i=1,#pack do emu.write(PACK_AT+i-1,pack[i],AC) end
for i=1,#helper do emu.write(AC_HELPER+i-1,helper[i],AC) end
for i=1,#renderer do emu.write(AC_RENDERER+i-1,renderer[i],AC) end
for i=1,6 do emu.write(AC_RENDERER+E_SELECTOR+i-1,KEY[i],AC) end
emu.write(MAILBOX_AC,0,AC)

local function p8(o) return pack[o+1] end
local function p16(o) return p8(o)|(p8(o+1)<<8) end
local function p32(o) return p16(o)|(p16(o+2)<<16) end
local function p16safe(o)
  local lo,hi=p8(o),p8(o+1); if lo==nil or hi==nil then return nil end
  return lo|(hi<<8)
end
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
    local cp=p16safe(P.chars+id*2); if cp==nil then return '<invalid glyph>' end
    out=out..utf8.char(cp)
  end
  return out
end

local installed=false
local function controller_present()
  if not (emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==(RESIDENT&0xFF) and
          emu.read(HOOK+2,MEM)==(RESIDENT>>8)) then return false end
  for i=1,#resident do if emu.read(RESIDENT+i-1,MEM)~=resident[i] then return false end end
  return true
end
local function old_present()
  return emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0xA0 and
         emu.read(HOOK+2,MEM)==0x7F and emu.read(0x7FA0,MEM)==0x08
end
local function poc_hook_present()
  return emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==(RESIDENT&0xFF) and
         emu.read(HOOK+2,MEM)==(RESIDENT>>8)
end
local function install_when_ready()
  if controller_present() then installed=true; return true end
  installed=false
  if not old_present() and not poc_hook_present() then return false end
  if old_present() then
    local outside=0
    for a=0x7F49,0x7FDF do
      if not(a>=0x7FA0 and a<=0x7FBF) and (emu.read(a,MEM) or 0)~=0xFF then outside=outside+1 end
    end
    if outside~=0 then emu.log('★ resident 설치 중지: 151 B 불일치 '..outside); return false end
  end
  for i=1,#resident do emu.write(RESIDENT+i-1,resident[i],MEM) end
  emu.write(HOOK,0x20,MEM); emu.write(HOOK+1,RESIDENT&0xFF,MEM)
  emu.write(HOOK+2,RESIDENT>>8,MEM); emu.write(HOOK+3,0xEA,MEM)
  installed=true
  emu.log(string.format('★ 오버레이 A 감지 · %d B resident 초기 설치 완료',#resident))
  emu.log('  명령함 AC $1F03F0 / 포트 $1A10 · 이후 Lua 명령 쓰기 0 B')
  return true
end

local frame=0
local original_vram,original_satb,original_tail,original_cpu=nil,nil,nil,nil
local native_active,end_seen=false,false
local check_save,inspect1,inspect2=0,0,0
local function take_guards()
  original_vram={}; for i=0,VRAM_BYTES-1 do original_vram[i]=emu.read(VRAM_AT+i,VRAM) or 0 end
  original_satb={}; for i=0,SATB_BYTES-1 do original_satb[i]=emu.read(SATB_AT+i,VRAM) or 0 end
  original_tail={}; for a=TAIL_LO,TAIL_HI do original_tail[a]=emu.read(a,MEM) or 0 end
  original_cpu={}; for i=0,CPU_CACHE_BYTES-1 do original_cpu[i]=emu.read(ENGINE+i,MEM) or 0 end
end
local function diff(kind)
  local bad=0
  if kind=='ac' then
    for i=0,VRAM_BYTES-1 do if (emu.read(AC_BACKUP+i,AC) or 0)~=original_vram[i] then bad=bad+1 end end
  elseif kind=='vram' then
    for i=0,VRAM_BYTES-1 do if (emu.read(VRAM_AT+i,VRAM) or 0)~=original_vram[i] then bad=bad+1 end end
  elseif kind=='cpu' then
    for i=0,CPU_CACHE_BYTES-1 do if (emu.read(ENGINE+i,MEM) or 0)~=original_cpu[i] then bad=bad+1 end end
  elseif kind=='cpu_ac' then
    for i=0,CPU_CACHE_BYTES-1 do if (emu.read(CPU_CACHE_AC+i,AC) or 0)~=original_cpu[i] then bad=bad+1 end end
  elseif kind=='satb' then
    for i=0,SATB_BYTES-1 do if (emu.read(SATB_AT+i,VRAM) or 0)~=original_satb[i] then bad=bad+1 end end
  elseif kind=='satb_ac' then
    for i=0,SATB_BYTES-1 do if (emu.read(SATB_AC+i,AC) or 0)~=original_satb[i] then bad=bad+1 end end
  else
    for a=TAIL_LO,TAIL_HI do if (emu.read(a,MEM) or 0)~=original_tail[a] then bad=bad+1 end end
  end
  return bad
end
local function native_state() return emu.read(MAILBOX_AC,AC) or 255 end
local function inspect(part)
  local actual,wanted=loaded_text(),text_at(expected[part].rec)
  local ready=emu.read(ENGINE+E_READY,MEM) or 0
  local elapsed=emu.read(ENGINE+E_ELAPSED,MEM) or 0
  local tail=diff('tail')
  emu.log(string.format('  native 자체검사 %d/2 · elapsed=%d · ready=%d · tail=%d/32 · "%s"',
                        part,elapsed,ready,tail,actual))
  if ready==1 and actual==wanted and tail==0 then emu.log('  ★ NATIVE TIMED PASS') end
end

-- 읽기 전용 관측: 명령은 BIOS 코드가 실행하면서 직접 쓴다.
emu.addMemoryCallback(function()
  if not installed or native_active then return end
  if (emu.read(0x22A6,MEM) or 0)==0 and (emu.read(0x22A7,MEM) or 0)==0x68 and
     (emu.read(0x22AA,MEM) or 0)==0x0E then
    take_guards(); native_active=true; end_seen=false
    check_save,inspect1,inspect2=frame+1,frame+8,frame+128
    emu.log(string.format('[%d] BIOS AD_PLAY E6800_0E 감지 · Lua 명령 쓰기 0 B',frame))
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addMemoryCallback(function()
  if native_active and not end_seen and native_state()==2 then
    end_seen=true; emu.log(string.format('[%d] BIOS AD_STAT 종료 경로 진입',frame))
  end
end,emu.callbackType.exec,0xF6EF,0xF6EF,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1
  install_when_ready()
  if check_save>0 and frame>=check_save then
    check_save=0; local bad=diff('ac'); local state=native_state()
    local cpu_ac,satb_ac=diff('cpu_ac'),diff('satb_ac')
    emu.log(string.format('  native 저장/교체: 패턴AC %d/%d · SATB AC %d/%d · CPU AC %d/%d · state=%d · magic=%02X %02X %02X',
      bad,VRAM_BYTES,satb_ac,SATB_BYTES,cpu_ac,CPU_CACHE_BYTES,state,
      emu.read(ENGINE,MEM) or 0,emu.read(ENGINE+1,MEM) or 0,emu.read(ENGINE+2,MEM) or 0))
    if bad==0 and state==2 then emu.log('  ★ NATIVE START PASS: BIOS -> resident -> renderer') end
  end
  if native_active and inspect1>0 and frame>=inspect1 then inspect1=0; inspect(1) end
  if native_active and inspect2>0 and frame>=inspect2 then inspect2=0; inspect(2) end
  if native_active and end_seen and native_state()==0 and
     (emu.read(ENGINE+H_STATUS,MEM) or 0)==2 then
    local bad,satb,tail,cpu=diff('vram'),diff('satb'),diff('tail'),diff('cpu')
    emu.log(string.format('  native 복원: 패턴 %d/%d · SATB %d/%d · CPU 캐시 %d/%d · tail=%d/32',
      bad,VRAM_BYTES,satb,SATB_BYTES,cpu,CPU_CACHE_BYTES,tail))
    if bad==0 and satb<=8 and cpu==0 and tail==0 then emu.log('  ★ NATIVE 0.8.0-r4 PASS: 패턴 + SATB DMA + 게임 캐시 복원 · UI 확인') end
    native_active,end_seen,original_vram,original_satb,original_tail,original_cpu=false,false,nil,nil,nil,nil
  end
end,emu.eventType.startFrame)

emu.log('LOAD_SUBTITLE_NATIVE 0.8.0-r4 loaded')
emu.log(string.format('  초기 AC 적재: pack %d B · helper %d B · renderer %d B',#pack,#helper,#renderer))
emu.log('  BIOS AD_PLAY/AD_STAT 훅 확인 · 이후 Lua 음성 명령 0 B')
emu.log('  오버레이 A가 나타나면 resident를 초기 설치하고 자동 시험한다')
