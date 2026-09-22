-- SUB 0.4.74-169c-full-route-probe -- 169C 문단 전후 모든 $3619 호출 읽기 전용
--
-- 0.4.73 결과: R10426:9 / :12 직전 state가 0000이다.
-- 이 파일은 알려진 행만 고르지 않고 $3619의 모든 source를 기록해,
-- 두 행 사이에 state를 끊는 숨은 renderer call이 있는지 확정한다.
-- Power Cycle 뒤 이 파일 하나만 실행. 게임 RAM/AC/VRAM/Sprite RAM write 0 B.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local OUT = 'C:/snatcher/dump/sub_0_4_74_169c_full_route_' .. os.date('%Y%m%d_%H%M%S') .. '.tsv'
local RECORDS = 'C:/snatcher/build/patch/0.4.5.11-reviewed-base/direct_records.tsv'

local function b(addr) return emu.read(addr, MEM) or 0 end
local function w(addr) return b(addr) | (b(addr + 1) << 8) end
local function sourceAt(ptr)
  local out = {}
  for i = 0, 63 do
    local v = b(ptr + i)
    if v == 0xFF then break end
    out[#out + 1] = string.char(v)
  end
  return table.concat(out)
end
local function hex(data)
  local out = {}
  for i = 1, #data do out[#out + 1] = string.format('%02X', data:byte(i)) end
  return table.concat(out, ' ')
end

-- source+state와 root source를 모두 표시한다. 파일은 읽기만 한다.
local routes, roots, sourceRefs = {}, {}, {}
do
  local f = assert(io.open(RECORDS, 'r'), 'cannot open ' .. RECORDS)
  f:read('*l')
  for line in f:lines() do
    local c = {}
    for field in (line .. '\t'):gmatch('(.-)\t') do c[#c + 1] = field end
    local state, source, ref = c[4] or '', c[10] or '', c[13] or ''
    routes[state .. '|' .. source] = ref
    if state == '0000' then roots[source] = ref end
    if ref:match('^R0435[4-8]:') or ref:match('^R10426:') then
      sourceRefs[source] = ref
    end
  end
  f:close()
end

local out = assert(io.open(OUT, 'w'))
out:write('n\tstate_before\tpointer\tsource_hex\troute_at_state\troute_at_root\t169c_ref\n')
out:flush()
local n = 0

local function onRenderer()
  local ptr = w(0x3471)
  if ptr ~= 0x3619 then return end
  local source = sourceAt(ptr)
  local sourceHex = hex(source)
  local state = string.format('%04X', w(0x7FEC))
  n = n + 1
  local atState = routes[state .. '|' .. sourceHex] or ''
  local atRoot = roots[sourceHex] or ''
  local ref = sourceRefs[sourceHex] or ''
  out:write(string.format('%d\t%s\t%04X\t%s\t%s\t%s\t%s\n',
    n, state, ptr, sourceHex, atState, atRoot, ref))
  out:flush()
  if ref ~= '' or (n % 20 == 0) then
    emu.log(string.format('ROUTEALL #%d state=%s stateHit=%s root=%s focus=%s',
      n, state, atState, atRoot, ref))
  end
end

emu.addMemoryCallback(onRenderer, emu.callbackType.exec,
  0x66E5, 0x66E5, CPU, MEM)
emu.log('SUB 0.4.74 169C FULL ROUTE PROBE loaded -- READ ONLY / game write 0 B')
emu.log('  every $3619 renderer call -> ' .. OUT)
emu.log('  Power Cycle 뒤 이것만 실행하고 시베리아 중립영토 설명을 연 뒤 Stop')
