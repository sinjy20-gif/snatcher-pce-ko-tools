-- SUB 0.4.40-callflow -- 인계서 §8-A 호출 흐름 census
--
-- 목적 하나뿐이다:
--   "같은 ADPCM 재생 중 1->2 전환(90f)은 되는데 2->3 전환(180f)은 왜 안 되는가"
--   를 **호출 기회의 유무**로 답한다.
--
-- 이 스크립트는 emu.write 를 단 한 번도 하지 않는다.  게임/엔진/VRAM/AC 를
-- 수정하지 않는다.  아래 주소의 실행 횟수를 프레임마다 세어 TSV 로 적을 뿐이다.
--
--     $601E   디스크 훅 (게임 스프라이트 엔진 진입 · JSR $7FA0 로 덮여 있음)
--     $7FA0   상주 스텁
--     $5B83   engine entry     (ENGINE+3)
--     $5B91   rebuild          (ENGINE+17)
--     $5BF6   count_ok         (ENGINE+118)
--     $FEC4   음성 gate        (0.4.31 이 KEY 를 잡는 지점)
--     $E742   BIOS IRQ/ADPCM 대기 경로
--     $E74A   BIOS IRQ/ADPCM 대기 경로
--
-- 실제로 수정을 하는 쪽은 아래에서 dofile 하는 자막 스택이다.  기본값
-- SUB_CALLFLOW_STACK='0.4.38' 은 정지를 그대로 재현하는 조합이다.  정지 자체가
-- 이번 실험의 관측 대상이므로 의도적으로 그 판을 쓴다.  단 **한 음성 지나는
-- 짧은 측정만** 하고, 장시간 플레이는 하지 않는다 (인계서 §9).
--
-- 읽는 법 -- 요약이 답한다:
--   * 90f 구간에는 HOOK/ENTRY 가 오는데 180f 구간에 0 이면
--     -> 호출 기회 자체가 사라진 것이다.  §8-B (BIOS 경로에서 rebuild 호출) 로 간다.
--   * 180f 이후에도 HOOK/ENTRY 가 계속 오는데 COUNTOK 만 0 이면
--     -> 호출은 살아 있고 엔진 내부 색인 비교가 실패하는 것이다.  전혀 다른 수사다.
--
-- 사용:
--   Mesen -> Debug -> Script Window -> 이 파일 열기 -> Run
--   미카 3조각 음성 ADPCM_00309D_D000_0E 가 나오는 장면을 지난다.
--   음성이 끝나거나 정지하면 콘솔에 요약이 나오고 TSV 가 닫힌다.
--
-- 옵션 (스크립트 실행 전 전역으로 지정 가능):
--   SUB_CALLFLOW_STACK      '0.4.38'(기본) · '0.4.36' · 'none'(스택 없이 BIOS만)
--   SUB_CALLFLOW_MARKS      구간 경계 프레임.  기본 {90,180} = 미카 조각 시작
--   SUB_CALLFLOW_TAIL       ADPCM 이 끝난 뒤에도 더 볼 프레임 수.  기본 240
--   SUB_CALLFLOW_MAX_FRAMES 한 음성 창의 상한.  기본 1200
--   SUB_CALLFLOW_BIOS       $E742/$E74A 를 셀지.  기본 true
--   SUB_CALLFLOW_BIOS_CAP   한 프레임 BIOS 히트가 이걸 넘으면 자동으로 끈다

local VERSION  = '0.4.40-callflow'
local STACK    = rawget(_G, 'SUB_CALLFLOW_STACK') or '0.4.38'
local MARKS    = rawget(_G, 'SUB_CALLFLOW_MARKS') or { 90, 180 }
local TAIL     = rawget(_G, 'SUB_CALLFLOW_TAIL') or 240
local MAXF     = rawget(_G, 'SUB_CALLFLOW_MAX_FRAMES') or 1200
local BIOS     = rawget(_G, 'SUB_CALLFLOW_BIOS') ~= false
local BIOS_CAP = rawget(_G, 'SUB_CALLFLOW_BIOS_CAP') or 20000

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENGINE = 0x5B80
local READY  = ENGINE + 343
local SEL    = ENGINE + 345
local STATE  = 0x7FDF

-- 스택보다 먼저 원본 emu.log 를 잡아둔다.  allocator 가 뒤에서 emu.log 를
-- allocator_skip_log.tsv 로 가는 tee 로 바꾸기 때문이다.  우리 로그는 우리
-- 파일에만 남긴다.
local realLog = emu.log
local function say(msg) realLog(msg) end

-- ------------------------------------------------------------------ 덤프 경로
-- 판올림할 때 파일 이름도 같이 올린다.  코드 없이 읽을 수 있는 로그는 없다.
local RUN_TAG = os.date('%Y%m%d_%H%M%S')
local OUT = string.format('C:/snatcher/dump/callflow_0_4_40_%s.tsv', RUN_TAG)

-- ------------------------------------------------------------------ 스택 적재
if STACK ~= 'none' then
  dofile('C:/snatcher/lua/SUB/' .. STACK .. '.lua')
