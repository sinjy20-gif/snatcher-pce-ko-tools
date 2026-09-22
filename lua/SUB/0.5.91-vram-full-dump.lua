-- SUB 0.5.91 -- VRAM 64 KB 전체를 원본과 대조하기 위해 뜬다 (관측 전용)
--
-- 왜 전체인가
-- ---------------------------------------------------------------------------
-- 0.5.90 이 원본에서 `$7900-$7DBF` 를 6 시점 떠봤더니 **한 번도 안 바뀌었다**
-- (468/1216 word · digest 0D1DAAB5 · CD-DA 내내 · 챕터1 들어가서도).
--
--     -> 정답지는 CD-DA 시작 시점의 내용 그대로다
--     -> 그것은 우리 헬퍼가 임대 시작에 백업하는 바로 그 값이다
--     -> 즉 0.4.6.48 의 복원은 **올바른 값을 올바르게 되돌리고 있었다**
--     -> 그런데도 깨진다.  그러므로 그 대역은 범인이 아니다
--
-- 남은 설명은 하나다.  임대 중 게임의 VRAM 스트림이 우리 MAWR 도둑질로 엉뚱한
-- 곳(우리 대역)에 쏟아졌고 (0.5.80 이 게임 PC $650C 의 320 word 를 목격),
-- **원래 가야 할 자리가 비었다.**  게임은 거기를 다시 안 그린다.
--
-- 그 "빈 자리" 는 원본과 통째로 대조하면 그냥 나온다.
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
-- Track 17 오디오 LBA 창에서 CD-DA 를 잡고, 세 시점에 **VRAM 64 KB 전부**를 뜬다.
--
--     #1 CD-DA+0      빌린 직후 (기준점)
--     #2 CD-DA+2900   챕터1
--     #3 CD-DA+4200   좀 더 뒤
--
-- 각 덤프는 2 KB 블록 32 개로 나눠 digest 를 찍는다.  원본과 패치판을 한 번씩
-- 돌린 뒤 `tools/compare_vram_dumps.py` 로 블록 대조하면 깨진 자리가 특정된다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 덤프 한 번에 64 KB 를 읽으므로 그 프레임만 잠깐 멈춘다 (관측에는 무해).
--
--     원본    BIOS  ...Firmware/[BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL
--             CUE   rom(japan)/Snatcher CD-ROMantic (Japan)/….cue      TAG 'orig'
--     패치본  BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce
--             CUE   같은 폴더 [KO].cue                                  TAG 'p48'
--
-- 산출물  C:/snatcher/dump/vramref/<태그>_full_<번호>_<프레임>.bin  + 요약 TSV

local TAG = 'run'          -- ★ 'orig' / 'p48' 로 바꿔서 각각 한 번씩 돌린다

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local VRAM_BYTES = 0x10000            -- 32K word
local BLOCK = 2048                    -- 2 KB 블록 32 개
local LBA_FROM, LBA_TO = 183500, 187500

local STAMP = os.date('%Y%m%d_%H%M%S')
local DIR   = 'C:/snatcher/dump/vramref'
os.execute('mkdir "C:\\snatcher\\dump\\vramref" 2>nul')
local PATH  = string.format('%s/%s_full_%s.tsv', DIR, TAG, STAMP)
local out   = assert(io.open(PATH, 'w'))
out:write('n\tframe\tlba\tblock\tstart\tnonzero\tdigest\n')

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

local function digest(t, from, to)
  local a, b = 0x1234, 0x5678
  for i = from, to do
    a = (a + t[i]) % 0xFFF1
    b = (b + a) % 0xFFF1
  end
  return string.format('%04X%04X', b, a)
end

local n = 0
local function grab(label, lba)
  n = n + 1
  local t = {}
  for i = 0, VRAM_BYTES - 1 do t[i + 1] = emu.read(i, VRAM) or 0 end

  local name = string.format('%s_full_%d_%df.bin', TAG, n, frame)
  local f = io.open(DIR .. '/' .. name, 'wb')
  if f then
    local chunk = {}
    for i = 1, VRAM_BYTES do chunk[i] = string.char(t[i]) end
    f:write(table.concat(chunk)); f:close()
  end

  local nz, blocks = 0, {}
  for b = 0, (VRAM_BYTES / BLOCK) - 1 do
    local from, to = b * BLOCK + 1, (b + 1) * BLOCK
    local z = 0
    for i = from, to do if t[i] ~= 0 then z = z + 1 end end
    nz = nz + z
    local dg = digest(t, from, to)
    blocks[#blocks + 1] = dg
    out:write(string.format('%d\t%d\t%d\t%d\t$%04X\t%d\t%s\n',
      n, frame, lba, b, (b * BLOCK) // 2, z, dg))
  end
  out:flush()
  say('0.5.91 #%d  %df  %s  0 아닌 바이트 %d/%d  -> %s', n, frame, label, nz,
      VRAM_BYTES, name)
end

local startFrame, idle, fp = nil, 0, false
local plan, planIdx = { 0, 2900, 4200 }, 1

emu.addEventCallback(function()
  frame = frame + 1
  if not fp and frame > 60 then
    fp = true
    local t = {}
    for a = 0x5B83, 0x5B8A do t[#t + 1] = string.format('%02X', emu.read(a, MEM) or 0) end
    say('0.5.91 · 슬롯 지문 $5B83: %s', table.concat(t, ' '))
  end
  local s = sector()
  if not startFrame then
    if s >= LBA_FROM and s <= LBA_TO then
      idle = idle + 1
      if idle >= 3 then
        startFrame = frame
        say('0.5.91 · %df  CD-DA 감지 (LBA %d)', frame, s)
      end
    else
      idle = 0
    end
  elseif planIdx <= #plan and frame - startFrame >= plan[planIdx] then
    grab(string.format('CD-DA+%d', plan[planIdx]), s)
    planIdx = planIdx + 1
    if planIdx > #plan then
      say('0.5.91 ===== 덤프 %d 개 완료 -- %s', n, PATH)
      say('        python tools/compare_vram_dumps.py 로 원본과 블록 대조한다')
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.91-vram-full-dump armed [%s] -- 순수 관측 · 게임 무수정', TAG)
say('  VRAM 64 KB 를 CD-DA+0 / +2900 / +4200 세 시점에 뜬다')
say('  ★ TAG 를 바꿔 원본과 패치판을 각각 한 번씩')
say('  덤프 : ' .. DIR)
