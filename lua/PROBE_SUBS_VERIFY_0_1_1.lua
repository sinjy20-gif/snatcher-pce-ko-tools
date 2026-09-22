-- PROBE_SUBS_VERIFY 0.1.1  --  로더 + 감시를 한 스크립트로
--
-- 0.1.0 의 결함 -- 사람이 타이밍을 맞춰야 했다
-- --------------------------------------------
-- 0.1.0 은 scriptEnded 에서 한 번만 읽었다.  그런데
--   * Mesen 스크립트 창은 하나뿐이라 프로브를 열면 로더가 죽는다 -> AC 가 안 채워진다
--   * 로더를 먼저 돌렸어도, 음성이 끝나면 케이브가 $5B80 을 복원한다
--     -> 그 뒤에 읽으면 "우리 엔진이 아니다" 가 나온다
-- 실제로 0.1.0 결과가 그랬다.  엔진 미설치와 "설치 후 복원" 을 구분할 수 없었다.
--
-- 이 판이 하는 것
-- ---------------
--   1  로더 노릇을 한다.  페이로드 -> AC $1C0500, 검증 뒤 매직 -> AC $1C04F0
--   2  매 프레임 $5B80 을 본다.  우리 엔진(48 DA 5A)이 보이는 순간을 잡는다
--   3  잡히면 그 프레임과 +30 프레임에 전부 스냅샷한다
--   4  정지할 때 요약한다
--
-- 사람이 맞출 타이밍이 없다.  음성 대사 장면을 지나가고 정지하면 된다.
--
-- 출력  C:/snatcher/dump/probe_subs_verify_0_1_1_<날짜>.tsv

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.pceArcadeCardRam
local RAM_LO, DONE = 0x5B80, 0x5BDE
local PAT_WORD, SAT_WORD = 0x7900, 0x10A0
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH = "C:/snatcher/SUBTITEL/0.2.13.bin"

local function rb(a, t) return emu.read(a, t) or 0 end
local function hex(a, n, t)
  local o = {}
  for i = 0, n - 1 do o[#o+1] = string.format('%02X', rb(a + i, t)) end
  return table.concat(o, ' ')
end
local function nz(a, n, t)
  local c = 0
  for i = 0, n - 1 do if rb(a + i, t) ~= 0 then c = c + 1 end end
  return c
end
local function installed()
  return rb(RAM_LO, MEM) == 0x48 and rb(RAM_LO+1, MEM) == 0xDA and rb(RAM_LO+2, MEM) == 0x5A
end

-- ---------- 로더 ----------
local f = io.open(PATH, "rb")
if f == nil then emu.log('★ 페이로드를 못 열었다: ' .. PATH) return end
local data = f:read("a"); f:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end
emu.log(string.format('PROBE_SUBS_VERIFY 0.1.1 -- 페이로드 %d B', #data))

local loaded, tries = false, 0
local seenAt, snaps, frames = nil, {}, 0

local function snap(tag)
  local s = {}
  s[#s+1] = string.format('[%s] 프레임 %d', tag, frames)
  s[#s+1] = string.format('  RAM $5B80        %s', hex(RAM_LO, 12, MEM))
  s[#s+1] = string.format('  done $5BDE       %02X', rb(DONE, MEM))
  s[#s+1] = string.format('  VRAM byte $%04X  %s  (비영 %d/32)',
      PAT_WORD*2, hex(PAT_WORD*2, 16, VRAM), nz(PAT_WORD*2, 32, VRAM))
  s[#s+1] = string.format('  VRAM byte $%04X  %s  (비영 %d/32)',
      PAT_WORD, hex(PAT_WORD, 16, VRAM), nz(PAT_WORD, 32, VRAM))
  s[#s+1] = string.format('  SAT byte $%04X   %s', SAT_WORD*2, hex(SAT_WORD*2, 8, VRAM))
  s[#s+1] = string.format('  SAT byte $%04X   %s', SAT_WORD, hex(SAT_WORD, 8, VRAM))
  for _, line in ipairs(s) do emu.log(line); snaps[#snaps+1] = line end
end

emu.addEventCallback(function()
  frames = frames + 1

  if not loaded then
    tries = tries + 1
    for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end
    local bad = 0
    for i = 1, #data do
      if emu.read(AC_ENGINE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
    end
    if bad == 0 then
      for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, MAGIC[i], AC) end
      loaded = true
      emu.log(string.format('  적재 완료 (%d 프레임째).  이제 $5B80 을 감시한다', tries))
    elseif tries >= 300 then
      loaded = true
      emu.log('★ AC 적재 실패 -- 게임이 돌고 있는지 확인해라')
    end
    return
  end

  if seenAt == nil then
    if installed() then
      seenAt = frames
      emu.log(string.format('★ 엔진이 설치됐다 (프레임 %d)', frames))
      snap('설치직후')
    end
  elseif frames == seenAt + 30 then
    snap('+30프레임')
  end
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  if seenAt == nil then
    emu.log('★ 엔진이 설치되는 순간을 한 번도 못 봤다')
    emu.log('  -> 게이트가 통과 안 했거나, 음성 구간을 안 지났다')
    snap('정지시점')
  else
    snap('정지시점')
  end
  local name = string.format('C:/snatcher/dump/probe_subs_verify_0_1_1_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local fh = io.open(name, 'w')
  if fh then
    fh:write('line\n')
    fh:write(string.format('엔진 설치 관측: %s\n', seenAt and ('프레임 ' .. seenAt) or '없음'))
    for _, s in ipairs(snaps) do fh:write(s .. '\n') end
    fh:close()
    emu.log('-> ' .. name)
  end
end, emu.eventType.scriptEnded)

emu.log('  로더 겸 감시.  음성 대사 장면을 지나가고 정지하면 된다')