end

-- ------------------------------------------------------------------ 감시 지점
local WATCH = {
  { name = 'HOOK',    addr = 0x601E },
  { name = 'STUB',    addr = 0x7FA0 },
  { name = 'ENTRY',   addr = ENGINE + 3 },
  { name = 'REBUILD', addr = ENGINE + 17 },
  { name = 'COUNTOK', addr = ENGINE + 118 },
  { name = 'GATE',    addr = 0xFEC4 },
  { name = 'E742',    addr = 0xE742, bios = true },
  { name = 'E74A',    addr = 0xE74A, bios = true },
}

for _, w in ipairs(WATCH) do
  w.n, w.total, w.off = 0, 0, false
  if w.bios and not BIOS then
    w.off = true
  else
    w.ref = emu.addMemoryCallback(function()
      if w.off then return end
      w.n = w.n + 1
    end, emu.callbackType.exec, w.addr, w.addr, CPU, MEM)
  end
end

local function unwatch(w)
  w.off = true
  if w.ref then
    pcall(emu.removeMemoryCallback, w.ref, emu.callbackType.exec,
          w.addr, w.addr, CPU, MEM)
    w.ref = nil
  end
end

-- ------------------------------------------------------------------ 파일
local out = io.open(OUT, 'w')
if out then
  out:write(string.format('# SUB %s · stack=%s · %s\n', VERSION, STACK, RUN_TAG))
  local names = {}
  for _, w in ipairs(WATCH) do
    names[#names + 1] = string.format('%s=$%04X', w.name, w.addr)
  end
  out:write('# watch: ' .. table.concat(names, ' ') .. '\n')
  out:write('# 값은 그 프레임 동안의 실행 횟수(delta)다.  누적이 아니다.\n')
  local head = { 'run', 'frame', 'vf', 'play', 'endaddr', 'pc', 'state', 'ready', 'start' }
  for _, w in ipairs(WATCH) do head[#head + 1] = w.name end
  head[#head + 1] = 'sel9'
  out:write(table.concat(head, '\t') .. '\n')
  out:flush()
end

local function note(msg)
  say(msg)
  if out then out:write('# ' .. msg .. '\n'); out:flush() end
end

-- ------------------------------------------------------------------ 상태
local frame, run, vf, silence = 0, 0, 0, 0
local window = false
local buckets, lastSeen = nil, nil
local biosKilled = false

local function bucketOf(v)
  local n = 1
  for _, mark in ipairs(MARKS) do
    if v >= mark then n = n + 1 end
  end
  return n
end

local function bucketName(n)
  local lo = (n == 1) and 0 or MARKS[n - 1]
  local hi = MARKS[n]
  if hi then return string.format('%d..%d', lo, hi - 1) end
  return string.format('%d..end', lo)
end

local function openWindow()
  run, vf, silence, window = run + 1, 0, 0, true
  buckets, lastSeen = {}, {}
  for n = 1, #MARKS + 1 do
    local b = { frames = 0 }
    for _, w in ipairs(WATCH) do b[w.name] = 0 end
    buckets[n] = b
  end
  for _, w in ipairs(WATCH) do w.total = 0 end
  note(string.format('SUB %s ▶ run #%d 시작 · 구간 경계 %s',
                     VERSION, run, table.concat(MARKS, ',')))
end

local function closeWindow(reason)
  if not window then return end
  window = false
  note(string.format('SUB %s ■ run #%d 끝 (%s) · %d 프레임', VERSION, run, reason, vf))
  local head = { string.format('%-10s %6s', 'window', 'frames') }
  for _, w in ipairs(WATCH) do head[#head + 1] = string.format('%8s', w.name) end
  note('  ' .. table.concat(head, ' '))
  for n = 1, #buckets do
    local b = buckets[n]
    if b.frames > 0 then
      local row = { string.format('%-10s %6d', bucketName(n), b.frames) }
      for _, w in ipairs(WATCH) do row[#row + 1] = string.format('%8d', b[w.name]) end
      note('  ' .. table.concat(row, ' '))
    end
  end
  note('  마지막으로 온 프레임 (vf):')
  for _, w in ipairs(WATCH) do
    note(string.format('    %-8s %s · 총 %d',
                       w.name,
                       lastSeen[w.name] and tostring(lastSeen[w.name]) or '없음',
                       w.total))
  end
  -- 결론 한 줄.  이것 하나만 읽어도 다음 수사가 갈린다.
  local hookLast, entryLast = lastSeen.HOOK, lastSeen.ENTRY
  local tailMark = MARKS[#MARKS]
  if tailMark then
    if (not entryLast) or entryLast < tailMark then
      note(string.format('  ==> ENTRY 가 %df 전에 끊겼다.  호출 기회 소실이 맞다 -> §8-B 로', tailMark))
    elseif (buckets[#buckets] or {}).COUNTOK == 0 then
      note('  ==> 호출은 계속 왔는데 COUNTOK 만 0 이다.  엔진 색인 비교를 봐야 한다')
    else
      note('  ==> 마지막 구간에도 COUNTOK 가 있다.  정지 원인이 호출 경로가 아니다')
    end
    if hookLast and entryLast and hookLast > entryLast then
      note('  ==> HOOK 은 오는데 ENTRY 가 안 온다.  상주 스텁/gate 조건이 막는 것이다')
    end
  end
  if out then out:flush() end
end

-- ------------------------------------------------------------------ 프레임
local function hexbytes(at, count)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', emu.read(at + i, MEM) or 0)
  end
  return table.concat(t)
end

emu.addEventCallback(function()
  frame = frame + 1

  local ok, s = pcall(emu.getState)
  s = ok and s or nil
  local playing = s and s['cdrom.adpcm.playing'] == true
  local endaddr = 0
  if s then
    endaddr = ((s['cdrom.adpcm.readAddress'] or 0) +
               (s['cdrom.adpcm.adpcmLength'] or 0)) & 0xFFFF
  end
  local pc = (s and s['cpu.pc']) or 0
  if type(pc) ~= 'number' then pc = 0 end

  -- BIOS 카운터 폭주 방지.  음성 창 밖에서도 감시는 돌고 있으므로 여기서 본다.
  -- 에뮬이 못 쓸 만큼 느려지면 스스로 끈다.
  if not biosKilled then
    for _, w in ipairs(WATCH) do
      if w.bios and not w.off and w.n > BIOS_CAP then
        biosKilled = true
        note(string.format('SUB %s ! %s 가 한 프레임 %d 회를 넘겼다.  BIOS 카운터를 끈다',
                           VERSION, w.name, w.n))
      end
    end
    if biosKilled then
      for _, w in ipairs(WATCH) do if w.bios then unwatch(w) end end
    end
  end

  if playing and not window then openWindow() end

  if window then
    local b = buckets[bucketOf(vf)]
    b.frames = b.frames + 1
    local row = {
      run, frame, vf, playing and 1 or 0,
      string.format('%04X', endaddr),
      string.format('%04X', math.floor(pc)),
      string.format('%02X', emu.read(STATE, MEM) or 0),
      string.format('%02X', emu.read(READY, MEM) or 0),
      (emu.read(SEL + 7, MEM) or 0) | ((emu.read(SEL + 8, MEM) or 0) << 8),
    }
    for _, w in ipairs(WATCH) do
      row[#row + 1] = w.n
      b[w.name] = b[w.name] + w.n
      w.total = w.total + w.n
      if w.n > 0 then lastSeen[w.name] = vf end
    end
    row[#row + 1] = hexbytes(SEL, 9)
    if out then
      out:write(table.concat(row, '\t') .. '\n')
      out:flush()
    end

    -- 경계 프레임은 콘솔에도 한 줄 남긴다.  로그만 보고도 찾을 수 있게.
    for _, mark in ipairs(MARKS) do
      if vf == mark then
        local parts = {}
        for _, w in ipairs(WATCH) do
          parts[#parts + 1] = string.format('%s=%d', w.name, w.n)
        end
        note(string.format('SUB %s · vf=%d · ready=%02X sel=%s · %s',
                           VERSION, vf, emu.read(READY, MEM) or 0,
                           hexbytes(SEL, 9), table.concat(parts, ' ')))
      end
    end

    vf = vf + 1
    silence = playing and 0 or (silence + 1)
    if silence > TAIL then
      closeWindow('ADPCM 종료 후 ' .. TAIL .. '프레임')
    elseif vf > MAXF then
      closeWindow('상한 ' .. MAXF .. '프레임')
    end
  end

  for _, w in ipairs(WATCH) do w.n = 0 end

  -- HUD.  0.4.31 은 y=4, allocator 는 y=4/14/24 를 쓰므로 아래로 비켜 그린다.
  if window then
    emu.drawString(4, 44, string.format('%s run#%d vf=%d', VERSION, run, vf),
                   0x60C0FF, 0x000000)
    emu.drawString(4, 54, string.format('HOOK %d  ENTRY %d  CNT %d',
                   (WATCH[1] or {}).total or 0, (WATCH[3] or {}).total or 0,
                   (WATCH[5] or {}).total or 0), 0x60C0FF, 0x000000)
  else
    emu.drawString(4, 44, string.format('%s 대기 · 음성 기다림', VERSION),
                   0x808080, 0x000000)
  end
end, emu.eventType.endFrame)

-- ------------------------------------------------------------------ 안내
say('SUB ' .. VERSION .. ' -- 인계서 §8-A 호출 흐름 census · 쓰기 0')
say('  자막 스택: ' .. STACK .. (STACK == '0.4.38' and '  (정지 재현판 · 짧게만 돌린다)' or ''))
say('  덤프: ' .. OUT)
local names = {}
for _, w in ipairs(WATCH) do
  names[#names + 1] = string.format('%s=$%04X%s', w.name, w.addr, w.off and '(off)' or '')
end
say('  감시: ' .. table.concat(names, ' '))
say('  미카 3조각 음성 ADPCM_00309D_D000_0E 장면을 지나면 요약이 나온다')
