-- PROBE_GAUDI_TEST5B_HOOK 0.1.0
-- test5b 영구 훅의 실행 경로와 입력 종료자 재삽입 지점을 기록한다.
-- 메모리는 수정하지 않는다.

local OUT = "C:\\snatcher\\dump\\probe_gaudi_test5b_hook_v010.tsv"
local MEM = emu.memType.pceMemory
local INPUT = 0x363E
local f = assert(io.open(OUT, "w"))
f:write("kind\tframe\tpc\ta\tx\ty\tp\tinput\tcode_b9e0\n")
f:flush()
local frame, rows = 0, 0

local function b(a) return emu.read(a % 0x10000, MEM) or 0 end
local function st()
  local ok,s=pcall(emu.getState); if ok and s then return s end; return nil
end
local function reg(s,n)
  if not s then return 0 end
  return s["cpu."..n] or s[n] or 0
end
local function hx(a,n)
  local t={}; for i=0,n-1 do t[#t+1]=string.format("%02X",b(a+i)) end
  return table.concat(t," ")
end
local function row(kind,s)
  rows=rows+1
  f:write(string.format("%s\t%d\t%04X\t%02X\t%02X\t%02X\t%02X\t%s\t%s\n",
    kind,frame,reg(s,"pc"),reg(s,"a"),reg(s,"x"),reg(s,"y"),reg(s,"p"),
    hx(INPUT,16),hx(0xB9E0,8))); f:flush()
end

for _,pc in ipairs({0xB9E0,0xBE56,0xBEB1,0xBEB6,0xB9FD,0xBA00,0xBA55,0xBA59}) do
  emu.addMemoryCallback(function() row(string.format("exec_%04X",pc),st()) end,
    emu.callbackType.exec,pc,pc,emu.cpuType.pce,MEM)
end

emu.addMemoryCallback(function(address,value)
  local s=st(); row(string.format("write_3642_%02X",value or 0),s)
end,emu.callbackType.write,0x3642,0x3642,emu.cpuType.pce,MEM)

emu.addEventCallback(function() frame=frame+1 end,emu.eventType.endFrame)
emu.addEventCallback(function()
  f:write(string.format("-- rows %d final %s\n",rows,hx(INPUT,16))); f:close()
end,emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_TEST5B_HOOK 0.1.0 -- read-only hook trace")
emu.log("test5b에서 깁슨 검색 실패까지 진행 후 Stop")
emu.log("output: "..OUT)
