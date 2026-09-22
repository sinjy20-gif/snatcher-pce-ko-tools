-- SUB 0.4.42-callflow -- 0.4.40 의 창 분할 버그를 고친 호출 흐름 census
--
-- 0.4.40 은 "ADPCM 이 TAIL 프레임 이상 멈추면 창을 닫는다" 뿐이었다.  음성
-- 사이 간격이 20 프레임쯤이라 TAIL=240 이면 **여러 음성이 한 창에 뭉쳤다**.
-- 그래서 90/180 경계가 엉뚱한 음성 기준으로 잡혔고 자동 결론 줄이 틀렸다.
-- (0.4.40 파일과 그 덤프는 그대로 둔다.  로그는 그것을 만든 코드가 있어야 읽힌다.)
--
-- 이 판은 창을 **음성 하나**로 자른다:
--   * ADPCM 이 재생 중이고 end 주소가 창의 것과 다르면 -> 새 음성.  창을 바꾼다.
--     (재생이 멈춘 프레임의 end 주소는 쓰레기라 무시한다.  2프레임 연속 확인)
--   * 재생이 TAIL 프레임 넘게 멈추면 -> 창을 닫는다.  정지 뒤를 보기 위한 꼬리다.
--
-- 기본 스택이 0.4.41 이다 -- stage 재무장 수정판.  §8-C 통과 기준 중
-- "각 전환마다 count_ok 1회 이상"을 이 census 가 직접 센다.
--
-- 미카 ADPCM_00309D_D000_0E = end $D000 · 3조각 · 경계 90f / 180f
-- 기대: 그 창에서 REBUILD 3 · COUNTOK 3 · 정지 없음.
--
-- 이 스크립트는 emu.write 를 하지 않는다.  수정은 아래에서 부르는 스택이 한다.
--
-- 옵션:
--   SUB_CALLFLOW_STACK      '0.4.41'(기본) · '0.4.38'(정지 재현) · 'none'
--   SUB_CALLFLOW_MARKS      구간 경계.  기본 {90,180}
--   SUB_CALLFLOW_TAIL       재생이 멈춘 뒤 더 볼 프레임.  기본 240
--   SUB_CALLFLOW_MAX_FRAMES 한 창의 상한.  기본 1200
--   SUB_CALLFLOW_BIOS       $E742/$E74A 를 셀지.  기본 true
--   SUB_CALLFLOW_BIOS_CAP   한 프레임 BIOS 히트 상한.  넘으면 자동으로 끈다

local VERSION  = '0.4.42-callflow'
local STACK    = rawget(_G, 'SUB_CALLFLOW_STACK') or '0.4.41'
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
local STAGE  = ENGINE + 503
local STATE  = 0x7FDF

local realLog = emu.log
local function say(msg) realLog(msg) end

-- 판올림하면 덤프 이름도 같이 올린다.  스택 이름까지 넣어 파일 하나로 조합을
-- 알아볼 수 있게 한다.
local RUN_TAG = os.date('%Y%m%d_%H%M%S')
local OUT = string.format('C:/snatcher/dump/callflow_0_4_42_%s_%s.tsv',
                          (STACK:gsub('[^%w]', '_')), RUN_TAG)

if STACK ~= 'none' then
  dofile('C:/snatcher/lua/SUB/' .. STACK .. '.lua')
end

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

