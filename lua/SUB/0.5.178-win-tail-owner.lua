-- 빌린 창 꼬리를 누가 건드리는가 + **그 놈 코드를 떠 온다**.  0.5.178
--
-- 0.5.178 이 알려준 것 / 틀린 것
-- ------------------------------
-- 알려준 것:
--   * 우리 반납은 `$FD19` 로 제대로 잡힌다 (cpu_cache = $FC7A-$FD1E).  프로브 정상.
--   * `$5E1E`(media_magic) 도 표에 나온다 -- **대조군 통과**.
--   * ★ 창밖 PC 가 **`$7FD9` 하나** 나왔다.  7 개 주소를 비슷한 횟수로 쓴다
--     -> 블록 전송(TII/TAI 계열) 하나가 창을 훑는 모양이다.
--
-- ⚠ 틀린 것: 0.5.178 의 판정 줄이 그걸 **`★ 못 쓴다`** 로 단정했다.
--   근거는 "PC 가 $5B80~$5E1E 밖 · $E000 밖" 뿐인데, `$7Fxx` 는 **우리도 쓰는 대역**이다
--   (`$7FDF`=STATE · `vars=$7FE0-$7FE7` · 상주부 `$7F4A`·`$7F52`·`$7F5E`).
--   범위로 단정하지 않겠다고 하고 판정 줄에서 똑같이 했다.  이 판은 **단정하지 않는다.**
--
-- 이 판이 더하는 것 -- 쓴 놈의 **코드를 떠 온다**
-- ----------------------------------------------
-- "주소가 아니라 routine 을 찾아라" 가 이 저장소의 규칙이다.  그래서 창밖 PC 를
-- 처음 보는 순간 그 주변 128 B 와 **MPR 8 개 전부**를 한 번 떠서 TSV 에 남긴다.
-- 역어셈은 오프라인에서 한다 -- 에뮬에서 눈으로 읽을 필요가 없다.
--
--     $7FD9 가 우리 상주부인가 게임인가 -> 이 덤프로 갈린다
--     블록 전송이면 원본/목적/길이가 명령 안에 즉치로 들어 있다 (TII $ssss,$dddd,$llll)
--
-- ⚠ MPR3 이 핵심이다.  `$6000-$7FFF` 는 뱅크가 바뀌는 창이라, 뱅크를 모르면
--   같은 주소라도 누구 코드인지 못 가른다 (오늘 MPR7 에서 똑같이 데였다).
--
-- 산출물  C:/snatcher/dump/win_tail_0_5_178_<시각>.tsv
--         C:/snatcher/dump/win_tail_0_5_178_<시각>_code.txt   <- ★ 역어셈용 덤프
--

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local CR = string.char(10)
local LO, HI = 0x5E18, 0x5E1E     -- 빌린 창 끝 7 바이트
local MARK, MAGIC = 0x5E1D, 0x5E1E

local OUT = 'C:/snatcher/dump/win_tail_0_5_178_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tkind\taddr\tpc\tmpr7\tmpr2\tvalue\n') end

local PC_KEY
local function ctx()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1, -1, -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc', 'cpu.PC' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  local pc = -1
  if PC_KEY ~= false then
    local v = s[PC_KEY]
    if type(v) == 'number' then pc = math.floor(v) & 0xFFFF end
  end
  local function mpr(n)
    local v = s[string.format('memoryManager.mpr[%d]', n)]
    if type(v) ~= 'number' then v = s[string.format('mpr[%d]', n)] end
    return type(v) == 'number' and (math.floor(v) & 0xFF) or -1
  end
  return pc, mpr(7), mpr(2)
end

local CODE = OUT:gsub('%.tsv$', '_code.txt')
local dumped = {}                 -- 이 PC 주변을 이미 떴는가
local frame = 0
local seen = {}                   -- "kind|addr|pc|mpr7" -> 횟수
local order = {}
local total = { r = 0, w = 0 }
local newRows = 0

local function hx(v, w)
  if v < 0 then return string.rep('-', w) end
  return string.format('%0' .. w .. 'X', v)
end

