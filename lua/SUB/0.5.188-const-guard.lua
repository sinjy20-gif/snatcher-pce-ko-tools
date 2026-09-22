-- SUB 0.5.188 -- 상수 sentinel 검사가 왜 매번 실패하나  ★순수 관측 · 쓰기 0 B
--
-- 어디까지 왔나 (0.5.187 실측)
-- ---------------------------------------------------------------------------
-- 커서 한 칸 = 레코드 11 회 재전개 = AC 읽기 2,201 B.  한 회가 정확히 200 B:
--
--     PACK  텍스트+메타   96 B   TEXT_SPAN = 0x60         ← 필요
--     TPL   상수 3 슬롯   96 B   CONST_SLOTS 3 x 32       ← 48 %.  매번 같은 바이트
--     DIR   엔트리         4 B
--     STATE 2 회           4 B
--
-- 그런데 헬퍼에는 그 96 B 를 건너뛰라고 넣어둔 검사가 있다:
--
--     LDA $5BE0 : CMP #first : BNE template_copy
--     LDA $5C3F : CMP #last  : BEQ template_done
--     (~14 사이클 vs 복사 593)
--
-- 11 회 전부 복사가 돌았다 -> **검사가 매번 실패한다.**  왜인지를 잰다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) `$5BE0-$5C3F` (상수 3 슬롯) 에 **누가 쓰는가** -- 주소 · PC · 프레임
--      헬퍼의 템플릿 전송 자신($BCD2-$BFFF)과 그 밖을 갈라서 센다
--      ★ 바깥에서 쓰는 게 있으면 그게 범인이다 (빌더 주석이 이미 의심하던 것)
--   2) sentinel 두 바이트 `$5BE0` · `$5C3F` 의 값을 매 프레임 표본으로 남긴다
--      값이 계속 흔들리면 (1) 이 맞고, 값이 고정인데도 복사가 돌면 sentinel
--      상수가 BIOS 판 데이터와 안 맞는 것이다
--
-- 판정
--   바깥 쓰기 > 0        -> ★ 그 PC 가 범인.  거기만 막으면 96 B x 11 이 사라진다
--   바깥 쓰기 = 0 이고
--   값이 고정            -> ★ sentinel 상수가 틀렸다.  검사가 영영 안 맞는다
--                           (또는 CONST_CHECK 가 이 빌드에서 꺼져 있다)
--
-- 쓰는 법
--   1) 이것만 로드.  정상 속도
--   2) 메뉴 띄우고 커서를 대여섯 칸 움직인다
--   3) Stop -> _summary.txt
--
-- 산출물  C:/snatcher/dump/constguard_0_5_188_<시각>_writes.tsv
--         C:/snatcher/dump/constguard_0_5_188_<시각>_summary.txt

local CONST_LO, CONST_HI = 0x5BE0, 0x5C3F     -- FONT_CACHE .. +95 (상수 3 슬롯)
local HELPER_LO, HELPER_HI = 0xBCD2, 0xBFFF   -- Bank 69 헬퍼 케이브
local MAX_ROWS = 4000
local REPORT   = 180

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/constguard_0_5_188_' .. STAMP

local wout = assert(io.open(BASE .. '_writes.tsv', 'w'))
wout:write('frame\taddr\tvalue\tpc\twho\n')
wout:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return (ok and type(v)=='number') and v or -1 end

local PC_KEY
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({'cpu.pc','cpu.programCounter','pc','cpu.PC'}) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and (math.floor(v) & 0xFFFF) or -1
end

local frame, rows = 0, 0
local inHelper, outHelper = 0, 0
local outPc, firstSeen = {}, {}
local sentA, sentB = {}, {}          -- sentinel 값 분포
local frameWrites = 0

emu.addMemoryCallback(function(address, value)
  local pc = pcNow()
  local who
  if pc >= HELPER_LO and pc <= HELPER_HI then
    inHelper = inHelper + 1
    who = 'HELPER'
  else
    outHelper = outHelper + 1
    who = 'OUTSIDE'
    outPc[pc] = (outPc[pc] or 0) + 1
    if firstSeen[pc] == nil then firstSeen[pc] = frame end
  end
  frameWrites = frameWrites + 1
  if rows < MAX_ROWS and who == 'OUTSIDE' then
    rows = rows + 1
    wout:write(('%d\t$%04X\t$%02X\t$%04X\t%s\n')
      :format(frame, address, (value or 0) & 0xFF, pc, who))
    wout:flush()
  end
end, emu.callbackType.write, CONST_LO, CONST_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local a, b = rd(CONST_LO), rd(CONST_HI)
  sentA[a] = (sentA[a] or 0) + 1
  sentB[b] = (sentB[b] or 0) + 1
  frameWrites = 0
  if frame % REPORT == 0 then
    say(('f%d  상수영역 쓰기  헬퍼 %d · 바깥 %d   sentinel $%02X/$%02X')
        :format(frame, inHelper, outHelper, a & 0xFF, b & 0xFF))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  wout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  put(('프레임 %d'):format(frame))
  put(('$%04X-$%04X 쓰기   헬퍼 안 %d · 헬퍼 바깥 %d'):format(CONST_LO, CONST_HI, inHelper, outHelper))
  if outHelper > 0 then
    put('★ 헬퍼 바깥에서 상수 영역을 덮는 놈이 있다 -- 이게 검사를 깨뜨린다')
    local rowsPc = {}
    for p, c in pairs(outPc) do rowsPc[#rowsPc+1] = { p = p, c = c } end
    table.sort(rowsPc, function(x, y) return x.c > y.c end)
    for i = 1, math.min(#rowsPc, 15) do
      put(('   PC $%04X  %d 회  (처음 f%d)')
          :format(rowsPc[i].p, rowsPc[i].c, firstSeen[rowsPc[i].p]))
    end
  else
    put('헬퍼 바깥 쓰기 0 -> 상수는 안 깨진다.  그런데도 복사가 돈다면')
    put('   sentinel 상수가 BIOS 판 데이터와 안 맞거나 CONST_CHECK 가 꺼진 빌드다')
  end
  local function dist(name, t)
    local r = {}
    for v, c in pairs(t) do r[#r+1] = { v = v, c = c } end
    table.sort(r, function(x, y) return x.c > y.c end)
    local parts = {}
    for i = 1, math.min(#r, 6) do
      parts[#parts+1] = ('$%02X x%d'):format(r[i].v & 0xFF, r[i].c)
    end
    put(('%s 값 분포 (%d 가지): %s'):format(name, #r, table.concat(parts, ' · ')))
  end
  dist(('sentinel A $%04X'):format(CONST_LO), sentA)
  dist(('sentinel B $%04X'):format(CONST_HI), sentB)
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.188-const-guard armed -- $5BE0-$5C3F 감시 · 쓰기 0 B')
say('  메뉴 띄우고 커서를 대여섯 칸 움직인 뒤 Stop')
say('  ' .. BASE .. '_writes.tsv')
