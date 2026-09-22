-- PROBE_SUB_AC_RESIDENT 0.7.0-r1
-- $7F49-$7FDF 151 B 상주 컨트롤러가 helper <-> renderer를 직접 교체한다.
-- Lua는 시작/종료 감지와 명령만 맡고 CPU $5B80 엔진 바이트를 복사하지 않는다.

local MEM, AC, VRAM = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam
local RESIDENT, ENGINE, PACK_AT = 0x7F49, 0x5B80, 0x1C0000
local HOOK, AC_HELPER, AC_RENDERER = 0x601E, 0x1F1C00, 0x1F1F00
local AC_BACKUP = 0x1F0400
local FORCE_BASE = rawget(_G, 'SUB_RESIDENT_FORCE_BASE') or 0x7900
FORCE_BASE = FORCE_BASE & 0xFFE0
local ALLVOICE = rawget(_G, 'SUB_RESIDENT_ALLVOICE') == true
local PRELOAD_PACK = rawget(_G, 'SUB_RESIDENT_PRELOAD_PACK') == true
local LUA_RESTORE = rawget(_G, 'SUB_RESIDENT_LUA_RESTORE') == true
local VRAM_AT, VRAM_BYTES = FORCE_BASE * 2, 2432
local TAIL_LO, TAIL_HI = 0x5E20, 0x5E3F
local KEY = { 0x78, 0x30, 0x00, 0x00, 0x68, 0x0E }

local RES_PATH = rawget(_G, 'SUB_RESIDENT_CONTROLLER_PATH') or
  'C:/snatcher/build/cutscene_subs/resident_controller_0_7.bin'
local H_SLOT_PATH = rawget(_G, 'SUB_RESIDENT_HELPER_PATH') or
  'C:/snatcher/build/cutscene_subs/resident_helper_slot_0_7.bin'
local R_SLOT_PATH = rawget(_G, 'SUB_RESIDENT_RENDERER_PATH') or
  'C:/snatcher/build/cutscene_subs/resident_renderer_slot_0_7.bin'
local PACK_PATH = rawget(_G, 'SUB_RESIDENT_PACK_PATH') or
  'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local R_STATE = 150
local H_COMMAND, H_STATUS = 173, 174
local E_READY, E_COUNT, E_SELECTOR, E_ELAPSED, E_RECORD = 364, 365, 366, 455, 461

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close()
  local t = {}; for i=1,#d do t[i]=d:byte(i) end
  return t
end
local resident, helper_slot, renderer_slot, pack =
  slurp(RES_PATH), slurp(H_SLOT_PATH), slurp(R_SLOT_PATH), slurp(PACK_PATH)
assert(#resident <= 151 and #helper_slot == 320 and #renderer_slot == 671,
       '0.7 build sizes changed; rebuild resident controller')

-- Optional standalone mode used by SUB 0.4.30.  The 0.4.5.9 signtest base
-- contains no subtitle payload preload, so Lua supplies all three AC images.
if PRELOAD_PACK then
  for i=1,#pack do emu.write(PACK_AT+i-1,pack[i],AC) end
end

-- Move both upload/restore and SATB pattern references to the requested word
-- base before the images are copied to Arcade Card RAM.
helper_slot[40]  = FORCE_BASE & 0xFF
helper_slot[42]  = (FORCE_BASE >> 8) & 0xFF
helper_slot[132] = FORCE_BASE & 0xFF
helper_slot[134] = (FORCE_BASE >> 8) & 0xFF
renderer_slot[166] = FORCE_BASE & 0xFF
renderer_slot[168] = (FORCE_BASE >> 8) & 0xFF
renderer_slot[277] = (FORCE_BASE >> 5) & 0xFF
renderer_slot[282] = 0x80 | (((FORCE_BASE >> 13) & 0x07) << 4) | 0x0F

local function p8(o) return pack[o+1] end
local function p16(o) return p8(o) | (p8(o+1) << 8) end
local function p32(o) return p16(o) | (p16(o+2) << 16) end
for i=0,5 do
  assert((emu.read(PACK_AT+i,AC) or -1)==p8(i),
         'AC pack differs; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua again')
end

for i=1,#helper_slot do emu.write(AC_HELPER+i-1,helper_slot[i],AC) end
for i=1,#renderer_slot do emu.write(AC_RENDERER+i-1,renderer_slot[i],AC) end

-- 스크립트를 다른 오버레이에서 열어도 실패시키지 않는다. 디스크의 오버레이 A와
-- 기존 $7FA0 상주부가 나타나는 프레임에만 151 B 컨트롤러를 설치한다.
local resident_installed, region_warned = false, false
local function controller_present()
  if not (emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==(RESIDENT&0xFF) and
          emu.read(HOOK+2,MEM)==(RESIDENT>>8)) then return false end
  for i=1,#resident do
    if i-1~=R_STATE and emu.read(RESIDENT+i-1,MEM)~=resident[i] then return false end
  end
  return true
