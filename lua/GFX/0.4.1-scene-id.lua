-- GFX 0.4.1 -- 헌정 화면을 **일대일로 식별하는 값**을 찾는다  ★순수 관측 · 쓰기 0 B · 화면에 안 그림
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- r3/r4 가 실패한 이유는 구현이 아니라 **식별 전략**이다.
--
--     r3  타일 16 B 지문         -> 나중에 다른 화면이 오염.  거짓 양성
--     r4  지문 + CD-DA track $17 -> 부팅부터 깨짐.  $263B 은 게임 RAM 이라
--                                   드라이버가 채우기 전엔 쓰레기값이다
--
-- 둘 다 "지금 올라가는 게 그 화면인가" 를 **추측**한다.  타일 내용은 재사용되고,
-- 음악 트랙은 화면이 아니라 주변 상황이다.
--
-- 원본 그래픽은 디스크에 생 데이터로 없다 (2026-09-09 실측 -- 연속 8 타일을
-- raw/swap16/planes/half01 네 형태로 트랙 01·02·24 전수 검색, 0 곳).
-- 압축이라는 뜻이고, 그러면 게임은 그 화면을 그릴 때 **디스크의 특정 자리를
-- 반드시 읽는다.**  그 읽기 LBA 는 화면과 일대일이다:
--
--     타일 지문처럼 재사용되지 않는다
--     CD-DA 트랙처럼 주변 상황이 아니다
--     타일이 올라오기 **전에** 나오므로 무장 타이밍도 여유가 있다
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) CD_READ ($E009) 진입 -- 그때의 제로페이지 $F8-$FF **통째로**
--      ★인자 배치를 추측하지 않는다.  블록을 그대로 뜨고, 어느 바이트가
--        화면마다 다른지 데이터가 말하게 한다
--   2) CD_READ 를 부른 자리 (스택의 반환주소)
--   3) 타일 업로더 $725C 진입 -- 호출자 PC 히스토그램
--   4) ★업로더가 들어왔을 때 $3B00 버퍼에 **헌정 지문**이 있으면
--      그 직전 CD_READ 의 LBA·호출자를 통째로 남긴다   ← 이게 답이다
--
-- 쓰는 법  ★한 번만 뜨면 된다
--   헌정 화면을 지나고, 그 뒤로 그래픽이 바뀌는 구간을 좀 더 진행한 뒤 Stop.
--   길게 돌수록 확신이 는다 (지문이 다른 데서도 나오는지 같은 주행에서 드러난다).
--
--   요약의 "지문 적중 직전 CD_READ" 를 본다.
--     값이 한 가지뿐   -> 그 LBA 가 게이트다.  오탐이 원리적으로 사라진다
--     값이 여러 가지   -> 지문이 다른 화면에서도 나온다는 뜻.  그 LBA 들을 비교해
--                        헌정 것만 고르거나, 더 위(스크립트 명령)로 올라간다
--
--   ⚠ 2026-09-09 정정: 어젯밤 인계서는 r3 오탐 장면을 "첸슈호 대화 끝" 이라고
--     적었지만 소유자 확인 결과 **그런 일은 없었다** (CD-DA 작업 얘기가 섞였다).
--     r3 가 어디서 깨졌는지는 아직 미상이다.  대조군 장면을 가정하지 말 것.
--
-- 산출물  C:/snatcher/dump/gfxscene_0_4_1_<시각>_reads.tsv
--         C:/snatcher/dump/gfxscene_0_4_1_<시각>_hits.tsv
--         C:/snatcher/dump/gfxscene_0_4_1_<시각>_summary.txt

local CD_READ  = 0xE009          -- 시스템카드 점프테이블.  $E045=AD_STAT 로 정렬 확인함
local UPLOADER = 0x725C          -- Track 02 공용 타일 업로더 (tile_writer 로그가 확정)
local BUF      = 0x3B00          -- 업로더가 읽는 타일 버퍼
local ZP_LO, ZP_HI = 0x20F0, 0x20FF  -- ★HuC6280 zero page 는 $2000-$20FF 다
                                     --  0.4.0 은 $00F8 을 읽어 I/O 의 FF 만 봤다
local STACK    = 0x2100          -- PCE 스택 페이지

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local PC_SAMPLE = 8              -- 업로더 호출자 PC 는 8 회에 1 표본 (무거워지지 않게)
local KEEP      = 6              -- 직전 CD_READ 를 몇 개까지 들고 있나
local MAX_READS = 2000
local REPORT    = 300

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxscene_0_4_1_' .. STAMP

