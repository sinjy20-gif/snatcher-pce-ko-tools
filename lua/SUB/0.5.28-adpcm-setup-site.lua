-- SUB 0.5.28 -- 게임이 ADPCM 을 어디서 세우는가.  네이티브로 6 B 키를 만들 수 있는가
--
-- 왜 필요한가
-- ---------------------------------------------------------------------------
-- CD-DA 는 0.4.6.24 로 네이티브 출력까지 닫혔다 (baseline §7).  다음은 ADPCM 인데,
-- §9.1 의 다섯 항목 중 **1 번만** 어렵다 -- "emu.getState() 없이 6 B 키 만들기".
--
-- 지금 Lua(0.4.31)의 키 정의는 이렇다.
--
--     finish = (cdrom.adpcm.readAddress + cdrom.adpcm.adpcmLength) & 0xFFFF
--     rate   =  cdrom.adpcm.playbackRate & 0xFF
--     key    = [ finish&FF, finish>>8, rate,
--                APCM[finish/4], APCM[finish/2], APCM[finish*5/8] ]
--
-- 문제는 `readAddress` 와 `adpcmLength` 가 **에뮬레이터 내부 상태**라는 것이다.
-- 네이티브 코드에는 그걸 되읽을 방법이 없다.  그러나 그 값들을 **게임 자신이
-- 하드웨어에 써넣는다.**  그 지점을 찾으면 네이티브 출처가 생긴다.
--
--     CD-DA 에서 $26F9(트랙 번호)를 찾은 것과 정확히 같은 수법이다.
--
-- ★ 키 정의는 절대 바꾸지 않는다.  팩 1950 조각 / 902 키와 이미 수집한 안전위치가
--   전부 이 6 B 키로 잡혀 있다.  키를 바꾸면 그게 다 날아간다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) `$1800-$180F` (ADPCM 포트) 에 대한 **모든 쓰기** -- 주소 · 값 · PC
--   2) 음성이 시작되는 순간(playing false->true)의 에뮬레이터 진실값
--        readAddress · adpcmLength · finish · rate · 그리고 완성된 6 B 키
--   3) ★ 자동 대조 -- 버퍼에 남은 각 쓰기 값이 위 진실값의 어느 바이트와 같은지
--        태그를 붙인다.  어느 포트가 어느 값을 나르는지 눈으로 바로 보인다
--   4) 쓰기를 낸 PC 주변 코드를 파일로 덤프한다 (다음 왕복 없이 디스어셈하려고)
--
-- 읽는 법
--     RA.lo/RA.hi/LEN.lo/LEN.hi 태그가 붙은 쓰기가 보이면
--         -> 게임이 그 값을 직접 써넣는다.  네이티브가 가로챌 수 있다.  **이식 가능**
--     아무 태그도 안 붙으면
--         -> 게임이 다른 형태(예: 블록 전송 · 계산된 값)로 넣는다.
--            덤프한 PC 를 디스어셈해서 출처를 따라가야 한다
--
-- ★ 음성 감지 0 이면 판정 불가.  상태 키 이름이 이 Mesen 판과 다른 것이다.
--
-- 읽기 전용이다.  자막 스택을 물지 않는다 (게임의 동작만 본다).
-- 화면에 아무것도 안 그린다.
-- Power Cycle 뒤 이 파일 하나만 로드하고, 음성이 나오는 곳을 아무데나 돌면 된다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local APCM = emu.memType.pceAdpcmRam

local PORT_LO, PORT_HI = 0x1800, 0x180F
local RING = 64                     -- 최근 쓰기 보관 개수

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT  = 'C:/snatcher/dump/adpcm_setup_0_5_28_' .. STAMP .. '.tsv'
local CODE = 'C:/snatcher/dump/adpcm_setup_code_0_5_28_' .. STAMP .. '.txt'
local out  = io.open(OUT, 'w')
local code = io.open(CODE, 'w')
if out then
  out:write('voice\tseq\tport\tvalue\tpc\ttag\tfinish\trate\tread_addr\tlength\tkey\n')
end

-- ---------------------------------------------------------------------------
-- 상태 읽기.  0.4.31 이 쓰는 키 이름을 그대로 쓴다.
-- ---------------------------------------------------------------------------
local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function num(s, k)
  local v = s and s[k]
  return type(v) == 'number' and math.floor(v) or 0
end

local function curPC()
  local s = st()
  if not s then return -1 end
  for _, k in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[k]) == 'number' then return math.floor(s[k]) & 0xFFFF end
  end
  return -1
end

