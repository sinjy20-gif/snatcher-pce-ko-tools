-- 빌린 창 **꼬리**를 누가 건드리는가.  0.5.177
--
-- 왜 이것이 필요한가
-- ------------------
-- ADPCM 엔진 재사용(`--adpcm-reuse`)이 0.7.25 에서 **한 번도 안 걸렸다.**
-- `e` 값이 0.7.24 와 한 자리도 다르지 않았다 (747·721·747·734·734·708·734).
--
-- 원인은 표식 자리였다.  표식을 CPU `$5E1D` 에 뒀는데, 음성이 끝나면
-- `patch_bios_cpu_cache.py` 가 빌린 RAM 을 **통째로 반납**한다:
--
--     for page, (dst, count) in ((0x5B80,256), (0x5C80,256), (0x5D80,159)):
--     -> 256+256+159 = 671 = $5B80~$5E1E **전체**
--
-- 그래서 표식이 매 음성마다 게임 원래 값으로 덮인다 -> 다음 arm 은 무조건 miss.
-- (헬퍼가 $5D3F 에서 끝나 안 닿는 것은 확인했는데 **반납**을 빠뜨렸다.)
--
-- 남은 길은 반납 코드가 우리 것이라는 점을 쓰는 것이다 -- `$5E1D` **한 바이트만**
-- 반납에서 빼면 표식이 살아남는다.  조건은 하나:
--
--     ★ 게임이 그 바이트를 정말 안 쓰는가
--
-- 안 쓴다는 증명 없이 빼면 대사 버퍼 한 칸을 망가뜨린다.
-- "FF 라서 비었겠지" 는 근거가 아니다 (2026-09-17 에 그 부류로 두 번 틀렸다).
--
-- 무엇을 보나
-- -----------
-- `$5E18~$5E1E` (창 끝 7 바이트) 의 **읽기와 쓰기**를 전부 잡고, 그때의
-- **PC 와 MPR7** 을 적는다.  한 바이트만 보면 "꼬리를 아무도 안 쓴다" 인지
-- "이 바이트만 안 쓴다" 인지 못 가른다.
--
--     $5E1D  = 슬롯 offset 669.  ★ 우리가 표식으로 쓰려는 자리
--     $5E1E  = 슬롯 offset 670.  media_magic($CD).  **우리가 이미 쓰고 있다**
--                                -> 이 자리가 표에 우리 PC 로 나오면 프로브가
--                                   제대로 도는 증거다 (대조군)
--
-- ⚠ 범위로 "우리 것/게임 것" 을 **미리 가르지 않는다.**
--   오늘 그렇게 단정해서 세 번 틀렸다 (MPR7 뱅크 · 지문 자리 · 반납 범위).
--   PC 를 날것으로 찍고 아래 힌트만 붙인다 -- 판단은 표를 보고 한다.
--
--     PC $5B80~$5E1E    우리 엔진/헬퍼가 그 창에서 실행 중
--     PC $E000~$FFFF    BIOS 대역.  ★MPR7 로 갈린다 ($00 케이브 · $01 우리 뱅크1)
--     그 밖            게임 코드일 가능성이 크다  <- 이것이 나오면 그 바이트는 못 쓴다
--
-- ⚠ 한 장면만 보고 판정하지 말 것.  여러 장면·여러 대사창을 지나야 한다.
--   "안 걸렸다" 는 "안 쓴다" 가 아니라 "아직 못 봤다" 일 수 있다.
--
-- 쓰는 법
-- -------
--   1) Power Cycle 로 판을 띄운다 (BIOS 와 CUE 둘 다 그 폴더)
--   2) 이 파일 **하나만** 연다
--   3) 대사·음성·국장실·이동 등 **여러 장면**을 돌아다닌다
--   4) 600 프레임마다 표가 찍힌다.  ★ Stop 을 눌러야 마지막 줄이 파일에 남는다
--
-- 산출물  C:/snatcher/dump/win_tail_0_5_177_<시각>.tsv
--
-- ★ 화면에 아무것도 안 그리고 게임 메모리에도 안 쓴다.  순수 관측이다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local LO, HI = 0x5E18, 0x5E1E     -- 빌린 창 끝 7 바이트
local MARK, MAGIC = 0x5E1D, 0x5E1E

local OUT = 'C:/snatcher/dump/win_tail_0_5_177_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
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

local frame = 0
local seen = {}                   -- "kind|addr|pc|mpr7" -> 횟수
local order = {}
local total = { r = 0, w = 0 }
local newRows = 0

local function hx(v, w)
  if v < 0 then return string.rep('-', w) end
  return string.format('%0' .. w .. 'X', v)
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
  emu.log(string.format('0.5.177 %df · 읽기 %d · 쓰기 %d · 조합 %d 종',
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
    emu.log(string.format('        $%04X %s · 창밖PC %d · 그 외 %d   %s',
                          addr, tag, outside, inside,
                          outside > 0 and '-> ★ 못 쓴다' or '-> 아직 창밖 접촉 없음'))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.177-win-tail-owner  ★ 읽기 전용 · 아무것도 안 깐다')
emu.log(string.format('  보는 곳: CPU $%04X~$%04X (빌린 창 $5B80-$5E1E 의 끝 7 B)', LO, HI))
emu.log('  묻는 것: **게임이 $5E1D 를 건드리는가** -- 안 건드리면 반납에서 뺄 수 있다')
emu.log('  $5E1E(media_magic)은 우리가 이미 쓰는 자리다 -> 표에 나오면 프로브 정상 (대조군)')
emu.log('  ⚠ 한 장면으로 판정하지 말 것.  "안 걸렸다" 는 "아직 못 봤다" 일 수 있다')
emu.log('  -> ' .. OUT)
