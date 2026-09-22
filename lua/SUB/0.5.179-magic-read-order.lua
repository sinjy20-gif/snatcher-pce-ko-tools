-- 반납된 값을 **누가 보기는 하는가**.  0.5.179
--
-- 답해야 할 질문 하나
-- -------------------
-- ADPCM 엔진 재사용 표식을 `$5E1D` 에 두려는데, 반납(671 B)이 매 음성마다 그 자리를
-- 게임 저장분으로 덮는다.  반납이 `$5E1D` 를 비켜 가게 하려면 +9 B 가 필요한데
-- `cpu_cache` 여유가 **0 B** 다 ($FD1F 부터 CD-DA 렌더러 402 B).
--
-- 0 B 로 되는 길이 하나 있다 -- 마지막 덩이를 `159 -> 157` 로 줄이는 것.
-- 그러면 `$5E1D` 와 **`$5E1E`(media_magic)** 가 둘 다 반납에서 빠진다.
-- `$5E1E` 는 디스패처가 프레임당 ~0.8 회 **읽는** 자리라 그냥 뺄 수 없다.
--
--     ★ 그런데 이건 잴 수 있다:
--       **반납된 값이 다음 적재 전에 읽히는 일이 있는가?**
--
--     없으면 반납된 값은 아무도 안 보는 값이고, 빼도 **관측상 무변화**다.
--     동작 변경이 검증된 no-op 로 바뀐다.
--
-- 어떻게 재나 -- 가정을 안 넣는다
-- -------------------------------
-- "어느 PC 가 반납이고 어느 PC 가 적재인가" 를 **미리 정하지 않는다.**
-- 오늘 범위·뱅크를 단정해서 네 번 틀렸다.  대신 **순서만** 적는다:
--
--     읽기가 날 때마다, 그 자리의 **직전 쓰기 PC** 를 같이 센다.
--     -> `읽기@$F3F6  <-  직전쓰기@$FD19` 같은 짝이 몇 번인지가 곧 답이다.
--
-- 오늘 역어셈으로 확인해 둔 것 (판정에 쓰지 말고 **대조용**으로만 볼 것):
--
--     $FD16 STA $5D80,X / $FD19 INX   반납  (patch_bios_cpu_cache · 라벨 r2)
--     $7FD6 STA $5D80,X / $7FD9 INX   적재  (상주부 렌더러 복사 · 소스가 $7FBB 라 부름)
--     ★ 프로브가 보고하는 PC 는 **쓰기 명령의 다음 명령**이다.  두 건 다 그랬다.
--
-- 읽는 법
-- -------
--     $5E1E 읽기가 **전부** 적재 뒤에만 온다        -> 반납에서 빼도 된다.  0 B 로 끝
--     $5E1E 읽기가 반납 뒤에도 온다                 -> ★ 못 뺀다.  다른 길을 찾아야 한다
--     $5E1D 를 우리 말고 누가 읽는다                -> ★ 그 자리는 애초에 포기
--
-- ⚠ 한 장면으로 판정하지 말 것.  음성이 여러 번 끝나야(= 반납이 여러 번 돌아야)
--   판정에 쓸 표본이 쌓인다.  `반납 뒤 읽기 0` 이 `반납 횟수 0` 때문이면 아무 뜻이 없다
--   -- 그래서 **쓰기 PC별 횟수도 같이** 찍는다 (반납이 실제로 돌았는지 확인용).
--
-- 산출물  C:/snatcher/dump/magic_order_0_5_179_<시각>.tsv
--
-- ★ 화면에 아무것도 안 그리고 게임 메모리에도 안 쓴다.  순수 관측이다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local MARK, MAGIC = 0x5E1D, 0x5E1E

local OUT = 'C:/snatcher/dump/magic_order_0_5_179_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tevent\taddr\tpc\tprev_write_pc\tgap_frames\n') end

local PC_KEY
local function pcnow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc', 'cpu.PC' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and (math.floor(v) & 0xFFFF) or -1
end

local frame = 0
local lastW = {}                  -- addr -> { pc, frame }
local writes = {}                 -- "addr|pc"      -> 횟수
local pairs_ = {}                 -- "addr|rpc|wpc" -> { n, gapMin, gapMax }
local order = {}                  -- pairs_ 키 순서
local wOrder = {}
local nRead, nWrite = 0, 0

local function hx(v) return v < 0 and '----' or string.format('%04X', v) end

