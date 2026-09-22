-- SUB 0.5.134 -- CD-DA 재생 중 현재 위치(LBA)를 읽을 수 있는가 (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- CD-DA 자막 색인은 **이미 LBA 로 되어 있다** (팩 안 cdda_index 770 항목):
--
--     entry: lba_from u24 LE · lba_to u24 LE · rec_off u24 LE · flags u8
--     범위  0 ~ 211,539 섹터 = 47.0 분 (75 섹터/초)
--
-- 그리고 지금 엔진이 그리는 두 줄이 색인 #712·#713 인데, 단위가 이렇게 갈린다:
--
--     색인 #712  lba 186752 - 트랙시작 184016 = 2736 섹터 ÷75 = 36.48 초
--     엔진 문턱                                  2189 프레임 ÷60 = 36.48 초
--
-- 같은 시각을 **다른 단위**로 들고 있다.  색인이 이미 LBA 이므로, 런타임이 현재
-- LBA 를 읽을 수만 있으면 **변환 없이 색인을 그대로 조회**할 수 있다.
--
--     읽을 수 있다  -> 색인 LBA 로 직접 비교.  프레임 세기도, 75:60 변환도 필요 없다
--     못 읽는다     -> 트랙 시작을 잡고 프레임을 세는 수밖에 없다 (변환 오차를 안고)
--
-- ★ 이 판은 그 하나만 묻는다.  게임을 한 바이트도 안 고친다.
--
-- 어떻게 -- 키 이름부터 찾는다
-- ---------------------------------------------------------------------------
-- ADPCM 쪽 프로브는 `cdrom.scsi.sector` · `cdrom.adpcm.*` 를 썼다.  그런데 그건
-- **로드 시점**의 값이고, CD-DA **재생 중**에도 같은 값이 흐르는지는 안 쟀다.
-- CD-DA 전용 필드가 따로 있을 수도 있다.
--
-- 그래서 이 판은 emu.getState() 의 키를 훑어 cd/audio/track/sector/lba 가 든 것을
-- **전부 후보로 잡고**, 프레임마다 값을 따라간다.  이름을 미리 안다고 가정하지 않는다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     어떤 후보가 184016 -> 187428 로 **단조증가**한다
--         ★그것이 재생 위치다.  "나"(LBA 직접 조회)로 간다
--     아무 후보도 안 움직인다 / 로드 때만 변한다
--         재생 위치를 못 읽는다.  "가"(프레임 세기)로 간다
--     움직이는데 범위가 다르다
--         상대 위치이거나 다른 단위다.  offset/배율을 로그에서 역산할 것
--
-- ⚠ 못 보는 것
--     Lua 가 못 읽는 내부 상태는 여기 안 잡힌다.  후보가 전부 정지여도
--     "하드웨어가 위치를 안 준다" 로 단정하지 말 것 -- "이 방법으로는 못 봤다" 다.
--     그 경우 BIOS 가 어딘가에 위치를 적어두는지 메모리 쪽을 따로 봐야 한다.
--
-- ⚠ 트랙 17 구간(184016~187428)은 2026-09-01 문서의 값이다.  새 빌드에서 다를 수 있다.
--   그래서 이 판은 그 범위를 **판정에 쓰지 않고 참고로만** 찍는다.
--
-- ★ 화면에 아무것도 안 그린다.
--
--   BIOS  환경 B에서 가져온 최신 동결본
--   CUE   같은 폴더의 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> **오프닝 CD-DA 를 끝까지** 재생
--   (자막 두 줄이 나오는 구간을 반드시 지나게 할 것)
--
-- 산출물  C:/snatcher/dump/cdda_pos_0_5_134_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local TRACK17_LO, TRACK17_HI = 184016, 187428      -- 참고용 (09-01 문서)
local SAMPLE_EVERY = 1                              -- 프레임마다
local MAX_KEYS = 24

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_pos_0_5_134_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))

local function say(f, ...) emu.log(string.format(f, ...)) end

local function st()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

