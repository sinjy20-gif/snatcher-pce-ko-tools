-- SUB 0.5.125 -- 복원 뒤 256 word 를 **누가** 쓰는지 PC 로 잡는다 (쓰기 0 B)
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- 0.5.124 로 딱 갈렸다 (세 프레임 동일):
--
--     pre   36 word   $1000-$1023   line 41..47    우리 wipe
--     A   1216 word   $6600-$6ABF   line 60..201   우리 19 청크.  정확
--     B    256 word   $6AC0-$6BBF   line 202..229  ★별도 전송
--
-- 256 word = 512 B = SATB 한 판(스프라이트 64 x 4 word)이다.  그리고 0.5.122 에서
-- 복원 프레임의 $1000 쓰기가 235~245 -> 28~36 으로 사라졌다.  같은 크기가 $6AC0 에
-- 나타났다.  MAWR 은 $6600 이후 아무도 다시 안 잡았다.
--
--     -> 게임의 SATB 갱신이 우리 VRAM 뒤로 리다이렉트되는 것으로 **보인다**
--
-- ★ 아직 지문이 없다.  크기·시점·위치·상보적 소실이 다 맞지만, 그 256 word 를
--   실제로 **누가** 썼는지는 안 봤다.  이 판은 그것만 잡는다.
--
-- 어떻게 -- 대조군을 같이 잡는다
-- ---------------------------------------------------------------------------
-- PC 조회는 비싸다 (0.5.83 이 쓰기마다 불러 1 fps 가 됐다).  그래서 **표본**만 뜬다.
--
--     A 구간   앞 몇 개 + 32 개마다     <- ★대조군.  우리 코드가 나와야 한다
--     B 구간   앞 몇 개 + 8 개마다      <- 본론
--
-- ★ A 구간 대조군이 핵심이다.  A 의 PC 가 $5B80-$5E1F 로 나오면 이 방법이 먹는다는
--   뜻이고, 그때 비로소 B 의 PC 를 믿을 수 있다.  A 가 엉뚱하게 나오면 **B 도 버린다.**
--
-- PC 만으로는 부족하다 -- PCE 는 뱅킹이 있다.  그래서 MPR 8 개도 같이 뜬다.
-- 같은 논리주소라도 MPR 이 다르면 다른 코드다.
--
-- 판정
-- ---------------------------------------------------------------------------
--     A PC 가 $5B80-$5E1F · B PC 가 그 밖    ★게임(또는 제3자)이 쓴다.  확정
--     A 와 B 의 PC 가 같은 구간              우리 코드가 256 word 를 더 쓴다
--                                            -> 헬퍼를 다시 읽어야 한다
--     A PC 가 $5B80-$5E1F 밖                 방법이 안 먹는다.  ★둘 다 버릴 것
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.124 와 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/writer_pc_0_5_125_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local ZP15 = 0x2015
local BIG_HITS = 4000

local A_EVERY, B_EVERY = 32, 8
local A_CAP, B_CAP = 12, 40

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/writer_pc_0_5_125_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tphase\twords\taddr_lo\taddr_hi\tpc_hist\tmpr\tin_engine\tverdict\n')

local function say(f, ...) emu.log(string.format(f, ...)) end

local LINE_KEY, PC_KEY
local function st()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

