-- PROBE GAUDI BAT WRITER 0.2.0 -- 누가 자판 타일맵을 쓰는가.  ★순수 관측 · 쓰기 0 B
--
-- 0.1.0 이 왜 0 건이었나
--   VDC 포트($0000-$0003)에 메모리 쓰기 콜백을 걸었는데, HuC6280 은 VDC 를
--   `ST0`/`ST1`/`ST2` **전용 명령**으로 쓴다.  메모리 접근이 아니라 콜백을 안 탄다.
--   그래서 이번에는 VRAM 자체에 건다.  안 걸리는 빌드면 등록에서 바로 알려준다.
--
-- 노리는 칸 (VRAM 워드 주소 = 행*64 + 열, 바이트 = 워드*2)
--   (34,20) $0894   (35,16) $08D0   (36,4) $0904     <- 반쪽을 나눠 쓰는 셋
--   자판 전체는 행 33~38 · 열 3~28  ->  바이트 $1086-$138F
--
-- 두 갈래로 동시에 본다
--   A) VRAM 쓰기 콜백이 되면: 그 순간의 PC·MPR 을 찍는다 -> 코드 자리가 바로 나온다
--   B) 안 되면: 매 프레임 그 칸들을 읽어 **값이 바뀌는 프레임**을 찍는다 ->
--      최소한 "언제" 가 나오고, 그 프레임에서 다시 좁힐 수 있다
--
-- 쓰는 법  로드 -> 가우디 자판에 **들어갔다가 한 번 나오고** -> Stop
-- 산출물   C:/snatcher/dump/gaudi_bat_writer_v020.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam
local OUT = "C:/snatcher/dump/gaudi_bat_writer_v020.tsv"
local BAT_W = 64
local LO, HI = (33 * BAT_W + 3) * 2, (38 * BAT_W + 28) * 2 + 1
local SHARED = { [34 * BAT_W + 20] = true, [35 * BAT_W + 16] = true, [36 * BAT_W + 4] = true }
local WATCH = { 34 * BAT_W + 20, 35 * BAT_W + 16, 36 * BAT_W + 4,
                33 * BAT_W + 4, 37 * BAT_W + 4 }

local frame, rows, hooked, keysLogged = 0, {}, false, false
local last = {}
local MAX = 3000

local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end
local function pick(s, ...)
  for _, k in ipairs({ ... }) do if s[k] ~= nil then return s[k] end end
  return -1
end
local function add(kind, word, value, s)
  if #rows >= MAX then return end
  s = s or st()
  if not keysLogged then
    keysLogged = true
    local ks = {}
    for k in pairs(s) do ks[#ks + 1] = k end
    table.sort(ks)
    emu.log("state keys: " .. table.concat(ks, " "))
  end
  rows[#rows + 1] = string.format("%s\t%d\t%d\t%d\t$%04X\t$%04X\t%s\t$%04X\t$%02X\t$%02X",
    kind, frame, word // BAT_W, word % BAT_W, word, value,
    SHARED[word] and "SHARED" or "-",
    pick(s, "cpu.pc", "pc") % 65536,
    pick(s, "cpu.mpr3", "mpr3") % 256,
    pick(s, "cpu.mpr5", "mpr5") % 256)
end

-- A) VRAM 쓰기 콜백
local ok, err = pcall(function()
  emu.addMemoryCallback(function(address, value)
    add("write", address // 2, value, nil)
  end, emu.callbackType.write, LO, HI, CPU, VRAM)
end)
hooked = ok
if ok then
  emu.log("VRAM 쓰기 콜백 등록됨 -- PC 가 바로 나온다")
else
  emu.log("VRAM 쓰기 콜백 불가 (" .. tostring(err) .. ") -- 프레임 감시로 간다")
end

-- B) 프레임 감시 (콜백이 되든 안 되든 같이 돌린다.  서로 검산이 된다)
local function rb(at) return emu.read(at, VRAM) or 0 end
emu.addEventCallback(function()
  frame = frame + 1
  for _, word in ipairs(WATCH) do
    local v = rb(word * 2) | (rb(word * 2 + 1) << 8)
    if last[word] ~= nil and last[word] ~= v then add("change", word, v, nil) end
    last[word] = v
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = assert(io.open(OUT, "w"))
  f:write("kind\tframe\trow\tcol\tvram_word\tvalue\tshared\tpc\tmpr3\tmpr5\n")
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()
  local w, c = 0, 0
  for _, r in ipairs(rows) do
    if r:sub(1, 5) == "write" then w = w + 1 else c = c + 1 end
  end
  emu.log(string.format("GAUDI BAT WRITER 0.2.0 -> %s  (콜백 %s · 쓰기 %d · 변화 %d)",
    OUT, hooked and "on" or "off", w, c))
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI BAT WRITER 0.2.0 loaded -- 자판에 들어갔다 나오고 Stop")
