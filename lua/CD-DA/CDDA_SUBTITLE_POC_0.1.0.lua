-- CDDA_SUBTITLE_POC 0.1.0 -- 새 CD-DA 계열의 첫 시각 렌더 실증.
--
-- 현재 출하 ADPCM 체인과 독립된 Lua-only POC다. $7900에 직접 쓰므로 이 파일
-- 하나만 올리고, 시험 뒤에는 Power Cycle 한다. VRAM map/0.4.93과 병용 금지.
--
-- 0.1.1 이 더한 것: CD-DA 시간 경로
--   CD-DA 이벤트는 **트랙 시작**에만 잡힌다 (실측: 전부 0.00 초 지점).
--   트랙 10 안에만 대사가 80 개고, 트랙 17 의 오프닝 내레이션은 36.46 초부터다.
--   그래서 이벤트가 아니라 **재생 위치**로 찾는다:
--
--       lba_from <= cdrom.audioPlayer.currentSector <= lba_to
--
--   구간 안에서 몇 번째 조각인지도 섹터로 센다 (프레임을 세지 않는다):
--       elapsed = (currentSector - lba_from) / 75
--
--   표는 빌드 때 절대 LBA 를 미리 박아둔 것을 쓴다 --
--   build/cutscene_subs/cdda_segments.tsv (407 구간 · 겹침 0)
--   한국어는 snatcher_tool/translation/cdda_subtitles.tsv (clip + part)
--
-- 이것이 마지막 기술 조각이다.  여기까지 오면 남은 것은 전부 데이터다.
--
-- 사슬
-- ----
--   음성 재생 시작  ->  지문  ->  event_id  ->  ko_text  ->  글리프  ->  화면
--
--   지문은 게임이 재생을 걸 때 쓴 레지스터 값이다.  시계가 아니라 사건이다.
--     ADPCM   ADPCM_<readAddr>_<length>_<rate>
--             재생 중에는 readAddr 가 움직이므로 **끝 주소**로 정규화한다
--             finish = (readAddr + length) & 0xFFFF   ->  E<finish>_<rate>
--             (이 수법은 POC_SUBTITLE_ACTIVE_0.1.0 에서 가져왔다)
--     CDDA    CDDA_<startSector 하위 16 비트>_0000_00
--
--   emu.getState() 는 **평평한 점표기 키**를 준다.  s["cdrom.adpcm.playing"] 처럼.
--   (중첩 테이블이 아니다 -- 여기서 한 번 헛짚었다)
--
-- 그리는 방식은 앞 판들에서 확정된 것 그대로
-- ------------------------------------------
--   $601E 의 LDA #$3F / STA $17 을 가로채 **게임보다 먼저** 민다 -> 슬롯 0.. = 맨 앞
--   무장 $6000 / 회수 $6072 -- 패치가 프레임 밖으로 안 샌다
--   안 밀은 프레임에는 우리 엔트리만 골라 SATB 에서 지운다
--   VDC 접근 0 회
--
-- 글자는 런타임에 조립한다
-- ----------------------
--   build/cutscene_subs/subfont_Galmuri9.bin   64 B/자 (플레인 0 본체 · 1 외곽선)
--   build/cutscene_subs/subfont_Galmuri9.tsv   char -> offset · advance (비례폭)
--   2477 자.  코퍼스 전부를 덮으므로 어떤 문장이 와도 그려진다.
--
-- 겸사겸사 수집 도구다
-- ------------------
--   카탈로그에 없는 지문도 전부 로그에 남긴다.  voice_events.tsv 는 지금 449 행이고
--   전부 status=unlinked 다.  플레이하며 이 로그를 모으면 그대로 카탈로그가 된다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sub_live_0_1_0_<날짜>.tsv
--       (300 프레임마다 흘려 쓴다)

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PAYLOAD = "C:/snatcher/SUBTITEL/0.2.13.bin"
local EVENTS  = "C:/snatcher/snatcher_tool/translation/voice_events.tsv"
local SUBS    = "C:/snatcher/snatcher_tool/translation/voice_subtitles.tsv"
local CDSEG   = "C:/snatcher/build/cutscene_subs/cdda_segments.tsv"
local CDSUB   = "C:/snatcher/snatcher_tool/translation/cdda_subtitles.tsv"
local FONTBIN = "C:/snatcher/build/cutscene_subs/subfont_Galmuri9.bin"
local FONTTSV = "C:/snatcher/build/cutscene_subs/subfont_Galmuri9.tsv"

