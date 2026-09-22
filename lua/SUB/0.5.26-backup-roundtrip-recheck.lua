-- SUB 0.5.26 -- SEI 를 뺀 뒤에도 VRAM 백업 왕복이 무손실인가 (쓰기 0 B)
--
-- 왜 다시 재나
-- ---------------------------------------------------------------------------
-- "백업 왕복 6/6 무손실" 은 **SEI 가 살아 있던 빌드**에서 잰 것이다.
-- 현행 기준판은 `$7F4A: 78 -> EA` 로 SEI 를 영구히 뺐다 (baseline §1/§4).
-- 그러면 helper 실행 중에 래스터 IRQ 가 들어올 수 있다.
--
-- helper 448 B 를 디스어셈한 결과 (2026-08-30, 해시 5A218EE1... 동결본)
-- ---------------------------------------------------------------------------
-- 세 루틴 전부 **VDC 선택 래치를 세워두고 여러 명령에 걸쳐 유지**한다.
--
--     save    $5BA4 ST0 #$01 -> STA $0002/$0003        4 명령 유지
--             $5BB2 ST0 #$02 -> TAI/TIN x19            4,864 B 전송 내내 유지
--     restore $5C19 ST0 #$02 -> LDA $1A00/STA .. x128 를 19 회
--     wipe    $5C4E ST0 #$01 .. $5C55 ST0 #$02 .. LDA $0002/$0003   7 명령 x64
--
-- ★ 그리고 helper 는 `ST0/ST1/ST2` 를 쓴다.  이 명령들은 게임의 섀도우 `$F7` 을
--   갱신하지 않는다.  그래서 IRQ 가 끼어들면 핸들러가 어떻게 하든 우리 값으로는
--   못 돌아온다.
--
--       핸들러가 복원 안 하면       래치 = $06 (RCR)   -> TAI 가 RCR 을 읽는다
--       핸들러가 $F7 로 복원하면    래치 = 게임의 값    -> 우리 $02 가 아니다
--
--   SEI 가 그것을 막고 있었다.  지금은 없다.
--
-- ⚠ 그러나 이것은 **가설이다.**  리프 `$E41F` 만 봤고 래스터 IRQ 핸들러 본체
--   (`$2202 -> $40A4`) 는 안 봤다.  핸들러가 `$0000` 을 아예 안 건드릴 수도 있다.
--   그래서 기계론이 아니라 **기능**을 직접 잰다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) VRAM -> AC     save 직후, AC $1F0400 의 2,432 B 가 저장 전 VRAM 과 같은가
--   2) AC -> VRAM     restore 직후, VRAM 이 **저장 전 원본**으로 돌아왔는가
--   3) 기계론 직격     helper 실행 중 **우리가 아닌 코드**가 VDC $0000 (레지스터
--                      선택) 에 쓰는가.  쓴다면 그 PC 는 어디인가
--
-- 읽는 법
--     불일치 0 · 외부쓰기 0    안전.  이 감사 항목을 닫는다
--     불일치 0 · 외부쓰기 >0   래치는 건드려지는데 결과는 멀쩡하다.
--                              핸들러가 복원한다는 뜻 -> PC 를 보고 확인
--     불일치 >0                ★ 백업이 깨지고 있다.  SEI 제거의 대가다
--
-- ★ 이 판은 `$7F4A` 가 NOP 이어도 오염이 아니다 -- 현행 기준판이 그렇다.
--   (0.5.16~0.5.21 의 오염 가드는 거꾸로다.  그것들을 이 빌드에 쓰지 말 것)
--
-- 읽기 전용이다.  Power Cycle 뒤 **이 파일 하나만** 로드한다.
-- 자막 스택은 baseline §1 의 통과 기준판을 그대로 물어온다.
--     0.4.93-hq-key-vram -> 0.4.89-vdc-rearm
-- 디스크/BIOS 는 동결 이미지 0.4.6.22-dictionary-key-vram 을 쓴다.

-- ★ 화면 오버레이 전면 차단.
-- 동결본 0.4.93(§2 해시 등재) 과 0.4.31 이 각각 HUD 를 그린다.  그 파일들을
-- 고치면 동결 해시가 깨지므로 **한 바이트도 안 건드리고** 함수만 무력화한다.
-- 이 무력화는 이 스크립트가 도는 동안에만 유효하다.
emu.drawString = function() end

dofile('C:/snatcher/lua/SUB/0.4.93-hq-key-vram.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam
local AC   = emu.memType.pceArcadeCardRam

-- helper 디스어셈에서 그대로 따온 상수 (해시 5A218EE1... 448 B)
local HELPER_LO, HELPER_HI = 0x5B80, 0x5D3F
local ENTRY      = 0x5B83
local ENTRY_SIG  = { 0xAD, 0x30, 0x5D, 0xD0, 0x64 }   -- LDA $5D30 / BNE  (renderer 와 구별)
local SAVE_RTS   = 0x5BEB
local RESTORE_RTS= 0x5C3F
local CTL_CMD    = 0x5D30
local CTL_BASE_L, CTL_BASE_H = 0x5D34, 0x5D35
local AC_BACKUP  = 0x1F0400        -- $1A02/$1A03/$1A04 = 00/04/1F
local CHUNKS, CHUNK_BYTES = 19, 128
local TOTAL = CHUNKS * CHUNK_BYTES -- 2,432 B = 1,216 word

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/backup_roundtrip_0_5_26_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tevent\tbase_word\tmismatch\ttotal\tforeign_w0\tfirst_pc\n') end

local function pc()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, k in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[k]) == 'number' then return math.floor(s[k]) & 0xFFFF end
  end
  return -1
end

