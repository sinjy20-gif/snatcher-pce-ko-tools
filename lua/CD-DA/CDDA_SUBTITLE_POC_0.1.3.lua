-- CDDA_SUBTITLE_RUNTIME 0.1.0 -- HQ ADPCM 체인에 합치는 CD-DA 트랙 자막 경로.
--
-- $7900에 직접 쓰는 Lua-only POC다. 이 파일 하나만 올리고 시험 뒤 Power Cycle.
-- 0.1.0은 옛 $601E 원본(LDA #$3F)만 받아 현재 $7F49 상주 훅에서는 한 번도
-- 무장하지 못했다. 0.1.2는 상주 JSR을 한 SATB 패스 동안만 자기 스텁으로 바꾸고
-- 곧 원상복구한다. VRAM map/0.4.93과 병용 금지.
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

local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
-- ★ 현재 출하 빌드는 AC $1C0000부터 번역 lookup 테이블을 이미 적재한다.
-- 이 Lua는 글꼴을 Lua에서 VRAM으로 직행시키므로 AC 엔진/매직이 전혀 필요 없다.
-- 여기에 옛 0.2.13 페이로드를 쓰면 테이블 offset $04F0/$0500을 덮어 UI가 일본어로
-- fallback한다. AC는 반드시 읽지도 쓰지도 않는다.
local CDSEG   = "C:/snatcher/build/cutscene_subs/cdda_segments.tsv"
local CDSUB   = "C:/snatcher/snatcher_tool/translation/cdda_subtitles.tsv"
local CDPOS   = "C:/snatcher/build/cutscene_subs/cdda_safe_positions.tsv"
local FONTBIN = "C:/snatcher/build/cutscene_subs/subfont_Galmuri9.bin"
local FONTTSV = "C:/snatcher/build/cutscene_subs/subfont_Galmuri9.tsv"

-- 자막용으로 빌드가 예약한 구간: $5C40-$5E1F (480 B, MPR2)
-- manifest.json  subtitle_ram_code = "5C40-5E1F"
-- 예전에는 $5C20 이라 예약 구간을 32 B 벗어나 걸쳐 있었다.
-- 팔레트 초기화 코드를 실제 6280 스텁 안에 넣으면서 코드가 64 B를 넘는다.
-- $5C40-$5CFF는 스텁, $5D00부터는 글자 28개의 SATB 레코드(140 B)로 분리한다.
local STUB, LIST = 0x5C40, 0x5D00
-- 0.1.1 실측: CD-DA의 SATB 패스는 $600C에서 시작하고 $650C가 VWR 루프다.
-- $600C에서 다음 프레임의 $601E를 무장하면, 그 다음 패스에서만 스텁이 돈다.
local ARM, HOOK, DISARM = 0x600C, 0x601E, 0x6072
local JSR_AT = 0x5CAD                 -- palette init(60 B) 뒤의 JSR $6463
local SATB_BYTE = 0x2000
local GLYPH_PALETTE = 0x0F             -- Galmuri 자막 전용 팔레트 (0은 게임 회색)
-- CD-DA 장면은 게임 자막 엔진의 stage 팔레트 초기화를 거치지 않는다.  따라서
-- 팔레트 15가 비어 있으면 SATB가 정상이어도 글자는 검정/투명처럼 보인다.
-- 글꼴의 2비트 픽셀값 1·2·3을 전부 초기화한다.  3도 비워 두면 외곽선 픽셀이
-- 다시 게임의 미초기화 색을 집는다.
local VCE_ADDR_LO, VCE_ADDR_HI = 0x0402, 0x0403
local VCE_DATA_LO, VCE_DATA_HI = 0x0404, 0x0405
local PAL15_BASE = 0x01F0
local PAL15_C1, PAL15_C2, PAL15_C3 = 0x01FF, 0x0000, 0x01FF -- 흰 본체 · 검은 외곽
local DEFAULT_POS = { vram_base = 0x7900, text_y = 192, center_x = 128 }
local INTEGRATED = rawget(_G, 'SUB_CDDA_INTEGRATED') == true
local POC_TEST = rawget(_G, 'SUB_CDDA_POC_TEST') == true
-- 한 줄 최대 글자 수는 VRAM 이 정한다.
--   패턴 시작 워드 $7900 · 글자당 $40 워드 · VRAM 마지막 워드 $7FFF
--   ($8000 - $7900) / $40 = 28 자.  딱 채운다.
-- 더 긴 문장은 voice_subtitles.tsv 의 part 로 나눠야 한다 (스키마에 이미 있다).
local MAX_GLYPH = 28

local RESIDENT = { 0x20, 0x49, 0x7F, 0xEA } -- 출하 $601E: JSR $7F49 / NOP
local PATCH = { 0x20, STUB & 0xFF, STUB >> 8, 0xEA }
-- 새 Studio는 트랙 단위 원고로 초기화했다. 이 POC는 아직 런타임 표 연결 전이므로
-- 첫 트랙의 두 줄을 고정해 SATB 출력만 독립 검증한다.
local TEST_PARTS = {
  { text = '1991년 6월 6일 모스크바', start_sec = 0.000, dur_sec = 4.130 },
  { text = '체르노톤 연구소, 의문의 대폭발', start_sec = 4.130, dur_sec = 4.130 },
}
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

-- CD-DA: 절대 LBA 구간 -> 트랙, 트랙 -> Studio의 단일 자막 원고.
-- 위치 표에서 verified인 트랙만 그린다. pending은 수집 전 안전 우선 skip이다.
local cdSegs, cdPartsByTrack, cdPos, trackStart, ncdsub = {}, {}, {}, {}, 0
do
  local h, r = read_tsv(CDSEG)
  if r then
    for _, row in ipairs(r) do
      local a = tonumber(col(h, row, 'lba_from'))
      local b = tonumber(col(h, row, 'lba_to'))
      if a and b then
        cdSegs[#cdSegs+1] = { a = a, b = b, clip = col(h, row, 'clip'),
                              track = col(h, row, 'track'),
                              jp = col(h, row, 'jp_whisper') }
        local track = col(h, row, 'track')
        if track ~= '' and (trackStart[track] == nil or a < trackStart[track]) then
          trackStart[track] = a
        end
      end
    end
    table.sort(cdSegs, function(x, y) return x.a < y.a end)
  end
  local h2, r2 = read_tsv(CDSUB)
  if r2 then
    for _, row in ipairs(r2) do
      local track, txt = col(h2, row, 'track'), col(h2, row, 'ko_text')
      if track ~= '' and txt ~= '' then
        cdPartsByTrack[track] = cdPartsByTrack[track] or {}
        table.insert(cdPartsByTrack[track], {
          part = tonumber(col(h2, row, 'part')) or 1,
          text = txt,
          start_sec = tonumber(col(h2, row, 'start_sec')) or 0,
          dur_sec = tonumber(col(h2, row, 'duration_sec')) or 99,
        })
      end
    end
    for _, v in pairs(cdPartsByTrack) do table.sort(v, function(x, y) return x.part < y.part end) end
  end
  local hp, rp = read_tsv(CDPOS)
  if rp then
    for _, row in ipairs(rp) do
      local track = col(hp, row, 'track')
      local base = tonumber(col(hp, row, 'vram_base'), 16)
      if track ~= '' and base then
        cdPos[track] = { vram_base = base, text_y = tonumber(col(hp, row, 'text_y')) or 192,
                         center_x = tonumber(col(hp, row, 'center_x')) or 128,
                         status = col(hp, row, 'status') }
      end
    end
  end
  for _ in pairs(cdPartsByTrack) do ncdsub = ncdsub + 1 end
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
local frames = 0
local armed, arms, pushes = false, 0, 0
local stranded, cleared = 0, 0
local pushed_this_frame = false
local cur = nil                 -- { offs, w, n, pos }  지금 그릴 줄
local cd_track, cd_part = nil, -1  -- 지금 화면에 있는 CD-DA 트랙·조각
local last_pos = DEFAULT_POS
local ram_backup = nil

local function rb(a, t) return emu.read(a, t or MEM) or 0 end
local function set_vce_color(index, value)
  emu.write(VCE_ADDR_LO, index & 0xFF, MEM)
  emu.write(VCE_ADDR_HI, (index >> 8) & 0x01, MEM)
  emu.write(VCE_DATA_LO, value & 0xFF, MEM)
  emu.write(VCE_DATA_HI, (value >> 8) & 0x01, MEM)
end
local function ensure_subtitle_palette()
  set_vce_color(PAL15_BASE + 1, PAL15_C1)
  set_vce_color(PAL15_BASE + 2, PAL15_C2)
  set_vce_color(PAL15_BASE + 3, PAL15_C3)
end
local function match(addr, want)
  for i = 1, #want do if rb(addr + i - 1) ~= want[i] then return false end end
  return true
end
local function fingerprint_ok()
  for _, s in ipairs(SIG) do if not match(s[1], s[2]) then return false end end
  return true
end

-- 문장 하나를 VRAM 에 올리고 그릴 준비를 한다
local function set_line(text, pos)
  pos = pos or DEFAULT_POS
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
    local base = pos.vram_base * 2 + (i - 1) * 0x80
    local src = used[i].off
    for b = 0, 63 do emu.write(base + b, font:byte(src + b + 1) or 0, VRAM) end
    for b = 64, 127 do emu.write(base + b, 0, VRAM) end
  end
  cur = { n = n, offs = offs, w = pen, pos = pos }
  last_pos = pos
  say(string.format('[프레임 %d] 자막 "%s"  %d 자 · %d px · x %d..%d',
        frames, text, n, pen, pos.center_x - math.floor(pen / 2),
        pos.center_x - math.floor(pen / 2) + pen - 1))
end

local function build_stub()
  local pos = cur.pos
  local xo, yo = pos.center_x + 32, pos.text_y + 64
  local out = { 0x08, 0x78 }
  -- Lua의 endFrame 포트 쓰기는 CD-DA VBlank 순서에서 유효하게 남지 않았다.
  -- 따라서 SATB를 조립하는 바로 그 CPU 경로에서 VCE 팔레트를 설정한다.
  -- A9 imm / 8D abs를 쓰므로 게임과 같은 실제 I/O 버스를 탄다.
  local function vce(port, value)
    out[#out + 1] = 0xA9; out[#out + 1] = value & 0xFF
    out[#out + 1] = 0x8D; out[#out + 1] = port & 0xFF; out[#out + 1] = port >> 8
  end
  local function color(index, value)
    vce(VCE_ADDR_LO, index & 0xFF); vce(VCE_ADDR_HI, (index >> 8) & 0x01)
    vce(VCE_DATA_LO, value & 0xFF); vce(VCE_DATA_HI, (value >> 8) & 0x01)
  end
  color(PAL15_BASE + 1, PAL15_C1)
  color(PAL15_BASE + 2, PAL15_C2)
  color(PAL15_BASE + 3, PAL15_C3)
  local tail = {
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
  for _, b in ipairs(tail) do out[#out + 1] = b end
  return out
end

local function build_records()
  local half = math.floor(cur.w / 2)
  local r = {}
  for i = 1, cur.n do
    local w2 = ((cur.pos.vram_base >> 6) << 1) + 2 * (i - 1)
    local off = cur.offs[i] - half
    if off < -128 then off = -128 elseif off > 127 then off = 127 end
    r[#r+1] = 0x00; r[#r+1] = 0x00; r[#r+1] = off & 0xFF
    -- 하위 니블은 팔레트다.  0.1.2는 이 값을 빼서 게임의 회색 팔레트를 썼다.
    r[#r+1] = w2 & 0xFF; r[#r+1] = 0x80 | ((w2 >> 8) << 4) | GLYPH_PALETTE
  end
  return r
end

local function clear_ours(pos)
  pos = pos or last_pos
  local lo = (pos.vram_base >> 6) << 1
  local hi = lo + 2 * (MAX_GLYPH - 1)
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local w2 = rb(o + 4, VRAM) + rb(o + 5, VRAM) * 256
    local at = rb(o + 6, VRAM) + rb(o + 7, VRAM) * 256
    if (at & 0x0F) == GLYPH_PALETTE and (at & 0x80) ~= 0
       and w2 >= lo and w2 <= hi then
      for i = 0, 7 do emu.write(o + i, 0, VRAM) end
      cleared = cleared + 1
    end
  end
end

local function restore_engine_ram()
  if not ram_backup then return end
  for i = 1, #ram_backup do emu.write(STUB + i - 1, ram_backup[i], MEM) end
  ram_backup = nil
end

local function disarm()
  if not armed then return end
  if match(HOOK, PATCH) then
    for i = 1, #RESIDENT do emu.write(HOOK + i - 1, RESIDENT[i], MEM) end
  else
    stranded = stranded + 1
    if stranded <= 3 then say(string.format('[프레임 %d] ★ 회수 실패', frames)) end
  end
  armed = false
end

emu.addMemoryCallback(function()
  -- $600C는 $601E보다 앞이다. 여기서 심은 훅은 **같은 프레임**의 $601E에서
  -- 실행되고 $6072에서 회수된다. 다음 프레임에 미리 회수하면 한 번도 못 돈다.
  if cur == nil then return end                 -- 띄울 자막이 없으면 아무것도 안 한다
  if not fingerprint_ok() then return end
  if not match(HOOK, RESIDENT) then return end
  local code, rec = build_stub(), build_records()
  -- 일반 ADPCM 엔진($5B80-$5E0C)과 같은 RAM을 잠시 빌린다. CD-DA가 끝나면
  -- 이 범위를 원상복구해야 다음 ADPCM 자막 엔진을 절대 손상시키지 않는다.
  if ram_backup == nil then
    ram_backup = {}
    for i = STUB, LIST + MAX_GLYPH * 5 - 1 do ram_backup[#ram_backup + 1] = rb(i, MEM) end
  end
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

emu.addEventCallback(function()
  frames = frames + 1

  if armed then disarm() end
  -- 평상시에는 ADPCM 엔진/SATB를 절대 훑지 않는다. CD-DA가 자기 RAM을 빌린
  -- 동안에만 직전 프레임의 우리 슬롯을 지운다.
  if not pushed_this_frame and (ram_backup ~= nil or cd_track ~= nil or cur ~= nil) then
    clear_ours()
  end
  pushed_this_frame = false

  local ok, s = pcall(emu.getState)
  if ok and s then
    local sector = s['cdrom.audioPlayer.currentSector']
    local seg = (type(sector) == 'number') and cd_segment_at(math.floor(sector)) or nil
    local pos = seg and cdPos[seg.track] or nil
    local parts = seg and pos and pos.status == 'verified' and cdPartsByTrack[seg.track] or nil
    -- 독립 POC를 다시 확인하고 싶을 때만 고정 두 줄을 허용한다. 통합판은 절대 사용 안 한다.
    if not INTEGRATED and POC_TEST and seg and seg.clip == 'c17_001.wav' then
      parts, pos = TEST_PARTS, (cdPos['17'] or DEFAULT_POS)
    end
    if parts == nil then
      if cd_track then
        cur, cd_track, cd_part = nil, nil, -1
        clear_ours(); restore_engine_ram()
      end
    else
      local elapsed = (math.floor(sector) - (trackStart[seg.track] or seg.a)) / 75.0
      local want = 0
      for i, pp in ipairs(parts) do
        if elapsed >= pp.start_sec and elapsed < pp.start_sec + pp.dur_sec then want = i end
      end
      if seg.track ~= cd_track or want ~= cd_part then
        cd_track, cd_part = seg.track, want
        if want == 0 then cur = nil; clear_ours()
        else
          set_line(parts[want].text, pos)
          say(string.format('[프레임 %d] CDDA track %s %.2f초 · VRAM $%04X y=%d',
              frames, seg.track, elapsed, pos.vram_base, pos.text_y))
        end
      end
    end
  end

  if cur then
    emu.drawString(4, 4, string.format('CDDA %s/%d  %d px', cd_track or '--', cd_part, cur.w),
                   0xFFFFFF, 0x000000)
  end

  if frames % 300 == 0 then
    say(string.format('--- %d --- 무장 %d · 푸시 %d · 지움 %d · 회수실패 %d · CDDA 번역트랙 %d',
          frames, arms, pushes, cleared, stranded, ncdsub))
    local f = io.open(string.format('C:/snatcher/dump/probe_sub_live_0_1_1_%s.tsv',
                                    os.date('%Y%m%d_%H%M%S')), 'w')
    if f then
      f:write('line\n')
      for _, l in ipairs(lines) do f:write(l .. '\n') end
      f:close()
    end
  end
end, emu.eventType.startFrame)

emu.log('CDDA_SUBTITLE_RUNTIME 0.1.0 loaded -- track table + verified-safe position gate')
emu.log(string.format('  %s · CD-DA 구간 %d · 번역 트랙 %d · 글꼴 %d 자',
        INTEGRATED and 'HQ 통합 모드' or '독립 모드', #cdSegs, ncdsub, nglyphs))
emu.log('  글자 팔레트 15 (흰 본체 / 검은 외곽선) · SATB 직전 실제 6280 I/O로 초기화')
emu.log('  AC 무접근: 기존 한국어 UI lookup 테이블을 보존한다')
emu.log('  ★ $600C에서 다음 $601E를 1회 무장 · SATB push가 1 이상이어야 화면에 보임')
emu.log('  ★ verified 위치만 렌더 · 종료 시 $5C40-$5D8B를 원래 ADPCM 엔진으로 복원')
