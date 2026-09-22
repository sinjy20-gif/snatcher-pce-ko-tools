-- GFX 0.4.2 -- 게이트 후보로 무장한 뒤 **몇 번째 업로드가 헌정인가**  ★순수 관측 · 쓰기 0 B
--
-- 0.4.1 이 찾은 것
-- ---------------------------------------------------------------------------
-- 헌정 타일이 올라가기 직전의 CD_READ 가 전체 239 회 중 **유일한 위치**를 읽는다:
--
--     f4670   호출자 $54E4   $20FD:$20FE = 03 5A   섹터 100 장
--     (전체 239 읽기 중 이 위치는 한 번뿐)
--
-- $20FD:$20FE 는 $BEAA 스트리밍에서 섹터 수(4)만큼 정확히 증가하던 **위치 필드**다.
-- 타일 지문처럼 '내용' 이 아니라 '디스크상의 자리' 이므로 다른 화면이 우연히 같은
-- 값을 쓸 이유가 없다.  r3/r4 가 쓰던 신호와 성격이 다르다.
--
-- ⚠ 남은 문제 -- 읽기와 업로드가 1,590 프레임(26 초) 떨어져 있다
-- ---------------------------------------------------------------------------
-- 그 사이 공용 업로더가 수천 번 돈다.  무장만으로는 어느 업로드가 헌정인지 못 정한다.
-- 그래서 이걸 잰다:
--
--     무장(위 CD_READ) 이후 업로더 **덩어리(burst)** 를 순서대로 세고,
--     그중 몇 번째에 헌정 지문이 나오는지
--
-- 판정
--   헌정이 무장 후 **첫 번째** $70EC 덩어리   -> 지문 없이 "무장 -> 첫 덩어리" 로 끝난다
--   n 번째로 일정하다                          -> 덩어리를 세서 n 번째에 넣는다
--   순서가 흔들린다                            -> 무장 + 지문 둘 다 쓴다 (그래도 r3 보다 훨씬 좁다)
--   무장이 안 걸린다                           -> 위치값이 주행마다 다르다.  다시 봐야 한다
--
-- 쓰는 법  0.4.1 과 같은 구간을 한 번 더 지난다 (부팅 -> 타이틀 -> 헌정)
--
-- 산출물  C:/snatcher/dump/gfxgate_0_4_2_<시각>_bursts.tsv
--         C:/snatcher/dump/gfxgate_0_4_2_<시각>_summary.txt

local CD_READ  = 0xE009
local UPLOADER = 0x725C
local BUF      = 0x3B00
local ZP_LO, ZP_HI = 0x20F0, 0x20FF     -- ★HuC6280 zero page 는 $2000-$20FF
local STACK    = 0x2100

-- 게이트 후보: 위치 $20FD:$20FE
local GATE_FD, GATE_FE = 0x03, 0x5A
local GATE_CALLER      = 0x54E4          -- 참고용.  판정에는 위치만 쓴다

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local BURST_GAP = 30                     -- 이 프레임 이상 비면 다른 덩어리로 센다
local REPORT    = 300

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxgate_0_4_2_' .. STAMP