-- 자막용으로 빌드가 예약한 구간: $5C40-$5E1F (480 B, MPR2)
-- manifest.json  subtitle_ram_code = "5C40-5E1F"
-- 예전에는 $5C20 이라 예약 구간을 32 B 벗어나 걸쳐 있었다.
local STUB, LIST = 0x5C40, 0x5C80
local ARM, HOOK, DISARM = 0x6000, 0x601E, 0x6072
local JSR_AT = 0x5C71
local SATB_BYTE, PAT_VRAM_BYTE = 0x2000, 0xF200
local SCREEN_W = 256
local TEXT_Y, CENTER_X = 192, 128       -- CD-DA 나레이션: 화면 아래
local ADPCM_ENABLED = false
local CDDA_TARGET_CLIP = 'c17_001.wav'
-- 한 줄 최대 글자 수는 VRAM 이 정한다.
--   패턴 시작 워드 $7900 · 글자당 $40 워드 · VRAM 마지막 워드 $7FFF
--   ($8000 - $7900) / $40 = 28 자.  딱 채운다.
-- 더 긴 문장은 voice_subtitles.tsv 의 part 로 나눠야 한다 (스키마에 이미 있다).
local MAX_GLYPH = 28

local ORIG  = { 0xA9, 0x3F, 0x85, 0x17 }
local PATCH = { 0x20, STUB & 0xFF, STUB >> 8, 0xEA }
local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
  { 0x6072, { 0x4C, 0xBE, 0x43 } },
}

local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

