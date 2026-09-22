-- SUB 0.5.172 -- CD-DA 정지 신호 찾기 (0.5.171 + BIOS 점프표 감시)
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 스케줄러는 elapsed 를 프레임마다 올릴 뿐 **트랙이 멈춘 걸 모른다.**
-- 그래서 오프닝을 스킵하면 (2026-09-04 실기):
--
--     첫 자막 전 스킵   ready=$FF 라 아무것도 안 그리고 STATE=2 에 갇힌다
--                       -> $5B80 을 안 돌려줘 게임이 검은 화면
--     첫 자막 후 스킵   구간이 계속 뜨고, stage 31 B 복사가 39 번 돌며
--                       게임이 되찾은 RAM 을 반복해 뭉갠다 -> 화면 파손
--
-- 옛 판(자체 타이머)에는 이 증상이 없었다.  36~45 초 **밖에서는 아무것도 안 하고**
-- 45 초에 스스로 STATE=3 을 썼기 때문이다.  즉 정지를 감지한 게 아니라 손대는
-- 범위가 9 초 · 2 회로 작았을 뿐이다.  스케줄러는 2 분 동안 39 번 쓴다.
--
-- 그래서 **진짜 정지 신호**가 필요하다.  전례 하나는 이미 폐기됐다:
--     0.4.6.23  ($263C | $2638) == 0 이면 정지
--     0.4.6.24  ★그건 지속 상태가 아니라 1 프레임짜리 시작 펄스였다
--
-- 무엇을 보나
-- -----------
--   1  메모리 후보 (값이 바뀔 때만 기록)
--        $26F9   cdda_check 가 트랙 판정에 쓰는 값 (& $7F == $11 이면 트랙 17)
--        $263C   accepted/waiting
--        $2638   actual track playing
--        $20A2   현재 트랙 (BCD)
--        $20A7~9 절대 MSF (BCD)
--        $7FDF   STATE
--        $180D   ADPCM playing bit (대조군)
--
--   2  ★BIOS 점프표 호출  $E000-$E05F
--        스킵하면 게임은 CD 오디오를 멈추라고 **BIOS 를 부를 수밖에 없다.**
--        표의 각 엔트리(3 B 간격)에 실행 콜백을 걸어 무엇이 언제 불리는지 센다.
--        메모리 값이 안 바뀌어도 이건 잡힐 가능성이 크다.
--        ⚠ 뱅크 $00 이 매핑돼 있을 때의 $E000-$E05F 다.  우리 창(뱅크 $01)이
--          열려 있는 동안의 접촉과 섞이지 않게 $FFD4/$F050 로 창 상태를 따로 센다.
--
-- 어떻게 쓰나
-- -----------
--   1  0.4.7.6 으로 오프닝을 튼다
--   2  자막이 몇 줄 지나가게 둔다      (재생 중 상태를 본다)
--   3  ★스킵한다
--   4  10 초쯤 더 둔다                 (멈춘 뒤 상태를 본다)
--   5  스크립트를 멈춘다               (요약이 찍힌다)
--
-- 판정
-- ----
--   재생 중 내내 한 값이다가 스킵 뒤 달라진 주소 -> 그것이 정지 신호
--   스킵 직후에만 불린 BIOS 엔트리              -> 그것이 정지 호출.  훅 대상
--   둘 다 없으면 -> 이 범위로는 못 잡는다.  다른 길을 찾아야 한다
--
-- 산출물  C:/snatcher/dump/cdda_stop_0_5_172_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_stop_0_5_172_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tname\taddr\told\tnew\n')

local function say(m) emu.log(m); print(m) end

local WATCH = {
  { name = 'trk_26F9', addr = 0x26F9 },
  { name = 'acc_263C', addr = 0x263C },
  { name = 'ply_2638', addr = 0x2638 },
  { name = 'sq_trk',   addr = 0x20A2 },
  { name = 'sq_m',     addr = 0x20A7 },
  { name = 'sq_s',     addr = 0x20A8 },
  { name = 'sq_f',     addr = 0x20A9 },
  { name = 'STATE',    addr = 0x7FDF },
  { name = 'adpcm',    addr = 0x180D },
}

local frame = 0
local last, changes, hold = {}, {}, {}
local rows = 0
for _, w in ipairs(WATCH) do
  last[w.name] = -1; changes[w.name] = 0; hold[w.name] = {}
