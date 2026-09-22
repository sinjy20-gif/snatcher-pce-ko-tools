-- PROBE GAUDI SEARCH TABLE 0.1.0 -- 0.7.13 검색표 훅이 어디서 새는가.
-- ★순수 관측 · 쓰기 0 B
--
-- 동굴 구조 (0.7.13, `build_gaudi_search_table_hook.py` 에서 역산)
--   $BE56  입구 (PHX · read_ptr 초기화)
--   $BE61  next      레코드 머리로
--   $BE6B  compare   표 바이트 vs 입력 $363D,Y
--   $BE7E  skip      다음 레코드로
--   $BE9F  matched   원본 키를 입력 버퍼에 덮어쓴다
--   $BEB8  done      못 찾았으면 원래 명령 복구하고 RTS
--   $BEC0/$BEC1      read_ptr (지금 보는 레코드의 CPU 주소)
--   $BEC3            표 시작
--
-- 입력 버퍼는 $363E 부터 FF 로 끝난다.
--
-- 쓰는 법  로드 -> 가우디에서 이름 입력하고 결정 -> 여러 개 해봐도 된다 -> Stop
-- 산출물   C:/snatcher/dump/gaudi_search_table_v010.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local OUT = "C:/snatcher/dump/gaudi_search_table_v010.tsv"
local INPUT = 0x363E
local TABLE = 0xBEC3
local rows, nth = {}, 0
local pending = nil

local function rb(at) return emu.read(at, MEM) or 0 end
local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end
local function mpr(s, n) return (s["memoryManager.mpr[" .. n .. "]"] or -1) % 256 end
local function hex(at, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format("%02X", rb(at + i)) end
  return table.concat(t, " ")
end
local function inputbytes()
  local t = {}
  for i = 0, 23 do
    local b = rb(INPUT + i)
    t[#t + 1] = string.format("%02X", b)
    if b == 0xFF then break end
  end
  return table.concat(t, " ")
end
local function record_index(ptr)
  -- read_ptr 가 표 시작에서 몇 번째 레코드인지 센다 (표를 그대로 걸어간다)
  local at, n = TABLE, 0
  while at < ptr and n < 64 do
    local len = rb(at)
    if len == 0 then return -1 end
    at = at + 1 + len
    while rb(at) ~= 0xFF and at < TABLE + 0x400 do at = at + 1 end
    at = at + 1
    n = n + 1
  end
  return (at == ptr) and n or -1
end

emu.addMemoryCallback(function()
  local s = st()
  nth = nth + 1
  pending = { n = nth, input = inputbytes(), mpr5 = mpr(s, 5), matched = "", rec = "", after = "" }
end, emu.callbackType.exec, 0xBE56, 0xBE56, CPU, MEM)

emu.addMemoryCallback(function()
  if not pending then return end
  local ptr = rb(0xBEC0) | (rb(0xBEC1) << 8)
  pending.matched = "MATCH"
  pending.rec = string.format("$%04X #%d", ptr, record_index(ptr))
end, emu.callbackType.exec, 0xBE9F, 0xBE9F, CPU, MEM)

emu.addMemoryCallback(function()
  if not pending then return end
  local ptr = rb(0xBEC0) | (rb(0xBEC1) << 8)
  if pending.matched == "" then
    pending.matched = "no-match"
    pending.rec = string.format("$%04X #%d 까지 봄", ptr, record_index(ptr))
  end
  pending.after = inputbytes()
  rows[#rows + 1] = pending
  emu.log(string.format("#%d %s  입력 %s  -> %s", pending.n, pending.matched,
    pending.input, pending.after))
  pending = nil
end, emu.callbackType.exec, 0xBEB8, 0xBEB8, CPU, MEM)

emu.addEventCallback(function()
  local f = assert(io.open(OUT, "w"))
  f:write("n\tresult\trecord\tmpr5\tinput_before\tinput_after\n")
  for _, r in ipairs(rows) do
    f:write(string.format("%d\t%s\t%s\t$%02X\t%s\t%s\n",
      r.n, r.matched, r.rec, r.mpr5, r.input, r.after))
  end
  f:close()
  emu.log(string.format("GAUDI SEARCH TABLE 0.1.0 -> %s  (%d 건)", OUT, #rows))
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI SEARCH TABLE 0.1.0 loaded -- 이름 몇 개 넣어보고 Stop")
