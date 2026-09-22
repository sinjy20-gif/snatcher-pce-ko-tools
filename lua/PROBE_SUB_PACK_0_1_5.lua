-- PROBE_SUB_PACK 0.1.5  --  한 줄 상한을 9 -> 19 자로
--
-- 왜 늘릴 수 있게 됐나
-- --------------------
-- 9 자 상한은 **VRAM 자리가 없어서** 둔 것이었다.  `$7900-$7B3F` 만 안전하다고
-- 믿었기 때문이다.  이제 음성 시작에 떠 두고 끝나면 되돌리므로, 음성 중에 비어
-- 있기만 하면 얼마든 빌릴 수 있다.
--
--     19 자 = $4C0 워드 -> $7900-$7DBF
--     음성 중 빈 창 $2078-$7FFF (24456 워드) 안에 든다   PROBE_VRAM_VOICE 0.1.0
--
-- 19 자는 실측 한 줄 한계다 (192 px · 초상화 위 폭).
--
-- ★ 엔진도 --max-glyphs 19 로 다시 구워야 한다 (레코드 자리가 19 칸 필요하다)
--
-- 0.1.4 에서 온 것: 열쇠는 **끝 주소** (읽기주소 + 길이)
--
-- 0.1.3 이 무엇을 보여줬나
-- ------------------------
-- 팩의 지문과 런타임 지문이 하나도 안 맞았다.  그런데 더해 보면 맞았다:
--
--     팩 0063+CF9D = D000     런타임 0068+CF98 = D000
--     팩 0066+579A = 5800     런타임 0064+579C = 5800
--     팩 006B+6795 = 6800     런타임 0070+6790 = 6800
--
-- **읽기주소 + 길이 = 끝 주소**만 안 변한다.  재생이 시작되는 지점이 매번 조금씩
-- 다르기 때문이다.  기존 연구의 "끝 주소로 정규화" 가 이 뜻이었다.
--
-- 팩 버전 3 부터 색인 열쇠가 끝 주소다 (항목 10 B).
--
-- 0.1.2 는 팩에 없는 지문을 세기만 하고 **무엇이었는지 안 남겼다.**  그래서
-- "대사 3 개가 지나갔는데 아무것도 안 떴다" 를 봐도 원인을 가릴 수 없었다:
--
--     A  팩에 없는 대사였다 (팩에 3 건뿐이다)      -> 정상
--     B  팩에 있는데 지문이 안 맞았다              -> ★ 문제
--
-- 넘긴 지문을 전부 찍으면 갈린다.  켤 때 팩이 가진 지문도 같이 알려준다.
--
-- 0.1.1 에서 지문 찾기·스테이징·VRAM 되돌리기까지 로그가 다 찍혔는데 **화면에는
-- 자막이 없었다.**  사슬이 네 마디라 어디서 끊겼는지 추측하면 안 된다.
--
--     1  엔진이 돌았나      ready 플래그가 1 이 됐나 ($5B80+138)
--     2  패턴이 올라갔나    VRAM $7900 이 0 이 아닌가
--     3  레코드가 맞나      엔진 안 list 바이트
--     4  SATB 에 들어갔나   워드 $1000 부터 우리 슬롯 (y · x · 패턴 · 속성)
--
-- 스테이징 몇 프레임 뒤에 넷을 다 떠서 찍는다.
--
-- 0.1.0 에서 무엇이 달라졌나
-- --------------------------
-- 글리프를 VRAM 에 올린 채 두면 **메뉴 선택 하이라이트가 깨진다.**  음성이 끝난
-- 뒤에도 계속 깨져 있었다 -- 게임이 그 자리를 다시 안 그린다는 뜻이다.
--
-- PROBE_VRAM_VOICE 0.1.0 이 답을 줬다:
--
--     음성 중  VRAM 을 거의 안 건드린다 ($2078-$7FFF 24456 워드가 무변화)
--     음성 밖  게임이 그 대부분을 다시 그린다
--
-- 즉 **음성 중에는 빌려도 되고, 끝나면 돌려주면 된다.**  $5B80 과 같은 방식이다.
-- 다만 RAM 과 달리 VRAM 은 게임이 알아서 안 지우므로 **우리가 되돌린다.**
--
--     음성 시작   그 구간 576 워드를 떠 둔다 -> 글리프를 올린다
--     음성 끝     떠 둔 것을 그대로 다시 쓴다
--
-- ($1080-$1FFF 도 무변화로 잡혔지만 쓰면 안 된다 -- 워드 $1000-$10FF 가 SATB 이고
--  그 뒷절반이 "안 쓰는 슬롯" 이라 안 바뀐 것뿐이다.)
--
-- 앞판(PROBE_ENGINE_STAGE 0.1.0)의 한계
-- --------------------------------------
-- ADPCM 이 울리면 **무조건** 같은 줄을 띄웠다.  효과음에도 떴다.  고정 한 줄을
-- 굽는 판이었으니 당연했다.
--
-- 이 판은 `subtitle_pack.bin` 을 읽는다.  팩에는 지문 색인이 들어 있다:
--
--     ADPCM 12 B   읽기주소 u16 · 길이 u16 · 재생률 u8 · 플래그 u8
--                  시작프레임 u16 · 기록오프셋 u32
--
-- 재생 시작 순간의 레지스터 세 값으로 찾아서, **있으면 띄우고 없으면 안 띄운다.**
-- 그것이 효과음을 거르는 방법이다 -- 따로 판정하지 않는다.  자막이 있으면 대사다.
--
-- 조각도 팩이 갖고 있다.  같은 지문의 항목들이 붙어 있고 `시작프레임` 이 다르므로,
-- 흐른 프레임으로 지금 조각을 고른다.
--
-- 자리 나눔 (앞판과 같다)
--     $601E  20 A0 7F EA   디스크
--     $7FA0  상주부 32 B    디스크
--     $5B80  엔진           이 스크립트가 음성 중에만 올린다
--     $1C0000 AC           글리프 패턴 -- 조각이 바뀔 때마다 다시 올린다
--
-- ★ build/patch/subtitle_resident/ 의 디스크로 켤 것
-- 출력  로그 + C:/snatcher/dump/probe_sub_pack_0_1_5_<날짜>.tsv

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE_AT, AC_BASE, STUB_AT = 0x5B80, 0x1C0000, 0x7FA0
local PAT_VRAM, PALETTE = 0x7900, 15
local MAX_GLYPHS = 19                     -- 실측 한 줄 한계 (192 px)

