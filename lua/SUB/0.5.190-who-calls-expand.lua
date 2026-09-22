-- SUB 0.5.190 -- 레코드 전개를 **누가** 11 번 부르는가  ★순수 관측 · 쓰기 0 B
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- 커서 한 칸 = 레코드 11 회 재전개 = AC 읽기 2,201 B ≈ 활성 구간 50 스캔라인.
-- 헬퍼 정문은 `JSR $7F88` 이고, 구운 바이트에서 요청 자리가 둘 나왔다:
--
--   $090016   slot = ($7FF1,$7FF2) + $84B5   -> STA $7FEF/$7FF0 -> JSR $7F88
--   $0900CA   slot = ($7FFC,$7FFD)           -> STA $7FEF/$7FF0 -> JSR $7F88
--
-- 이 둘을 **11 번 돌리는 바깥 루프**가 어디인지가 마지막 고리다.
-- 그 자리에 "이 줄은 안 바뀌었다" 조건을 걸면 11 -> 1~2 가 된다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- `$7F88` 이 실행되는 순간 스택 꼭대기에서 **복귀 주소**를 읽는다.
-- JSR 은 (복귀주소-1) 을 hi,lo 순으로 밀어 넣으므로
--     caller = (S+1 에 담긴 값 | S+2 << 8) + 1
-- 스택 페이지는 $2100-$21FF (HuC6280).
--
-- 같이 남기는 것
--     slot   = $7FEF | $7FF0<<8        어느 레코드를 달라고 했나
--     frame  · 프레임 안 몇 번째 호출인가
--
-- 판정
--   한 프레임에 caller 가 **한 자리에서 11 번**  -> 그 자리가 바깥 루프. 끝
--   caller 가 여러 자리로 흩어진다              -> 더 위에서 부른다. 그 목록이 단서
--   slot 11 개가 매번 **같은 값 순서**          -> 안 바뀐 줄을 다시 그리는 게 확정
--
-- 쓰는 법
--   1) 이것만 로드.  정상 속도
--   2) 메뉴 띄우고 커서를 서너 칸 움직인다
--   3) Stop -> _summary.txt
--
-- 산출물  C:/snatcher/dump/whocalls_0_5_190_<시각>_calls.tsv / _summary.txt

local ENTRY   = 0x7F88
local STACK   = 0x2100
local MAX_ROWS = 6000

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/whocalls_0_5_190_' .. STAMP

local cout = assert(io.open(BASE .. '_calls.tsv', 'w'))
cout:write('frame\tnth\tcaller\tslot\n')
cout:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return (ok and type(v)=='number') and v or -1 end

local SP_KEY
local function sp()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if SP_KEY == nil then
    SP_KEY = false
    for _, k in ipairs({'cpu.sp','cpu.stackPointer','cpu.s','sp'}) do
      if type(s[k]) == 'number' then SP_KEY = k break end
    end
  end
  if SP_KEY == false then return -1 end
  local v = s[SP_KEY]
  return type(v) == 'number' and (math.floor(v) & 0xFF) or -1
end

local frame, rows, total = 0, 0, 0
local perFrame = 0
local callerCount, pairCount = {}, {}
local maxPerFrame, maxFrame = 0, 0

emu.addMemoryCallback(function()
  local s = sp()
  local caller = -1
  if s >= 0 then
    local lo = rd(STACK + ((s + 1) & 0xFF))
    local hi = rd(STACK + ((s + 2) & 0xFF))
    if lo >= 0 and hi >= 0 then caller = ((lo | (hi << 8)) + 1) & 0xFFFF end
  end
  local slot = (rd(0x7FEF) & 0xFF) | ((rd(0x7FF0) & 0xFF) << 8)
  perFrame = perFrame + 1
  total = total + 1
  callerCount[caller] = (callerCount[caller] or 0) + 1
  local key = ('%04X/%04X'):format(caller, slot)
  pairCount[key] = (pairCount[key] or 0) + 1
  if rows < MAX_ROWS then
    rows = rows + 1
    cout:write(('%d\t%d\t$%04X\t$%04X\n'):format(frame, perFrame, caller, slot))
    cout:flush()
  end
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if perFrame > maxPerFrame then maxPerFrame, maxFrame = perFrame, frame end
  if perFrame >= 5 then
    say(('f%d  전개 호출 %d 회'):format(frame, perFrame))
  end
  perFrame = 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  cout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  put(('프레임 %d · 전개 호출 %d 회 · 한 프레임 최대 %d 회 (f%d)')
      :format(frame, total, maxPerFrame, maxFrame))
  local rowsC = {}
  for c, n in pairs(callerCount) do rowsC[#rowsC+1] = { c = c, n = n } end
  table.sort(rowsC, function(x, y) return x.n > y.n end)
  put(('부른 자리 %d 곳:'):format(#rowsC))
  for i = 1, math.min(#rowsC, 12) do
    put(('   $%04X   %d 회'):format(rowsC[i].c, rowsC[i].n))
  end
  local rowsP = {}
  for k, n in pairs(pairCount) do rowsP[#rowsP+1] = { k = k, n = n } end
  table.sort(rowsP, function(x, y) return x.n > y.n end)
  put(('(부른자리/슬롯) 조합 %d 개.  많은 순:'):format(#rowsP))
  for i = 1, math.min(#rowsP, 16) do
    put(('   %s   %d 회'):format(rowsP[i].k, rowsP[i].n))
  end
  put('')
  put('읽는 법: 같은 슬롯이 여러 번이면 안 바뀐 줄을 다시 그리는 것이다.')
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.190-who-calls-expand armed -- $7F88 실행 감시 · 쓰기 0 B')
say('  메뉴 띄우고 커서를 서너 칸 움직인 뒤 Stop')
say('  ' .. BASE .. '_calls.tsv')
