-- SUB 0.4.81 -- $1600 기준표와 ping-pong의 실제 표시 타일만 비교한다.
-- 0.4.80은 19칸 전체를 비교해 미사용 꼬리 작업공간까지 mismatch로 셌다.
-- 이 판은 FRAME_2 SATB가 참조한 타일만 세므로 화면에 보이는 글자만 판정한다.
-- 먼저 0.4.79 기준표를 만든 상태에서 Power Cycle 뒤 이 파일 하나만 실행.

dofile('C:/snatcher/lua/SUB/0.4.73-controller-stage-pingpong.lua')

local VERSION = '0.4.81-pingpong-visible-glyph-compare'
local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
local CPU = emu.cpuType.pce
local ENGINE, COUNT_OK, GLYPH_DONE, SELECTOR = 0x5B80, 0x5B80 + 118, 0x5B80 + 289, 0x5B80 + 345
local VRAM_LO, VRAM_HI, CELLS, WORDS, SATB = 144, 146, 19, 0x40, 0x1000
local BASELINE = 'C:/snatcher/dump/sub_0_4_79_fixedbase_baseline.tsv'
local stamp=os.date('%Y%m%d_%H%M%S')
local OUT='C:/snatcher/dump/sub_0_4_81_visible_compare_'..stamp..'.tsv'

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
local function visible(base)
  local cells={}
  for slot=0,63 do
    local at=SATB+slot*4
    local pat,attr=rw(at+2),rw(at+3)
    local first=(pat&0x07FF)<<5
    local wide=(attr&0x0100)~=0 and 2 or 1
    local hc=(attr>>12)&3
    local tall=hc==0 and 1 or (hc==1 and 2 or 4)
    for i=0,wide*tall-1 do
      local cell=((first+i*WORDS)-base)//WORDS
      if cell>=0 and cell<CELLS then cells[cell]=true end
    end
  end
  return cells
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
  local shown,bad,missing=visible(active.base),0,0
  local numbers={}; for cell in pairs(shown) do numbers[#numbers+1]=cell end; table.sort(numbers)
  for _,cell in ipairs(numbers) do
    local want=expected[active.key..':'..active.part..':'..cell] or ''
    local got=hash(active.base,cell); local match=want~='' and want==got
    if want=='' then missing=missing+1 elseif not match then bad=bad+1 end
    out:write(string.format('%s\t%d\t%04X\t%d\t%s\t%s\t%s\n',active.key,active.part,active.base,cell,want,got,match and 'Y' or 'N'))
  end
  out:flush()
  emu.log(string.format('SUB %s %s part%d base=$%04X visible=%d mismatch=%d missing=%d%s',VERSION,active.key,active.part,active.base,#numbers,bad,missing,bad>0 and ' ★' or ''))
  active=nil
end,emu.eventType.endFrame)
emu.addEventCallback(function() out:close(); emu.log('SUB '..VERSION..' 끝 -- '..OUT) end,emu.eventType.scriptEnded)
emu.log('SUB '..VERSION..' loaded -- visible tiles only / READ ONLY')
emu.log('  Power Cycle 뒤 이 파일 하나만 실행 · 0.4.79 기준표와 실제 표시 타일만 비교')