-- 엔진 파일 안 오프셋 (engine.json 의 offsets)
local OFF = { ready = 138, list = 139, count_x = 44, count_a = 130 }

local function slurp(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a'); f:close()
  local t = {}
  for i = 1, #d do t[i] = d:byte(i) end
  return t
end

local engine = slurp('C:/snatcher/build/cutscene_subs/engine.bin')
local pack = slurp('C:/snatcher/build/cutscene_subs/subtitle_pack.bin')

local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

-- ---------------------------------------------------------------- 팩 읽기
local P = {}
local function u8(o) return pack[o + 1] end
local function u16(o) return u8(o) | (u8(o + 1) << 8) end
local function u32(o) return u16(o) | (u16(o + 2) << 16) end

local function parse_pack()
  if not pack then return false end
  if u8(0) ~= 0x53 or u8(1) ~= 0x4E or u8(2) ~= 0x53 or u8(3) ~= 0x42 then
    say('★ 팩 magic 이 SNSB 가 아니다'); return false
  end
  P.version = u16(4)
  P.glyph_count, P.glyph_off = u16(8), u32(10)
  P.adpcm_count, P.adpcm_off = u16(14), u32(16)
  P.record_off = u32(26)
  P.glyph_bytes, P.cell_bytes = u8(34), u8(35)
  P.char_off = u32(38)
  P.adpcm_stride = u8(42)
  return true
end

local function char_at(id)
  return u16(P.char_off + id * 2)
end

-- 지문에 맞는 조각들을 앞으로 걸어가며 모은다 (팩이 그렇게 정렬돼 있다)
local function find_parts(end_addr, rate)
  local out = {}
  for i = 0, P.adpcm_count - 1 do
    local at = P.adpcm_off + i * P.adpcm_stride
    if u16(at) == end_addr and u8(at + 2) == rate then
      out[#out+1] = { start_frame = u16(at + 4), rec = u32(at + 6) }
    elseif #out > 0 then
      break                               -- 붙어 있으므로 끊기면 끝이다
    end
  end
  return out
end

local function read_record(rec)
  local base = P.record_off + rec
  local cells, width = u8(base), u8(base + 1)
  local out = { width = width, cells = {} , text = '' }
  for i = 0, cells - 1 do
    local at = base + 6 + i * P.cell_bytes
    local id, x = u16(at), u8(at + 2)
    out.cells[#out.cells+1] = { id = id, x = x }
    out.text = out.text .. utf8.char(char_at(id))
  end
  return out
end

-- ---------------------------------------------------------------- 올리기
local VRAMT = emu.memType.pceVideoRam
local VRAM_WORDS = MAX_GLYPHS * 0x40      -- 19 x $40 = 1216 워드 ($7900-$7DBF)
local backup = nil                        -- 음성 시작에 떠 두는 원래 내용

local SATB_WORD = 0x1000                  -- VDC 워드.  한 항목 4 워드
local check_at = 0                        -- 이 프레임에 되읽는다
local check_n = 0

local seen_miss = {}                      -- 넘긴 지문은 한 번씩만 찍는다
local frames, shown, skipped = 0, 0, 0
local armed, was_playing = false, false
local parts, part_index, voice_start = nil, 0, 0
local checked = false

local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end

local function n_cells(record)
  return math.min(#record.cells, MAX_GLYPHS)
end

local function put_part(record)
  local n = n_cells(record)
  local half = math.floor(record.width / 2)

  -- 글리프 패턴을 AC 로
  for i = 1, n do
    local src = P.glyph_off + record.cells[i].id * P.glyph_bytes
    for b = 0, P.glyph_bytes - 1 do
      emu.write(AC_BASE + (i - 1) * P.glyph_bytes + b, u8(src + b), AC)
    end
  end

  -- 레코드를 엔진 안으로
  for i = 1, n do
    local word = ((PAT_VRAM >> 6) << 1) + 2 * (i - 1)
    local off = record.cells[i].x - half
    if off < 0 then off = off + 256 end
    local at = ENGINE_AT + OFF.list + (i - 1) * 5
    emu.write(at + 0, 0x00, MEM); emu.write(at + 1, 0x00, MEM)
    emu.write(at + 2, off & 0xFF, MEM)
    emu.write(at + 3, word & 0xFF, MEM)
    emu.write(at + 4, 0x80 | ((word >> 8) << 4) | PALETTE, MEM)
  end

  emu.write(ENGINE_AT + OFF.count_x + 1, n, MEM)     -- LDX #n
  emu.write(ENGINE_AT + OFF.count_a + 1, n, MEM)     -- LDA #n
  emu.write(ENGINE_AT + OFF.ready, 0x00, MEM)        -- 패턴을 다시 올리게
end

-- VRAM 을 빌리기 전에 떠 둔다.  음성 하나당 한 번이면 된다
local function vram_save()
  backup = {}
  for i = 0, VRAM_WORDS - 1 do
    backup[i] = emu.read(PAT_VRAM + i, VRAMT) or 0
  end
end

local function vram_restore()
  if not backup then return end
  for i = 0, VRAM_WORDS - 1 do
    emu.write(PAT_VRAM + i, backup[i], VRAMT)
  end
  backup = nil
end

local function inspect(n)
  local ready = emu.read(ENGINE_AT + OFF.ready, MEM)
  local magic = string.format('%02X %02X %02X',
        emu.read(ENGINE_AT, MEM), emu.read(ENGINE_AT + 1, MEM), emu.read(ENGINE_AT + 2, MEM))
  say(string.format('    [1] 매직 %s · ready %d  %s', magic, ready,
        ready == 1 and '-> 엔진이 돌았다' or '★ 엔진이 안 돌았다'))

  local pat = {}
  for i = 0, 5 do pat[#pat+1] = string.format('%04X', emu.read(PAT_VRAM + i, VRAMT) or 0) end
  local blank = true
  for i = 0, 63 do if (emu.read(PAT_VRAM + i, VRAMT) or 0) ~= 0 then blank = false; break end end
  say(string.format('    [2] VRAM $%04X %s  %s', PAT_VRAM, table.concat(pat, ' '),
        blank and '★ 전부 0 -- 패턴이 안 올라갔다' or '-> 패턴 있다'))

  local rec = {}
  for i = 0, 9 do rec[#rec+1] = string.format('%02X', emu.read(ENGINE_AT + OFF.list + i, MEM)) end
  say(string.format('    [3] list %s  (앞 2 칸)', table.concat(rec, ' ')))

  local sat = {}
  for i = 0, 3 do sat[#sat+1] = string.format('%04X', emu.read(SATB_WORD + i, VRAMT) or 0) end
  say(string.format('    [4] SATB[0] y=%s x=%s pat=%s attr=%s', sat[1], sat[2], sat[3], sat[4]))
end

local function stage(record)
  vram_save()
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  put_part(record)
  armed = true
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0x00, MEM) end
  armed = false
  vram_restore()                          -- 빌린 것을 돌려준다
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_sub_pack_0_1_5_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:close()
end

local ready = parse_pack()
if ready then
  emu.log(string.format('팩 버전 %d · 글리프 %d 자 · ADPCM 조각 %d',
                        P.version, P.glyph_count, P.adpcm_count))
  -- 팩이 가진 지문을 미리 알려준다 -- 어느 장면으로 가야 하는지 알 수 있게
  local listed = {}
  for i = 0, P.adpcm_count - 1 do
    local at = P.adpcm_off + i * P.adpcm_stride
    local key = string.format('끝 %04X 률 %02X', u16(at), u8(at + 2))
    if not listed[key] then
      listed[key] = true
      emu.log(string.format('  팩에 있는 지문  %s  "%s"', key,
                            read_record(u32(at + 6)).text))
    end
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  if not ready or not engine then return end

  if not checked and stub_ok() then
    checked = true
    say('준비됨 -- 훅과 상주부 확인')
  end
  if frames == 1800 and not checked then
    say('★ 상주부나 훅을 못 봤다 -- build/patch/subtitle_resident/ 로 켰는지 볼 것')
  end

  if check_at > 0 and frames == check_at then
    check_at = 0
    inspect(check_n)
  end

  local s = emu.getState()
  local playing = s['cdrom.adpcm.playing'] == true

  if playing and not was_playing then
    local ending = (((s['cdrom.adpcm.readAddress'] or 0)
                   + (s['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    local found = find_parts(ending, s['cdrom.adpcm.playbackRate'] or 0)
    if #found == 0 then
      skipped = skipped + 1                -- 자막이 없다 = 효과음이거나 아직 번역 전
      local key = string.format('끝 %04X 률 %02X  (%04X+%04X)', ending,
            s['cdrom.adpcm.playbackRate'] or 0,
            s['cdrom.adpcm.readAddress'] or 0, s['cdrom.adpcm.adpcmLength'] or 0)
      if not seen_miss[key] then
        seen_miss[key] = true
        say(string.format('[%d] 넘김  %s  (팩에 없다)', frames, key))
      end
      parts = nil
    else
      parts, part_index, voice_start = found, 1, frames
      local record = read_record(found[1].rec)
      stage(record)
      shown = shown + 1
      check_at, check_n = frames + 8, n_cells(record)
      say(string.format('[%d] 끝 %04X  조각 %d개  "%s"',
            frames, ending, #found, record.text))
    end
  elseif playing and parts then
    -- 흐른 프레임으로 지금 조각을 고른다
    local elapsed = frames - voice_start
    local want = part_index
    for i = #parts, 1, -1 do
      if elapsed >= parts[i].start_frame then want = i; break end
    end
    if want ~= part_index then
      part_index = want
      local record = read_record(parts[want].rec)
      put_part(record)
      say(string.format('    +%df  조각 %d  "%s"', elapsed, want, record.text))
    end
  elseif not playing and was_playing then
    if armed then
      disarm()
      say(string.format('    음성 끝 -- VRAM %d 워드 되돌림', VRAM_WORDS))
    end
    parts = nil
  end
  was_playing = playing

  if frames % 3600 == 0 then
    say(string.format('--- %d --- 띄움 %d · 자막 없어 넘김 %d', frames, shown, skipped))
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_PACK 0.1.5 loaded')
emu.log('  ★ build/patch/subtitle_resident/ 의 디스크로 켤 것')
emu.log('  팩에 지문이 있는 대사에만 자막이 뜬다 -- 효과음은 저절로 걸러진다')
emu.log(string.format('  한 줄 최대 %d 자 · VRAM $%04X-$%04X 를 빌렸다 되돌린다',
                      MAX_GLYPHS, PAT_VRAM, PAT_VRAM + VRAM_WORDS - 1))
