-- SUB 0.5.38 -- 디스패처가 도는 순간의 **문맥**을 본다 (AC 포트가 왜 FF 인가)
--
-- 지금까지 좁혀진 것
-- ---------------------------------------------------------------------------
-- 0.4.7.2 디스패처가 AC 를 **고정 주소로** 읽어도 `FF FF FF` 가 나온다.
-- 그런데 Lua 의 되읽기는 정상이다 (표 첫 항목 00 30 6B 확인).
--
--     -> 표는 그 자리에 있다.  포트 경로가 AC 에 안 닿는다.
--
-- 엔진(`engine_ac_timed_safe_poc`)은 **같은 관용구**로 AC 를 잘 읽는다.
--
--     set_ac: $1A02/$1A03/$1A04 = 주소 · $1A07=1 · $1A08=0 · $1A09=$11
--     읽기  : $1A00 (자동증가)
--
-- 다른 점은 **어디서 도는가** 뿐이다.
--
--     엔진      CD-RAM $5B80 · $601E 상주 경로 · 인터럽트 정상
--     디스패처  BIOS 뱅크1 (MPR7 교체) · SEI · AD_PLAY 한복판
--
-- 그래서 이 프로브는 진입 순간의 MPR 매핑을 뜬다.  AC 포트는 I/O 페이지(뱅크 $FF)
-- 에 있으므로 MPR0 이 $FF 가 아니면 $1A00 은 남의 것을 읽는다.
--
-- 무엇을 찍나
-- ---------------------------------------------------------------------------
--   1) 디스패처 진입($F0EA) 순간의 MPR0~MPR7
--   2) 비교를 위해 훅 자리($F5F5) 진입 순간의 MPR0~MPR7
--   3) AC 제어 레지스터 $1A02-$1A09 의 현재 값 (데이터 포트 $1A00 은 건드리지 않는다)
--
-- ★ $1A00 은 읽지 않는다.  자동증가가 있어 읽는 순간 포인터가 움직인다.
--
-- 읽기 전용이다.  아무 주소에도 쓰지 않는다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.
--     BIOS  build/patch/0.4.7.2-lba-probe/Syscard3_galmuri_0.4.7.2-lba-probe.pce
--     CUE   build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local DISPATCH = 0xF0EA        -- 뱅크1 디스패처 진입
local HOOK     = 0xF5F5        -- 뱅크0 훅 자리

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/dispatch_context_0_5_38_' .. STAMP .. '.txt'
local out = io.open(OUT, 'w')

local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function mprs(s)
  local t = {}
  for i = 0, 7 do
    local v
    for _, k in ipairs({ 'cpu.mpr[' .. i .. ']', 'mpr' .. i,
                         'memoryManager.mpr[' .. i .. ']' }) do
      if type(s and s[k]) == 'number' then v = math.floor(s[k]) & 0xFF break end
    end
    t[#t + 1] = v and string.format('%02X', v) or '??'
  end
  return table.concat(t, ' ')
end

local function acRegs()
  local t = {}
  for _, a in ipairs({ 0x1A02, 0x1A03, 0x1A04, 0x1A05, 0x1A06,
                       0x1A07, 0x1A08, 0x1A09 }) do
    t[#t + 1] = string.format('%04X=%02X', a, emu.read(a, MEM) or 0)
  end
  return table.concat(t, ' ')
end

local seen = { [DISPATCH] = 0, [HOOK] = 0 }
local LIMIT = 6

local function report(name, addr)
  seen[addr] = seen[addr] + 1
  if seen[addr] > LIMIT then return end
  local s = st()
  local line = string.format('%s #%d  MPR %s\n           AC %s',
                             name, seen[addr], mprs(s), acRegs())
  emu.log('SUB 0.5.38 ' .. line:gsub('\n%s*', ' | '))
  if out then out:write(line .. '\n\n'); out:flush() end
end

emu.addMemoryCallback(function() report('DISPATCH $F0EA', DISPATCH) end,
  emu.callbackType.exec, DISPATCH, DISPATCH, CPU, MEM)
emu.addMemoryCallback(function() report('HOOK     $F5F5', HOOK) end,
  emu.callbackType.exec, HOOK, HOOK, CPU, MEM)

emu.addEventCallback(function()
  if out then out:close() end
  emu.log(string.format('SUB 0.5.38 끝 -- 훅 %d 회 · 디스패처 %d 회',
                        seen[HOOK], seen[DISPATCH]))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.38-dispatch-context armed -- 읽기 전용 · $1A00 은 안 건드린다')
emu.log('  ★ 보려는 것: 디스패처 진입 때 MPR0 이 $FF 인가 (AC 포트가 I/O 페이지에 있다)')
emu.log('  ★ 훅과 디스패처의 MPR 을 나란히 찍어 뱅크 교체 영향을 본다')
emu.log('  각 지점 최대 6 회만 찍는다')
emu.log('  로그: ' .. OUT)