-- ---------------------------------------------------------------- 표 읽기
local function read_tsv(path)
  local f = io.open(path, 'rb')
  if f == nil then say('★ 못 열었다: ' .. path); return nil, nil end
  local text = f:read('a'); f:close()
  text = text:gsub('^\239\187\191', '')
  local head, rows = nil, {}
  for line in text:gmatch('[^\r\n]+') do
    local fields = {}
    for v in (line .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = v end
    if head == nil then
      head = {}
      for i, n in ipairs(fields) do head[n] = i end
    else
      rows[#rows + 1] = fields
    end
  end
  return head, rows
end
local function col(h, r, n) return (h and h[n]) and (r[h[n]] or '') or '' end

-- 재생 중에는 readAddr 가 움직인다.  끝 주소로 정규화해야 같은 열쇠가 나온다
local function norm(fp)
  local r, l, rate = fp:match('^ADPCM_(%x+)_(%x+)_(%x+)$')
  if r then
    local finish = (tonumber(r, 16) + tonumber(l, 16)) % 0x10000
    if finish == 0xFFFF then return fp end
    return string.format('E%04X_%02X', finish, tonumber(rate, 16))
  end
  return fp
end

local eh, er = read_tsv(EVENTS)
local sh, sr = read_tsv(SUBS)
if er == nil or sr == nil then return end

-- 자막 표를 먼저 읽어 "자막이 달린 event_id" 를 알아둔다.
-- 정규화 열쇠는 여러 이벤트가 공유한다 -- 449 이벤트가 71 열쇠로 줄어든다.
-- 대부분은 **같은 클립을 반복 수집**한 것이다 (E6800_0E 17 개, 지속시간 전부 3.32 초).
-- 그러니 열쇠 하나에 여럿이 붙으면 **자막 있는 것 > 대사 > 화자 있는 것** 순으로 고른다.
-- 이 우선순위가 없으면 마지막 행이 덮어써서, 자막이 달린 행이 있어도 못 찾는다.
local hasSub = {}
for _, r in ipairs(sr) do
  local id = col(sh, r, 'event_id')
  if id ~= '' and col(sh, r, 'ko_text') ~= '' then hasSub[id] = true end
end

local function rank(id, kind, speaker)
  if hasSub[id] then return 3 end
  if kind == '대사' then return 2 end
  if speaker ~= '' then return 1 end
  return 0
end

local eventByKey, keyById, bestRank, collide = {}, {}, {}, 0
for _, r in ipairs(er) do
  local id, fp = col(eh, r, 'event_id'), col(eh, r, 'fingerprint')
  if fp ~= '' then
    local k = norm(fp)
    local kind, speaker = col(eh, r, 'kind'), col(eh, r, 'speaker')
    local sc = rank(id, kind, speaker)
    if eventByKey[k] == nil then
      eventByKey[k] = { id = id, kind = kind, speaker = speaker }
      bestRank[k] = sc
    else
      collide = collide + 1
      if sc > bestRank[k] then
        eventByKey[k] = { id = id, kind = kind, speaker = speaker }
        bestRank[k] = sc
      end
    end
    keyById[id] = k
  end
end

-- event_id -> part 순서대로
local partsById = {}
for _, r in ipairs(sr) do
  local id, txt = col(sh, r, 'event_id'), col(sh, r, 'ko_text')
  if id ~= '' and txt ~= '' then
    partsById[id] = partsById[id] or {}
    table.insert(partsById[id], {
      part = tonumber(col(sh, r, 'part')) or 1,
      text = txt,
      start_sec = tonumber(col(sh, r, 'start_sec')) or 0,
      dur_sec = tonumber(col(sh, r, 'duration_sec')) or 99,
    })
  end
end
for _, v in pairs(partsById) do table.sort(v, function(a, b) return a.part < b.part end) end

local nsub = 0
for _ in pairs(partsById) do nsub = nsub + 1 end

-- CD-DA: 절대 LBA 구간 -> clip,  clip -> 조각들
local cdSegs, cdPartsByClip, ncdsub = {}, {}, 0
do
  local h, r = read_tsv(CDSEG)
  if r then
    for _, row in ipairs(r) do
      local a = tonumber(col(h, row, 'lba_from'))
      local b = tonumber(col(h, row, 'lba_to'))
      if a and b then
        cdSegs[#cdSegs+1] = { a = a, b = b, clip = col(h, row, 'clip'),
                              jp = col(h, row, 'jp_whisper') }
      end
    end
    table.sort(cdSegs, function(x, y) return x.a < y.a end)
  end
  local h2, r2 = read_tsv(CDSUB)
  if r2 then
    for _, row in ipairs(r2) do
      local clip, txt = col(h2, row, 'clip'), col(h2, row, 'ko_text')
      if clip ~= '' and txt ~= '' then
        cdPartsByClip[clip] = cdPartsByClip[clip] or {}
        table.insert(cdPartsByClip[clip], {
          part = tonumber(col(h2, row, 'part')) or 1,
          text = txt,
          start_sec = tonumber(col(h2, row, 'start_sec')) or 0,
          dur_sec = tonumber(col(h2, row, 'duration_sec')) or 99,
        })
      end
    end
    for _, v in pairs(cdPartsByClip) do table.sort(v, function(x, y) return x.part < y.part end) end
  end
  for _ in pairs(cdPartsByClip) do ncdsub = ncdsub + 1 end
end

-- 재생 위치가 든 구간을 찾는다.  407 개라 이분 탐색이면 충분하다.
local function cd_segment_at(sector)
  local lo, hi = 1, #cdSegs
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local s = cdSegs[mid]
    if sector < s.a then hi = mid - 1
    elseif sector > s.b then lo = mid + 1
    else return s end
  end
  return nil
end

-- ---------------------------------------------------------------- 글꼴
local ff = io.open(FONTBIN, 'rb')
if ff == nil then say('★ 글꼴이 없다: ' .. FONTBIN); return end
local font = ff:read('a'); ff:close()
local fh2, fr = read_tsv(FONTTSV)
if fr == nil then return end
local glyph = {}
for _, r in ipairs(fr) do
  local ch = col(fh2, r, 'char')
  if ch ~= '' then
    glyph[ch] = { off = tonumber(col(fh2, r, 'offset'), 16),
                  adv = tonumber(col(fh2, r, 'advance')) or 10 }
  end
end
local nglyphs = 0
for _ in pairs(glyph) do nglyphs = nglyphs + 1 end

local function utf8chars(s)
  local out = {}
  for c in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out + 1] = c end
  return out
end

-- ---------------------------------------------------------------- 상태
local frames, loaded, tries = 0, false, 0
local armed, arms, pushes = false, 0, 0
local stranded, cleared = 0, 0
local pushed_this_frame = false
local cur = nil                 -- { chars, offs, w, n }  지금 그릴 줄
local active = nil              -- { id, key, parts, idx, start_frame }
local was_playing = false
local cd_clip, cd_part = nil, -1   -- 지금 화면에 있는 CD-DA 구간·조각
local seen_keys, unknown_n = {}, 0

local function rb(a, t) return emu.read(a, t or MEM) or 0 end
local function match(addr, want)
  for i = 1, #want do if rb(addr + i - 1) ~= want[i] then return false end end
  return true
end
local function fingerprint_ok()
  for _, s in ipairs(SIG) do if not match(s[1], s[2]) then return false end end
  return true
end

-- 문장 하나를 VRAM 에 올리고 그릴 준비를 한다
local function set_line(text)
  local cs = utf8chars(text)
  local n, pen, offs, used = 0, 0, {}, {}
  for _, ch in ipairs(cs) do
    local g = glyph[ch]
    if g and n < MAX_GLYPH then
      n = n + 1
      used[n] = g
      offs[n] = pen
      pen = pen + g.adv
    end
  end
  if n == 0 then cur = nil; return end
  if #cs > n then
    say(string.format('[프레임 %d] ★ 잘림: %d 자 중 %d 자만 올렸다 -- part 로 나눠야 한다',
          frames, #cs, n))
  end
  for i = 1, n do
    local base = PAT_VRAM_BYTE + (i - 1) * 0x80
    local src = used[i].off
    for b = 0, 63 do emu.write(base + b, font:byte(src + b + 1) or 0, VRAM) end
    for b = 64, 127 do emu.write(base + b, 0, VRAM) end
  end
  cur = { n = n, offs = offs, w = pen }
  say(string.format('[프레임 %d] 자막 "%s"  %d 자 · %d px · x %d..%d',
        frames, text, n, pen, CENTER_X - math.floor(pen / 2),
        CENTER_X - math.floor(pen / 2) + pen - 1))
end

local function build_stub()
  local xo, yo = CENTER_X + 32, TEXT_Y + 64
  return {
    0x08, 0x78,
    0xA9, 0x3F, 0x85, 0x17,
    0xAD, 0x00, 0x65, 0xC9, 0x82,
    0xD0, 0x27,
    0xA9, yo & 0xFF, 0x85, 0x08,
    0xA9, (yo >> 8) & 0xFF, 0x85, 0x09,
    0xA9, xo & 0xFF, 0x85, 0x0A,
    0xA9, (xo >> 8) & 0xFF, 0x85, 0x0B,
    0x64, 0x0C, 0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F,
    0xA9, LIST & 0xFF, 0x85, 0x10,
    0xA9, LIST >> 8,   0x85, 0x11,
    0xA9, cur.n, 0x85, 0x16,
    0x20, 0x63, 0x64,
    0x28, 0x60,
  }
end

local function build_records()
  local half = math.floor(cur.w / 2)
  local r = {}
  for i = 1, cur.n do
    local w2 = 0x3C8 + 2 * (i - 1)
    local off = cur.offs[i] - half
    if off < -128 then off = -128 elseif off > 127 then off = 127 end
    r[#r+1] = 0x00; r[#r+1] = 0x00; r[#r+1] = off & 0xFF
    r[#r+1] = w2 & 0xFF; r[#r+1] = 0x80 | ((w2 >> 8) << 4)
  end
  return r
end

local function clear_ours()
  local hi = 0x3C8 + 2 * (MAX_GLYPH - 1)
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local w2 = rb(o + 4, VRAM) + rb(o + 5, VRAM) * 256
    local at = rb(o + 6, VRAM) + rb(o + 7, VRAM) * 256
    if at == 0x0080 and w2 >= 0x3C8 and w2 <= hi then
      for i = 0, 7 do emu.write(o + i, 0, VRAM) end
      cleared = cleared + 1
    end
  end
end

-- ---------------------------------------------------------------- 페이로드
local pf = io.open(PAYLOAD, 'rb')
if pf == nil then say('★ 페이로드를 못 열었다: ' .. PAYLOAD); return end
local data = pf:read('a'); pf:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

local function disarm()
  if not armed then return end
  if match(HOOK, PATCH) then
    for i = 1, #ORIG do emu.write(HOOK + i - 1, ORIG[i], MEM) end
  else
    stranded = stranded + 1
    if stranded <= 3 then say(string.format('[프레임 %d] ★ 회수 실패', frames)) end
  end
  armed = false
end

emu.addMemoryCallback(function()
  if armed then disarm() end
  if cur == nil then return end                 -- 띄울 자막이 없으면 아무것도 안 한다
  if not fingerprint_ok() then return end
  if not match(HOOK, ORIG) then return end
  local code, rec = build_stub(), build_records()
  for i = 1, #code  do emu.write(STUB + i - 1, code[i], MEM) end
  for i = 1, #rec   do emu.write(LIST + i - 1, rec[i],  MEM) end
  for i = 1, #PATCH do emu.write(HOOK + i - 1, PATCH[i], MEM) end
  armed = true; arms = arms + 1
end, emu.callbackType.exec, ARM, ARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function() disarm() end,
  emu.callbackType.exec, DISARM, DISARM, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  pushes = pushes + 1; pushed_this_frame = true
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

-- ---------------------------------------------------------------- 지문
local function adpcm_key(s)
  local r = s['cdrom.adpcm.readAddress']
  local l = s['cdrom.adpcm.adpcmLength']
  local rate = s['cdrom.adpcm.playbackRate']
  if type(r) ~= 'number' or type(l) ~= 'number' or type(rate) ~= 'number' then return nil end
  local finish = (math.floor(r) + math.floor(l)) % 0x10000
  if finish == 0xFFFF then return string.format('ADPCM_%04X_%04X_%02X', r, l, rate) end
  return string.format('E%04X_%02X', finish, rate)
end

local function note_key(key, src)
  if seen_keys[key] then return end
  seen_keys[key] = true
  local e = eventByKey[key]
  if e then
    say(string.format('[프레임 %d] %s %s  -> %s  kind=%s %s%s',
          frames, src, key, e.id, e.kind ~= '' and e.kind or '(미분류)',
          e.speaker ~= '' and ('· ' .. e.speaker) or '',
          partsById[e.id] and '  ★ 자막 있음' or ''))
  else
    unknown_n = unknown_n + 1
    say(string.format('[프레임 %d] %s %s  -> 카탈로그에 없음', frames, src, key))
  end
end

local function start_subtitle(key, src)
  note_key(key, src)
  local e = eventByKey[key]
  if e == nil then return end
  local parts = partsById[e.id]
  if parts == nil then return end
  active = { id = e.id, key = key, parts = parts, idx = 0, start_frame = frames }
end

local function stop_subtitle()
  if active or cur then
    active = nil; cur = nil
    clear_ours()
  end
end

emu.addEventCallback(function()
  frames = frames + 1

  if not loaded then
    tries = tries + 1
    for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end
    local bad = 0
    for i = 1, #data do
      if rb(AC_ENGINE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
    end
    if bad == 0 then
      for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, MAGIC[i], AC) end
      loaded = true
      say(string.format('AC 적재 완료 · ADPCM 이벤트 %d -> 열쇠 %d · 자막 %d | CD-DA 구간 %d · 자막 %d | 글자 %d',
                        #er, (function() local c=0; for _ in pairs(eventByKey) do c=c+1 end; return c end)(),
                        nsub, #cdSegs, ncdsub, nglyphs))
    elseif tries >= 300 then loaded = true; say('★ AC 적재 실패') end
  end

  if armed then disarm() end
  if not pushed_this_frame then clear_ours() end
  pushed_this_frame = false

  local ok, s = pcall(emu.getState)
  if ok and s then
    -- ADPCM: 재생 시작 모서리에서 지문을 읽는다
    local playing = s['cdrom.adpcm.playing'] == true
    if ADPCM_ENABLED then
      if playing and not was_playing then
        local k = adpcm_key(s)
        if k then start_subtitle(k, 'ADPCM') end
      elseif not playing and was_playing then
        stop_subtitle()
      end
    end
    was_playing = playing

    -- CD-DA: 재생 위치가 어느 구간에 드는가.  이벤트가 아니라 시계다.
    -- ADPCM 이 이미 자막을 띄우고 있으면 건드리지 않는다 (그쪽은 사건 기반이라 더 정확하다)
    if active == nil then
      local sector = s['cdrom.audioPlayer.currentSector']
      local seg = (type(sector) == 'number') and cd_segment_at(math.floor(sector)) or nil
      local parts = seg and seg.clip == CDDA_TARGET_CLIP and cdPartsByClip[seg.clip] or nil
      if parts == nil then
        if cd_clip then cd_clip, cd_part = nil, -1; cur = nil; clear_ours() end
      else
        local elapsed = (math.floor(sector) - seg.a) / 75.0
        local want = 0
        for i, pp in ipairs(parts) do
          if elapsed >= pp.start_sec and elapsed < pp.start_sec + pp.dur_sec then want = i end
        end
        if seg.clip ~= cd_clip or want ~= cd_part then
          cd_clip, cd_part = seg.clip, want
          if want == 0 then cur = nil; clear_ours()
          else
            set_line(parts[want].text)
            if not seen_keys['CD:' .. seg.clip] then
              seen_keys['CD:' .. seg.clip] = true
              say(string.format('[프레임 %d] CDDA %s  %.2f초  %s',
                    frames, seg.clip, elapsed, seg.jp:sub(1, 34)))
            end
          end
        end
      end
    end
  end

  -- part 진행: start_sec / duration_sec 로 넘긴다
  if active then
    local sec = (frames - active.start_frame) / 60.0
    local want = 0
    for i, p in ipairs(active.parts) do
      if sec >= p.start_sec and sec < p.start_sec + p.dur_sec then want = i end
    end
    if want ~= active.idx then
      active.idx = want
      if want == 0 then cur = nil; clear_ours()
      else set_line(active.parts[want].text) end
    end
  end

  if cur then
    emu.drawString(4, 4, string.format('SUB %d/%d  %d px',
          active and active.idx or 0, active and #active.parts or 0, cur.w), 0xFFFFFF, 0x000000)
  end

  if frames % 300 == 0 then
    say(string.format('--- %d --- 푸시 %d · 지움 %d · 회수실패 %d · 본 지문 %d (카탈로그 밖 %d)',
          frames, pushes, cleared, stranded, (function()
            local c = 0; for _ in pairs(seen_keys) do c = c + 1 end; return c end)(), unknown_n))
    local f = io.open(string.format('C:/snatcher/dump/probe_sub_live_0_1_1_%s.tsv',
                                    os.date('%Y%m%d_%H%M%S')), 'w')
    if f then
      f:write('line\n')
      for _, l in ipairs(lines) do f:write(l .. '\n') end
      f:close()
    end
  end
end, emu.eventType.startFrame)

emu.log('CDDA_SUBTITLE_POC 0.1.0 loaded -- c17_001 only')
emu.log(string.format('  target %s · y=%d · ADPCM OFF · CD-DA 구간 %d · 글꼴 %d 자',
        CDDA_TARGET_CLIP, TEXT_Y, #cdSegs, nglyphs))
emu.log('  첫 두 줄: 1991년 6월 6일 모스크바 / 체르노톤 연구소, 의문의 대폭발')
emu.log('  ★ Lua-only $7900 direct-write POC: 다른 Lua와 병용하지 말고 시험 뒤 Power Cycle')
