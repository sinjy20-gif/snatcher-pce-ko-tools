-- SUB 0.5.173 -- 스킵 누른 순간부터 CD-DA 정지까지 무슨 일이 일어나나
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 0.4.7.7 이 `$20A2 != $17` 로 정지를 잡아 스킵 파손을 없앴다.  그런데
-- **자막 도중** 스킵하면 자막이 2 개쯤 더 뜨고 멈춘다.  우리 검사는 매 프레임
-- 도니까 늦는 건 검사가 아니라 **신호 자체**다.
--
--     구간 간격 약 200~250 프레임 (3~4 초)
--     2 개 더 떴다 -> 누른 시점부터 $20A2 가 0 이 될 때까지 7~8 초
--
-- 게임이 CD 오디오를 **페이드아웃한 뒤** 멈추는 것으로 보인다.  그렇다면
-- 페이드를 시작하는 순간이 훨씬 빠른 신호다.  0.5.172 로그에 후보가 있다:
--
--     $E02D  x12   처음 f124  마지막 f23679      <- BIOS 점프표의 CD_FADE 자리
--
-- 무엇을 보나
-- -----------
--   1  패드 입력          스킵을 누른 **정확한 프레임**
--   2  BIOS 점프표 호출   $E000-$E05F 를 **매번** 기록한다
--                         단 매 프레임 폴링되는 것($E01B·$E045 류)은 50 회를
--                         넘으면 그 주소만 조용히 끈다 -- 로그가 안 터진다
--   3  $20A2 · $20A7~9    SUBQ 가 실제로 0 이 되는 프레임
--   4  $7FDF STATE        엔진이 언제 풀리나
--
-- 어떻게 쓰나
-- -----------
--   1  0.4.7.7 로 오프닝을 튼다
--   2  ★자막이 3~4 개 지나갈 때까지 둔다
--   3  ★스킵한다
--   4  10 초쯤 더 둔다
--   5  스크립트를 멈춘다   (요약이 찍힌다)
--
-- 읽는 법
-- -------
--   요약의 "스킵 타임라인" 을 본다:
--
--     누름 f?  ->  BIOS 호출들  ->  $20A2=0 f?
--
--   누름과 $20A2=0 사이에 불린 BIOS 엔트리가 있으면 **그것이 더 빠른 신호**다.
--   간격(프레임)이 곧 지금 지연이고, 그 엔트리로 바꾸면 얼마나 줄지도 나온다.
--   아무것도 없으면 $20A2 가 최선이고, 자막 2 개는 감수해야 한다.
--
-- 산출물  C:/snatcher/dump/skip_latency_0_5_173_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/skip_latency_0_5_173_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tname\tdetail\n')

local function say(m) emu.log(m); print(m) end

local frame = 0
local timeline = {}          -- 스킵 누른 뒤의 사건만 모은다
local pressedAt = nil
local stoppedAt = nil

local function note(kind, name, detail)
  out:write(('%d\t%s\t%s\t%s\n'):format(frame, kind, name, detail or ''))
  out:flush()
  if pressedAt and not stoppedAt then
    timeline[#timeline + 1] = ('  +%-5d f%-7d %-6s %s %s')
      :format(frame - pressedAt, frame, kind, name, detail or '')
  end
end

-- ---- 1) 패드 입력 --------------------------------------------------------
-- Mesen 판마다 API 가 달라 pcall 로 감싸고, 안 되면 조용히 끈다.
local inputOK = true
local heldBefore = ''
local function padState()
  local ok, s = pcall(emu.getInput, 0)
  if not ok or type(s) ~= 'table' then return nil end
  local parts = {}
  for k, v in pairs(s) do
    if v == true then parts[#parts + 1] = tostring(k) end
  end
  table.sort(parts)
  return table.concat(parts, '+')
end

-- ---- 2) BIOS 점프표 ------------------------------------------------------
local bank1 = false
emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