end
local function poc_hook_present()
  return emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==(RESIDENT&0xFF) and
         emu.read(HOOK+2,MEM)==(RESIDENT>>8)
end
local function legacy_present()
  return emu.read(HOOK,MEM)==0x20 and emu.read(HOOK+1,MEM)==0xA0 and
         emu.read(HOOK+2,MEM)==0x7F and emu.read(0x7FA0,MEM)==0x08
end
local function try_install_resident()
  if controller_present() then resident_installed=true; return true end
  resident_installed=false
  if poc_hook_present() then
    for i=1,#resident do emu.write(RESIDENT+i-1,resident[i],MEM) end
    resident_installed=true
    emu.log('★ 이전 0.7 resident를 수정판으로 다시 설치')
    return true
  end
  if not legacy_present() then return false end
  local outside=0
  for a=0x7F49,0x7FDF do
    if not (a>=0x7FA0 and a<=0x7FBF) and (emu.read(a,MEM) or 0)~=0xFF then outside=outside+1 end
  end
  if outside~=0 then
    if not region_warned then
      region_warned=true
      emu.log(string.format('★ $7F49-$7FDF 설치 중지: 기존 32 B 밖 불일치 %d B',outside))
    end
    return false
  end
  for i=1,#resident do emu.write(RESIDENT+i-1,resident[i],MEM) end
  emu.write(HOOK,0x20,MEM); emu.write(HOOK+1,RESIDENT&0xFF,MEM)
  emu.write(HOOK+2,RESIDENT>>8,MEM); emu.write(HOOK+3,0xEA,MEM)
  resident_installed=true
  emu.log(string.format('★ 오버레이 A 감지 · resident %d B 설치 · 훅 $601E -> $%04X',#resident,RESIDENT))
  return true
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
  for i=0,n-1 do
    local at=ENGINE+E_RECORD+6+i*4
    local id=(emu.read(at,MEM) or 0)|((emu.read(at+1,MEM) or 0)<<8)
    out=out..utf8.char(p16(P.chars+id*2))
  end
  return out
end
local frames,was_playing=0,false
local phase='idle'
local original_vram,original_tail=nil,nil
local inspect1,inspect2,save_check=0,0,0
local function guards()
  original_vram={}; for i=0,VRAM_BYTES-1 do original_vram[i]=emu.read(VRAM_AT+i,VRAM) or 0 end
  original_tail={}; for a=TAIL_LO,TAIL_HI do original_tail[a]=emu.read(a,MEM) or 0 end
end
local function diff(kind)
  local bad=0
  if kind=='ac' then
    for i=0,VRAM_BYTES-1 do if (emu.read(AC_BACKUP+i,AC) or 0)~=original_vram[i] then bad=bad+1 end end
  elseif kind=='vram' then
    for i=0,VRAM_BYTES-1 do if (emu.read(VRAM_AT+i,VRAM) or 0)~=original_vram[i] then bad=bad+1 end end
  else
    for a=TAIL_LO,TAIL_HI do if (emu.read(a,MEM) or 0)~=original_tail[a] then bad=bad+1 end end
  end
  return bad
end

local function begin()
  guards()
  for i=1,6 do emu.write(AC_RENDERER+E_SELECTOR+i-1,KEY[i],AC) end
  emu.write(AC_HELPER+H_COMMAND,0,AC); emu.write(AC_HELPER+H_STATUS,0,AC)
  emu.write(RESIDENT+R_STATE,1,MEM)
  phase,save_check,inspect1,inspect2='rendering',frames+1,frames+8,frames+128
  emu.log(string.format('[%d] RESIDENT START · 명령 1 B · 상주부가 helper 320 B -> renderer 671 B 교체',frames))
  emu.log('  Lua CPU 엔진 복사 0 B · 조각 제어 0 B')
end
local function inspect(part)
  local actual,wanted=loaded_text(),text_at(expected[part].rec)
  local ready=emu.read(ENGINE+E_READY,MEM) or 0
  local elapsed=emu.read(ENGINE+E_ELAPSED,MEM) or 0
  local tail=diff('tail')
  emu.log(string.format('  자체검사 %d/2 · elapsed=%d · ready=%d · tail diff=%d/32 · "%s"',
                        part,elapsed,ready,tail,actual))
  if ready==1 and actual==wanted and tail==0 then emu.log('  ★ RESIDENT TIMED PASS')
  else emu.log(string.format('  ★ RESIDENT TIMED FAIL: 기대="%s"',wanted)) end
end
local function restore()
  emu.write(AC_HELPER+H_COMMAND,0,AC); emu.write(AC_HELPER+H_STATUS,0,AC)
  emu.write(RESIDENT+R_STATE,3,MEM)
  phase='restoring'
  emu.log(string.format('[%d] RESIDENT END · 명령 1 B · 상주부가 restore helper로 교체',frames))
end
local function finish()
  local bad,tail=diff('vram'),diff('tail')
  local state=emu.read(RESIDENT+R_STATE,MEM) or 255
  emu.log(string.format('  복원검사: status=%d · state=%d · VRAM 불일치 %d/%d · tail=%d/32',
                        emu.read(ENGINE+H_STATUS,MEM) or 0,state,bad,VRAM_BYTES,tail))
  if bad==0 and tail==0 and state==0 then
    emu.log('  ★ RESIDENT 0.7.0-r1 PASS: 상주부 교체 · 자체 자막 · VRAM 복원 완료 -- UI 확인')
  else emu.log('  ★ RESIDENT 0.7.0-r1 FAIL') end
  if LUA_RESTORE and original_vram then
    for i=0,VRAM_BYTES-1 do emu.write(VRAM_AT+i,original_vram[i],VRAM) end
    emu.log(string.format('  Lua safety restore $%04X-$%04X',
      FORCE_BASE, FORCE_BASE + VRAM_BYTES // 2 - 1))
  end
  phase,original_vram,original_tail='idle',nil,nil
end

emu.addEventCallback(function()
  frames=frames+1
  if not try_install_resident() then return end
  if save_check>0 and frames>=save_check then
    save_check=0
    local bad=diff('ac'); local state=emu.read(RESIDENT+R_STATE,MEM) or 0
    emu.log(string.format('  저장/교체검사: AC 불일치 %d/%d · state=%d · engine magic=%02X %02X %02X',
      bad,VRAM_BYTES,state,emu.read(ENGINE,MEM),emu.read(ENGINE+1,MEM),emu.read(ENGINE+2,MEM)))
    if bad==0 and state==2 then emu.log('  ★ RESIDENT SWAP PASS: 저장 후 renderer까지 상주부가 설치') end
    if bad~=0 or state~=2 then
      emu.log('  ★ RESIDENT SWAP FAIL: 이후 문자 검사를 중단한다')
      emu.write(RESIDENT+R_STATE,0,MEM)
      inspect1,inspect2,phase=0,0,'failed'
    end
  end
  if phase=='rendering' and inspect1>0 and frames>=inspect1 then inspect1=0; inspect(1) end
  if phase=='rendering' and inspect2>0 and frames>=inspect2 then inspect2=0; inspect(2) end
  if phase=='restoring' and (emu.read(ENGINE+H_STATUS,MEM) or 0)==2 then finish() end

  local s=emu.getState() or {}; local playing=s['cdrom.adpcm.playing']==true
  if playing and not was_playing and phase=='idle' then
    local ending=(((s['cdrom.adpcm.readAddress'] or 0)+(s['cdrom.adpcm.adpcmLength'] or 0))%0x10000)
    local rate=(s['cdrom.adpcm.playbackRate'] or 0)
    if (ALLVOICE and rate==0x0E) or
       (s['cdrom.scsi.sector']==0x003078 and ending==0x6800 and rate==0x0E) then
      begin()
    end
  elseif not playing and was_playing and phase=='rendering' then restore() end
  was_playing=playing
end,emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_RESIDENT 0.7.0-r1 loaded')
emu.log(string.format('  resident %d/151 B · helper %d B slot · renderer %d B',#resident,#helper_slot,#renderer_slot))
emu.log('  $7F49-$7FDF BIOS 전환 여유 사용 · 훅 $601E -> $7F49')
emu.log('  Lua는 시작/종료 명령만 쓴다; AC -> CPU 엔진 교체는 상주부가 수행')
emu.log(string.format('  mode=%s · preload_pack=%s · VRAM=$%04X-$%04X · lua_restore=%s',
  ALLVOICE and 'ALLVOICE' or 'E6800 only', tostring(PRELOAD_PACK), FORCE_BASE,
  FORCE_BASE + VRAM_BYTES // 2 - 1, tostring(LUA_RESTORE)))
emu.log(string.format('  현재 오버레이는 대기: $601E=%02X %02X %02X %02X · 오버레이 A가 오면 자동 설치',
  emu.read(HOOK,MEM) or 0,emu.read(HOOK+1,MEM) or 0,emu.read(HOOK+2,MEM) or 0,emu.read(HOOK+3,MEM) or 0))
