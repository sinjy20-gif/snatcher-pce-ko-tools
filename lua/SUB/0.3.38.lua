-- SUB 0.3.38 -- 0.3.37 + "패치가 정말 먹었나" 확인
--
-- 0.3.37 로 base 를 $1110 으로 강제했는데 하단 깨짐이 이전과 똑같다는 보고.
-- 그렇다면 글리프 쓰기 경로가 안 옮겨진 것이다.  의심 지점:
--
--   prepareFirst 는 헬퍼를 AC 사본에 패치한다 (AC_HELPER + 39/41/131/133).
--   그런데 헬퍼는 AC 에서 실행되지 않는다 -- RAM 으로 복사된 뒤 돈다.
--   이미 복사가 끝난 뒤라면 AC 를 고쳐도 이번 판에는 효과가 없다.
--   그러면 글리프는 여전히 $7900 에 쓰이고 SATB 만 $1110 을 가리킨다.
--
-- 이 판은 count_ok 패치 직후 세 가지를 읽어서 찍는다.
--
--   CPU 렌더러 off 165/167/276 이 기대값인가        -> 렌더러 패치 성공 여부
--   AC 헬퍼   off 39/41/131/133 이 기대값인가        -> AC 쓰기 자체는 됐는가
--   VRAM 의 base / $7900 / $6100 에 0 아닌 word 수  -> 글리프가 실제로 어디 있나
--
-- 마지막 줄이 핵심이다.  base 가 0 이고 $7900 이 차 있으면 쓰기 경로가
-- 안 옮겨진 것이고, 헬퍼를 RAM 사본에서 패치해야 한다는 뜻이다.
--
-- SUB 0.3.37 -- 창 밖 주소 강제 시험 (패턴 상위 비트가 실재하는지 가른다)
--
-- 0.3.36 측정:
--   창 $6000-$7FFF  최대연속   768 word · 총여유  1,392
--   VRAM 전체       최대연속 3,824 word @ $1110 · 총여유 11,648
--   (BAT 4096 + SATB 256 은 used 로 제외)
--
-- 자리는 창 밖에 있다.  그런데 $1110 을 쓰려면 base>>13 이 3 에서 0 으로
-- 바뀌므로 패턴 상위 2 비트를 패치해야 하는데, 그 자리를 바이너리에서 아직
-- 못 찾았다 (LDA #$03 없음 · STA $5CF3,X 없음 · off 364 이후는 작업 버퍼).
--
-- 그래서 아는 것만 고치고 강제로 써 본다.
--
--   patch  off 165 MAWR 하위 · off 167 MAWR 상위 · off 276 패턴 하위
--   미패치 패턴 상위 2 비트
--
-- 결과 해석:
--   글리프 정상          상위 비트는 안 쓰이거나 다른 데서 유도된다 -> 창 확장 끝
--   글리프 엉뚱한 자리   상위 비트 실재 -> 렌더러 쪽을 계속 추적
--   아무것도 안 뜸       헬퍼가 복사를 못 한다 -> 헬퍼 쪽도 상위 비트 필요
--
-- 주소를 바꿔 보려면:  SUB_ALLOCATOR_FORCE_BASE = 0xXXXX  를 먼저 세우고 실행.
-- 평소 탐색으로 돌리려면 파일 안 FORCE_BASE 를 nil 로.
-- snapshot/restore 는 그대로라 음성이 끝나면 원래 내용으로 되돌린다.
--
-- SUB 0.3.36 -- 0.3.35 의 측정 오류를 고친 판
--
-- 0.3.35 는 "VRAM 전체 최대연속 4352 word @ $0000" 을 찍고 "창 확장으로 해결
-- 가능" 이라고 판정했다.  ★ 그 4352 word 는 BAT($0000-$0FFF, 4096) 와
-- SATB($1000-$10FF, 256) 자신이다.  referencedWords() 가 BAT 가 가리키는
-- 타일 패턴만 표시하고 BAT/SATB 본체는 표시하지 않아서 살아 있는 구조 둘이
-- 통째로 "비어 있음" 으로 잡혔다.
--
-- 지금 창이 $6000-$7B00 이라 우연히 안 건드렸을 뿐이다.  그 판정을 믿고 창을
-- 넓혔으면 BAT 를 덮어써 화면이 통째로 날아갔다.
--
-- 이 판은 BAT 와 SATB 를 used 로 표시한 뒤 다시 잰다.  나머지는 0.3.35 와 같다.
--
-- SUB 0.3.35 -- 0.3.34 + 실패 시 부족량 측정
--
-- 0.3.34 (간격 0x40, 시도 108 번) 로도 조각 #2 에서 SKIP 이 났다.
-- 다음 수를 고르려면 "얼마나 모자란가" 를 알아야 한다.
--
--   창 $6000-$7FFF 최대연속 < N  그런데  VRAM 전체 최대연속 >= N
--       -> 창 확장으로 해결된다 (패턴 상위 2 비트 자리를 찾아야 함)
--   VRAM 전체 최대연속 < N
--       -> 창을 넓혀도 소용없다.  글리프 개별 배치로 연속성을 깨거나
--          N (= 글리프 수 x 0x40) 을 줄여야 한다
--
-- SKIP 이 날 때만 SHORTFALL 세 줄을 찍는다.  나머지 동작은 0.3.34 와 같다.
--
-- SUB 0.3.34 -- 0.3.5 와 같은 동작 + 후보 간격 0x100 -> 0x40 (독립 파일)
--
-- 왜: 0.3.5 로 메탈기어 이후 문서 화면을 지나니 조각 #2 에서
--     "SKIP: count_ok 뒤 안전 블록 없음" 이 났다.  그 장면은 BG 패턴 892 개
--     (약 14,272 word)가 참조 중이라 $6000-$7B00 을 0x100 간격으로 28 번
--     보는 것으로는 연속 1216 word 를 못 찾는다.  간격을 0x40 으로 줄여
--     시도를 28 -> 108 번으로 늘린다.
--
-- 어떻게: 지금까지는 VRAM 주소의 상위 바이트만 패치해 base 가 0x100 정렬이어야
--     했다.  바이너리를 뜯어 하위 바이트 자리를 찾았다.
--
--       renderer  off 164 13 00 = ST1 #$00  -> off 165 가 MAWR 하위
--                 off 166 23 79 = ST2 #$79  -> off 167 이 MAWR 상위
--                 off 276 = 패턴 하위 (69 C8 = ADC #$C8)
--       helper    off 38 13 00 -> off 39 하위 / off 40 23 79 -> off 41 상위
--                 off 130 13 00 -> off 131 하위 / off 132 23 79 -> off 133 상위
--
--     이제 하위 바이트도 같이 패치하므로 검사한 자리와 실제 업로드 자리가 같다.
--
-- 창은 아직 $6000-$7B00 그대로다.  32K 전체로 넓히려면 패턴 상위 2 비트
-- (base>>13) 자리를 찾아야 하는데 아직 확정하지 않았다.  이 창 안에서는
-- base>>5 의 상위 2 비트가 항상 3 이라 상위 비트를 안 건드려도 정합하다.
--
-- 0.3.5 의 전역 설정(INPLACE_IMAGES / TARGET_END=0x6800 / PATCH_AT_COUNT_OK)을
-- 파일 안에 기본값으로 넣었다.  이 파일 하나만 실행하면 된다.
-- 읽기 전용이 아니다 -- VRAM 주소 피연산자와 VRAM 자체를 쓴다.
--
-- Dynamic subtitle VRAM allocator POC 0.3.1 -- referenced-free blocks (2026-08-26)
--
-- 0.3.0 은 VRAM 내용이 전부 0 인 블록만 골랐다.  게임은 장면이 바뀌어도 예전
-- 패턴을 VRAM 에 남겨 두므로, 아무도 참조하지 않는 안전한 자리도 거의 전부
-- 탈락했다.  이 판은 내용이 아니라 현재 BAT + SATB 참조만 본다.
--
-- 이번 판의 범위
-- -------------
--   * BAT: 현재 VDC columnCount * rowCount 엔트리가 참조하는 8x8 패턴 제외
--   * SATB: 현재 64 슬롯이 참조하는 스프라이트 패턴 범위 제외
--   * 후보 간격은 0x100 word 유지
--
-- 후보 간격을 아직 0x40 으로 줄이지 않는 이유:
-- helper/renderer 의 VRAM 주소 하위 바이트는 현재 바이너리에 00 으로 고정돼 있고
-- 이 Lua 는 상위 바이트만 패치한다.  하위 바이트 패치 위치를 확정하기 전 0x40
-- 후보를 쓰면 검사한 자리와 실제 백업/업로드 자리가 달라질 수 있다.
--
-- Lua 전용 검증판.  디스크 빌드에는 아직 넣지 않는다.

local MEM, VRAM, AC, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam,
                              emu.memType.pceArcadeCardRam, emu.memType.cpu
local VERSION = rawget(_G, 'SUB_ALLOCATOR_VERSION') or '0.3.38'
local INPLACE_IMAGES = rawget(_G, 'SUB_ALLOCATOR_INPLACE_IMAGES') ~= false
local TARGET_END = rawget(_G, 'SUB_ALLOCATOR_TARGET_END') or 0x6800
-- 창 밖 주소를 강제로 써 본다.  0.3.36 측정에서 $1110-$1FFF 에
-- 3824 word 연속 공백이 있었다.  nil 로 두면 평소대로 탐색한다.
local FORCE_BASE = rawget(_G, 'SUB_ALLOCATOR_FORCE_BASE') or 0x1110
local PATCH_AT_COUNT_OK = rawget(_G, 'SUB_ALLOCATOR_PATCH_AT_COUNT_OK') ~= false
local ENGINE, REBUILD, STATE = 0x5B80, 0x5BA6, 0x7FDF
local AC_HELPER, AC_RENDERER = 0x1F1C00, 0x1F1F00
local N = 19 * 0x40
local active, started, firstBase, currentBase, pendingBase, rebuilds = false, false, nil, nil, nil, 0
local saved = {}

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end
local HELPER = readFile('C:/snatcher/build/cutscene_subs/subtitle_vram_helper.bin')
local RENDERER = readFile('C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin')
local KEY = {0x78, 0x30, 0x00, 0x00, 0x68, 0x0E}

local function poke(s, pos, value)
  return s:sub(1, pos - 1) .. string.char(value) .. s:sub(pos + 1)
end
local function put(at, data)
  for i = 1, #data do emu.write(at + i - 1, data:byte(i), AC) end
end
local function prepareFirst(base)
  -- helper 41/133, renderer 167/276 are binary zero-based offsets.
  if INPLACE_IMAGES then
    -- 0.3.2: 디스크가 Track24에서 선적재한 현재 판본을 보존한다.
    -- 전체 이미지를 로컬 파일로 교체하거나 selector KEY를 덮지 않고,
    -- VRAM 기준 주소를 담은 피연산자 네 바이트만 바꾼다.
    emu.write(AC_HELPER + 39, base & 0xFF, AC)
    emu.write(AC_HELPER + 41, base >> 8, AC)
    emu.write(AC_HELPER + 131, base & 0xFF, AC)
    emu.write(AC_HELPER + 133, base >> 8, AC)
    if PATCH_AT_COUNT_OK then
      -- 조회가 끝나기 전에는 renderer를 한 바이트도 건드리지 않는다.
      -- CPU로 복사된 뒤 count_ok callback에서 주소만 바꾼다.
      return
    end
    emu.write(AC_RENDERER + 165, base & 0xFF, AC)
    emu.write(AC_RENDERER + 167, base >> 8, AC)
    emu.write(AC_RENDERER + 276, (base >> 5) & 0xFF, AC)
    return
  end
  local h = poke(poke(HELPER, 42, base >> 8), 134, base >> 8)
  local r = poke(poke(RENDERER, 168, base >> 8), 277, (base >> 5) & 0xFF)
  put(AC_HELPER, h); put(AC_RENDERER, r)
  for i = 1, 6 do emu.write(AC_RENDERER + 365 + i, KEY[i], AC) end
end

local function rb(addr) return emu.read(addr, VRAM) or 0 end
local function wb(addr, value) emu.write(addr, value, VRAM) end
local function rw(word)
  local at = word * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function snapshot(base)
  local data = {}
  for word = base, base + N - 1 do
    local at = word * 2
    data[#data + 1] = rb(at)
    data[#data + 1] = rb(at + 1)
  end
  saved[base] = data
end

local function restore(base)
  local data = saved[base]
  if not data then return false end
  for word = base, base + N - 1 do
    local at, i = word * 2, (word - base) * 2 + 1
    wb(at, data[i]); wb(at + 1, data[i + 1])
  end
  return true
end

local function saneDimension(value, fallback)
  value = tonumber(value)
  if value == 32 or value == 64 or value == 128 then return value end
  return fallback
end

local function mark(used, first, count)
  local last = math.min(first + count - 1, 0x7FFF)
  if first < 0 or first > 0x7FFF then return end
  for word = first, last do used[word] = true end
end

local wEntries = 0
local function referencedWords()
  local used = {}
  local ok, state = pcall(emu.getState)
  if not ok or not state then state = {} end

  -- BAT 은 VRAM word $0000 에서 시작한다.  현재 MWR 로 정해진 실제 크기만
  -- 읽어야 한다.  무조건 $0000-$0FFF 를 BAT 로 읽으면 그 뒤 패턴 데이터를
  -- BAT 엔트리로 오해해 안전한 후보를 대량으로 막는다.
  local columns = saneDimension(state['vdc.hvReg.columnCount'], 64)
  local rows = saneDimension(state['vdc.hvReg.rowCount'], 64)
  local entries = math.min(columns * rows, 0x1000)
  wEntries = entries
  -- ★ BAT 와 SATB 자신도 쓰이는 자리다.  0.3.35 까지는 이 둘을 표시하지 않아
  -- $0000-$10FF 4352 word 가 통째로 "비어 있음" 으로 잡혔다.  창이 $6000-$7B00
  -- 이라 우연히 안 건드렸을 뿐이고, 창을 넓히면 BAT 를 덮어써 화면이 날아간다.
  mark(used, 0x0000, entries)          -- BAT 본체
  mark(used, 0x1000, 0x100)            -- SATB 본체 (byte $2000, 64 x 8 B)

  local batPatterns = {}
  for i = 0, entries - 1 do
    local pattern = rw(i) & 0x07FF
    if not batPatterns[pattern] then
      batPatterns[pattern] = true
      mark(used, pattern * 0x10, 0x10)       -- BG 8x8 4bpp = 16 words
    end
  end

  -- SATB 는 VRAM byte $2000 (word $1000), 64 slots x 8 bytes.
  -- 크기 비트까지 반영해 시작 패턴만이 아니라 스프라이트 전체 범위를 막는다.
  local spriteCount = 0
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local y = rb(at) | (rb(at + 1) << 8)
    local x = rb(at + 2) | (rb(at + 3) << 8)
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local width = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local first = (pattern & 0x07FF) << 5
      mark(used, first, width * height * 0x40)
      spriteCount = spriteCount + 1
    end
  end

  local bgCount = 0
  for _ in pairs(batPatterns) do bgCount = bgCount + 1 end
  return used, columns, rows, bgCount, spriteCount
end

local function freeBlock(base, used)
  for word = base, base + N - 1 do
    if used[word] then return false end
  end
  return true
end

-- 실패했을 때 "얼마나 모자란가" 를 재는 부분.  창 확장으로 될 일인지,
-- 연속성을 깨야만 하는 일인지가 이 숫자로 갈린다.
local function runStats(used, lo, hi)
  local best, bestAt, cur, curAt, free = 0, nil, 0, nil, 0
  for word = lo, hi do
    if used[word] then
      cur, curAt = 0, nil
    else
      free = free + 1
      if cur == 0 then curAt = word end
      cur = cur + 1
      if cur > best then best, bestAt = cur, curAt end
    end
  end
  return best, bestAt, free
end

local function reportShortfall(used)
  local wBest, wAt, wFree = runStats(used, 0x6000, 0x7FFF)
  local aBest, aAt, aFree = runStats(used, 0x0000, 0x7FFF)
  emu.log(string.format(
    'SUB %s SHORTFALL 필요=%d word', VERSION, N))
  emu.log(string.format(
    '  창 $6000-$7FFF : 최대연속 %d word @ $%s · 총여유 %d word',
    wBest, wAt and string.format('%04X', wAt) or '----', wFree))
  emu.log(string.format(
    '  VRAM 전체      : 최대연속 %d word @ $%s · 총여유 %d word',
    aBest, aAt and string.format('%04X', aAt) or '----', aFree))
  emu.log(string.format('  (BAT %d word + SATB 256 word 는 used 로 제외했다)', wEntries))
  if aBest >= N then
    emu.log('  -> 창 밖에 연속 자리가 있다.  창 확장(패턴 상위 비트)이 유효하다')
  elseif aBest >= 640 then
    emu.log('  -> 1216 은 안 되지만 절반(10 글자 = 640 word)은 들어간다.')
    emu.log('     조각을 잘게 쪼개는 쪽이 창 확장보다 싸다')
  else
    emu.log('  -> 연속 자리가 거의 없다.  글리프 개별 배치로 연속성을 깨야 한다')
  end
end

local function choose()
  local used, columns, rows, bgCount, spriteCount = referencedWords()
  if FORCE_BASE then
    -- 우리가 아는 세 바이트(MAWR 하위/상위, 패턴 하위)만 고쳐서 창 밖 주소를
    -- 써 본다.  패턴 상위 2 비트(base>>13)는 자리를 못 찾아 안 고친다.
    -- 화면이 정상이면 그 비트는 안 쓰이거나 다른 데서 유도되는 것이고,
    -- 엉뚱한 데 뜨면 실재하므로 계속 추적해야 한다.
    local ok = freeBlock(FORCE_BASE, used)
    emu.log(string.format(
      'SUB %s FORCE base=$%04X (스캔상 %s) · 패턴상위 %d -> %d (미패치)',
      VERSION, FORCE_BASE, ok and '비어있음' or '★사용중★',
      3, (FORCE_BASE >> 13) & 0x03))
    return FORCE_BASE, columns, rows, bgCount, spriteCount
  end
  -- 0x100-word aligned: helper/renderer 의 VRAM low byte가 아직 00 고정이다.
  for base = 0x6000, 0x7B00, 0x40 do
    if freeBlock(base, used) then
      return base, columns, rows, bgCount, spriteCount
    end
  end
  reportShortfall(used)
  return nil, columns, rows, bgCount, spriteCount
end

local function patchRenderer(base)
  -- renderer binary offset 167 = VDC MAWR high, 276 = list pattern low.
  -- CPU address is zero-based offset from $5B80.
  emu.write(ENGINE + 165, base & 0xFF, MEM)
  emu.write(ENGINE + 167, base >> 8, MEM)
  emu.write(ENGINE + 276, (base >> 5) & 0xFF, MEM)

  -- ★ 패치가 실제로 먹었는지, 그리고 글리프가 어디에 쓰였는지 확인한다.
  -- 하단 깨짐이 base 를 바꿔도 똑같다면 쓰기 경로가 안 옮겨진 것이다.
  local function vw(word)
    local at = word * 2
    return (emu.read(at, VRAM) or 0) | ((emu.read(at + 1, VRAM) or 0) << 8)
  end
  local function nz(word, n)
    local c = 0
    for i = 0, n - 1 do if vw(word + i) ~= 0 then c = c + 1 end end
    return c
  end
  emu.log(string.format('SUB %s VERIFY base=$%04X', VERSION, base))
  emu.log(string.format('  CPU 렌더러  off165=$%02X off167=$%02X off276=$%02X (기대 $%02X/$%02X/$%02X)',
    emu.read(ENGINE + 165, MEM) or 0, emu.read(ENGINE + 167, MEM) or 0,
    emu.read(ENGINE + 276, MEM) or 0,
    base & 0xFF, base >> 8, (base >> 5) & 0xFF))
  emu.log(string.format('  AC 헬퍼     off39=$%02X off41=$%02X off131=$%02X off133=$%02X (기대 $%02X/$%02X)',
    emu.read(AC_HELPER + 39, AC) or 0, emu.read(AC_HELPER + 41, AC) or 0,
    emu.read(AC_HELPER + 131, AC) or 0, emu.read(AC_HELPER + 133, AC) or 0,
    base & 0xFF, base >> 8))
  emu.log(string.format('  VRAM 비어있지않은 word:  base $%04X = %d/64   $7900 = %d/64   $6100 = %d/64',
    base, nz(base, 64), nz(0x7900, 64), nz(0x6100, 64)))
end

local function reset(reason)
  if currentBase and restore(currentBase) then
    emu.log(string.format('DYNAMIC FRAGMENT %s restore $%04X (%s)', VERSION, currentBase, reason))
  end
  active, started, firstBase, currentBase, pendingBase, rebuilds, saved = false, false, nil, nil, nil, 0, {}
end

emu.addMemoryCallback(function()
  local state = emu.getState()
  local endAddr = ((state['cdrom.adpcm.readAddress'] or 0) +
                   (state['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if (state['cdrom.adpcm.playbackRate'] or -1) ~= 0x0E then return end
  -- 현재 native BIOS POC 자체가 아직 E6800_0E 하나만 시작시킨다.  범용
  -- selector가 들어가기 전에는 allocator도 같은 범위에서만 돌아야 한다.
  if TARGET_END and endAddr ~= TARGET_END then return end
  reset('new voice')
  local columns, rows, bgCount, spriteCount
  pendingBase, columns, rows, bgCount, spriteCount = choose()
  if not pendingBase then
    emu.log(string.format('DYNAMIC FRAGMENT %s START SKIP: 참조 없는 블록 없음 · BAT %dx%d/%d패턴 · SATB %d',
                          VERSION, columns, rows, bgCount, spriteCount))
    return
  end
  prepareFirst(pendingBase)
  active = true
  emu.log(string.format('DYNAMIC FRAGMENT %s armed: end=$%04X · first $%04X · BAT %dx%d/%d패턴 · SATB %d',
                        VERSION, endAddr, pendingBase, columns, rows, bgCount, spriteCount))
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if not active then return end
  if PATCH_AT_COUNT_OK then return end
  if currentBase then restore(currentBase) end
  local base, columns, rows, bgCount, spriteCount
  if pendingBase then
    base = pendingBase
    pendingBase = nil
  else
    base, columns, rows, bgCount, spriteCount = choose()
  end
  if not base then
    emu.log(string.format('DYNAMIC FRAGMENT %s SKIP #%d: 참조 없는 블록 없음 · BAT %dx%d/%d패턴 · SATB %d',
                          VERSION, rebuilds + 1, columns, rows, bgCount, spriteCount))
    return
  end
  if not saved[base] then snapshot(base) end
  patchRenderer(base)
  started = true
  rebuilds = rebuilds + 1
  if not firstBase then firstBase = base end
  currentBase = base
  emu.log(string.format('DYNAMIC FRAGMENT %s #%d: $%04X selected (BAT+SATB unreferenced)', VERSION, rebuilds, base))
end, emu.callbackType.exec, REBUILD, REBUILD, emu.cpuType.pce, CPU)

-- 0.3.5 경로: 색인 비교가 성공해 count_ok에 들어온 뒤, glyph upload 전에만
-- CPU renderer의 VRAM 주소를 바꾼다.  조회 시작점 $5BA6은 완전히 무수정이다.
if PATCH_AT_COUNT_OK then
  emu.addMemoryCallback(function()
    if not active then return end
    if currentBase then restore(currentBase) end
    local base = pendingBase or choose()
    pendingBase = nil
    if not base then
      emu.log(string.format('DYNAMIC FRAGMENT %s SKIP: count_ok 뒤 안전 블록 없음', VERSION))
      return
    end
    if not saved[base] then snapshot(base) end
    patchRenderer(base)
    started = true
    rebuilds = rebuilds + 1
    if not firstBase then firstBase = base end
    currentBase = base
    emu.log(string.format('DYNAMIC FRAGMENT %s #%d: $%04X selected at count_ok',
                          VERSION, rebuilds, base))
  end, emu.callbackType.exec, ENGINE + 139, ENGINE + 139, emu.cpuType.pce, CPU)
end

emu.addEventCallback(function()
  if active and started and (emu.read(STATE, MEM) or 0) == 0 then reset('voice end') end
end, emu.eventType.startFrame)

emu.log('POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR ' .. VERSION .. ' -- BAT+SATB referenced-free')
emu.log('  음성마다 · 조각마다 현재 참조되지 않는 19글자 블록을 고른다')
if INPLACE_IMAGES then
  emu.log('  AC 헬퍼/렌더러 전체 교체 0 B · VRAM 주소 피연산자 4 B만 수정')
else
  emu.log('  후보 간격 $100 유지 · 디스크 빌드에는 아직 미반영')
end