end

-- ---- BIOS 점프표 --------------------------------------------------------
-- 뱅크 $01 창이 열려 있는 동안은 같은 주소가 우리 코드다.  창 상태를 따로 센다.
local bank1 = false
emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

local ENTRY_LO, ENTRY_HI = 0xE000, 0xE05F
local calls = {}          -- addr -> 호출 수 (창이 닫혀 있을 때만)
local firstAt = {}        -- addr -> 처음 불린 프레임
local lastAt = {}         -- addr -> 마지막으로 불린 프레임
for a = ENTRY_LO, ENTRY_HI, 3 do
  local at = a
  emu.addMemoryCallback(function()
    if bank1 then return end            -- 우리 창이 열려 있으면 우리 코드다
    calls[at] = (calls[at] or 0) + 1
    if not firstAt[at] then
      firstAt[at] = frame
      if rows < 600 then
        rows = rows + 1
        say(('f%-7d BIOS  $%04X  처음 불림'):format(frame, at))
        out:write(('%d\tBIOS\tfirst\t%04X\t\t\n'):format(frame, at))
        out:flush()
      end
    end
    lastAt[at] = frame
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

-- ---- 프레임마다 메모리 후보 확인 -----------------------------------------
emu.addEventCallback(function()
  frame = frame + 1
  for _, w in ipairs(WATCH) do
    local v = emu.read(w.addr, MEM, false) or -1
    local prev = last[w.name]
    if v ~= prev then
      last[w.name] = v
      if prev ~= -1 then
        changes[w.name] = changes[w.name] + 1
        if rows < 600 then
          rows = rows + 1
          say(('f%-7d MEM   %-9s $%04X  $%02X -> $%02X')
                :format(frame, w.name, w.addr, prev, v))
          out:write(('%d\tMEM\t%s\t%04X\t%02X\t%02X\n')
                      :format(frame, w.name, w.addr, prev, v))
          out:flush()
        end
      end
    end
    local t = hold[w.name]
    t[v] = (t[v] or 0) + 1
  end
  if frame % 600 == 0 then
    local parts = {}
    for _, w in ipairs(WATCH) do
      parts[#parts + 1] = ('%s=$%02X'):format(w.name, last[w.name])
    end
    say(('심박 f%-7d  %s'):format(frame, table.concat(parts, ' ')))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝 -- 메모리 후보 (값별 체류 프레임 수)')
  out:write('#\n# 메모리 후보\n')
  for _, w in ipairs(WATCH) do
    local vals = {}
    for v, n in pairs(hold[w.name]) do vals[#vals + 1] = { v = v, n = n } end
    table.sort(vals, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(#vals, 5) do
      parts[#parts + 1] = ('$%02X x%d'):format(vals[i].v, vals[i].n)
    end
    local line = ('  %-9s $%04X  변화 %-4d  %s')
                   :format(w.name, w.addr, changes[w.name],
                           table.concat(parts, ' · '))
    say(line); out:write('# ' .. line .. '\n')
  end

  say('')
  say('끝 -- BIOS 점프표 호출 (처음/마지막 프레임)')
  out:write('#\n# BIOS 점프표\n')
  local addrs = {}
  for a in pairs(calls) do addrs[#addrs + 1] = a end
  table.sort(addrs)
  if #addrs == 0 then
    say('  ★한 번도 안 불렸다 -- 창 판별이 잘못됐거나 이 범위가 아니다')
  end
  for _, a in ipairs(addrs) do
    local line = ('  $%04X  x%-6d  처음 f%-7d  마지막 f%d')
                   :format(a, calls[a], firstAt[a], lastAt[a])
    say(line); out:write('# ' .. line .. '\n')
  end
  out:close()
  say('')
  say('  읽는 법:')
  say('   · 재생 중 내내 한 값이다가 스킵 뒤 달라진 주소  -> 정지 신호')
  say('   · 스킵한 프레임 근처에서 처음 불린 BIOS 엔트리  -> 정지 호출.  훅 대상')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.172-cdda-stop-signal armed -- 순수 관측')
say('  오프닝 재생 -> 자막 몇 줄 -> ★스킵 -> 10 초 더 -> 스크립트 정지')
say('  스킵한 대략의 프레임을 기억해 두면 읽기 쉽다 (심박이 600 프레임마다 찍힌다)')
say('  ' .. PATH)
