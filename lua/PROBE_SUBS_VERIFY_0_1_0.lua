-- PROBE_SUBS_VERIFY 0.1.0
--
-- 무엇을 재나
-- ------------
-- SUBTITEL 0.2.13 이 어디까지 실제로 해냈는지.  단계별로 되읽는다.
--
-- 왜 필요한가
--   0.2.13 은 화면이 깨끗한데 글자가 안 뜬다.  용의자가 셋인데 추측으로는 못 가른다.
--     1  엔진이 설치가 안 됐다
--     2  설치는 됐는데 업로드 경로를 한 번도 못 탔다 (PC 가드가 계속 튕김)
--     3  업로드는 됐는데 화면에 안 나온다 (SAT 값·팔레트·슬롯)
--
-- 읽는 것
--   RAM  $5B80  엔진 첫 바이트.  48 DA 5A .. 면 우리 엔진이다
--   RAM  $5BDE  done 플래그.  01 이면 업로드 경로를 탔다
--   VRAM 워드 $7900  패턴이 도착했나
--   VRAM 워드 $10A0  SAT 엔트리가 도착했나 (f4 00 84 00 c8 03 80 00 이어야 한다)
--
-- ★ Mesen 의 pceVideoRam 은 **바이트 주소**다 (V12 가 tile*32 로 읽는다).
--   그래서 워드 $7900 = 바이트 $F200, 워드 $10A0 = 바이트 $2140 이다.
--   확신이 없으므로 두 해석 모두 읽어서 보여준다.
--
-- 출력  C:/snatcher/dump/probe_subs_verify_0_1_0_<날짜>.tsv   (읽기만 한다)
--
-- 쓰는 법  음성 대사를 한 번 지나간 뒤 실행하고 정지한다.

local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
local RAM_LO, DONE = 0x5B80, 0x5BDE
local PAT_WORD, SAT_WORD = 0x7900, 0x10A0
local WANT_SAT = { 0xF4,0x00,0x84,0x00,0xC8,0x03,0x80,0x00 }

local function rb(a, t) return emu.read(a, t) or 0 end
local function hex(a, n, t)
  local o = {}
  for i = 0, n - 1 do o[#o+1] = string.format('%02X', rb(a + i, t)) end
  return table.concat(o, ' ')
end
local function nonzero(a, n, t)
  local c = 0
  for i = 0, n - 1 do if rb(a + i, t) ~= 0 then c = c + 1 end end
  return c
end

local function run()
  local lines = {}
  local function say(s) emu.log(s); lines[#lines+1] = s end

  say('--- 1. 엔진 설치 ---')
  say(string.format('  RAM $%04X : %s', RAM_LO, hex(RAM_LO, 12, MEM)))
  local ok = rb(RAM_LO, MEM) == 0x48 and rb(RAM_LO+1, MEM) == 0xDA and rb(RAM_LO+2, MEM) == 0x5A
  say('  -> ' .. (ok and '우리 엔진이 설치돼 있다' or '★ 우리 엔진이 아니다 (설치 실패 또는 이미 복원됨)'))

  say('--- 2. done 플래그 ---')
  local d = rb(DONE, MEM)
  say(string.format('  $%04X = %02X  -> %s', DONE, d,
      d == 1 and '업로드 경로를 탔다' or '★ 한 번도 안 탔다 (PC 가드가 계속 튕겼거나 게이트 미통과)'))

  say('--- 3. 패턴 (VRAM) ---')
  say(string.format('  워드해석 $%04X    : %s  (비영 %d/32)',
      PAT_WORD, hex(PAT_WORD, 16, VRAM), nonzero(PAT_WORD, 32, VRAM)))
  say(string.format('  바이트해석 $%04X  : %s  (비영 %d/32)',
      PAT_WORD*2, hex(PAT_WORD*2, 16, VRAM), nonzero(PAT_WORD*2, 32, VRAM)))

  say('--- 4. SAT 엔트리 (VRAM) ---')
  say(string.format('  기대값            : F4 00 84 00 C8 03 80 00'))
  say(string.format('  워드해석 $%04X    : %s', SAT_WORD, hex(SAT_WORD, 8, VRAM)))
  say(string.format('  바이트해석 $%04X  : %s', SAT_WORD*2, hex(SAT_WORD*2, 8, VRAM)))
  local m1, m2 = true, true
  for i = 1, 8 do
    if rb(SAT_WORD + i - 1, VRAM) ~= WANT_SAT[i] then m1 = false end
    if rb(SAT_WORD*2 + i - 1, VRAM) ~= WANT_SAT[i] then m2 = false end
  end
  say('  -> ' .. (m1 and '워드해석 자리에 일치' or m2 and '바이트해석 자리에 일치'
      or '★ 어느 쪽에도 없다'))

  local name = string.format('C:/snatcher/dump/probe_subs_verify_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
    emu.log('-> ' .. name)
  end
end

emu.addEventCallback(run, emu.eventType.scriptEnded)
emu.log('PROBE_SUBS_VERIFY 0.1.0 loaded')
emu.log('  음성 대사 한 번 지나간 뒤 정지하면 단계별로 되읽는다')
