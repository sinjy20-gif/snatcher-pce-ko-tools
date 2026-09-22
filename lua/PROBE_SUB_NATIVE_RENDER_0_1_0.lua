-- PROBE_SUB_NATIVE_RENDER 0.1.0 -- 완전 읽기 전용
-- 0.8.4-r2의 renderer 선택 키/자체 시각/레코드/SATB 삽입을 측정한다.

local MEM,AC,VRAM,CPU=emu.memType.pceMemory,emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam,emu.memType.cpu
local ENGINE,STATE,AC_RENDERER=0x5B80,0x7FDF,0x1F1F00
local E_READY,E_COUNT,E_SELECTOR,E_ELAPSED,E_RECORD=364,365,366,455,461
local KEY={0x78,0x30,0x00,0x00,0x68,0x0E}

local function hex_mem(kind,at,n)
  local out={}
  for i=0,n-1 do out[#out+1]=string.format('%02X',emu.read(at+i,kind) or 0) end
  return table.concat(out,' ')
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
local function selector_ok(kind,base)
  for i=1,6 do if (emu.read(base+i-1,kind) or 0)~=KEY[i] then return false end end
  return true
end
local function snapshot(tag,frame)
  local ready=emu.read(ENGINE+E_READY,MEM) or 0
  local count=emu.read(ENGINE+E_COUNT,MEM) or 0
  local elapsed=emu.read(ENGINE+E_ELAPSED,MEM) or 0
  emu.log(string.format('  %s f=%d state=%02X elapsed=%d ready=%d count=%d ours=%d',
    tag,frame,emu.read(STATE,MEM) or 0,elapsed,ready,count,ours()))
  emu.log('    CPU selector '..hex_mem(MEM,ENGINE+E_SELECTOR,6))
  if count>0 and count<40 then
    emu.log('    record head  '..hex_mem(MEM,ENGINE+E_RECORD,math.min(32,6+count*4)))
  end
end

local frame,startFrame=0,nil
local samples={[2]=true,[8]=true,[30]=true,[60]=true,[125]=true}
local targetSeen=false

emu.addMemoryCallback(function()
  if (emu.read(0x22A6,MEM) or 0)==0 and (emu.read(0x22A7,MEM) or 0)==0x68 and
     (emu.read(0x22AA,MEM) or 0)==0x0E then
    targetSeen=true
    emu.log(string.format('[%d] E6800_0E 관측',frame))
  end
end,emu.callbackType.exec,0xF61A,0xF61A,emu.cpuType.pce,CPU)

emu.addEventCallback(function()
  frame=frame+1
  local state=emu.read(STATE,MEM) or 0xFF
  if targetSeen and not startFrame and state==2 then
    startFrame=frame
    emu.log(string.format('[%d] renderer 활성',frame))
    emu.log('  AC  selector '..hex_mem(AC,AC_RENDERER+E_SELECTOR,6)..
      (selector_ok(AC,AC_RENDERER+E_SELECTOR) and '  PASS' or '  FAIL'))
    snapshot('+0',frame)
  elseif startFrame and state==2 then
    local age=frame-startFrame
    if samples[age] then samples[age]=nil; snapshot('+'..age,frame) end
  elseif startFrame and state==0 then
    snapshot('END',frame)
    emu.log('★ 측정 종료 -- Lua 쓰기 0 B')
    startFrame,targetSeen=nil,false
  end
end,emu.eventType.startFrame)

emu.log('PROBE_SUB_NATIVE_RENDER 0.1.0 loaded -- 읽기 전용')
emu.log('  AC/CPU/VRAM 쓰기 0 B · selector/elapsed/ready/record/SATB 측정')
