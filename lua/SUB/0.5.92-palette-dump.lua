-- SUB 0.5.92 -- VCE 팔레트를 원본과 대조한다 (관측 전용)
--
-- 왜 팔레트인가
-- ---------------------------------------------------------------------------
-- 0.5.91 로 VRAM 64 KB 를 원본과 통째로 대조했다 (2026-09-01).
--
-- ```
-- 챕터1 시점    $4800-$4FFF · $6C00-$6FFF 만 다름
-- +4200         $6F00-$6FFF 256 word (양쪽 다 난수 · 스크래치로 보임)
--               SATB $105E · $1076 각 1 word
-- BAT $0000-$0FFF   완전히 같음
-- $7900-$7DBF       완전히 같음   <- 우리 복원은 정확했다.  그 대역은 범인이 아니다
-- ```
--
-- 타일도 배치도 같은데 화면은 깨져 보인다.  그러면 남는 것은 **색**이다.
-- 우리 렌더러는 자막용으로 팔레트 $F 를 세우고 (`layout.GLYPH_PALETTE = 0x0F`)
-- 그것을 되돌린 적이 없다.  게임은 장면이 바뀔 때만 팔레트를 다시 올리므로
-- 한 번 덮으면 계속 남는다 -- 챕터1 부터 접수처까지 이어지는 성질과 맞는다.
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
-- Track 17 오디오 LBA 창에서 CD-DA 를 잡고 네 시점에 VCE 팔레트 512 엔트리
-- (배경 16 x 16 + 스프라이트 16 x 16) 를 전부 뜬다.
--
--     #1 CD-DA+0     빌리기 직전
--     #2 CD-DA+2200  첫 자막이 떠 있는 동안
--     #3 CD-DA+2900  챕터1
--     #4 CD-DA+4200  좀 더 뒤
--
-- 원본과 패치판을 한 번씩 돌린 뒤 `tools/compare_palette_dumps.py` 로 대조하면
-- **어느 팔레트의 어느 색이 달라졌는지**가 그대로 나온다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
--
--     원본    BIOS  ...Firmware/[BIOS] … .pce.JP_ORIGINAL
--             CUE   rom(japan)/…/….cue                    TAG 'orig'
--     패치본  BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce
--             CUE   같은 폴더 [KO].cue                     TAG 'p48'
--
-- 산출물  C:/snatcher/dump/vramref/<태그>_pal_<번호>_<프레임>.bin  + 요약 TSV

local TAG = 'run'          -- ★ 'orig' / 'p48' 로 바꿔서 각각 한 번씩

local MEM = emu.memType.pceMemory
local LBA_FROM, LBA_TO = 183500, 187500
local ENTRIES = 512                       -- 배경 256 + 스프라이트 256

-- 팔레트 메모리 타입은 코어마다 이름이 다르다.  있는 것을 골라 쓴다.
local PAL = nil
for _, name in ipairs({ 'pcePaletteRam', 'pceVideoColorRam', 'pceCgRam', 'palette' }) do
  if emu.memType[name] ~= nil then PAL = emu.memType[name]; break end
end

local STAMP = os.date('%Y%m%d_%H%M%S')
local DIR   = 'C:/snatcher/dump/vramref'
os.execute('mkdir "C:\\snatcher\\dump\\vramref" 2>nul')
local PATH  = string.format('%s/%s_pal_%s.tsv', DIR, TAG, STAMP)
local out   = assert(io.open(PATH, 'w'))
out:write('n\tframe\tlba\tentry\tvalue\n')

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

local n = 0
local function grab(label, lba)
  n = n + 1
  local bytes, vals = {}, {}
  for e = 0, ENTRIES - 1 do
    local lo = emu.read(e * 2, PAL) or 0
    local hi = emu.read(e * 2 + 1, PAL) or 0
    bytes[#bytes + 1] = lo; bytes[#bytes + 1] = hi
    vals[e] = lo | (hi << 8)
  end
  local name = string.format('%s_pal_%d_%df.bin', TAG, n, frame)
  local f = io.open(DIR .. '/' .. name, 'wb')
  if f then
    local chunk = {}
    for i = 1, #bytes do chunk[i] = string.char(bytes[i]) end
    f:write(table.concat(chunk)); f:close()
  end
  for e = 0, ENTRIES - 1 do
    out:write(string.format('%d\t%d\t%d\t%d\t%03X\n', n, frame, lba, e, vals[e]))
  end
  out:flush()
  -- 자막용 팔레트($F = 배경 15번) 를 눈으로도 볼 수 있게 찍는다
  local t = {}
  for i = 0, 15 do t[#t + 1] = string.format('%03X', vals[15 * 16 + i]) end
  say('0.5.92 #%d  %df  %s  -> %s', n, frame, label, name)
  say('        배경 팔레트 15 : %s', table.concat(t, ' '))
end

local startFrame, idle = nil, 0
local plan, planIdx = { 0, 2200, 2900, 4200 }, 1

emu.addEventCallback(function()
  frame = frame + 1
  local s = sector()
  if not startFrame then
    if s >= LBA_FROM and s <= LBA_TO then
      idle = idle + 1
      if idle >= 3 then
        startFrame = frame
        say('0.5.92 · %df  CD-DA 감지 (LBA %d)', frame, s)
      end
    else
      idle = 0
    end
  elseif planIdx <= #plan and frame - startFrame >= plan[planIdx] then
    grab(string.format('CD-DA+%d', plan[planIdx]), s)
    planIdx = planIdx + 1
    if planIdx > #plan then
      say('0.5.92 ===== 덤프 %d 개 완료 -- %s', n, PATH)
      say('        python tools/compare_palette_dumps.py orig p48')
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

if PAL == nil then
  say('0.5.92 ** 팔레트 메모리 타입을 못 찾았다 -- 이 프로브는 판정할 수 없다')
else
  say('SUB 0.5.92-palette-dump armed [%s] -- 순수 관측 · 게임 무수정', TAG)
  say('  VCE 512 엔트리를 CD-DA+0 / +2200 / +2900 / +4200 에 뜬다')
  say('  ★ TAG 를 바꿔 원본과 패치판을 각각 한 번씩')
  say('  덤프 : ' .. DIR)
end
