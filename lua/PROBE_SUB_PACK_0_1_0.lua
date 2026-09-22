-- PROBE_SUB_PACK 0.1.0  --  팩이 자막을 몬다.  지문에 맞는 대사에만 뜬다
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
-- 출력  로그 + C:/snatcher/dump/probe_sub_pack_0_1_0_<날짜>.tsv

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE_AT, AC_BASE, STUB_AT = 0x5B80, 0x1C0000, 0x7FA0
local PAT_VRAM, PALETTE = 0x7900, 15
local MAX_GLYPHS = 9                      -- VRAM $7900-$7B3F 까지만 검증됐다

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
local function find_parts(read_addr, length, rate)
  local out = {}
  for i = 0, P.adpcm_count - 1 do
    local at = P.adpcm_off + i * P.adpcm_stride
    if u16(at) == read_addr and u16(at + 2) == length and u8(at + 4) == rate then
      out[#out+1] = { start_frame = u16(at + 6), rec = u32(at + 8) }
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
local frames, shown, skipped = 0, 0, 0
local armed, was_playing = false, false
local parts, part_index, voice_start = nil, 0, 0
local checked = false

local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end

local function put_part(record)
  local n = math.min(#record.cells, MAX_GLYPHS)
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

local function stage(record)
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  put_part(record)
  armed = true
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0x00, MEM) end
  armed = false
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_sub_pack_0_1_0_%s.tsv',
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

  local s = emu.getState()
  local playing = s['cdrom.adpcm.playing'] == true

  if playing and not was_playing then
    local found = find_parts(s['cdrom.adpcm.readAddress'] or 0,
                             s['cdrom.adpcm.adpcmLength'] or 0,
                             s['cdrom.adpcm.playbackRate'] or 0)
    if #found == 0 then
      skipped = skipped + 1                -- 자막이 없다 = 효과음이거나 아직 번역 전
      parts = nil
    else
      parts, part_index, voice_start = found, 1, frames
      local record = read_record(found[1].rec)
      stage(record)
      shown = shown + 1
      say(string.format('[%d] %04X/%04X/%02X  조각 %d개  "%s"',
            frames, s['cdrom.adpcm.readAddress'], s['cdrom.adpcm.adpcmLength'],
            s['cdrom.adpcm.playbackRate'], #found, record.text))
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
    if armed then disarm() end
    parts = nil
  end
  was_playing = playing

  if frames % 3600 == 0 then
    say(string.format('--- %d --- 띄움 %d · 자막 없어 넘김 %d', frames, shown, skipped))
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_PACK 0.1.0 loaded')
emu.log('  ★ build/patch/subtitle_resident/ 의 디스크로 켤 것')
emu.log('  팩에 지문이 있는 대사에만 자막이 뜬다 -- 효과음은 저절로 걸러진다')
emu.log(string.format('  한 줄 최대 %d 자 (VRAM $7900-$7B3F 까지만 검증됨)', MAX_GLYPHS))