local out = io.open(OUT, 'w')
if out then
  out:write(string.format('# SUB %s · stack=%s · %s\n', VERSION, STACK, RUN_TAG))
  local names = {}
  for _, w in ipairs(WATCH) do
    names[#names + 1] = string.format('%s=$%04X', w.name, w.addr)
  end
  out:write('# watch: ' .. table.concat(names, ' ') .. '\n')
  out:write('# 창 = 음성 하나.  vf 는 그 음성 시작 이후 프레임이다.\n')
  out:write('# 값은 그 프레임 동안의 실행 횟수(delta)다.  누적이 아니다.\n')
  local head = { 'run', 'frame', 'vf', 'play', 'endaddr', 'pc', 'state',
                 'ready', 'start', 'stageok' }
  for _, w in ipairs(WATCH) do head[#head + 1] = w.name end
  head[#head + 1] = 'sel9'
  out:write(table.concat(head, '\t') .. '\n')
  out:flush()
end

local function note(msg)
  say(msg)
  if out then out:write('# ' .. msg .. '\n'); out:flush() end
end

local frame, run, vf, silence = 0, 0, 0, 0
local window, voiceEnd = false, nil
local pendEnd, pendN = nil, 0
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

local function openWindow(endaddr)
  run, vf, silence, window, voiceEnd = run + 1, 0, 0, true, endaddr
  pendEnd, pendN = nil, 0
  buckets, lastSeen = {}, {}
  for n = 1, #MARKS + 1 do
    local b = { frames = 0 }
    for _, w in ipairs(WATCH) do b[w.name] = 0 end
    buckets[n] = b
  end
  for _, w in ipairs(WATCH) do w.total = 0 end
  note(string.format('SUB %s ▶ run #%d 시작 · 음성 end=$%04X · 경계 %s',
                     VERSION, run, endaddr, table.concat(MARKS, ',')))
end

local function closeWindow(reason)
  if not window then return end
  window = false
  note(string.format('SUB %s ■ run #%d 끝 · end=$%04X · %s · %d 프레임',
                     VERSION, run, voiceEnd or 0, reason, vf))
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
  local rb, ck, entry = 0, 0, nil
  for _, w in ipairs(WATCH) do
    if w.name == 'REBUILD' then rb = w.total end
    if w.name == 'COUNTOK' then ck = w.total end
    if w.name == 'ENTRY' then entry = w.total end
  end
  note(string.format('  이 음성: REBUILD %d회 · COUNTOK %d회 · ENTRY %d회', rb, ck, entry))
  note(string.format('  마지막 히트 vf: HOOK %s · ENTRY %s · REBUILD %s · COUNTOK %s · E742 %s',
                     tostring(lastSeen.HOOK), tostring(lastSeen.ENTRY),
                     tostring(lastSeen.REBUILD), tostring(lastSeen.COUNTOK),
                     tostring(lastSeen.E742)))

  -- 정지 판정.  HOOK 이 창 끝까지 왔으면 게임 루프가 살아 있었다는 뜻이다.
  local alive = lastSeen.HOOK and (vf - lastSeen.HOOK) <= 3
  if not alive then
    note(string.format('  ==> 게임 루프가 vf=%s 에서 멈췄다 (정지)',
                       tostring(lastSeen.HOOK)))
    if lastSeen.ENTRY and lastSeen.REBUILD and lastSeen.ENTRY > lastSeen.REBUILD then
      note('  ==> 마지막 ENTRY 는 왔는데 REBUILD 로 못 갔다 -- JSR stage 가 안 돌아온 형태다')
    end
  else
    note('  ==> 게임 루프 정상 (창 끝까지 HOOK 이 왔다)')
    if #MARKS + 1 == rb then
      note(string.format('  ==> 조각 %d개가 모두 rebuild 됐다.  §8-C 호출 기준 통과', rb))
    else
      note(string.format('  ==> rebuild %d회 -- 경계 수(%d조각)와 다르다.  확인 필요',
                         rb, #MARKS + 1))
    end
  end
  if out then out:flush() end
end

local function hexbytes(at, count)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', emu.read(at + i, MEM) or 0)
  end
  return table.concat(t)
end

-- stage 첫 바이트가 팔레트 루틴인지(A9 F1 8D) 글리프 데이터인지 한 눈에.
local function stageOk()
  return ((emu.read(STAGE, MEM) or 0) == 0xA9 and
          (emu.read(STAGE + 1, MEM) or 0) == 0xF1 and
          (emu.read(STAGE + 30, MEM) or 0) == 0x60) and 1 or 0
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

  -- 창 경계.  재생 중일 때의 end 주소만 믿는다 (멈춘 프레임의 값은 쓰레기다).
  if playing then
    if not window then
      openWindow(endaddr)
    elseif endaddr ~= voiceEnd then
      if pendEnd == endaddr then
        pendN = pendN + 1
        if pendN >= 2 then                    -- 2프레임 연속이면 새 음성으로 본다
          closeWindow('새 음성 시작')
          openWindow(endaddr)
        end
      else
        pendEnd, pendN = endaddr, 1
      end
    else
      pendEnd, pendN = nil, 0
    end
  end

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
      stageOk(),
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

    for _, mark in ipairs(MARKS) do
      if vf == mark then
        local parts = {}
        for _, w in ipairs(WATCH) do
          parts[#parts + 1] = string.format('%s=%d', w.name, w.n)
        end
        note(string.format('SUB %s · vf=%d · ready=%02X stage=%d sel=%s · %s',
                           VERSION, vf, emu.read(READY, MEM) or 0, stageOk(),
                           hexbytes(SEL, 9), table.concat(parts, ' ')))
      end
    end

    vf = vf + 1
    silence = playing and 0 or (silence + 1)
    if silence > TAIL then
      closeWindow('재생 종료 후 ' .. TAIL .. '프레임')
    elseif vf > MAXF then
      closeWindow('상한 ' .. MAXF .. '프레임')
    end
  end

  for _, w in ipairs(WATCH) do w.n = 0 end

  if window then
    emu.drawString(4, 44, string.format('%s run#%d vf=%d $%04X', VERSION, run, vf,
                   voiceEnd or 0), 0x60C0FF, 0x000000)
    emu.drawString(4, 54, string.format('HOOK %d  ENTRY %d  RB %d  CNT %d',
                   WATCH[1].total, WATCH[3].total, WATCH[4].total, WATCH[5].total),
                   0x60C0FF, 0x000000)
  else
    emu.drawString(4, 44, string.format('%s 대기 · 음성 기다림', VERSION),
                   0x808080, 0x000000)
  end
end, emu.eventType.endFrame)

say('SUB ' .. VERSION .. ' -- 음성별 창 census · 쓰기 0')
say('  자막 스택: ' .. STACK)
say('  덤프: ' .. OUT)
local names = {}
for _, w in ipairs(WATCH) do
  names[#names + 1] = string.format('%s=$%04X%s', w.name, w.addr, w.off and '(off)' or '')
end
say('  감시: ' .. table.concat(names, ' '))
say('  stageok 열 = stage 가 팔레트 루틴이면 1, 글리프 데이터로 덮였으면 0')
say('  미카 end=$D000 창에서 REBUILD 3 · COUNTOK 3 이면 통과다')
