-- SUB 0.5.77 -- 복원 직전에 백업을 **최신 화면으로** 갈아치운다 (개입 시험)
--
-- 왜 0.5.76 이 판정을 못 냈나
-- ---------------------------------------------------------------------------
-- 0.5.76 은 복원을 **건너뛰었다.**  그러면 우리가 그린 글자가 $7900-$7DBF 에
-- 그대로 남는다.  그 자리를 쓰는 화면은 어차피 깨진다.
--
--     낡은 백업으로 덮어도   깨짐
--     아무것도 안 해도       깨짐 (우리 글자가 남아서)
--
-- 두 경우가 같은 결과를 내므로 **가려지지 않는다.**  설계가 틀렸다.
--
-- 이 판이 다른 점
-- ---------------------------------------------------------------------------
-- 복원은 **그대로 돌린다.**  대신 복원 직전에 백업을 현재 VRAM 으로 덮어쓴다.
--
--     복원이 쓰는 내용 = 지금 화면에 있는 내용  ->  복원해도 아무 일도 안 일어남
--
-- 그러면 "우리 글자가 남는" 변수가 사라지고 **낡은 내용** 하나만 남는다.
--
--     화면 멀쩡   -> ★ 낡은 백업이 범인.  확정
--     여전히 깨짐 -> 복원 내용이 아니다.  재생 중 다른 것이 깨뜨린다
--
-- 왜 이 가설인가 (0.5.75 실측)
-- ---------------------------------------------------------------------------
-- ```
-- 5075f CDDA_START      우리가 $7900-$7DBF 를 백업
-- 재생 중               writesGame 320 (PC $650C-$60BA) -- 게임이 같은 자리에 씀
-- 7788f 복원            start->after=0  즉 CD-DA **시작 시점**으로 되돌림
-- 그 뒤 챕터1           게임이 재생 중에 올린 것이 지워진 채로 표시
-- ```
-- 순서가 CD-DA -> 챕터1 -> 접수처 이므로 복원은 첫 깨진 화면보다 **앞**이다.
--
-- 무엇을 어떻게
-- ---------------------------------------------------------------------------
--   · 헬퍼 진입($5B83)에서 command != 0 (복원) 이고 base 가 $7900 일 때만
--   · VRAM base*2 부터 2,432 B 를 AC $1F0400 (백업 슬롯) 으로 옮긴다
--   · Lua 쓰기는 에뮬레이션 사이클을 안 먹으므로 타이밍이 안 변한다
--
-- ★ 게임 코드는 한 바이트도 안 고친다.  백업 **내용**만 바꾼다.
-- ★ ADPCM 은 안 건드린다 (base 가 $7900 일 때만).
--
-- 판정 -- 하나만 본다
--     챕터1 화면이 멀쩡한가.  접수처까지 안 가도 된다
--
-- ⚠ 진단용이다.  Power Cycle 뒤 이 파일 하나만 로드한다.
--     BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce
--     CUE   같은 폴더 [KO].cue      · 스킵하지 말고 CD-DA 재생
--
-- ★ 화면에 아무것도 그리지 않는다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam
local AC = emu.memType.pceArcadeCardRam

local ENTRY = 0x5B83
local ENTRY_SIG = { 0xAD, 0x30, 0x5D, 0xD0 }      -- LDA $5D30 / BNE  (헬퍼 확인)
local CTL_CMD = 0x5D30
local CTL_LO, CTL_HI = 0x5D34, 0x5D35
local AC_BACKUP = 0x1F0400
local CHUNKS, CHUNK = 19, 128
local TOTAL = CHUNKS * CHUNK                      -- 2,432 B = 1,216 word
local CDDA_BASE = 0x7900

local frame, refreshed, skippedAdpcm = 0, 0, 0
local warned = false

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

local function isHelper()
  for i = 1, #ENTRY_SIG do
    if (emu.read(ENTRY + i - 1, MEM) or -1) ~= ENTRY_SIG[i] then return false end
  end
  return true
end

emu.addMemoryCallback(function()
  if not isHelper() then
    if not warned then
      warned = true
      emu.log('SUB 0.5.77 ★★ $5B83 이 헬퍼가 아니다 -- 이번 진입은 건너뛴다')
    end
    return
  end
  if (emu.read(CTL_CMD, MEM) or 0) == 0 then return end        -- 저장 경로는 무관

  local base = ((emu.read(CTL_HI, MEM) or 0) << 8) | (emu.read(CTL_LO, MEM) or 0)
  if base ~= CDDA_BASE then
    skippedAdpcm = skippedAdpcm + 1
    return
  end

  -- ★ 백업 슬롯을 지금 화면으로 덮는다.  복원은 그대로 돌되 내용이 같아진다.
  local at = base * 2
  local diff = 0
  for i = 0, TOTAL - 1 do
    local now = emu.read(at + i, VRAM) or 0
    if (emu.read(AC_BACKUP + i, AC) or -1) ~= now then diff = diff + 1 end
    emu.write(AC_BACKUP + i, now, AC)
  end
  refreshed = refreshed + 1
  if refreshed <= 5 then
    emu.log(string.format(
      'SUB 0.5.77 ★ %df · base $%04X · 백업을 현재 화면으로 갱신 #%d (바뀐 바이트 %d/%d)',
      frame, base, refreshed, diff, TOTAL))
  end
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  emu.log(string.format('SUB 0.5.77 끝 -- 갱신 %d회 · ADPCM 무시 %d회',
                        refreshed, skippedAdpcm))
  if refreshed == 0 then
    emu.log('  ★ 한 번도 갱신 안 함 -- CD-DA 복원이 안 왔다.  판정 불가')
  end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.77-refresh-cdda-backup armed')
emu.log('  복원은 그대로 돌린다.  백업 내용만 현재 화면으로 갈아치운다')
emu.log('  ★ 판정: 챕터1 화면이 멀쩡한가 (접수처까지 안 가도 된다)')
emu.log('  ★ 게임 코드는 한 바이트도 안 고친다 · ADPCM 은 안 건드린다')
