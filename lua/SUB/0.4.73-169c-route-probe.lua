-- SUB 0.4.73-169c-route-probe -- R04354~R04358 / R10426 lookup 경로 읽기 전용
--
-- 왜: `▽国連は『<원문 5자>』のよう` 는 출하 레코드에 두 상태 경로로 들어 있다.
--      실제 $66E5 진입 직전의 source + SRT4 state($7FEC/$7FED)를 기록해
--      어느 앞 줄이 state를 0으로 떨어뜨리는지 확인한다.
--
-- Power Cycle 뒤 이 파일 하나만 실행. 게임 RAM/AC/VRAM/Sprite RAM write 0 B.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local OUT = 'C:/snatcher/dump/sub_0_4_73_169c_route_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local RECORDS = 'C:/snatcher/build/patch/0.4.5.11-reviewed-base/direct_records.tsv'

local function b(addr)
  return emu.read(addr, MEM) or 0
end

local function w(addr)
  return b(addr) | (b(addr + 1) << 8)
end

local function bytesHex(data)
  local out = {}
  for i = 1, #data do out[#out + 1] = string.format('%02X', data:byte(i)) end
  return table.concat(out, ' ')
end

local function sourceAt(ptr)
  local out = {}
  for i = 0, 63 do
    local v = b(ptr + i)
    if v == 0xFF then break end
    out[#out + 1] = string.char(v)
  end
  return table.concat(out)
end

-- 이 문단의 출하 레코드만 source+state -> ref/번역으로 역색인한다.
local expected = {}
local knownSource = {}
do
  local f = assert(io.open(RECORDS, 'r'), 'cannot open ' .. RECORDS)
  f:read('*l')
  for line in f:lines() do
    local col = {}
    for field in (line .. '\t'):gmatch('(.-)\t') do col[#col + 1] = field end
    local ref = col[13] or ''
    if ref:match('^R0435[4-8]:') or ref:match('^R10426:') then
      local state, source, ko = col[4], col[10], col[14]
      expected[(state or '') .. '|' .. (source or '')] = ref .. '|' .. (ko or '')
      knownSource[source or ''] = true
    end
  end
  f:close()
end

local out = assert(io.open(OUT, 'w'))
out:write('n\tbefore_state\tpointer\tsource_hex\tmatching_record\tnote\n')
out:flush()

local seen, frame = 0, 0
local function onRenderer()
  local ptr = w(0x3471)
  if ptr ~= 0x3619 then return end
  local source = sourceAt(ptr)
  local hex = bytesHex(source)

  -- 169C 문단은 이들 source들이거나, 그 사이에 state를 끊은 원인이 되는
  -- 바로 앞 줄이다. 해당 문단 문자열 전체를 비교하지 않고 모든 $3619 행을
  -- 파일에 남겨서 전후 1행도 보존한다.
  local state = string.format('%04X', w(0x7FEC))
  local hit = expected[state .. '|' .. hex] or ''
  local root = expected['0000|' .. hex] or ''
  if knownSource[hex] then
    seen = seen + 1
    local note = hit ~= '' and 'HIT_EXPECTED' or
                 (root ~= '' and 'ROOT_ONLY' or 'TARGET_STATE_MISS')
    out:write(string.format('%d\t%s\t%04X\t%s\t%s\t%s\n',
      seen, state, ptr, hex, hit ~= '' and hit or root, note))
    out:flush()
    emu.log(string.format('ROUTE #%d state=%s %s %s', seen, state, note,
      hit ~= '' and hit or root))
  end
end

emu.addMemoryCallback(onRenderer, emu.callbackType.exec,
  0x66E5, 0x66E5, CPU, MEM)
emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.log('SUB 0.4.73 169C ROUTE PROBE loaded -- READ ONLY / game write 0 B')
emu.log('  $66E5 source + $7FEC state only; output: ' .. OUT)
emu.log('  Power Cycle 뒤 이 파일 하나만 실행하고 시베리아 중립영토 설명을 연다')
