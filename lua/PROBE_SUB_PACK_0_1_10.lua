-- PROBE_SUB_PACK 0.1.10  --  열쇠를 (sector, 길이) 로 바꿨다
--
-- 0.1.9 의 측정이 답을 냈다 (2026-08-24)
-- ---------------------------------------------------------------------------
-- 끝 주소는 못 쓴다.  672 이벤트를 **59 값**으로 뭉갠다.  실기에서 이렇게 보였다:
--
--     실제 「<원문 6자>」(효과음)      -> 자막 "국장님, 길리언 시드 씨를"
--     실제 「<원문 8자>!」(효과음)  -> 자막 "맞다, 국장님이 말씀하셨어요."
--
-- 프로브가 잰 지문이 `voice_events.tsv` 의 `clip_file` 과 그대로 맞아서, 그때
-- 실제로 난 음성이 무엇이었는지 표에서 되찾을 수 있었다.  넷 중 셋이 남의
-- 자막이었다.  효과음 필터가 같이 깨진 것이기도 하다.
--
-- sector 는 둘 다 참이었다:
--     1  재생 시작 프레임에 값이 보인다
--     2  다시 틀어도 같다   08-20 수집값 = 08-24 프로브값 (14394/12395/12408)
--
-- 후보 점수 (672 이벤트 · 대사충돌 / 효과음이대사를 / 값개수)
--     끝주소       34 / 25 /  59
--     sector        0 /  6 / 565
--     sector+길이   0 /  1 / 668     <- 이것.  팩 버전 5
--
-- 측정층은 **그대로 둔다.**  바꾼 열쇠가 실기에서도 갈라내는지 같은 표로 계속
-- 확인해야 한다.  후보를 지우면 다음에 또 한 판 돌아야 한다.
--
-- 무엇을 재나 (인계서 §3)
-- -----------------------
-- 지금 열쇠는 `(읽기주소 + 길이) & FFFF` 다.  그런데 그 합이 **버퍼의 끝 주소**라
-- 같은 크기 등급의 음성이 전부 같은 값을 낸다.  대사 56 이벤트가 25 열쇠로
-- 뭉개져서 31 건이 충돌하고 자막 70 개가 팩에서 빠진다.
--
-- 후보는 `sector` 다.  쓸 수 있으려면 둘이 참이어야 한다:
--
--     1  재생이 시작되는 그 프레임에 값이 보인다
--        ADPCM 은 CD 에서 먼저 읽어 두고 나중에 재생한다.  재생 시점에는
--        헤드가 이미 지나가 있을 수 있다.  그러면 못 쓴다
--     2  같은 음성을 다시 틀어도 같은 값이다
--        끝 주소가 "합만 안 변한다" 였던 것처럼, 이것도 재 봐야 안다
--
-- 어떻게 재나 -- **정답지를 따로 만든다**
-- --------------------------------------
-- "같은 음성인가" 를 후보 열쇠로 판정하면 순환논법이다.  그래서 판정은
-- 내용으로 한다: 재생 시작 순간의 ADPCM RAM 을 지문으로 접는다 (수집기 0.2.3 과
-- **같은 방법·같은 상수** -- 끝에서 8 KB · FNV).  그 지문이 정답지다.
--
--     지문이 같다  = 같은 음성          -> 후보 값도 같아야 한다 (재현성)
--     지문이 다르다 = 다른 음성          -> 후보 값이 달라야 한다 (구분력)
--
-- 이 둘을 각각 세어서 끝에 표로 낸다.  "sector 가 된다/안 된다" 를 짐작이 아니라
-- 숫자로 닫으려는 것이다.
--
-- 덤으로 CD-DA 의 `currentSector` 가 어떻게 움직이는지도 같이 찍는다.
-- 인계서 §2.2 (CD-DA 판정을 런타임에 붙이기) 의 근거가 여기서 같이 나온다.
--
-- 0.1.9 가 같이 고친 것 -- 잔류 백스톱 (3_PLACED §2)
-- ---------------------------------------------------------------------------
-- `$601E` 를 안 지나는 프레임이 있다 (**메뉴가 떠 있을 때 등**).  그러면 게임이
-- SATB 를 다시 안 쓰고, 지난 프레임의 우리 엔트리가 그대로 남는다.  화면에서는
-- UI 선택 스프라이트가 깨진 것으로 보인다.
--
-- 판단은 지문이 아니라 **이번 프레임에 실제로 밀었는가** 로 한다.  지문은
-- "오버레이가 갈렸다" 만 알려주지 "이번에 안 그렸다" 는 못 알려준다.
-- 안 밀었으면 SATB 64 칸을 훑어 **우리 것만** 지운다.
--
-- 기준판 `PROBE_SUB_TEXT_0_1_0.lua` 에 이미 있던 것이다.  팩 계열(SUB_PACK)이
-- 그것을 안 이어받고 따로 자라서 같은 구멍이 다시 열렸다.
--
-- 밀었는지는 엔진 안의 `JSR $6463` 에 훅을 걸어 잡는다 ($5C06 · engine.bin 실측).
-- 기준판은 스텁 안 `$5C71` 을 봤는데, 지금은 상주부가 디스크에 박혀 있어 자리가
-- 다르다.
--
-- SATB 주소는 **짐작하지 않는다**
-- ---------------------------------------------------------------------------
-- 문서가 갈린다.  1_BREAKTHROUGH §4 는 "VDC 워드 $1000 = Mesen 바이트 $2000",
-- 기준판은 바이트 `0x2000`, 그런데 0.1.8 은 워드 `0x1000`/`0x7900` 으로 패턴을
-- 올려서 **화면에 글자가 떴다.**  둘 다 맞을 수는 없다.
--
-- 그래서 민 다음 프레임에 후보 둘을 다 훑어, 우리 패턴 대역($3C8..)과
-- attr $0080 을 가진 엔트리가 **실제로 있는 쪽**을 고른다.  고르기 전에는
-- 아무것도 안 지운다 -- 틀린 자리를 지우면 남의 스프라이트를 부순다.
--
-- 무엇을 안 건드렸나
-- ------------------
-- 자막을 띄우는 부분(stage · put_part · disarm · 조각 전환)은 그대로다.
-- 측정은 그 옆에 붙어서 읽기만 한다.  0.1.8 로 뜨던 것은 그대로 뜬다.
--
-- 0.1.8 에서 온 것: AC 자리표를 따른다
--
-- 왜 바꿨나
-- ---------
-- 팩도 `$1C0000`, 글리프 스테이징도 `$1C0000` 이었다.  **같은 자리다.**
-- 팩을 아직 AC 에 안 올려서 안 터졌을 뿐, 올리는 순간 첫 글자가 팩 머리를 덮는다.
--
-- 적재 경로(부팅 로더)를 설계하려면 **무엇을 어디로 싣는지**가 먼저 정해져야 한다.
-- `tools/subtitle_layout.py` 가 그 표다:
--
--     $1C0000  팩            192 KB 까지
--     $1F0000  엔진 이미지     1 KB
--     $1F0400  VRAM 백업      4 KB
--     $1F1400  글리프 스테이징  2 KB    <- 이 스크립트가 쓰는 곳
--
-- 0.1.7 에서 온 것: SATB 세기 · 자리(위/중간/아래) · 19 자 · 끝 주소 열쇠
--
-- 팩에는 16 칸이 들어 있고 (`"안내와 오퍼레이터를 맡고 있는"`), Lua 상한도 19 인데
-- 화면에는 **정확히 9 칸**만 나온다.  9 는 예전 상한이라 어딘가 남아 있는 값 같지만
-- 짐작하면 안 된다.  세어 본다:
--
--     $16   우리가 넣은 글자 수            -- 우리가 쓴 값이 그대로 있나
--     $17   게임이 남긴 SATB 빈 슬롯 수    -- 이것이 9 면 자리가 모자란 것이다
--     SATB  우리 패턴을 쓰는 항목이 몇 개  -- 실제로 몇 칸이 들어갔나
--
-- 0.1.6 에서 온 것: 자막마다 자리 (위 32 · 중간 122 · 아래 192)
--
-- 왜
-- --
-- 게임 중 대사는 초상화 위(122)가 맞는데, CD-DA 컷신은 화면을 다 쓰므로 거기
-- 뜨면 그림을 가린다.  그래서 기록 머리의 남는 바이트를 y 로 쓴다 (팩 버전 4).
--
--     위 32 · 중간 122 · 아래 192      글리프가 16 px 이라 아래는 224-16 안쪽
--     기본  ADPCM 중간 · CD-DA 아래
--
-- 엔진의 원점 즉치값을 자막마다 바꿔 쓴다 (org+1 = y 하위 · org+5 = y 상위).
--
-- 0.1.5 에서 온 것: 한 줄 19 자 · VRAM 빌렸다 되돌리기
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
-- 출력  로그 + C:/snatcher/dump/probe_sub_pack_0_1_8_<날짜>.tsv

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE_AT, STUB_AT = 0x5B80, 0x7FA0
local AC_BASE = 0x1F1400        -- 글리프 스테이징 (subtitle_layout.py)
local PAT_VRAM, PALETTE = 0x7900, 15
local MAX_GLYPHS = 19                     -- 실측 한 줄 한계 (192 px)