local bout = assert(io.open(BASE .. '_bursts.tsv', 'w'))
bout:write('burst\tsince_arm\tstart_frame\tend_frame\tcalls\tcaller\tsig_hits\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return (ok and type(v) == 'number') and v or -1 end

local function reg(cands)
  local key
  return function()
    local ok, s = pcall(emu.getState)
    if not ok or type(s) ~= 'table' then return -1 end
    if key == nil then
      key = false
      for _, k in ipairs(cands) do if type(s[k]) == 'number' then key = k break end end
    end
    if key == false then return -1 end
    local v = s[key]
    return type(v) == 'number' and math.floor(v) or -1
  end
end
local spNow = reg({ 'cpu.sp', 'cpu.s', 'sp', 'cpu.stackPointer' })

local function callerPC()
  local sp = spNow()
  if sp < 0 then return -1 end
  local lo, hi = rd(STACK + ((sp + 1) & 0xFF)), rd(STACK + ((sp + 2) & 0xFF))
  if lo < 0 or hi < 0 then return -1 end
  return ((hi << 8) | lo) & 0xFFFF
end

local function sigHere()
  for i, want in ipairs(SIG) do
    if rd(BUF + i - 1) ~= want then return false end
  end
  return true
end

local frame = 0
local armed, armFrame, nArm = false, -1, 0
local burst = nil                 -- {n, start, last, calls, caller, sigs}
local burstNo, burstSinceArm = 0, 0
local nUp, nHit = 0, 0
local dedBursts = {}              -- 지문이 나온 덩어리의 (무장후 순번)

local function closeBurst()
  if not burst then return end
  bout:write(('%d\t%s\t%d\t%d\t%d\t$%04X\t%d\n'):format(
    burst.n, burst.since >= 0 and tostring(burst.since) or '',
    burst.start, burst.last, burst.calls, burst.caller & 0xFFFF, burst.sigs))
  bout:flush()
  if burst.sigs > 0 and burst.since >= 0 then dedBursts[#dedBursts + 1] = burst.since end
  burst = nil
end

emu.addMemoryCallback(function()
  local fd, fe = rd(0x20FD), rd(0x20FE)
  if fd == GATE_FD and fe == GATE_FE then
    armed, armFrame = true, frame
    nArm = nArm + 1
    burstSinceArm = 0
    closeBurst()
    say(('  ★f%d  게이트 무장 -- 위치 $%02X:%02X · 호출자 $%04X · 섹터 %d')
        :format(frame, fd, fe, callerPC() & 0xFFFF, rd(0x20F8) & 0xFF))
  end
end, emu.callbackType.exec, CD_READ, CD_READ, CPU, MEM)

emu.addMemoryCallback(function()
  nUp = nUp + 1
  local hit = sigHere()
  if hit then nHit = nHit + 1 end
  if burst and (frame - burst.last) > BURST_GAP then closeBurst() end
  if not burst then
    burstNo = burstNo + 1
    local since = -1
    if armed then burstSinceArm = burstSinceArm + 1; since = burstSinceArm end
    burst = { n = burstNo, since = since, start = frame, last = frame,
              calls = 0, caller = callerPC(), sigs = 0 }
  end
  burst.last = frame
  burst.calls = burst.calls + 1
  if hit then burst.sigs = burst.sigs + 1 end
end, emu.callbackType.exec, UPLOADER, UPLOADER, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if burst and (frame - burst.last) > BURST_GAP then closeBurst() end
  if frame % REPORT == 0 then
    say(('f%d  무장 %d · 업로더 %d · 덩어리 %d · ★지문 %d')
        :format(frame, nArm, nUp, burstNo, nHit))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  closeBurst()
  bout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end

  put(('프레임 %d'):format(frame))
  put(('게이트 무장 %d 회 (첫 무장 f%d)'):format(nArm, armFrame))
  put(('업로더 진입 %d · 덩어리 %d · 지문 적중 %d'):format(nUp, burstNo, nHit))
  put('')

  if nArm == 0 then
    put('★ 게이트가 한 번도 안 걸렸다.  0 은 "이상 없음" 이 아니다.')
    put(('   위치 $%02X:%02X 를 읽는 CD_READ 가 이 주행엔 없었다.'):format(GATE_FD, GATE_FE))
    put('   -> 위치값이 주행마다 다르거나, 헌정 화면을 안 지났다.')
  elseif #dedBursts == 0 then
    put('★ 무장은 했는데 그 뒤 지문이 안 나왔다.')
    put('   -> 무장과 헌정 업로드가 이어지지 않는다.  창을 다시 봐야 한다.')
  else
    local same = true
    for _, v in ipairs(dedBursts) do if v ~= dedBursts[1] then same = false end end
    put(('★★ 헌정 지문이 나온 덩어리 = 무장 후 %s 번째')
        :format(table.concat(dedBursts, ', ')))
    if same and dedBursts[1] == 1 then
      put('   -> 무장 직후 **첫 덩어리**다.  지문 없이 "무장 -> 첫 덩어리" 로 끝난다.')
    elseif same then
      put(('   -> 항상 %d 번째다.  덩어리를 세서 그 자리에 넣으면 된다.'):format(dedBursts[1]))
    else
      put('   -> 순번이 흔들린다.  무장 + 지문 둘 다 쓴다 (그래도 r3 보다 훨씬 좁다).')
    end
  end
  put('')
  put('덩어리 표는 _bursts.tsv 에 있다 (무장 후 순번 · 호출자 · 지문 수).')
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.4.2-gate-window armed -- 게이트 위치 $03:$5A · 쓰기 0 B · 화면에 안 그림')
say('  0.4.1 과 같은 구간을 한 번 더 (부팅 -> 타이틀 -> 헌정)')
say('  ' .. BASE .. '_bursts.tsv')
