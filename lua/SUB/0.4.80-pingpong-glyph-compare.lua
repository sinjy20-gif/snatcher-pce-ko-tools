-- SUB 0.4.80 -- 0.4.79 $1600 기준표와 A/B ping-pong 표시 타일을 비교.
-- 0.4.79를 같은 저장 지점에서 먼저 실행해 기준표를 만든 뒤 사용한다.
-- 추가 게임/AC/VRAM/Sprite RAM write 0 B.

dofile('C:/snatcher/lua/SUB/0.4.73-controller-stage-pingpong.lua')

local VERSION = '0.4.80-pingpong-glyph-compare'
local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
local CPU = emu.cpuType.pce
local ENGINE, COUNT_OK, GLYPH_DONE, SELECTOR = 0x5B80, 0x5B80 + 118, 0x5B80 + 289, 0x5B80 + 345
local VRAM_LO, VRAM_HI, CELLS, WORDS = 144, 146, 19, 0x40
local BASELINE = 'C:/snatcher/dump/sub_0_4_79_fixedbase_baseline.tsv'
local stamp=os.date('%Y%m%d_%H%M%S')
local OUT='C:/snatcher/dump/sub_0_4_80_pingpong_compare_'..stamp..'.tsv'

local expected={}
local fh=assert(io.open(BASELINE,'r'),'0.4.79 기준표가 없습니다: '..BASELINE)
for line in fh:lines() do
  local k,p,c,h=line:match('^(%x+)\t(%d+)\t(%d+)\t(%x+)$')
  if k then expected[k..':'..p..':'..c]=h end
end
fh:close()
local out=assert(io.open(OUT,'w')); out:write('key\tpart\tbase\tcell\texpected\tactual\tmatch\n')

local function rb(a,k) local ok,v=pcall(emu.read,a,k); return ok and type(v)=='number' and v or 0 end
local function rw(w) local a=w*2; return rb(a,VRAM)|(rb(a+1,VRAM)<<8) end
local function key()
  local t={}; for i=0,5 do t[#t+1]=string.format('%02X',rb(SELECTOR+i,MEM)) end; return table.concat(t)
end
local function hash(base,cell)
  local h=2166136261
  for at=base+cell*WORDS,base+(cell+1)*WORDS-1 do
    local v=rw(at); h=((h~(v&255))*16777619)&0xFFFFFFFF; h=((h~((v>>8)&255))*16777619)&0xFFFFFFFF
  end
  return string.format('%08X',h)
end

local frame,active,parts=0,nil,{}
emu.addMemoryCallback(function()
  local k=key(); parts[k]=(parts[k] or 0)+1
  active={key=k,part=parts[k],base=rb(ENGINE+VRAM_LO,MEM)|(rb(ENGINE+VRAM_HI,MEM)<<8),born=frame,done=false}
end,emu.callbackType.exec,COUNT_OK,COUNT_OK,CPU,MEM)
emu.addMemoryCallback(function() if active then active.done=true end end,emu.callbackType.exec,GLYPH_DONE,GLYPH_DONE,CPU,MEM)
emu.addEventCallback(function()
  frame=frame+1
  if not active or not active.done or frame-active.born~=2 then return end
  local bad,missing=0,0
  for cell=0,CELLS-1 do
    local want=expected[active.key..':'..active.part..':'..cell] or ''
    local got=hash(active.base,cell); local match=want~='' and want==got
    if want=='' then missing=missing+1 elseif not match then bad=bad+1 end
    out:write(string.format('%s\t%d\t%04X\t%d\t%s\t%s\t%s\n',active.key,active.part,active.base,cell,want,got,match and 'Y' or 'N'))
  end
  out:flush()
  emu.log(string.format('SUB %s %s part%d base=$%04X mismatch=%d missing=%d%s',VERSION,active.key,active.part,active.base,bad,missing,bad>0 and ' ★' or ''))
  active=nil
end,emu.eventType.endFrame)
emu.addEventCallback(function() out:close(); emu.log('SUB '..VERSION..' 끝 -- '..OUT) end,emu.eventType.scriptEnded)
emu.log('SUB '..VERSION..' loaded -- compare A/B glyphs to 0.4.79 baseline / READ ONLY')
emu.log('  Power Cycle 뒤 이 파일 하나만 실행 · 같은 저장 지점에서 미카 3조각까지')