-- 엔진 파일 안 오프셋 (engine.json 의 offsets)
local OFF = { ready = 138, list = 139, count_x = 44, count_a = 130, org = 98 }

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
  -- 판이 안 맞으면 조용히 엉뚱한 자막을 띄운다.  여기서 크게 막는다.
  if P.version ~= 5 or P.adpcm_stride ~= 12 then
    say(string.format('★ 팩 판이 안 맞는다: 버전 %d · ADPCM 항목 %d B  (5 / 12 여야 한다)',
          P.version, P.adpcm_stride))
    say('   tools/build_subtitle_pack.py 를 다시 돌릴 것')
    return false
  end
  return true
end

local function char_at(id)
  return u16(P.char_off + id * 2)
end

-- 지문에 맞는 조각들을 앞으로 걸어가며 모은다 (팩이 그렇게 정렬돼 있다)
-- 팩 버전 5 항목:  sector u24 · length u16 · flags u8 · start_frame u16 · rec u32
local function u24(o) return u16(o) | (u8(o + 2) << 16) end

local function find_parts(sector, length)
  local out = {}
  for i = 0, P.adpcm_count - 1 do
    local at = P.adpcm_off + i * P.adpcm_stride
    if u24(at) == sector and u16(at + 3) == length then
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
  -- +03 이 y 다 (팩 버전 4).  0 이면 옛 팩이므로 중간으로 본다
  local y = u8(base + 3)
  if y == 0 then y = 122 end
  local out = { width = width, y = y, cells = {}, text = '' }
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

  local sat_y = record.y + 64                        -- SATB 는 y+64 기준
  emu.write(ENGINE_AT + OFF.org + 1, sat_y & 0xFF, MEM)
  emu.write(ENGINE_AT + OFF.org + 5, (sat_y >> 8) & 0xFF, MEM)
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

  -- 우리 패턴 번호 범위: base 부터 2 씩
  local base = (PAT_VRAM >> 6) << 1
  local mine, used = 0, 0
  for e = 0, 63 do
    local pat = emu.read(SATB_WORD + e * 4 + 2, VRAMT) or 0
    local y = emu.read(SATB_WORD + e * 4, VRAMT) or 0
    if y ~= 0 then used = used + 1 end
    if pat >= base and pat < base + n * 2 then mine = mine + 1 end
  end
  say(string.format('    [5] 넣으려던 %d 칸 · SATB 에 들어간 우리 것 %d · 쓰인 슬롯 %d/64',
        n, mine, used))
  say(string.format('    [6] zp $16 = %d (글자 수) · $17 = %d (게임이 남긴 빈 슬롯)',
        emu.read(0x16, MEM), emu.read(0x17, MEM)))
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
  local f = io.open(string.format('C:/snatcher/dump/probe_sub_pack_0_1_10_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:close()
end

-- ==========================================================================
-- 측정층 (0.1.9)
-- ==========================================================================

local ADPCM_RAM_SIZE = 0x10000
local ADPCMT = emu.memType.pceAdpcmRam
-- 수집기 0.2.3 과 **같은 값이어야 한다.**  다르면 여기서 접은 것과 저기서 뜬
-- 클립 파일이 서로 다른 이름을 갖게 되어 대조가 안 된다.
local FINGERPRINT_TAIL = 8192

-- 재생 시작 순간의 ADPCM RAM 을 접는다.  끝에서부터 잡는다 -- 같은 대사도
-- 시작이 몇 바이트 흔들리고 끝은 고정이기 때문이다 (2026-08-20 실측).
local function voice_fingerprint(read_addr, length)
  if ADPCMT == nil or length == nil or length <= 0 then return nil end
  local first = math.max(0, length - FINGERPRINT_TAIL)
  local step = math.max(1, math.floor((length - first) / 512))
  local h = 2166136261
  local i = first
  while i < length do
    local b = emu.read((read_addr + i) % ADPCM_RAM_SIZE, ADPCMT) or 0
    h = (h ~ b) * 16777619 % 4294967296
    i = i + step
  end
  return h
end

local STAMP = os.date('%Y%m%d_%H%M%S')
local KEYPATH = 'C:/snatcher/dump/probe_key_0_1_10_' .. STAMP .. '.tsv'
local CDDAPATH = 'C:/snatcher/dump/probe_cdda_0_1_10_' .. STAMP .. '.tsv'

-- getState 는 평평한 키를 준다.  `cdrom.` 으로 시작하는 것을 통째로 찍는다 --
-- 무엇이 쓸모 있는지 아직 모르므로 고르지 않는다.
local key_cols = nil
local key_rows = {}
local by_print = {}          -- 지문 -> { [후보값] = 횟수 }
local print_order = {}

local function cdrom_keys(state)
  local out = {}
  for k, v in pairs(state) do
    if type(k) == 'string' and k:sub(1, 6) == 'cdrom.'
       and (type(v) == 'number' or type(v) == 'boolean') then
      out[#out+1] = k
    end
  end
  table.sort(out)
  return out
end

local function fmt(v)
  if type(v) == 'boolean' then return v and '1' or '0' end
  if type(v) == 'number' then return string.format('%d', math.floor(v)) end
  return ''
end

-- 후보를 여러 개 같이 잰다.  하나만 재면 그것이 실패했을 때 또 한 판 돌아야 한다.
local function candidates(state, ending)
  return {
    end_addr = string.format('%04X', ending),
    sector = fmt(state['cdrom.scsi.sector']),
    cur_sector = fmt(state['cdrom.audioPlayer.currentSector']),
    read_addr = fmt(state['cdrom.adpcm.readAddress']),
    length = fmt(state['cdrom.adpcm.adpcmLength']),
  }
end

local function record_key(state, ending, fp)
  if key_cols == nil then
    key_cols = cdrom_keys(state)
    local f = io.open(KEYPATH, 'w')
    if f then
      f:write('frame\tfingerprint\tend_addr\trate\t' .. table.concat(key_cols, '\t') .. '\n')
      f:close()
    end
  end
  local vals = {}
  for _, k in ipairs(key_cols) do vals[#vals+1] = fmt(state[k]) end
  local row = string.format('%d\t%s\t%04X\t%02X\t%s', frames,
        fp and string.format('%08X', fp) or '',
        ending, state['cdrom.adpcm.playbackRate'] or 0,
        table.concat(vals, '\t'))
  key_rows[#key_rows+1] = row
  local f = io.open(KEYPATH, 'a')
  if f then f:write(row .. '\n'); f:close() end

  if fp then
    local slot = by_print[fp]
    if slot == nil then
      slot = { n = 0, seen = {} }
      by_print[fp] = slot
      print_order[#print_order+1] = fp
    end
    slot.n = slot.n + 1
    local c = candidates(state, ending)
    for name, v in pairs(c) do
      slot.seen[name] = slot.seen[name] or {}
      slot.seen[name][v] = (slot.seen[name][v] or 0) + 1
    end
  end
end

-- ---- CD-DA.  currentSector 가 어떻게 움직이는지 (인계서 §2.2 근거) ----------
local CDDA_GRACE = 12
local cdda = nil
local cdda_prev, cdda_last_adv = nil, nil
local cdda_rows = {}

local function cdda_finish()
  if cdda == nil then return end
  local row = string.format('%d\t%d\t%d\t%d\t%d\t%.3f',
        cdda.start_frame, frames, cdda.first, cdda.last,
        cdda.last - cdda.first, (frames - cdda.start_frame) / 60.0)
  cdda_rows[#cdda_rows+1] = row
  say(string.format('CDDA  섹터 %d -> %d  (%d 섹터 · %.1f초 · 초당 %.1f)',
        cdda.first, cdda.last, cdda.last - cdda.first,
        (frames - cdda.start_frame) / 60.0,
        (cdda.last - cdda.first) / math.max(0.001, (frames - cdda.start_frame) / 60.0)))
  cdda = nil
  cdda_last_adv = nil
end

local function cdda_tick(state)
  local sec = state['cdrom.audioPlayer.currentSector']
  if type(sec) ~= 'number' then
    cdda_prev = nil
    if cdda and cdda_last_adv and frames - cdda_last_adv >= CDDA_GRACE then cdda_finish() end
    return
  end
  sec = math.floor(sec)
  if cdda_prev == nil then cdda_prev = sec; return end
  if sec ~= cdda_prev then
    if cdda == nil then
      cdda = { start_frame = frames, first = sec, last = sec }
      say(string.format('CDDA  시작 섹터 %d  (frame %d)', sec, frames))
    else
      cdda.last = sec
    end
    cdda_last_adv = frames
  elseif cdda and cdda_last_adv and frames - cdda_last_adv >= CDDA_GRACE then
    cdda_finish()
  end
  cdda_prev = sec
end

-- ---- 끝에 내는 표 -- 이것이 §3 의 답이다 ----------------------------------
local function key_report()
  if #print_order == 0 then
    say('★ 잰 음성이 없다.  대사가 나오는 곳을 지나야 한다')
    return
  end
  local repeated = 0
  for _, fp in ipairs(print_order) do
    if by_print[fp].n > 1 then repeated = repeated + 1 end
  end
  say('')
  say(string.format('== 열쇠 측정 == 음성 %d 회 · 서로 다른 음성 %d 개 · 다시 틀린 것 %d 개',
        #key_rows, #print_order, repeated))

  local names = { 'end_addr', 'sector', 'cur_sector', 'read_addr', 'length' }
  say('')
  say(string.format('%-11s %14s %14s', '후보', '재현성', '구분력'))
  say(string.format('%-11s %14s %14s', '', '같은음성=같은값', '다른음성=다른값'))
  for _, name in ipairs(names) do
    -- 재현성: 다시 틀린 음성에서 값이 하나로 유지됐나
    local stable, unstable = 0, 0
    -- 구분력: 값 하나에 음성이 몇 개나 몰리나
    local owners = {}
    for _, fp in ipairs(print_order) do
      local slot = by_print[fp]
      local vs = slot.seen[name] or {}
      local nv, only = 0, nil
      for v, _ in pairs(vs) do nv = nv + 1; only = v end
      if slot.n > 1 then
        if nv == 1 then stable = stable + 1 else unstable = unstable + 1 end
      end
      for v, _ in pairs(vs) do
        owners[v] = owners[v] or {}
        owners[v][fp] = true
      end
    end
    local values, collided = 0, 0
    for v, set in pairs(owners) do
      values = values + 1
      local c = 0
      for _ in pairs(set) do c = c + 1 end
      if c > 1 then collided = collided + c end
    end
    say(string.format('%-11s  %4d 안정 %4d 흔들림  %4d 값 · %4d 음성이 겹침',
          name, stable, unstable, values, collided))
  end
  say('')
  say('읽는 법:  흔들림 0 이고 겹침 0 인 후보가 열쇠로 쓸 수 있는 것이다')
  say(string.format('  -> %s', KEYPATH))

  local f = io.open(CDDAPATH, 'w')
  if f then
    f:write('start_frame\tend_frame\tfirst_sector\tlast_sector\tsectors\tseconds\n')
    for _, r in ipairs(cdda_rows) do f:write(r .. '\n') end
    f:close()
    say(string.format('CD-DA 구간 %d 개  -> %s', #cdda_rows, CDDAPATH))
  end
end

-- ==========================================================================
-- 잔류 백스톱 (3_PLACED §2)
-- ==========================================================================

-- 우리 패턴 대역.  엔진이 쓰는 패턴 번호는 (PAT_VRAM >> 6) << 1 부터 2 씩이다.
local OUR_PAT_LO = (PAT_VRAM >> 6) << 1
local OUR_PAT_HI = OUR_PAT_LO + 2 * (MAX_GLYPHS - 1)

-- 후보 둘.  stride 는 한 엔트리 크기다 (워드면 4, 바이트면 8).
local SATB_CANDS = {
  { name = '워드 $1000', base = 0x1000, stride = 4, w = 1 },
  { name = '바이트 $2000', base = 0x2000, stride = 8, w = 2 },
}
local satb = nil                -- 정해진 뒤 여기 들어간다
local satb_decided = false

local function sat_field(c, slot, index)
  -- index 0=y 1=x 2=pattern 3=attr
  local o = c.base + slot * c.stride + index * c.w
  if c.w == 1 then return emu.read(o, VRAMT) or 0 end
  return (emu.read(o, VRAMT) or 0) + ((emu.read(o + 1, VRAMT) or 0) << 8)
end

-- 우리 엔트리인가.
--
-- ★ 기준판의 `attr == $0080` 을 그대로 쓰면 **영영 0 개**다.  그것은 팔레트가
-- 0 이던 시절 조건이고, 6_LIVE §4 가 그날 밤 팔레트를 0 -> 15 로 바꿨다
-- (0 은 메뉴가 쓴다).  엔진이 실제로 쓰는 값은
--
--     0x80 | ((패턴워드 >> 8) << 4) | PALETTE
--
-- 이라 상위 니블이 패턴 상위비트에 따라 흔들리고 하위 니블이 팔레트다.
-- 그래서 **팔레트 니블 + 패턴 대역** 두 가지로 본다.  둘 다 맞아야 우리 것이다.
local function is_ours(pat, attr)
  return (attr & 0x0F) == PALETTE
     and (attr & 0x80) ~= 0
     and pat >= OUR_PAT_LO and pat <= OUR_PAT_HI
end

local function count_ours(c)
  local n = 0
  for slot = 0, 63 do
    if is_ours(sat_field(c, slot, 2), sat_field(c, slot, 3)) then n = n + 1 end
  end
  return n
end

-- 민 직후에 부른다.  우리 엔트리가 보이는 쪽이 진짜 SATB 다.
--
-- 못 찾아도 매 프레임 떠들지 않는다.  0.1.9 첫 판이 그것 때문에 로그를 수천 줄
-- 도배했다 -- 못 찾는 상태가 계속되면 같은 줄이 프레임마다 나온다.
local decide_tries, DECIDE_MAX = 0, 240
local decide_reported = false

local function decide_satb()
  if satb_decided or decide_tries >= DECIDE_MAX then return end
  decide_tries = decide_tries + 1
  local best, best_n = nil, 0
  local parts = {}
  for _, c in ipairs(SATB_CANDS) do
    local n = count_ours(c)
    parts[#parts+1] = string.format('%s %d', c.name, n)
    if n > best_n then best, best_n = c, n end
  end
  if best then
    satb, satb_decided = best, true
    say(string.format('    SATB 자리 결정: %s  (우리 엔트리 %d 개 · %d 번째 시도)',
          best.name, best_n, decide_tries))
    say(string.format('    후보별: %s', table.concat(parts, ' · ')))
    say('    -> 백스톱을 켠다')
  elseif decide_tries >= DECIDE_MAX and not decide_reported then
    decide_reported = true
    say(string.format('    ★ %d 프레임 밀었는데 두 후보 어디에도 우리 엔트리가 없다',
          DECIDE_MAX))
    say(string.format('       후보별: %s', table.concat(parts, ' · ')))
    say('       백스톱을 안 켠다 -- 자리를 모르는 채로 지우면 남의 것을 부순다')
    say(string.format('       찾던 것: 팔레트 %d · 패턴 $%03X-$%03X · attr bit7',
          PALETTE, OUR_PAT_LO, OUR_PAT_HI))
  end
end

-- 우리 것만 지운다.  attr 과 패턴 대역 둘 다 맞아야 우리 것이다.
local cleared_total = 0
local function clear_ours()
  if satb == nil then return end
  for slot = 0, 63 do
    if is_ours(sat_field(satb, slot, 2), sat_field(satb, slot, 3)) then
      local o = satb.base + slot * satb.stride
      for i = 0, satb.stride - 1 do emu.write(o + i, 0, VRAMT) end
      cleared_total = cleared_total + 1
    end
  end
end

-- 엔진이 게임 푸시 루프를 부르는 자리.  여기가 돌면 이번 프레임에 민 것이다.
local ENGINE_PUSH_AT = 0x5C06          -- engine.bin 안 JSR $6463 (실측)
local pushed_this_frame = false
local push_hits = 0

emu.addMemoryCallback(function()
  pushed_this_frame = true
  push_hits = push_hits + 1
end, emu.callbackType.exec, ENGINE_PUSH_AT, ENGINE_PUSH_AT, emu.cpuType.pce, MEM)

local ready = parse_pack()
if ready then
  emu.log(string.format('팩 버전 %d · 글리프 %d 자 · ADPCM 조각 %d',
                        P.version, P.glyph_count, P.adpcm_count))
  -- 팩이 가진 지문을 미리 알려준다 -- 어느 장면으로 가야 하는지 알 수 있게
  local listed = {}
  for i = 0, P.adpcm_count - 1 do
    local at = P.adpcm_off + i * P.adpcm_stride
    local key = string.format('sec %06X len %04X', u24(at), u16(at + 3))
    if not listed[key] then
      listed[key] = true
      emu.log(string.format('  팩에 있는 열쇠  %s  "%s"', key,
                            read_record(u32(at + 8)).text))
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

  cdda_tick(s)

  if playing and not was_playing then
    local ending = (((s['cdrom.adpcm.readAddress'] or 0)
                   + (s['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    -- 0.1.9: 재는 것이 먼저다.  아래 자막 로직은 그대로 둔다.
    -- 지문은 재생이 막 시작된 이 프레임의 RAM 으로 접어야 한다 -- 한 프레임만
    -- 늦어도 다음 음성이 덮어쓸 수 있다.
    local fp = voice_fingerprint(s['cdrom.adpcm.readAddress'] or 0,
                                 s['cdrom.adpcm.adpcmLength'] or 0)
    record_key(s, ending, fp)
    -- 0.1.10: 열쇠는 (sector, 길이).  sector 는 실수로 올 수 있어 내림한다
    -- (%X 는 소수부가 있는 수를 받으면 죽는다).
    local sector = math.floor(s['cdrom.scsi.sector'] or 0)
    local length = math.floor(s['cdrom.adpcm.adpcmLength'] or 0)
    local found = find_parts(sector, length)
    if #found == 0 then
      skipped = skipped + 1                -- 자막이 없다 = 효과음이거나 아직 번역 전
      local key = string.format('sec %06X len %04X  (끝 %04X)', sector, length, ending)
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
      say(string.format('[%d] sec %06X len %04X  조각 %d개  y=%d  "%s"',
            frames, sector, length, #found, record.y, record.text))
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
      say(string.format('    +%df  조각 %d  y=%d  "%s"', elapsed, want, record.y, record.text))
    end
  elseif not playing and was_playing then
    if armed then
      disarm()
      say(string.format('    음성 끝 -- VRAM %d 워드 되돌림', VRAM_WORDS))
    end
    parts = nil
  end
  was_playing = playing

  -- 잔류 제거.  지문이 아니라 **이번 프레임에 실제로 밀었는지**로 판단한다.
  -- 밀었으면: 자리를 아직 모를 때 여기서 정한다.
  -- 안 밀었으면: 지난 프레임의 우리 엔트리가 남아 있으므로 지운다.
  if pushed_this_frame then
    if not satb_decided then decide_satb() end
  elseif armed or satb ~= nil then
    clear_ours()
  end
  pushed_this_frame = false

  if frames % 3600 == 0 then
    say(string.format('--- %d --- 띄움 %d · 자막 없어 넘김 %d · 푸시 %d · 잔류지움 %d',
          frames, shown, skipped, push_hits, cleared_total))
    flush()
  end
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  key_report()
  say('')
  say(string.format('== 잔류 백스톱 == 푸시 %d 회 · 우리 엔트리 지움 %d 회',
        push_hits, cleared_total))
  if push_hits == 0 then
    say('  ★ 푸시가 0 이다.  엔진이 $5C06 을 안 지났다 -- 엔진을 다시 구웠으면')
    say('     JSR $6463 자리가 바뀌었을 수 있다 (ENGINE_PUSH_AT 확인)')
  elseif not satb_decided then
    say('  ★ 밀었는데도 SATB 후보 어디에도 우리 엔트리가 안 보였다 -- 자리를 다시 재야 한다')
  end
  flush()
end, emu.eventType.scriptEnded)

emu.log('PROBE_SUB_PACK 0.1.10 loaded  --  열쇠 (sector, 길이) · 측정 · 잔류 백스톱')
emu.log('  ★ 측정 결과는 Stop 을 눌러야 나온다 (scriptEnded 에서 표를 낸다)')
emu.log('  ' .. KEYPATH)
if ADPCMT == nil then
  emu.log('  ★ ADPCM 메모리 타입이 없다 -- 지문을 못 접는다.  측정이 안 된다')
end
emu.log('  ★ build/patch/subtitle_resident/ 의 디스크로 켤 것')
emu.log('  팩에 지문이 있는 대사에만 자막이 뜬다 -- 효과음은 저절로 걸러진다')
emu.log(string.format('  한 줄 최대 %d 자 · VRAM $%04X-$%04X 를 빌렸다 되돌린다',
                      MAX_GLYPHS, PAT_VRAM, PAT_VRAM + VRAM_WORDS - 1))