local function writerPC()
  local s = st()
  if not s then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc' }) do
      if type(s[k]) == 'number' then PC_KEY = k; break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local function mprString()
  local s = st()
  if not s then return '-' end
  local t = {}
  for i = 0, 7 do
    local v = s['cpu.mpr[' .. i .. ']'] or s['mpr' .. i] or s['memoryManager.mpr[' .. i .. ']']
    t[#t + 1] = type(v) == 'number' and string.format('%02X', v) or '--'
  end
  return table.concat(t, ' ')
end

-- VDC 그림자
local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits, phase = 0, 0
local buckets = {}

local function newB() return { n = 0, lo = -1, hi = -1, pc = {}, samples = 0, mpr = nil } end
local function reset() buckets = { [0] = newB(), [1] = newB(), [2] = newB() } end
reset()

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if port == 2 then if selReg == 0x00 then pendLo = value end return end
  if selReg == 0x00 then
    mawr = ((value << 8) | pendLo) & 0xFFFF
  elseif selReg == 0x05 then
    incr = incrFrom(value)
  elseif selReg == 0x02 then
    local a = mawr & 0x7FFF
    local b = buckets[phase]
    b.n = b.n + 1
    if b.lo < 0 or a < b.lo then b.lo = a end
    if b.hi < 0 or a > b.hi then b.hi = a end

    local every = (phase == 2) and B_EVERY or A_EVERY
    local cap   = (phase == 2) and B_CAP or A_CAP
    if phase >= 1 and b.samples < cap and (b.n <= 3 or b.n % every == 0) then
      local pc = writerPC()
      b.pc[pc] = (b.pc[pc] or 0) + 1
      b.samples = b.samples + 1
      if b.mpr == nil then b.mpr = mprString() end
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  value = (value or 0) & 0xFF
  if phase == 0 and value == 19 then phase = 1
  elseif phase == 1 and value == 0 then phase = 2 end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local function hist(b)
  local t = {}
  for pc, n in pairs(b.pc) do
    t[#t + 1] = { pc = pc, n = n }
  end
  table.sort(t, function(x, y) return x.n > y.n end)
  local parts = {}
  for i = 1, math.min(#t, 6) do
    parts[#parts + 1] = string.format('$%04X x%d', t[i].pc, t[i].n)
  end
  return #parts > 0 and table.concat(parts, ' · ') or '-'
end

local function allInEngine(b)
  local any = false
  for pc, _ in pairs(b.pc) do
    any = true
    if pc < ENGINE_LO or pc > ENGINE_HI then return false, true end
  end
  return any, any
end

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits >= BIG_HITS then
    restores = restores + 1
    local A, B = buckets[1], buckets[2]
    local aIn = select(1, allInEngine(A))
    local bIn = select(1, allInEngine(B))

    local verdict
    if A.samples == 0 then verdict = '★A표본없음-판정불가'
    elseif not aIn then verdict = '★대조군실패-둘다버릴것'
    elseif B.samples == 0 then verdict = 'B표본없음'
    elseif bIn then verdict = '우리코드가-더쓴다'
    else verdict = '★제3자가-쓴다' end

    for ph, name in pairs({ [1] = 'A', [2] = 'B' }) do
      local b = buckets[ph]
      out:write(string.format('%d\t%s\t%d\t%04X\t%04X\t%s\t%s\t%s\t%s\n',
        frame, name, b.n, b.lo < 0 and 0 or b.lo, b.hi < 0 and 0 or b.hi,
        hist(b), b.mpr or '-', tostring(select(1, allInEngine(b))), verdict))
    end
    out:flush()

    say('RESTORE f%d', frame)
    say('  A %d word $%04X-$%04X  PC %s', A.n, A.lo < 0 and 0 or A.lo,
        A.hi < 0 and 0 or A.hi, hist(A))
    say('      MPR %s   엔진안=%s', A.mpr or '-', tostring(aIn))
    say('  B %d word $%04X-$%04X  PC %s', B.n, B.lo < 0 and 0 or B.lo,
        B.hi < 0 and 0 or B.hi, hist(B))
    say('      MPR %s   엔진안=%s', B.mpr or '-', tostring(bIn))
    say('  [%s]', verdict)
    say('')
  end

  hits, phase = 0, 0
  reset()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.125 끝 -- 복원 %d 회 · 저장 %s', restores, PATH)
  if restores == 0 then say('0.5.125 ⚠ 복원을 못 봤다.  판정하지 말 것') end
  say('0.5.125 ⚠ A 구간(대조군) PC 가 $5B80-$5E1F 로 안 나오면 B 도 믿지 말 것')
end, emu.eventType.scriptEnded)

say('SUB 0.5.125-writer-pc armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  A 구간(우리 19청크)을 대조군으로 같이 뜬다.  거기가 엔진 안이어야 B 를 믿는다')
say('  덤프 : ' .. PATH)