-- 1) 후보 키를 찾는다 (이름을 미리 안다고 가정하지 않는다)
local KEYS = nil
local function findKeys(s)
  local t = {}
  for k, v in pairs(s) do
    if type(v) == 'number' then
      local lk = k:lower()
      if lk:find('cd') or lk:find('audio') or lk:find('track')
         or lk:find('sector') or lk:find('lba') or lk:find('adpcm') then
        t[#t + 1] = k
      end
    end
  end
  table.sort(t)
  if #t > MAX_KEYS then
    -- 너무 많으면 sector/lba/track 이 든 것을 우선한다
    local pri, rest = {}, {}
    for _, k in ipairs(t) do
      local lk = k:lower()
      if lk:find('sector') or lk:find('lba') or lk:find('track') then pri[#pri+1]=k
      else rest[#rest+1]=k end
    end
    t = {}
    for _, k in ipairs(pri) do t[#t+1]=k end
    for _, k in ipairs(rest) do if #t < MAX_KEYS then t[#t+1]=k end end
  end
  return t
end

local frame = 0
local first, last, moved, minv, maxv = {}, {}, {}, {}, {}
local logged = 0

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end

  if KEYS == nil then
    KEYS = findKeys(s)
    say('0.5.134 후보 키 %d 개', #KEYS)
    for _, k in ipairs(KEYS) do say('   %s = %s', k, tostring(s[k])) end
    if #KEYS == 0 then
      say('0.5.134 ⚠ 후보 키를 하나도 못 찾았다.  이 코어는 CD 상태를 노출하지 않는다')
      say('0.5.134   -> 아무 판정도 하지 말 것.  메모리 쪽을 따로 봐야 한다')
    end
    local hdr = {'frame'}
    for _, k in ipairs(KEYS) do hdr[#hdr+1] = k end
    out:write(table.concat(hdr, '\t') .. '\n')
    for _, k in ipairs(KEYS) do
      first[k] = s[k]; last[k] = s[k]; moved[k] = 0
      minv[k] = s[k]; maxv[k] = s[k]
    end
    return
  end

  local row = { tostring(frame) }
  local any = false
  for _, k in ipairs(KEYS) do
    local v = s[k]
    if type(v) ~= 'number' then v = -1 end
    row[#row+1] = tostring(math.floor(v))
    if v ~= last[k] then moved[k] = moved[k] + 1; any = true end
    last[k] = v
    if v < minv[k] then minv[k] = v end
    if v > maxv[k] then maxv[k] = v end
  end
  if any and logged < 20000 then
    out:write(table.concat(row, '\t') .. '\n'); out:flush(); logged = logged + 1
  end

  if frame % 600 == 0 then
    local parts = {}
    for _, k in ipairs(KEYS) do
      if moved[k] > 0 then
        parts[#parts+1] = string.format('%s %d..%d(%d회)', k:gsub('^cdrom%.',''),
                                        math.floor(minv[k]), math.floor(maxv[k]), moved[k])
      end
    end
    say('0.5.134 f%d 움직인 것: %s', frame,
        #parts > 0 and table.concat(parts, ' · ') or '(없음)')
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.134 끝 -- 프레임 %d · 기록 %d 행', frame, logged)
  if KEYS == nil or #KEYS == 0 then
    say('0.5.134 ⚠ 후보 키 없음.  판정 불가')
  else
    say('0.5.134 키별 요약 (움직인 것만)')
    local found = false
    for _, k in ipairs(KEYS) do
      if moved[k] > 0 then
        found = true
        local inRange = (minv[k] <= TRACK17_HI and maxv[k] >= TRACK17_LO)
        say('   %-34s %d .. %d   변화 %d 회%s', k,
            math.floor(minv[k]), math.floor(maxv[k]), moved[k],
            inRange and '   ★트랙17 참고범위와 겹침' or '')
      end
    end
    if not found then
      say('   (하나도 안 움직였다)')
      say('0.5.134 ⚠ "위치를 못 읽는다" 가 아니라 "이 방법으로는 못 봤다" 다.')
      say('0.5.134   BIOS 가 메모리에 위치를 적어두는지 따로 볼 것')
    end
  end
  say('0.5.134 참고: 트랙17 구간 %d~%d 은 09-01 문서 값이다.  새 빌드에서 다를 수 있다',
      TRACK17_LO, TRACK17_HI)
  say('0.5.134 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.134-cdda-position armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : CD-DA 재생 중 현재 위치(LBA)를 읽을 수 있는가')
say('  키 이름을 미리 안다고 가정하지 않는다.  cd/audio/track/sector/lba 를 전부 후보로 잡는다')
say('  오프닝 CD-DA 를 자막 두 줄이 나오는 구간까지 재생할 것')
say('  덤프 : ' .. PATH)