emu.addMemoryCallback(function(address)
  local pc = pcnow()
  lastW[address] = { pc = pc, frame = frame }
  local k = string.format('%04X|%04X', address, pc & 0xFFFF)
  if writes[k] == nil then writes[k] = 0; wOrder[#wOrder + 1] = { addr = address, pc = pc, key = k } end
  writes[k] = writes[k] + 1
  nWrite = nWrite + 1
  if out then
    out:write(string.format('%d\twrite\t%04X\t%s\t-\t-\n', frame, address, hx(pc)))
  end
end, emu.callbackType.write, MARK, MAGIC, CPU, MEM)

emu.addMemoryCallback(function(address)
  local pc = pcnow()
  local w = lastW[address]
  local wpc = w and w.pc or -1
  local gap = w and (frame - w.frame) or -1
  local k = string.format('%04X|%04X|%04X', address, pc & 0xFFFF, wpc & 0xFFFF)
  local e = pairs_[k]
  if e == nil then
    e = { n = 0, lo = gap, hi = gap }
    pairs_[k] = e
    order[#order + 1] = { addr = address, rpc = pc, wpc = wpc, key = k }
    -- ★ TSV 에는 **처음 보는 짝만** 남긴다.  $5E1E 는 초당 수십 번 읽히므로
    --   전부 적으면 파일이 수십만 줄이 된다.  질문은 "어떤 짝이 존재하나" 다
    if out then
      out:write(string.format('%d\tread\t%04X\t%s\t%s\t%d\n',
                              frame, address, hx(pc), hx(wpc), gap))
      out:flush()
    end
  end
  e.n = e.n + 1
  if gap >= 0 then
    if e.lo < 0 or gap < e.lo then e.lo = gap end
    if gap > e.hi then e.hi = gap end
  end
  nRead = nRead + 1
end, emu.callbackType.read, MARK, MAGIC, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 ~= 0 then return end
  emu.log(string.format('0.5.179 %df · 읽기 %d · 쓰기 %d', frame, nRead, nWrite))

  -- ① 쓰기 PC 별 횟수 -- 반납이 **실제로 돌았는지** 확인용 (표본 있음의 증거)
  table.sort(wOrder, function(a, b) return (writes[a.key] or 0) > (writes[b.key] or 0) end)
  emu.log('        [쓴 놈]  addr   PC     횟수')
  for i = 1, math.min(#wOrder, 8) do
    local r = wOrder[i]
    emu.log(string.format('                 $%04X  $%s  %6d', r.addr, hx(r.pc), writes[r.key] or 0))
  end
  if #wOrder == 0 then emu.log('                 (아직 쓰기 없음)') end

  -- ② ★ 판정: 읽기와 그 직전 쓰기의 짝
  table.sort(order, function(a, b) return (pairs_[a.key].n) > (pairs_[b.key].n) end)
  emu.log('        [읽기 <- 직전쓰기]  addr   읽기PC   직전쓰기PC   횟수   간격(프레임)')
  for i = 1, math.min(#order, 12) do
    local r = order[i]
    local e = pairs_[r.key]
    emu.log(string.format('                 $%04X  $%s   $%s   %6d   %d~%d',
                          r.addr, hx(r.rpc), hx(r.wpc), e.n, e.lo, e.hi))
  end
  if #order == 0 then emu.log('                 (아직 읽기 없음)') end
  if #order > 12 then emu.log(string.format('                 ... %d 짝 더', #order - 12)) end

  -- ③ 자리별 한 줄 요약.  ⚠ 어느 PC 가 반납인지 **단정하지 않는다**
  for _, addr in ipairs({ MARK, MAGIC }) do
    local wset = {}
    for _, r in ipairs(order) do
      if r.addr == addr and r.wpc >= 0 then wset[hx(r.wpc)] = (wset[hx(r.wpc)] or 0) + pairs_[r.key].n end
    end
    local t = {}
    for k, n in pairs(wset) do t[#t + 1] = string.format('$%s:%d', k, n) end
    table.sort(t)
    emu.log(string.format('        $%04X 읽기의 직전쓰기 분포: %s',
                          addr, #t > 0 and table.concat(t, ' ') or '(읽기 없음)'))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.179-magic-read-order  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log('  묻는 것: **반납된 값이 다음 적재 전에 읽히는가**')
emu.log('    전부 적재 뒤에만 읽힌다 -> 반납에서 빼도 관측상 무변화 (0 B 로 끝)')
emu.log('    반납 뒤에도 읽힌다     -> ★ 못 뺀다')
emu.log('  대조용(오늘 역어셈 확인): $FD19=반납 · $7FD9=적재')
emu.log('    ★ 보고되는 PC 는 쓰기 명령의 **다음** 명령이다')
emu.log('  ⚠ 음성이 여러 번 끝나야 반납 표본이 쌓인다 -- [쓴 놈] 표로 확인할 것')
emu.log('  -> ' .. OUT)
