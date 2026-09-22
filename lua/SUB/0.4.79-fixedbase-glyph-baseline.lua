-- SUB 0.4.79 -- 고정 $1600 정상 경로의 표시 타일 지문 기준표 작성.
--
-- 0.4.58의 controller/stage만 사용한다. allocator/ping-pong/wipe 없음.
-- 같은 저장 지점에서 첫 음성부터 재생한 뒤 Stop하면 0.4.80이 이 파일과
-- A/B ping-pong 결과를 자동 비교한다. 추가 게임 write 0 B.

dofile('C:/snatcher/lua/SUB/0.4.58-controller-stage.lua')

local VERSION = '0.4.79-fixedbase-glyph-baseline'
local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
local CPU = emu.cpuType.pce
local ENGINE, COUNT_OK, GLYPH_DONE, SELECTOR = 0x5B80, 0x5B80 + 118, 0x5B80 + 289, 0x5B80 + 345
local VRAM_LO, VRAM_HI, CELLS, WORDS = 144, 146, 19, 0x40
local OUT = 'C:/snatcher/dump/sub_0_4_79_fixedbase_baseline.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('key\tpart\tcell\thash\n')

local function rb(a, k) local ok,v=pcall(emu.read,a,k); return ok and type(v)=='number' and v or 0 end
local function rw(w) local a=w*2; return rb(a,VRAM)|(rb(a+1,VRAM)<<8) end
local function key()
  local t={}; for i=0,5 do t[#t+1]=string.format('%02X',rb(SELECTOR+i,MEM)) end; return table.concat(t)
end
local function hash(base, cell)
  local h=2166136261
  for at=base+cell*WORDS,base+(cell+1)*WORDS-1 do
    local v=rw(at); h=((h~(v&255))*16777619)&0xFFFFFFFF; h=((h~((v>>8)&255))*16777619)&0xFFFFFFFF
  end
  return string.format('%08X',h)
end

local frame, active, parts = 0, nil, {}
emu.addMemoryCallback(function()
  local k=key(); parts[k]=(parts[k] or 0)+1
  active={key=k,part=parts[k],base=rb(ENGINE+VRAM_LO,MEM)|(rb(ENGINE+VRAM_HI,MEM)<<8),born=frame,done=false}
end,emu.callbackType.exec,COUNT_OK,COUNT_OK,CPU,MEM)
emu.addMemoryCallback(function() if active then active.done=true end end,emu.callbackType.exec,GLYPH_DONE,GLYPH_DONE,CPU,MEM)
emu.addEventCallback(function()
  frame=frame+1
  if not active or not active.done or frame-active.born~=2 then return end
  for cell=0,CELLS-1 do out:write(string.format('%s\t%d\t%d\t%s\n',active.key,active.part,cell,hash(active.base,cell))) end
  out:flush()
  emu.log(string.format('SUB %s %s part%d base=$%04X saved',VERSION,active.key,active.part,active.base))
  active=nil
end,emu.eventType.endFrame)
emu.addEventCallback(function() out:close(); emu.log('SUB '..VERSION..' 끝 -- '..OUT) end,emu.eventType.scriptEnded)
emu.log('SUB '..VERSION..' loaded -- fixed $1600 glyph baseline / READ ONLY')
emu.log('  Power Cycle 뒤 이 파일 하나만 실행 · 미카 3조각 뒤 Stop')