-- ---------------------------------------------------------------------------
-- writer PC 주변 코드 덤프 -- 호출 시점의 뱅크 매핑 그대로 읽는다
-- ---------------------------------------------------------------------------
local dumped, dumpCount = {}, 0
local function dumpAround(pc)
  if pc < 0 or dumped[pc] or not code or dumpCount >= 12 then return end
  dumped[pc] = true
  dumpCount = dumpCount + 1
  local lo = math.max(0, pc - 0x50)
  local hi = math.min(0xFFFF, pc + 0x30)
  local hex = {}
  for a = lo, hi do hex[#hex + 1] = string.format('%02X', emu.read(a, MEM) or 0) end

  local s = st()
  local mpr = {}
  for i = 0, 7 do
    local v = s and (s['cpu.mpr[' .. i .. ']'] or s['mpr' .. i]
                     or s['memoryManager.mpr[' .. i .. ']'])
    mpr[#mpr + 1] = type(v) == 'number' and string.format('%02X', v) or '??'
  end

  code:write(string.format('\n== ADPCM 포트에 쓴 PC $%04X (Mesen 보고값 그대로) ==  MPR %s\n',
                           pc, table.concat(mpr, ' ')))
  code:write(string.format('org $%04X\n', lo))
  for i = 1, #hex, 32 do
    code:write(string.format('%04X  %s\n', lo + i - 1,
               table.concat(hex, ' ', i, math.min(i + 31, #hex))))
  end
  code:flush()
  emu.log(string.format('SUB 0.5.28 ★ CODE DUMP  포트 writer PC $%04X (%d B)', pc, hi - lo + 1))
end

-- ---------------------------------------------------------------------------
-- 포트 쓰기 링버퍼
-- ---------------------------------------------------------------------------
local ring, ringN = {}, 0
emu.addMemoryCallback(function(address, value)
  ringN = ringN + 1
  ring[(ringN - 1) % RING + 1] = {
    port = address & 0xFFFF, value = (value or 0) & 0xFF, pc = curPC(), n = ringN,
  }
end, emu.callbackType.write, PORT_LO, PORT_HI, CPU, MEM)

-- ---------------------------------------------------------------------------
-- 음성 시작 감지 + 자동 대조
-- ---------------------------------------------------------------------------
local wasPlaying, voices, lastSeen = false, 0, 0
local warned = false

local function hex6(k)
  return (k:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

-- 각 쓰기 값이 진실값의 어느 바이트인지 태그를 붙인다
local function tagOf(v, ra, len, fin, rate)
  local t = {}
  if v == (ra & 0xFF) then t[#t + 1] = 'RA.lo' end
  if v == ((ra >> 8) & 0xFF) then t[#t + 1] = 'RA.hi' end
  if v == (len & 0xFF) then t[#t + 1] = 'LEN.lo' end
  if v == ((len >> 8) & 0xFF) then t[#t + 1] = 'LEN.hi' end
  if v == (fin & 0xFF) then t[#t + 1] = 'FIN.lo' end
  if v == ((fin >> 8) & 0xFF) then t[#t + 1] = 'FIN.hi' end
  if v == rate then t[#t + 1] = 'rate' end
  return #t > 0 and table.concat(t, '/') or '-'
end

emu.addEventCallback(function()
  local s = st()
  if not s then return end

  local playing = s['cdrom.adpcm.playing'] == true
  if not playing then wasPlaying = false; return end
  if wasPlaying then return end
  wasPlaying = true

  -- 상태 키가 이 Mesen 판에 없으면 판정 불가다.  한 번만 경고한다
  if not warned and s['cdrom.adpcm.readAddress'] == nil then
    warned = true
    emu.log('SUB 0.5.28 ★★ cdrom.adpcm.readAddress 가 없다 -- 상태 키 이름이 다르다')
    emu.log('   0.4.31 과 같은 Mesen 판인지 확인할 것.  지금 판정은 불가')
  end

  local ra   = num(s, 'cdrom.adpcm.readAddress')
  local len  = num(s, 'cdrom.adpcm.adpcmLength')
  local fin  = (ra + len) & 0xFFFF
  local rate = num(s, 'cdrom.adpcm.playbackRate') & 0xFF
  local a1, a2, a3 = fin // 4, fin // 2, (fin * 5) // 8
  local key = string.char(fin & 0xFF, fin >> 8, rate,
                          emu.read(a1, APCM) or 0,
                          emu.read(a2, APCM) or 0,
                          emu.read(a3, APCM) or 0)

  voices = voices + 1
  emu.log(string.format(
    'SUB 0.5.28 ★ VOICE #%d · key %s · finish $%04X = RA $%04X + LEN $%04X · rate $%02X',
    voices, hex6(key), fin, ra, len, rate))

  -- 이 음성 직전의 포트 쓰기를 순서대로 편다
  local list = {}
  local first = math.max(lastSeen + 1, ringN - RING + 1)
  for n = first, ringN do
    local e = ring[(n - 1) % RING + 1]
    if e and e.n == n then list[#list + 1] = e end
  end
  lastSeen = ringN

  if #list == 0 then
    emu.log('   (직전 포트 쓰기 없음 -- 이 음성은 이전 설정을 재사용했다)')
  end
  for i, e in ipairs(list) do
    local tag = tagOf(e.value, ra, len, fin, rate)
    if tag ~= '-' or i > #list - 12 then     -- 태그 붙은 것 + 마지막 12 개만 로그
      emu.log(string.format('   $%04X <- $%02X   PC $%04X   %s',
                            e.port, e.value, e.pc, tag))
    end
    dumpAround(e.pc)
    if out then
      out:write(string.format('%d\t%d\t%04X\t%02X\t%04X\t%s\t%04X\t%02X\t%04X\t%04X\t%s\n',
        voices, i, e.port, e.value, e.pc, tag, fin, rate, ra, len, hex6(key)))
    end
  end
  if out then out:flush() end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.28-adpcm-setup-site armed -- 게임의 ADPCM 셋업 지점을 찾는다')
emu.log('  포트 $1800-$180F 쓰기를 모으고, 음성 시작 시점의 진실값과 자동 대조한다')
emu.log('  태그: RA=readAddress · LEN=adpcmLength · FIN=finish · rate')
emu.log('  ★ RA/LEN 태그가 붙은 쓰기가 보이면 네이티브 이식이 열린다')
emu.log('  ★ VOICE 0 이면 판정 불가 (상태 키 이름이 다름)')
emu.log('  로그: ' .. OUT)
emu.log('  코드: ' .. CODE)