-- ★ 창밖 PC 를 처음 보면 그 주변 코드와 MPR 전부를 한 번 떠 둔다.
--   추측 대신 역어셈으로 정체를 밝히는 것이 이 저장소의 규칙이다
local function dump_code(pc)
  if pc < 0 or dumped[pc] then return end
  dumped[pc] = true
  local f = io.open(CODE, 'a')
  if not f then return end
  local lo = (pc - 64) & 0xFFF0
  f:write(string.format('=== PC $%04X (frame %d) · 덤프 $%04X~$%04X' .. CR,
                        pc, frame, lo, lo + 127))
  local ok, s = pcall(emu.getState)
  if ok and type(s) == 'table' then
    local parts = {}
    for n = 0, 7 do
      local v = s[string.format('memoryManager.mpr[%d]', n)]
      if type(v) ~= 'number' then v = s[string.format('mpr[%d]', n)] end
      parts[#parts + 1] = string.format('MPR%d=%s', n,
        type(v) == 'number' and string.format('%02X', math.floor(v) & 0xFF) or '??')
    end
    f:write('    ' .. table.concat(parts, ' ') .. CR)
  end
  for row = 0, 7 do
    local at = lo + row * 16
    local bytes = {}
    for i = 0, 15 do
      local okr, b = pcall(emu.read, at + i, MEM)
      bytes[#bytes + 1] = (okr and type(b) == 'number')
                          and string.format('%02X', b & 0xFF) or '??'
    end
    f:write(string.format('    $%04X  %s' .. CR, at, table.concat(bytes, ' ')))
  end
  f:write(CR)
  f:close()
  emu.log(string.format('        ★ $%04X 주변 코드를 떴다 -> %s', pc, CODE))
end

local function hint(pc)
  if pc < 0 then return '?' end
  if pc >= 0x5B80 and pc <= 0x5E1E then return '창안(우리 엔진/헬퍼)' end
  if pc >= 0xE000 then return 'BIOS대역(MPR7로 갈림)' end
  return '★창밖 -- 게임일 수 있다'
end

local function note(kind, addr, value)
  local pc, m7, m2 = ctx()
  local key = string.format('%s|%04X|%04X|%02X', kind, addr, pc & 0xFFFF, m7 & 0xFF)
  if seen[key] == nil then
    seen[key] = 0
    order[#order + 1] = { kind = kind, addr = addr, pc = pc, m7 = m7, m2 = m2, key = key }
    newRows = newRows + 1
    -- ★ TSV 에는 **처음 보는 조합만** 남긴다.  게임이 창을 두드리면 수십만 줄이
    --   되는데, 우리가 답해야 할 질문은 "누가 건드리나" 라서 조합만으로 충분하다
    if out then
      out:write(string.format('%d\t%s\t%04X\t%04X\t%02X\t%02X\t%s\n',
                              frame, kind, addr, pc & 0xFFFF, m7 & 0xFF, m2 & 0xFF,
                              value == nil and '-' or string.format('%02X', value & 0xFF)))
      out:flush()
    end
  end
  if kind == 'write' and pc >= 0 and (pc < 0x5B80 or (pc > 0x5E1E and pc < 0xE000)) then
    dump_code(pc)
  end
  seen[key] = seen[key] + 1
  total[kind == 'read' and 'r' or 'w'] = total[kind == 'read' and 'r' or 'w'] + 1
end

emu.addMemoryCallback(function(address, value)
  note('write', address, value)
end, emu.callbackType.write, LO, HI, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  note('read', address, value)
end, emu.callbackType.read, LO, HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 ~= 0 then return end
  emu.log(string.format('0.5.178 %df · 읽기 %d · 쓰기 %d · 조합 %d 종',
                        frame, total.r, total.w, #order))
  if #order == 0 then
    emu.log('        아직 아무도 안 건드렸다 -- 장면을 더 돌아다닐 것')
    return
  end
  table.sort(order, function(a, b) return (seen[a.key] or 0) > (seen[b.key] or 0) end)
  emu.log('        addr  kind   PC    MPR7 MPR2   횟수   힌트')
  for i = 1, math.min(#order, 14) do
    local r = order[i]
    emu.log(string.format('        $%s %-5s $%s  %s   %s  %6d   %s',
                          hx(r.addr, 4), r.kind, hx(r.pc, 4), hx(r.m7, 2),
                          hx(r.m2, 2), seen[r.key] or 0, hint(r.pc)))
  end
  if #order > 14 then emu.log(string.format('        ... %d 종 더', #order - 14)) end

  -- ★ 판정에 쓰는 두 줄.  자리별로 **창밖 PC** 가 있었는지만 본다
  for _, addr in ipairs({ MARK, MAGIC }) do
    local outside, inside = 0, 0
    for _, r in ipairs(order) do
      if r.addr == addr then
        if r.pc >= 0 and (r.pc < 0x5B80 or (r.pc > 0x5E1E and r.pc < 0xE000)) then
          outside = outside + (seen[r.key] or 0)
        else
          inside = inside + (seen[r.key] or 0)
        end
      end
    end
    local tag = (addr == MARK) and '★표식 후보' or ' media_magic(대조군)'
    -- ⚠ **단정하지 않는다.**  `$7Fxx` 처럼 우리도 쓰는 대역이 '창밖' 으로 잡힌다.
    --   0.5.177 이 여기서 `못 쓴다` 로 못박았는데 그건 근거를 넘은 말이었다.
    local who = {}
    for _, r in ipairs(order) do
      if r.addr == addr and r.pc >= 0
         and (r.pc < 0x5B80 or (r.pc > 0x5E1E and r.pc < 0xE000)) then
        who[string.format('$%04X', r.pc)] = true
      end
    end
    local list = {}
    for k in pairs(who) do list[#list + 1] = k end
    table.sort(list)
    emu.log(string.format('        $%04X %s · 창밖 %d (%s) · 그 외 %d   %s',
                          addr, tag, outside,
                          #list > 0 and table.concat(list, ',') or '없음', inside,
                          outside > 0 and '-> ★ 그 PC 정체를 밝혀야 판정된다'
                                       or '-> 아직 창밖 접촉 없음'))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.178-win-tail-owner  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log(string.format('  보는 곳: CPU $%04X~$%04X (빌린 창 $5B80-$5E1E 의 끝 7 B)', LO, HI))
emu.log('  묻는 것: **게임이 $5E1D 를 건드리는가** -- 안 건드리면 반납에서 뺄 수 있다')
emu.log('  $5E1E(media_magic)은 우리가 이미 쓰는 자리다 -> 표에 나오면 프로브 정상 (대조군)')
emu.log('  ⚠ 한 장면으로 판정하지 말 것.  "안 걸렸다" 는 "아직 못 봤다" 일 수 있다')
emu.log('  -> ' .. OUT)
emu.log('  -> ' .. CODE .. '   ★ 창밖 PC 주변 코드 덤프 (역어셈용)')
