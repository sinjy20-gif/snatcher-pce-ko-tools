-- PROBE_GAUDI_SEARCH 0.1.6
--
-- v0.1.5에서 앞단 색인 진입은 성공했지만 게임이 입력 길이 2를 기준으로
-- 최종 비교 전에 INPUT+4를 FF로 다시 썼다. BA59(색인)와 BA00(최종 비교)
-- 양쪽 진입 시 원본 「ギブスン」 키를 복원해 변환 방식 자체를 검증한다.
-- 디스크 이미지는 수정하지 않는다.

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v016.tsv"
local MEM = emu.memType.pceMemory
local INPUT = 0x363E
local KO = {0x83,0x45,0x83,0x6A,0xFF}
local JP = {0x83,0x4D,0x83,0x75,0x83,0x58,0x83,0x93,0xFF,0x40}
local CAND = {0x83,0x4D,0x83,0x75,0x83,0x58,0x83,0x93,0xFF}

local f = assert(io.open(OUT, "w"))
f:write("kind\tframe\tpc\tx\ty\td4d5\tptr\tinput\tc985\n")
f:flush()
local frame, indexRewrites, finalRewrites, restores = 0, 0, 0, 0

local function b(a) return emu.read(a % 0x10000, MEM) or 0 end
local function st()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return nil
end
local function reg(s, n)
  if not s then return 0 end
  return s["cpu." .. n] or s[n] or 0
end
local function mpr(s, slot)
  if not s then return 0 end
  return s[string.format("memoryManager.mpr[%d]", slot)]
      or s[string.format("mpr[%d]", slot)] or 0
end
local function starts(a, v)
  for i=1,#v do if b(a+i-1) ~= v[i] then return false end end
  return true
end
local function hx(a, n)
  local t={}
  for i=0,n-1 do t[#t+1]=string.format("%02X",b(a+i)) end
  return table.concat(t," ")
end
local function row(kind, s)
  local d=b(0x20D4)|(b(0x20D5)<<8)
  local p=b(0x2090)|(b(0x2091)<<8)
  f:write(string.format("%s\t%d\t%04X\t%02X\t%02X\t%04X\t%04X:%02X\t%s\t%s\n",
    kind,frame,reg(s,"pc"),reg(s,"x"),reg(s,"y"),d,p,b(0x2092),
    hx(INPUT,32),hx(0xC985,16)))
  f:flush()
end
local function writeJP()
  for i=1,#JP do emu.write(INPUT+i-1,JP[i],MEM) end
  for a=INPUT+10,INPUT+31,2 do
    emu.write(a,0x81,MEM); emu.write(a+1,0x40,MEM)
  end
end

-- 앞단 색인에 들어가기 전에 한글 토큰을 원본 검색 키로 바꾼다.
emu.addMemoryCallback(function()
  local s=st()
  if starts(INPUT,KO) then
    row("index_before",s); writeJP(); indexRewrites=indexRewrites+1
    row("index_rewritten",st())
  end
end,emu.callbackType.exec,0xBA59,0xBA59,emu.cpuType.pce,MEM)

-- 게임이 길이 2 기준 FF를 다시 삽입한 뒤이므로 최종 비교 직전에 재복원한다.
emu.addMemoryCallback(function()
  local s=st()
  if b(INPUT)==0x83 and b(INPUT+1)==0x4D
      and b(INPUT+2)==0x83 and b(INPUT+3)==0x75 then
    writeJP(); finalRewrites=finalRewrites+1
    row("final_rewritten",st())
  end
end,emu.callbackType.exec,0xBA00,0xBA00,emu.cpuType.pce,MEM)

for _,pc in ipairs({0xBA00,0xBA19,0xBA59,0xBA6D}) do
  emu.addMemoryCallback(function()
    row(string.format("compare_%04X",pc),st())
  end,emu.callbackType.exec,pc,pc,emu.cpuType.pce,MEM)
end

-- 앞선 0.1.4의 런타임 후보 치환이 남아 있으면 원본으로 복구한다.
emu.addEventCallback(function()
  frame=frame+1
  local s=st()
  if mpr(s,6)==0x7E and b(0xC985)==0x83 and b(0xC986)==0x45
      and b(0xC987)==0x83 and b(0xC988)==0x6A then
    for i=1,#CAND do emu.write(0xC985+i-1,CAND[i],MEM) end
    restores=restores+1; row("candidate_restored",st())
  end
end,emu.eventType.endFrame)

emu.addEventCallback(function()
  f:write(string.format("-- index_rewrites %d final_rewrites %d restores %d\n",
    indexRewrites,finalRewrites,restores)); f:close()
end,emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.6 -- 색인/최종 비교 이중 변환")
emu.log("깁슨 입력 -> 결정 -> 결과 뒤 Stop")
emu.log("output: " .. OUT)