local frame = 0
local inHelper = false
local snapshot = nil          -- 저장 전 VRAM 원본
local snapBase = -1
local foreign, foreignPC = 0, -1
local saves, restores = 0, 0
local badSave, badRound = 0, 0

local function isHelper()
  for i = 1, #ENTRY_SIG do
    if (emu.read(ENTRY + i - 1, MEM) or -1) ~= ENTRY_SIG[i] then return false end
  end
  return true
end

local function baseWord()
  local lo = emu.read(CTL_BASE_L, MEM) or 0
  local hi = emu.read(CTL_BASE_H, MEM) or 0
  return (hi << 8) | lo
end

-- VRAM 은 바이트 주소로 읽는다.  word 주소 * 2 가 시작이다.
local function readVram(bw, n)
  local t, at = {}, bw * 2
  for i = 0, n - 1 do t[i + 1] = emu.read(at + i, VRAM) or 0 end
  return t
end

local function readAc(at, n)
  local t = {}
  for i = 0, n - 1 do t[i + 1] = emu.read(at + i, AC) or 0 end
  return t
end

local function diff(a, b)
  if not a or not b then return -1 end
  local n = 0
  for i = 1, math.min(#a, #b) do if a[i] ~= b[i] then n = n + 1 end end
  return n
end

local function record(ev, base, mm)
  if out then
    out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%s\n',
      frame, ev, base, mm, TOTAL, foreign,
      foreignPC >= 0 and string.format('%04X', foreignPC) or '-'))
    out:flush()
  end
end

-- 진입
emu.addMemoryCallback(function()
  if not isHelper() then return end
  inHelper = true
  foreign, foreignPC = 0, -1
  local cmd = emu.read(CTL_CMD, MEM) or 0
  if cmd == 0 then
    snapBase = baseWord()
    snapshot = readVram(snapBase, TOTAL)      -- 저장 **전** 원본을 잡아둔다
  end
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

-- save 완료 -- VRAM -> AC 를 검증
emu.addMemoryCallback(function()
  if not inHelper then return end
  inHelper = false
  saves = saves + 1
  local ac = readAc(AC_BACKUP, TOTAL)
  local mm = diff(snapshot, ac)
  if mm ~= 0 then badSave = badSave + 1 end
  emu.log(string.format(
    'SUB 0.5.26 %s SAVE #%d · base $%04X(word) · VRAM→AC 불일치 %d/%d · 외부 $0000 쓰기 %d%s',
    mm == 0 and '·' or '★', saves, snapBase, mm, TOTAL, foreign,
    foreignPC >= 0 and string.format(' (PC $%04X)', foreignPC) or ''))
  record('SAVE', snapBase, mm)
end, emu.callbackType.exec, SAVE_RTS, SAVE_RTS, CPU, MEM)

-- restore 완료 -- 왕복(AC -> VRAM)을 검증
emu.addMemoryCallback(function()
  if not inHelper then return end
  inHelper = false
  restores = restores + 1
  local nowBase = baseWord()
  local back = readVram(nowBase, TOTAL)
  local mm = diff(snapshot, back)
  if mm ~= 0 then badRound = badRound + 1 end
  emu.log(string.format(
    'SUB 0.5.26 %s RESTORE #%d · base $%04X · 왕복 불일치 %d/%d · 외부 $0000 쓰기 %d%s%s',
    mm == 0 and '·' or '★', restores, nowBase, mm, TOTAL, foreign,
    foreignPC >= 0 and string.format(' (PC $%04X)', foreignPC) or '',
    (snapBase >= 0 and nowBase ~= snapBase) and ' ⚠base 바뀜' or ''))
  record('RESTORE', nowBase, mm)
end, emu.callbackType.exec, RESTORE_RTS, RESTORE_RTS, CPU, MEM)

-- ★ 기계론 직격: helper 도는 동안 우리가 아닌 코드가 레지스터 선택을 건드리는가
emu.addMemoryCallback(function(address)
  if not inHelper then return end
  if (address & 3) ~= 0 then return end          -- $0000 = 레지스터 선택만
  local p = pc()
  if p >= HELPER_LO and p <= HELPER_HI then return end   -- 우리 것은 뺀다
  foreign = foreign + 1
  if foreignPC < 0 then foreignPC = p end
end, emu.callbackType.write, 0x0000, 0x0000, CPU, MEM)

-- ★ 화면에 아무것도 그리지 않는다.  게임 화면을 가리면 눈으로 하는 판정이 막힌다.
-- 상태는 전부 로그와 TSV 로만 낸다.
local seiSeen = nil
emu.addEventCallback(function()
  frame = frame + 1
  -- $7F4A 는 어느 빌드인지 알려주는 값이다.  바뀔 때만 한 줄 남긴다
  local sei = emu.read(0x7F4A, MEM) or -1
  if sei ~= seiSeen then
    seiSeen = sei
    emu.log(string.format('SUB 0.5.26 · %df · $7F4A = %s',
      frame, sei == 0x78 and 'SEI (구 빌드)' or
             (sei == 0xEA and 'NOP (현행 기준판)' or string.format('$%02X ??', sei))))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.26-backup-roundtrip-recheck armed -- SEI 제거 후 백업 왕복 재검증')
emu.log('  1) save 직후 VRAM→AC  2) restore 직후 왕복  3) helper 중 외부 $0000 쓰기')
emu.log('  ★ $7F4A 가 NOP 이어도 오염이 아니다 (현행 기준판이 그렇다)')
emu.log('  ★ SAVE/RESTORE 가 0 이면 판정 불가 -- 자막 Lua 를 같이 로드했는지 볼 것')
emu.log('  로그: ' .. OUT)
