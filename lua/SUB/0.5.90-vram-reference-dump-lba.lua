-- SUB 0.5.90 -- $7900-$7DBF 의 "정답지" 를 뜬다 (원본/패치판 공용 · 관측 전용)
--
-- 왜
-- ---------------------------------------------------------------------------
-- 노스킵 챕터1 에서 깨지는 자리는 **게임이 다시 안 그리는 VRAM** 이다
-- (소유자 확인 2026-09-01).  그러니 거기 있어야 할 값은 하나로 정해져 있다.
--
--     복원(.48)      낡은 그림을 덮음      -> 깨짐
--     기입 생략(.56) 우리 글자가 남음      -> 깨짐
--     0 으로 칠함(.58)                     -> 깨짐
--
-- 셋 다 **근거 없는 값**이었다.  추측을 그만두고 원본에서 실측한다.
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
-- CD-DA(Track 17) 재생을 감지한 뒤 정해진 시점마다 VRAM word $7900-$7DBF
-- (2,432 B) 를 통째로 파일로 뜬다.  헬퍼도 STATE 도 안 본다 -- **원본 게임에서도
-- 그대로 돈다.**
--
--     dump #1  CD-DA 시작 직후          우리가 백업하는 그 시점
--     #2 +2188  첫 자막 문턱
--     #3 +2683  마지막 문턱 (복원 시점)
--     #4 +2900 · #5 +3400 · #6 +4200    챕터1 진입 이후
--
-- 매 덤프마다 SHA 앞 16 자리와 0 이 아닌 word 수를 로그로 찍는다.  원본과
-- 패치판을 같은 파일로 한 번씩 돌려 **같은 번호끼리 비교**하면 된다.
--
--     원본 #4 == 패치 #4   -> 이 대역은 범인이 아니다
--     다르다               -> 원본 #4 가 곧 정답지다.  그걸 팩에 구워 복원 때 쓴다
--                             (0.4.6.11 의 접수처 복구와 같은 방식 · 다만 실측값)
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 원본으로 돌릴 때 BIOS 는 Firmware/...pce.JP_ORIGINAL (E11527B3B96CE112),
--   디스크는 rom(japan)/Snatcher CD-ROMantic (Japan)/….cue 를 쓴다.
--
-- 산출물  C:/snatcher/dump/vramref/<태그>_<번호>_<프레임>.bin  + 요약 TSV
--   태그는 아래 TAG 를 바꿔서 원본/패치판을 구분한다.

local TAG = 'run'          -- ★ 'orig' / 'p48' / 'p58' 처럼 바꿔서 돌린다

-- 0.5.89 는 데이터 트랙 읽기(LBA 211857)에 걸려 CD-DA 보다 한참 앞에서 떴다.
-- Track 17 오디오 구간은 0.5.80/0.5.82 가 실측해 둔 값이다.  디스크 배치는
-- 빌드와 무관하므로 원본에서도 같은 창을 쓴다.
local LBA_FROM, LBA_TO = 183500, 187500

local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

local WORD_LO, WORD_HI = 0x7900, 0x7DBF
local BYTES = (WORD_HI - WORD_LO + 1) * 2          -- 2,432 B

local STAMP = os.date('%Y%m%d_%H%M%S')
local DIR   = 'C:/snatcher/dump/vramref'
local PATH  = string.format('%s/%s_%s.tsv', DIR, TAG, STAMP)
os.execute('mkdir "C:\\snatcher\\dump\\vramref" 2>nul')
local out = assert(io.open(PATH, 'w'))
out:write('n\tframe\tbytes\tnonzero_words\tdigest\tfile\n')

local frame = 0
local function say(f, ...) emu.log(string.format(f, ...)) end

local sectorKey = nil
local function sector()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if sectorKey == nil then
    for _, k in ipairs({ 'cdrom.audioPlayer.currentSector',
                         'cdrom.audio.currentSector',
                         'cdrom.currentSector' }) do
      if s[k] ~= nil then sectorKey = k; break end
    end
  end
  local v = sectorKey and s[sectorKey] or nil
  return type(v) == 'number' and math.floor(v) or -1
end

-- 가벼운 체크섬 (외부 라이브러리 없이 두 판을 대조하기만 하면 된다)
local function digest(bytes)
  local a, b = 0x1234, 0x5678
  for i = 1, #bytes do
    a = (a + bytes[i]) % 0xFFF1
    b = (b + a) % 0xFFF1
  end
  return string.format('%04X%04X', b, a)
end

local n = 0
local function grab(label)
  n = n + 1
  local bytes, nz = {}, 0
  for w = WORD_LO, WORD_HI do
    local lo = emu.read(w * 2, VRAM) or 0
    local hi = emu.read(w * 2 + 1, VRAM) or 0
    bytes[#bytes + 1] = lo; bytes[#bytes + 1] = hi
    if lo ~= 0 or hi ~= 0 then nz = nz + 1 end
  end
  local name = string.format('%s_%d_%df.bin', TAG, n, frame)
  local f = io.open(DIR .. '/' .. name, 'wb')
  if f then
    local chunk = {}
    for i = 1, #bytes do chunk[i] = string.char(bytes[i]) end
    f:write(table.concat(chunk)); f:close()
  end
  local dg = digest(bytes)
  say('0.5.90 #%d  %df  %s  0 아닌 word %d/1216  digest %s', n, frame, label, nz, dg)
  out:write(string.format('%d\t%d\t%d\t%d\t%s\t%s\n', n, frame, BYTES, nz, dg, name))
  out:flush()
end

local startFrame, idle = nil, 0
local fingerprinted = false
local plan, planIdx = { 0, 2188, 2683, 2900, 3400, 4200 }, 1

emu.addEventCallback(function()
  frame = frame + 1
  local s = sector()
  if not fingerprinted and frame > 60 then
    fingerprinted = true
    local t = {}
    for a = 0x5B83, 0x5B8A do t[#t + 1] = string.format('%02X', emu.read(a, MEM) or 0) end
    say('0.5.90 · 슬롯 지문 $5B83: %s   (어느 판이 돌고 있는지 확인용)',
        table.concat(t, ' '))
  end
  if not startFrame then
    -- ★ Track 17 오디오 LBA 창 안에서만 잡는다
    if s >= LBA_FROM and s <= LBA_TO then
      idle = idle + 1
      if idle >= 3 then
        startFrame = frame
        say('0.5.90 · %df  CD-DA 감지 (LBA %d) -- 이제부터 정해진 시점에 뜬다', frame, s)
      end
    else
      idle = 0
    end
  elseif planIdx <= #plan and frame - startFrame >= plan[planIdx] then
    grab(string.format('CD-DA+%d (LBA %d)', plan[planIdx], s))
    planIdx = planIdx + 1
    if planIdx > #plan then
      say('0.5.90 ===== 덤프 %d 개 완료 -- %s', n, PATH)
      say('        같은 번호끼리 digest 를 비교한다 (원본 vs 패치판)')
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.90-vram-reference-dump-lba armed [%s] -- 순수 관측 · 게임 무수정', TAG)
say('  $7900-$7DBF (2,432 B) 를 CD-DA 기준 6 시점에 뜬다')
say('  ★ TAG 를 바꿔가며 원본 / 패치판을 각각 한 번씩 돌린다')
say('  덤프 : ' .. DIR)