local LOUD = 50                 -- 이만큼 넘게 불리면 그 주소는 조용히 끈다
local calls, muted = {}, {}
for a = 0xE000, 0xE05F, 3 do
  local at = a
  calls[at] = 0
  emu.addMemoryCallback(function()
    if bank1 then return end
    calls[at] = calls[at] + 1
    if muted[at] then return end
    if calls[at] > LOUD then
      muted[at] = true
      note('BIOS', ('$%04X'):format(at), '이후 생략 (폴링)')
      return
    end
    note('BIOS', ('$%04X'):format(at), ('x%d'):format(calls[at]))
    if pressedAt and not stoppedAt then
      say(('★ +%-4d f%-7d BIOS $%04X  (누른 뒤)'):format(frame - pressedAt, frame, at))
    end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

-- ---- 3·4) 프레임마다 메모리 ---------------------------------------------
local WATCH = {
  { name = 'sq_trk', addr = 0x20A2 },
  { name = 'sq_m',   addr = 0x20A7 },
  { name = 'sq_s',   addr = 0x20A8 },
  { name = 'sq_f',   addr = 0x20A9 },
  { name = 'STATE',  addr = 0x7FDF },
}
local last = {}
for _, w in ipairs(WATCH) do last[w.name] = -1 end

emu.addEventCallback(function()
  frame = frame + 1

  if inputOK then
    local held = padState()
    if held == nil then
      inputOK = false
      say('  ⚠ 패드 입력을 못 읽는다 -- 누른 프레임은 $20A2 기준으로만 본다')
    elseif held ~= heldBefore then
      if held ~= '' then
        note('PAD', held, '')
        if not pressedAt and last['sq_trk'] == 0x17 then
          pressedAt = frame
          say(('★스킵 누름으로 본다  f%d  (%s)'):format(frame, held))
        end
      end
      heldBefore = held
    end
  end

  for _, w in ipairs(WATCH) do
    local v = emu.read(w.addr, MEM, false) or -1
    if v ~= last[w.name] then
      local prev = last[w.name]
      last[w.name] = v
      if prev ~= -1 then
        note('MEM', w.name, ('$%02X -> $%02X'):format(prev, v))
        if w.name == 'sq_trk' and prev == 0x17 and v ~= 0x17 and not stoppedAt then
          stoppedAt = frame
          say(('★CD-DA 정지 감지  f%d  ($17 -> $%02X)'):format(frame, v))
        end
        if w.name == 'STATE' and (v == 0x03 or v == 0x00) and stoppedAt then
          say(('  엔진 해제  f%-7d STATE -> $%02X'):format(frame, v))
        end
      end
    end
  end

  if frame % 600 == 0 then
    say(('심박 f%-7d  sq_trk=$%02X STATE=$%02X')
          :format(frame, last['sq_trk'], last['STATE']))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('#\n')
  say('')
  if pressedAt and stoppedAt then
    local gap = stoppedAt - pressedAt
    local line1 = ('스킵 타임라인 -- 누름 f%d  ->  정지 f%d   지연 %d 프레임 (약 %.1f 초)')
                    :format(pressedAt, stoppedAt, gap, gap / 60)
    say(line1); out:write('# ' .. line1 .. '\n')
    say('')
    say('  그 사이에 일어난 일:')
    out:write('# 그 사이에 일어난 일\n')
    for _, l in ipairs(timeline) do
      say(l); out:write('# ' .. l .. '\n')
    end
    say('')
    say('  ★누름과 정지 사이에 불린 BIOS 엔트리가 있으면 그것이 더 빠른 신호다.')
    say('   없으면 $20A2 가 최선이다.')
  elseif stoppedAt then
    say(('정지는 f%d 에 잡혔는데 누른 프레임을 못 골랐다 (패드 입력 못 읽음)')
          :format(stoppedAt))
  else
    say('★스킵이 안 잡혔다 -- 트랙 17 재생 중에 스킵했는지 확인할 것')
  end

  out:write('#\n# BIOS 점프표 총 호출 수\n')
  local addrs = {}
  for a, n in pairs(calls) do if n > 0 then addrs[#addrs + 1] = a end end
  table.sort(addrs)
  say('')
  say('BIOS 점프표 총 호출 수')
  for _, a in ipairs(addrs) do
    local l = ('  $%04X  x%d%s'):format(a, calls[a], muted[a] and '  (폴링, 로그 생략됨)' or '')
    say(l); out:write('# ' .. l .. '\n')
  end
  out:close()
  say('')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.173-skip-latency armed -- 순수 관측')
say('  오프닝 재생 -> 자막 3~4 개 지나가게 두기 -> ★스킵 -> 10 초 더 -> 스크립트 정지')
say('  ' .. PATH)