local rout = assert(io.open(BASE .. '_reads.tsv', 'w'))
rout:write('frame\tcaller\tF8\tF9\tFA\tFB\tFC\tFD\tFE\tFF\n')
local hout = assert(io.open(BASE .. '_hits.tsv', 'w'))
hout:write('frame\tuploader_caller\tprev_read_frame\tprev_read_caller\tprev_zp\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return (ok and type(v) == 'number') and v or -1 end

local KEYS = {}
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

-- JSR 로 들어왔을 때 스택 맨 위의 반환주소 -> 부른 자리
local function callerPC()
  local sp = spNow()
  if sp < 0 then return -1 end
  local lo = rd(STACK + ((sp + 1) & 0xFF))
  local hi = rd(STACK + ((sp + 2) & 0xFF))
  if lo < 0 or hi < 0 then return -1 end
  return ((hi << 8) | lo) & 0xFFFF          -- JSR 이 밀어넣는 값은 '다음 명령 - 1'
end

local function zpBlock()
  local t = {}
  for a = ZP_LO, ZP_HI do t[#t + 1] = rd(a) & 0xFF end
  return t
end

local function zpStr(t)
  local p = {}
  for _, v in ipairs(t) do p[#p + 1] = ('%02X'):format(v) end
  return table.concat(p, ' ')
end

local function sigHere()
  for i, want in ipairs(SIG) do
    if rd(BUF + i - 1) ~= want then return false end
  end
  return true
end

local frame = 0
local nRead, nUp, nHit = 0, 0, 0
local recent = {}                 -- 최근 CD_READ 링
local readCallers, upCallers, readByCaller = {}, {}, {}
local hitLba = {}                 -- 지문 적중 직전 CD_READ 의 제로페이지 문자열 분포
local tick = 0

emu.addMemoryCallback(function()
  nRead = nRead + 1
  local zp = zpBlock()
  local c = callerPC()
  readCallers[c] = (readCallers[c] or 0) + 1
  local ck = ('$%04X | %s'):format(c & 0xFFFF, zpStr(zp))
  readByCaller[ck] = (readByCaller[ck] or 0) + 1
  local rec = { frame = frame, caller = c, zp = zp }
  table.insert(recent, 1, rec)
  if #recent > KEEP then table.remove(recent) end
  if nRead <= MAX_READS then
    rout:write(('%d\t$%04X\t%s\n'):format(frame, c & 0xFFFF, zpStr(zp):gsub(' ', '\t')))
  end
end, emu.callbackType.exec, CD_READ, CD_READ, CPU, MEM)

emu.addMemoryCallback(function()
  nUp = nUp + 1
  local hit = sigHere()
  tick = tick + 1
  local c = -1
  if hit or (tick % PC_SAMPLE == 0) then
    c = callerPC()
    upCallers[c] = (upCallers[c] or 0) + 1
  end
  if hit then
    nHit = nHit + 1
    local p = recent[1]
    local key = p and zpStr(p.zp) or '(직전 CD_READ 없음)'
    hitLba[key] = (hitLba[key] or 0) + 1
    hout:write(('%d\t$%04X\t%s\t%s\t%s\n'):format(
      frame, c & 0xFFFF,
      p and tostring(p.frame) or '',
      p and ('$%04X'):format(p.caller & 0xFFFF) or '',
      key))
    hout:flush()
  end
end, emu.callbackType.exec, UPLOADER, UPLOADER, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 120 == 0 then rout:flush() end
  if frame % REPORT == 0 then
    say(('f%d  CD_READ %d · 업로더 %d · ★지문적중 %d'):format(frame, nRead, nUp, nHit))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  rout:close(); hout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  local function top(name, t, fmt, n)
    local r = {}
    for v, c in pairs(t) do r[#r + 1] = { v = v, c = c } end
    table.sort(r, function(x, y) return x.c > y.c end)
    put(('%s (%d 가지)'):format(name, #r))
    for i = 1, math.min(#r, n or 12) do put(('    ' .. fmt):format(r[i].v, r[i].c)) end
  end

  put(('프레임 %d'):format(frame))
  put(('CD_READ %d · 업로더 진입 %d · 지문 적중 %d'):format(nRead, nUp, nHit))
  put('')

  if nUp == 0 then
    put('★ 업로더가 한 번도 안 돌았다.  0 은 "이상 없음" 이 아니다.')
    put('   그래픽이 새로 올라오는 화면을 지나야 한다.')
  elseif nHit == 0 then
    put('★ 업로더는 돌았지만 헌정 지문은 한 번도 안 나왔다.')
    put('   -> 이 주행은 헌정 화면을 안 지났다.  그 화면을 지나서 다시 잴 것.')
    top('업로더 호출자 PC', upCallers, 'PC $%04X   %d 회')
  else
    put('★★ 지문 적중 직전의 CD_READ 인자 (제로페이지 $F8-$FF)')
    put('    ↓ 이 값이 헌정에만 나오면 그게 화면 게이트다')
    top('', hitLba, '%s   x%d', 10)
    put('')
    top('업로더 호출자 PC', upCallers, 'PC $%04X   %d 회')
  end
  put('')
  top('CD_READ 호출자 PC', readCallers, 'PC $%04X   %d 회', 10)
  put('')
  put('★ CD_READ 호출자 + 인자 조합 -- 드문 조합이 화면 로드일 가능성이 높다')
  top('', readByCaller, '%s   x%d', 20)
  put('')
  put('※ 적중 직전 CD_READ 가 한 값뿐이면 그게 게이트다.')
  put('   여러 값이면 지문이 다른 화면에서도 나온다는 뜻이다.')
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.4.1-scene-id armed -- CD_READ $E009 + 업로더 $725C · 쓰기 0 B · 화면에 안 그림')
say('  헌정 화면을 지나고, 그래픽 바뀌는 구간을 좀 더 진행한 뒤 Stop')
say('  ' .. BASE .. '_reads.tsv')
