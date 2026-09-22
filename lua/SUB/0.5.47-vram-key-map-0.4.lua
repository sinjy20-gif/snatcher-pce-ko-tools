-- SUB VRAM-key-map 0.4 -- ADPCM 키/CD-DA 조각마다 재생 중 비어 있던 자리를 찾는다
--
-- ===========================================================================
-- 0.4 (2026-08-31) -- 조용히 버리던 것을 없앤다
-- ===========================================================================
--
-- 0.3 이 무엇을 잃고 있었나
-- ------------------------
-- `actualAdpcmVoice` 가 **매 프레임** 6 B 키를 새로 계산하고, 마스터에 없으면
-- `nil` 을 돌려줬다.  상위에서는 그것이 "음성이 안 나오는 중" 과 구별이 안 된다.
-- 로그도 행도 안 남고 **대사 하나가 통째로 사라진다.**
--
-- 그 키가 깨지기 쉬웠다:
--
--     finish = readAddress + adpcmLength   두 필드를 따로 읽는다 -> 찢어진다
--     샘플 3 B 를 ADPCM RAM 에서 읽는다     스트리밍 링버퍼라 시점마다 다르다
--
-- 실측(2026-08-31): 덤프에 남은 고유 키 477 중 **205 (43%) 가 마스터와 불일치**
-- 였다.  그리고 그 205 는 그나마 기록이라도 된 것이다 -- 필터에 걸린 것은 흔적
-- 조차 없다.  접수처 연속 대사 12 줄 중 11 줄이 이렇게 사라진 것이 확인됐다.
--
-- 0.4 가 바꾼 것 -- 셋
-- -------------------
--   1  신원을 **재생 시작 순간 한 번만** 정하고 끝까지 붙든다 (adpcmLatch).
--      프레임마다 다시 재지 않으니 중간에 찢어져도 신원이 안 흔들린다.
--
--   2  키를 **마스터와 같은 형식**으로 만든다.  `sector + end + rate` 는 마스터
--      1,055 행에서 중복 0 이다 (sector 만으로는 8 건 겹친다).
--
--          ADPCM_00378A_3800_0E
--                ^^^^^^ sector  ^^^^ end  ^^ rate
--
--      옛 12 B 런타임 키도 `runtime_key` 열에 같이 적는다 -- 지금까지 모은
--      272 키와 이어붙일 다리다.  옛 덤프를 버리지 않아도 된다.
--
--   3  **마스터에 없어도 안 버린다.**  `matched=no` 로 적고 그대로 기록한다.
--      살릴 수 있고, 무엇보다 얼마나 놓치는지가 화면에 보인다.
--
-- 출력 이름이 다르다 (map3 / spans3).  옛 덤프에 섞으면 키 형식이 두 가지인
-- 파일이 되어 mark_vram_observed 가 헷갈린다.
--
-- CD-DA 경로는 한 줄도 안 건드렸다 -- 그쪽은 잘 돌고 있다.
--
-- ===========================================================================
-- 아래는 0.3 원문 (그대로 보존)
-- ===========================================================================
--
-- SUB VRAM-key-map 0.3 -- ADPCM 키/CD-DA 조각마다 재생 중 비어 있던 자리를 찾는다
--
-- ══ 0.1 의 결함 네 가지를 고친 판 (2026-08-29) ═══════════════════════════
--
-- 0.1 로 잰 표를 그대로 박았더니 자막이 깨졌다.  자리 선택 문제가 아니라
-- **측정이 자유 공간을 실제보다 넓게 봤다.**  코드에서 확인한 원인 넷:
--
--   1  BAT 본체를 점유로 안 쳤다
--      scanBat 이 BAT 가 **가리키는 타일**만 표시하고, BAT 표 자체(word 0 부터)는
--      건드리지 않았다.  그래서 $0000-$0FFF 가 늘 "자유" 로 나왔다.
--      거기 글리프를 쓰면 타일맵이 통째로 망가진다.
--
--   2  BAT 스캔을 4096 엔트리에서 잘랐다
--          local entries = math.min(columns * rows, 0x1000)
--      화면이 128x64 면 8192 엔트리다.  절반이 안 훑히고, 그 절반이 가리키던
--      BG 패턴이 자유로 나온다.  국장실에서 타일맵 윗부분이 튀어나온 원인으로
--      가장 유력하다.
--
--   3  SATB 주소를 word $1000 으로 하드코딩했다
--      PCE 는 SATB 원본 주소를 DVSSR(레지스터 $13)로 정한다.  고정이 아니다.
--      주소가 다르면 SAT 를 엉뚱한 데서 읽고, SATB 본체 256 word 도 안 지킨다.
--
--   4  BAT 를 10 프레임에 한 번만 봤다
--      장면이 바뀌면 최대 10 프레임 동안 옛 BG 참조로 판단한다.
--
-- ══ 같이 고친 것 -- 속도 ═════════════════════════════════════════════════
--
-- 위 2·4 를 고치면 BAT 를 매 프레임 8192 엔트리 x 16 word = 13 만 번 표시하게
-- 된다.  Lua 로는 못 쓴다.  그래서 **모으는 단위를 올렸다**:
--
--     CPU 쓰기 / DMA   word 단위 그대로 (이미 정확하다)
--     BG 패턴          tile 단위로 모아 끝에서 x16 으로 펼친다
--     스프라이트 패턴   32 word 유닛 단위로 모아 끝에서 x32 로 펼친다
--
-- 프레임당 8192 + 1024 회면 감당된다.  결과는 word 단위로 같다.
--
-- ══ 무엇을 점유로 치나 ═══════════════════════════════════════════════════
--
--     BAT 본체            word 0 .. columns*rows-1        ★ 새로 추가
--     BG 패턴             BAT 각 엔트리가 가리키는 16 word
--     SATB 본체           DVSSR .. DVSSR+255              ★ 새로 추가
--     스프라이트 패턴      SAT 각 슬롯의 pattern/size
--     CPU 워드 쓰기        VDC 포트 재구성
--     VRAM-VRAM DMA       DESR/LENR 재구성
--
-- ══ 반드시 자막 엔진 없이 돌릴 것 ════════════════════════════════════════
--
-- 우리 글리프가 올라가면 그 자리가 "사용 중" 으로 기록되어 관측이 오염된다.
-- 0.4.31 / 0.4.57~0.4.64 계열을 같이 올리지 말 것.  이 파일 하나만 실행한다.
-- 아무것도 쓰지 않는 읽기 전용이다.
--
-- ══ 계측기 자체 검증 ═════════════════════════════════════════════════════
--
-- Mesen 은 pceVideoRam 에 write 콜백을 주지 않는다.  그래서 VDC 포트를 훅해
-- MAWR 로 주소를 재구성한다.  재구성이 맞는지 실제 VRAM 과 대조해 일치율을
-- 화면에 띄운다.  ★CHECK 가 뜨면 그 실행은 버린다.
--
-- 화면에 BAT/SATB 실측값도 같이 띄운다.  0.1 이 가정했던 64x64 / $1000 과
-- 다르면 그 자체가 이번 수정이 필요했다는 증거다.
--
--     dump/vram_key_map2_<시각>.tsv       ADPCM 키별 후보 base
--     dump/vram_key_spans2_<시각>.tsv     ADPCM 키별 자유 구간 원자료
--     dump/cdda_vram_map_<시각>.tsv       CD-DA 자막 조각별 후보 base
--     dump/cdda_vram_spans_<시각>.tsv     CD-DA 자막 조각별 자유 구간 원자료
--
-- 표를 만들 때:  python tools/build_vram_key_bases.py --spans <위 spans2 파일>

-- `0.5.24-subtitle-vram-map.lua`가 이 값을 켜면 ADPCM은 팩에 실제로 등록된
-- 자막 음성만 기록한다. CD-DA는 cdda_segments.tsv의 자막 조각만 기록한다.
local ONLY_SUBTITLE_KEYS = rawget(_G, 'SUB_VRAM_MAP_ONLY_SUBTITLES') == true
-- 자막별 출하 지도에서는 true: 짧게 나타났다 사라지는 BAT 항목도 남긴다.
-- 수집 중 성능보다 음성 전체 점유의 합집합 정확도가 우선이다.
local STRICT_BAT = rawget(_G, 'SUB_VRAM_MAP_STRICT_BAT') == true
-- RUN_2처럼 실제 플레이와 함께 돌릴 때는 화면 위 상태표가 시야를 가린다.
-- 수집·검증·파일 출력은 그대로 두고 HUD 그리기만 선택적으로 끈다.
local HIDE_HUD = rawget(_G, 'SUB_VRAM_MAP_HIDE_HUD') == true
-- 팩(902) 대신 **음성 마스터 전체**(고유 1,024키)를 필터로 쓴다.
--
-- 왜 필터를 아예 끄지 않는가:  actualAdpcmVoice 의 키는 재생 중 매 프레임 다시
-- 계산되고, finish 가 흔들린 프레임에서는 실재하지 않는 키가 나온다.  필터를 끄면
-- 그 찢어진 키가 그대로 기록된다 -- 2026-08-29 주행이 192키 중 142키를 그렇게
-- 버렸다.  08-30 주행이 100% 깨끗한 것은 표본이 나아져서가 아니라 팩 필터가
-- 찢어진 키를 걸러냈기 때문이다.
--
-- 그래서 "끄는" 대신 **넓힌다.**  마스터는 실제 주행으로 모은 1,024키라 진짜 음성은
-- 다 들어 있고 찢어진 키는 들어 있지 않다.  has_subtitle=0 인 152행(전부
-- status=ambiguous_audio -- 효과음 확정이 아니라 분류 보류)도 이때 같이 잡힌다.
local ALL_VOICE_KEYS = rawget(_G, 'SUB_VRAM_MAP_ALL_VOICE_KEYS') == true
local VOICE_MASTER = 'C:/snatcher/snatcher_tool/translation/voice_console_keys.tsv'
local SUBTITLE_PACK = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local CDDA_SEGMENTS = 'C:/snatcher/build/cutscene_subs/cdda_segments.tsv'

local VRAM = emu.memType.pceVideoRam
local MEM = emu.memType.pceMemory
local APCM = emu.memType.pceAdpcmRam
local CPU = emu.cpuType.pce

local VDC_LO, VDC_HI = 0x0000, 0x03FF
local VRAM_WORDS = 0x8000
local NEED_WORDS = 19 * 0x40          -- 0x4C0
local ALIGN = 0x20                    -- 스프라이트 패턴 base 는 32 word 배수
local VOICE_RATE = 0x0E
local CDDA_STOP_GRACE_FRAMES = 12

local VERIFY_EVERY = 60

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/vram_key_map3_' .. stamp .. '.tsv'
local SPANS = 'C:/snatcher/dump/vram_key_spans3_' .. stamp .. '.tsv'
local CDDA_OUT = 'C:/snatcher/dump/cdda_vram_map_' .. stamp .. '.tsv'
local CDDA_SPANS = 'C:/snatcher/dump/cdda_vram_spans_' .. stamp .. '.tsv'

local out = assert(io.open(OUT, 'w'))
out:write('key\taudio_type\tframes\tmarked\tfree_spans\tbase_count\tfirst_base\tbases\truntime_key\tmatched\n')
out:flush()

local spansOut = assert(io.open(SPANS, 'w'))
spansOut:write('key\taudio_type\tfirst\tlast\twords\truntime_key\tmatched\n')
spansOut:flush()

-- CD-DA는 ADPCM 키 표에 섞지 않는다. 나중에 Studio의 트랙/part 시각과
-- cdda_segments 조각을 교차해 안전 위치를 합성한다.
local cddaOut = assert(io.open(CDDA_OUT, 'w'))
cddaOut:write('key\ttrack\tclip\tlba_from\tlba_to\tframes\tmarked\tfree_spans\tbase_count\tfirst_base\tbases\n')
cddaOut:flush()

local cddaSpansOut = assert(io.open(CDDA_SPANS, 'w'))
cddaSpansOut:write('key\ttrack\tclip\tlba_from\tlba_to\tfirst\tlast\twords\n')
cddaSpansOut:flush()

local frame = 0
local closed = false

-- VDC 디코더
local selReg, mawr, dataLo = 0, 0, 0
local desr, lenr = 0, 0
local mwrReg = nil                    -- 레지스터 $09.  BAT 크기를 정한다
local dvssr = nil                     -- 레지스터 $13.  SATB 원본 주소
local portHits = 0
local cpuWords, dmaWords = 0, 0

-- 현재 음성.  세 종류를 따로 모아 끝에서 word 로 펼친다.
local curKey, curType, curFrames, curVoice = nil, nil, 0, nil
local wordMark = {}                   -- CPU 쓰기 · DMA (word)
local tileMark = {}                   -- BG 패턴 (tile = 16 word)
local unitMark = {}                   -- 스프라이트 패턴 (unit = 32 word)
local batWords = 0                    -- 이 음성 동안 본 BAT 본체 최대 크기
local satbSeen = {}                   -- 이 음성 동안 본 SATB 주소들

local seenKeys, keyCount = {}, 0
local rowCount = 0

-- 디코더 대조
local shadow, shadowCount = {}, 0
local verifySamples, verifyOk = 0, 0

local installed = false

local function rb(at) return emu.read(at, VRAM) or 0 end
local function rw(w)
  local at = w * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function noteWord(w)
  if curKey == nil then return end
  wordMark[w] = true
end

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  portHits = portHits + 1

  if port == 0 then
    selReg = value
  elseif port == 2 then
    dataLo = value
    if selReg == 0x00 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x09 then mwrReg = value              -- ★ MWR
    elseif selReg == 0x11 then desr = (desr & 0xFF00) | value
    elseif selReg == 0x12 then lenr = (lenr & 0xFF00) | value
    elseif selReg == 0x13 then dvssr = ((dvssr or 0) & 0xFF00) | value  -- ★ DVSSR
    end
  elseif port == 3 then
    if selReg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 0x02 then
      local w = mawr & 0x7FFF
      noteWord(w)
      cpuWords = cpuWords + 1
      if shadowCount < 64 then
        if shadow[w] == nil then shadowCount = shadowCount + 1 end
        shadow[w] = dataLo | (value << 8)
      elseif shadow[w] ~= nil then
        shadow[w] = dataLo | (value << 8)
      end
      mawr = (mawr + 1) & 0xFFFF
    elseif selReg == 0x11 then
      desr = (desr & 0x00FF) | (value << 8)
    elseif selReg == 0x12 then
      lenr = (lenr & 0x00FF) | (value << 8)
      local count = lenr + 1
      dmaWords = dmaWords + count
      local dst = desr & 0x7FFF
      for i = 0, count - 1 do noteWord((dst + i) & 0x7FFF) end
    elseif selReg == 0x13 then
      dvssr = ((dvssr or 0) & 0x00FF) | (value << 8)
    end
  end
end

installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write,
                        VDC_LO, VDC_HI, CPU, MEM)
end)

local function number(state, name)
  local v = state[name]
  return type(v) == 'number' and math.floor(v) or 0
end

local function hex(s)
  return (s:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

-- 선택: 팩에 있는 실제 자막 키만 수집한다. 호스트 파일 읽기만 하며
-- 엔진/AC/VDC에는 전혀 쓰지 않는다. v6 index의 첫 6 B는 ADPCM 키다.
local subtitleKeys, subtitleKeyCount = nil, 0
local keySourceName = nil
if ALL_VOICE_KEYS then
  -- 음성 마스터의 runtime_key_hex 열.  '00 F0 0E AB 8D A9' 처럼 공백이 끼어 있다.
  local f = assert(io.open(VOICE_MASTER, 'rb'),
                   '음성 마스터를 열 수 없다: ' .. VOICE_MASTER)
  local text = f:read('*a'); f:close()
  text = text:gsub('^\239\187\191', '')            -- UTF-8 BOM
  local column = nil
  subtitleKeys = {}
  for line in text:gmatch('[^\r\n]+') do
    local cells, n = {}, 0
    for cell in (line .. '\t'):gmatch('([^\t]*)\t') do
      n = n + 1; cells[n] = cell
    end
    if column == nil then
      for i = 1, n do
        if cells[i] == 'runtime_key_hex' then column = i end
      end
      assert(column, 'runtime_key_hex 열이 없다: ' .. VOICE_MASTER)
    else
      local key = (cells[column] or ''):gsub('%s', ''):upper()
      if #key == 12 and not subtitleKeys[key] then
        subtitleKeys[key] = true
        subtitleKeyCount = subtitleKeyCount + 1
      end
    end
  end
  assert(subtitleKeyCount > 0, '음성 마스터에서 키를 하나도 못 읽었다')
  keySourceName = '음성 마스터 전체'
elseif ONLY_SUBTITLE_KEYS then
  local f = assert(io.open(SUBTITLE_PACK, 'rb'),
                   'subtitle pack을 열 수 없다: ' .. SUBTITLE_PACK)
  local pack = f:read('*a'); f:close()
  local function u16(at)
    return pack:byte(at + 1) | (pack:byte(at + 2) << 8)
  end
  local function u32(at)
    return u16(at) | (u16(at + 2) << 16)
  end
  assert(pack:sub(1, 4) == 'SNSB' and u16(4) == 6,
         'SNSB v6 subtitle pack이 아니다')
  subtitleKeys = {}
  local count, indexAt = u16(14), u32(16)
  for n = 0, count - 1 do
    local key = hex(pack:sub(indexAt + n * 13 + 1, indexAt + n * 13 + 6))
    if not subtitleKeys[key] then
      subtitleKeys[key] = true
      subtitleKeyCount = subtitleKeyCount + 1
    end
  end
end

-- 0.4: 마스터 키 이름(`key` 열) 을 따로 읽는다.  `ADPCM_00378A_3800_0E` 형식이고
-- sector+end+rate 라 1,055 행에서 중복이 0 이다.  이것이 신원 판정의 기준이다.
-- 못 읽어도 죽지 않는다 -- masterKeys 가 nil 이면 전부 matched 로 친다 (안 버린다).
local masterKeys, masterKeyCount = nil, 0
do
  local f = io.open(VOICE_MASTER, 'rb')
  if f ~= nil then
    local text = f:read('*a'); f:close()
    text = text:gsub('^\239\187\191', '')            -- UTF-8 BOM
    local column = nil
    masterKeys = {}
    for line in text:gmatch('[^\r\n]+') do
      local cells, n = {}, 0
      for cell in (line .. '\t'):gmatch('([^\t]*)\t') do
        n = n + 1; cells[n] = cell
      end
      if column == nil then
        for i = 1, n do if cells[i] == 'key' then column = i end end
      else
        local key = (cells[column] or ''):gsub('%s', ''):upper()
        if #key > 0 and not masterKeys[key] then
          masterKeys[key] = true
          masterKeyCount = masterKeyCount + 1
        end
      end
    end
    if masterKeyCount == 0 then masterKeys = nil end
  end
end
-- CD-DA는 트랙 전체가 아니라 전사/자막 조각의 절대 LBA 범위로 센다.
-- 트랙 하나가 수 분이고 화면도 계속 바뀌므로 트랙 전체 교집합은 지나치게
-- 보수적이다. 조각별 원자료를 모아 두면 Studio에서 더 긴 part를 만들 때
-- 해당 조각들의 교집합으로 안전 위치를 계산할 수 있다.
local cddaSegments = {}
do
  local f = assert(io.open(CDDA_SEGMENTS, 'rb'),
                   'CD-DA 구간 표를 열 수 없다: ' .. CDDA_SEGMENTS)
  local text = f:read('*a'); f:close()
  text = text:gsub('^\239\187\191', '')
  local header = nil
  for line in text:gmatch('[^\r\n]+') do
    local fields = {}
    for value in (line .. '\t'):gmatch('([^\t]*)\t') do
      fields[#fields + 1] = value
    end
    if header == nil then
      header = {}
      for i, name in ipairs(fields) do header[name] = i end
      for _, need in ipairs({'clip', 'track', 'lba_from', 'lba_to'}) do
        assert(header[need], 'CD-DA 구간 표 열이 없다: ' .. need)
      end
    else
      local a = tonumber(fields[header.lba_from])
      local b = tonumber(fields[header.lba_to])
      local clip = fields[header.clip] or ''
      if a and b and b > a and clip ~= '' then
        cddaSegments[#cddaSegments + 1] = {
          id = clip:gsub('%.wav$', ''),
          audioType = 'CDDA',
          track = fields[header.track] or '',
          clip = clip,
          a = a,
          b = b,
        }
      end
    end
  end
  table.sort(cddaSegments, function(x, y)
    if x.a ~= y.a then return x.a < y.a end
    return x.b < y.b
  end)
  assert(#cddaSegments > 0, 'CD-DA 구간 표가 비었다')
end

-- 0.4.31 의 actualVoice 와 같은 계산이어야 팩 키와 맞는다.
-- 0.4: 재생 한 번 = 신원 하나.  latch 에 물려 두고 프레임마다 다시 재지 않는다.
-- 0.3 은 매 프레임 새로 계산해서, 한 번이라도 찢어지면 그 대사가 통째로 없어졌다.
local adpcmLatch = nil
local adpcmMissed, adpcmOffRate = 0, 0

local function actualAdpcmVoice()
  local ok, state = pcall(emu.getState)
  if not ok or not state or state['cdrom.adpcm.playing'] ~= true then
    adpcmLatch = nil                    -- 재생이 끝났다.  다음 것은 새로 잰다
    return nil
  end
  if adpcmLatch ~= nil then return adpcmLatch end   -- 이미 정해진 신원을 붙든다

  local rate = number(state, 'cdrom.adpcm.playbackRate') & 0xFF
  if rate ~= VOICE_RATE then
    -- 음성이 아닌 ADPCM (효과음 등).  0.3 과 같이 제외하지만 세기는 한다 --
    -- "왜 이 구간이 안 잡히지" 를 다음에는 숫자로 확인할 수 있게.
    adpcmOffRate = adpcmOffRate + 1
    adpcmLatch = nil
    return nil
  end

  local finish = (number(state, 'cdrom.adpcm.readAddress') +
                  number(state, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
  local sector = number(state, 'cdrom.scsi.sector') & 0xFFFFFF
  -- 마스터와 같은 형식.  sector 가 들어가서 끝 주소만 쓸 때의 뭉침이 풀린다.
  local id = string.format('ADPCM_%06X_%04X_%02X', sector, finish, rate)

  -- 옛 12 B 키.  0.3 과 같은 계산이라 지금까지 모은 272 키와 이어붙는 다리다.
  -- 신원으로는 안 쓴다 -- 적어만 둔다.
  -- 표본 자리는 이대로 **고정**한다 (build_voice_console_keys.py 와 같아야 한다).
  -- 옮겨서 충돌을 줄이려는 시도는 2026-09-02 에 실패했다 -- 버퍼 앞쪽 자리는
  -- 클립 범위 밖이라 산출이 1,211 -> 1,022 로 줄어든다.  그쪽 주석 참고.
  local a1, a2, a3 = finish // 4, finish // 2, (finish * 5) // 8
  local runtime = hex(string.char(finish & 0xFF, finish >> 8, rate,
                                  emu.read(a1, APCM) or 0,
                                  emu.read(a2, APCM) or 0,
                                  emu.read(a3, APCM) or 0))

  local matched = (masterKeys == nil) or (masterKeys[id] == true)
  if not matched then
    -- ★ 여기서 버리지 않는다.  이것이 0.4 의 존재 이유다.
    adpcmMissed = adpcmMissed + 1
    emu.log(string.format(
      'VRAM-key-map 0.4 ! 마스터에 없는 키 %s (runtime %s) -- 버리지 않고 기록한다',
      id, runtime))
  end

  adpcmLatch = { id = id, audioType = 'ADPCM', runtimeKey = runtime, matched = matched }
  return adpcmLatch
end

-- 절대 sector를 포함하는 조각을 이분 탐색한다. lba_to는 다음 조각의
-- lba_from과 같은 경우가 많아서 [from,to) 반열린 구간으로 취급한다.
local function cddaSegmentAt(sector)
  local lo, hi = 1, #cddaSegments
  while lo <= hi do
    local mid = (lo + hi) // 2
    local seg = cddaSegments[mid]
    if sector < seg.a then
      hi = mid - 1
    elseif sector >= seg.b then
      lo = mid + 1
    else
      return seg
    end
  end
  return nil
end

-- CD-DA는 ADPCM RAM state가 아니라 audioPlayer sector가 전진한다. 멈춘
-- sector 값이 state에 남을 수 있으므로 12 frame 동안 전진이 없으면 종료한다.
local cddaPreviousSector, cddaLastAdvanceFrame = nil, nil
local function actualCddaVoice(state)
  local sector = state and state['cdrom.audioPlayer.currentSector']
  if type(sector) ~= 'number' then
    cddaPreviousSector = nil
    return nil
  end
  sector = math.floor(sector)
  if cddaPreviousSector == nil then
    cddaPreviousSector = sector
    return nil
  end
  if sector ~= cddaPreviousSector then
    cddaLastAdvanceFrame = frame
  end
  cddaPreviousSector = sector
  if cddaLastAdvanceFrame == nil or
      frame - cddaLastAdvanceFrame >= CDDA_STOP_GRACE_FRAMES then
    return nil
  end
  return cddaSegmentAt(sector)
end

local function actualVoice()
  local adpcm = actualAdpcmVoice()
  if adpcm then return adpcm end
  local ok, state = pcall(emu.getState)
  return actualCddaVoice(ok and state or nil)
end

local function saneDimension(v, fallback)
  v = tonumber(v)
  if v == 32 or v == 64 or v == 128 then return v end
  return fallback
end

-- ★ MWR($09) 이 BAT 크기의 1차 근거다.  Mesen state 는 보조다.
--     bits 5-4  화면 폭   00=32  01=64  10/11=128
--     bit  6    화면 높이  0=32   1=64
local function dimensions()
  if mwrReg then
    local w = (mwrReg >> 4) & 0x03
    local columns = (w == 0) and 32 or (w == 1) and 64 or 128
    local rows = ((mwrReg >> 6) & 1) == 1 and 64 or 32
    return columns, rows
  end
  local ok, state = pcall(emu.getState)
  if not ok or not state then return 64, 64 end
  return saneDimension(state['vdc.hvReg.columnCount'], 64),
         saneDimension(state['vdc.hvReg.rowCount'], 64)
end

-- SATB 주소.  DVSSR 을 못 봤으면 옛 가정($1000)으로 떨어지되 화면에 알린다.
local function satbAddress()
  if dvssr then return dvssr & 0x7FFF end
  local ok, state = pcall(emu.getState)
  if ok and state then
    local v = state['vdc.satbAddress'] or state['vdc.dvssr']
    if type(v) == 'number' then return math.floor(v) & 0x7FFF end
  end
  return 0x1000
end

local function scanSatb()
  if curKey == nil then return end
  local satb = satbAddress()
  satbSeen[satb] = true
  for slot = 0, 63 do
    local at = satb + slot * 4
    local y = rw(at)
    local x = rw(at + 1)
    local pattern = rw(at + 2)
    local attr = rw(at + 3)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local wide = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local tall = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local base = (pattern & 0x07FF) << 5
      local units = wide * tall * 2          -- 0x40 word = 2 유닛
      for i = 0, units - 1 do
        unitMark[((base >> 5) + i) & 0x3FF] = true
      end
    end
  end
end

-- ★ 상한 없음.  그리고 BAT 본체 크기를 기록해 둔다 (끝에서 점유로 편다).
--
-- 비용 조절: 8192 엔트리를 매 프레임 다 읽으면 emu.read 가 프레임당 1.6 만 회라
-- FPS 가 죽는다.  음성 첫 프레임에는 전부 훑고(초기 상태를 놓치면 안 된다),
-- 그 뒤에는 BAT_SLICE 분할로 돌아가며 훑는다.  음성 하나가 보통 100~500 프레임
-- 이므로 몇 프레임이면 한 바퀴 돈다.
local BAT_SLICE = 4

local function scanBat(full)
  if curKey == nil then return end
  local columns, rows = dimensions()
  local entries = columns * rows
  if entries > VRAM_WORDS then entries = VRAM_WORDS end
  if entries > batWords then batWords = entries end
  if full then
    for i = 0, entries - 1 do
      tileMark[rw(i) & 0x07FF] = true
    end
  else
    local part = frame % BAT_SLICE
    local step = (entries + BAT_SLICE - 1) // BAT_SLICE
    local from = part * step
    local to = math.min(from + step, entries) - 1
    for i = from, to do
      tileMark[rw(i) & 0x07FF] = true
    end
  end
end

local function verifyDecoder()
  for w, v in pairs(shadow) do
    verifySamples = verifySamples + 1
    if rw(w) == v then verifyOk = verifyOk + 1 end
  end
  shadow, shadowCount = {}, 0
end

-- 모아 둔 세 단위를 word 점유로 펼친다.
local function buildOccupancy()
  local used = {}
  local n = 0
  local function put(w)
    if w >= 0 and w < VRAM_WORDS and used[w] == nil then
      used[w] = true
      n = n + 1
    end
  end
  for w in pairs(wordMark) do put(w) end
  for t in pairs(tileMark) do
    local base = t * 0x10
    for k = 0, 15 do put(base + k) end
  end
  for u in pairs(unitMark) do
    local base = u * 0x20
    for k = 0, 31 do put(base + k) end
  end
  for i = 0, batWords - 1 do put(i) end                 -- ★ BAT 본체
  for satb in pairs(satbSeen) do
    for k = 0, 255 do put(satb + k) end                 -- ★ SATB 본체
  end
  return used, n
end

-- 음성이 끝났다.  누적 점유에서 자유 구간과 후보 base 를 뽑아 기록한다.
local function finishVoice()
  if curKey == nil then return end

  local used, curMarked = buildOccupancy()

  local spans, spanN = {}, 0
  local runStart = nil
  for w = 0, VRAM_WORDS do
    local free = (w < VRAM_WORDS) and (used[w] == nil) or false
    if free then
      if runStart == nil then runStart = w end
    elseif runStart ~= nil then
      spanN = spanN + 1
      spans[spanN] = { runStart, w - 1 }
      runStart = nil
    end
  end

  local bases, baseN = {}, 0
  for i = 1, spanN do
    local f, l = spans[i][1], spans[i][2]
    local b = ((f + ALIGN - 1) // ALIGN) * ALIGN
    while b + NEED_WORDS - 1 <= l do
      baseN = baseN + 1
      bases[baseN] = b
      b = b + ALIGN
    end
  end

  local list, listN = {}, 0
  for i = 1, math.min(baseN, 24) do
    listN = listN + 1
    list[listN] = string.format('%04X', bases[i])
  end

  if curType == 'CDDA' then
    cddaOut:write(string.format('%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n',
      curKey, curVoice.track, curVoice.clip, curVoice.a, curVoice.b,
      curFrames, curMarked, spanN, baseN,
      baseN > 0 and string.format('%04X', bases[1]) or '-',
      table.concat(list, ',')))
    cddaOut:flush()
  else
    out:write(string.format('%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n',
      curKey, curType, curFrames, curMarked, spanN, baseN,
      baseN > 0 and string.format('%04X', bases[1]) or '-',
      table.concat(list, ','),
      curVoice and curVoice.runtimeKey or '',
      (curVoice == nil or curVoice.matched ~= false) and 'yes' or 'no'))
    out:flush()
  end

  for i = 1, spanN do
    local f, l = spans[i][1], spans[i][2]
    if l - f + 1 >= ALIGN then
      if curType == 'CDDA' then
        cddaSpansOut:write(string.format('%s\t%s\t%s\t%d\t%d\t%04X\t%04X\t%d\n',
          curKey, curVoice.track, curVoice.clip, curVoice.a, curVoice.b,
          f, l, l - f + 1))
      else
        spansOut:write(string.format('%s\t%s\t%04X\t%04X\t%d\t%s\t%s\n',
          curKey, curType, f, l, l - f + 1,
          curVoice and curVoice.runtimeKey or '',
          (curVoice == nil or curVoice.matched ~= false) and 'yes' or 'no'))
      end
    end
  end
  if curType == 'CDDA' then cddaSpansOut:flush() else spansOut:flush() end

  rowCount = rowCount + 1
  if baseN == 0 then
    emu.log(string.format('VRAM-key-map2 ★ %s : 자유 base 0 개 (%d 프레임 · 점유 %d word)',
                          curKey, curFrames, curMarked))
  end

  curKey, curType, curFrames, curVoice = nil, nil, 0, nil
  wordMark, tileMark, unitMark = {}, {}, {}
  batWords, satbSeen = 0, {}
end

emu.addEventCallback(function()
  frame = frame + 1

  local voice = actualVoice()
  local key = voice and voice.id or nil

  if key ~= curKey then
    if curKey ~= nil then finishVoice() end
    if key ~= nil then
      curKey, curType, curFrames, curVoice = key, voice.audioType, 0, voice
      wordMark, tileMark, unitMark = {}, {}, {}
      batWords, satbSeen = 0, {}
      if not seenKeys[key] then
        seenKeys[key] = true
        keyCount = keyCount + 1
      end
      -- 시작 프레임의 화면 상태도 점유로 친다.  여기서는 BAT 를 통째로 훑는다.
      scanSatb()
      scanBat(true)
    end
  end

  if curKey ~= nil then
    curFrames = curFrames + 1
    scanSatb()
    scanBat(STRICT_BAT)                -- strict면 매 프레임 전수 스캔
  end

  if frame % VERIFY_EVERY == 0 then verifyDecoder() end

  if HIDE_HUD then return end

  local rate = verifySamples > 0 and (verifyOk * 100 // verifySamples) or -1
  local trust = rate >= 90
  local columns, rows = dimensions()
  emu.drawString(4, 4, string.format('KEY-MAP3  키 %d  기록 %d  미등록 %d', keyCount, rowCount, adpcmMissed),
                 0xFFFFFF, 0x000000)
  emu.drawString(4, 14, string.format('decoder %s %d%% (%d)',
                 trust and 'OK' or '★CHECK', rate, verifySamples),
                 trust and 0x40FF40 or 0xFFA000, 0x000000)
  emu.drawString(4, 24, string.format('BAT %dx%d=%d  SATB $%04X%s',
                 columns, rows, columns * rows, satbAddress(),
                 dvssr and '' or ' (추정)'),
                 (mwrReg and dvssr) and 0x40FF40 or 0xFFA000, 0x000000)
  if curKey then
    emu.drawString(4, 34, string.format('%s %s  %df', curType, curKey, curFrames),
                   0x60D0FF, 0x000000)
  else
    emu.drawString(4, 34, string.format('cpu %d  dma %d  port %d',
                   cpuWords, dmaWords, portHits), 0x808080, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  if curKey ~= nil then finishVoice() end
  verifyDecoder()
  local rate = verifySamples > 0 and (verifyOk * 100 // verifySamples) or -1
  out:close()
  spansOut:close()
  cddaOut:close()
  cddaSpansOut:close()
  local columns, rows = dimensions()
  emu.log(string.format('VRAM-key-map 0.4 -- 마스터에 없던 키 %d 개 (버리지 않고 기록함) · rate≠$0E 로 건너뜀 %d',
                        adpcmMissed, adpcmOffRate))
  emu.log(string.format('VRAM-key-map3 끝 -- 프레임 %d · 고유 키 %d · 기록 %d',
                        frame, keyCount, rowCount))
  emu.log(string.format('  디코더 대조 %d 표본 중 %d 일치 (%d%%)',
                        verifySamples, verifyOk, rate))
  emu.log(string.format('  마지막 BAT %dx%d = %d word · SATB $%04X%s',
                        columns, rows, columns * rows, satbAddress(),
                        dvssr and '' or ' (DVSSR 못 봄 · $1000 가정)'))
  if not installed or verifySamples == 0 or rate < 90 then
    emu.log('  ★ 디코더를 믿을 수 없다.  이 결과를 근거로 쓰지 마라.')
  end
  emu.log('  map:   ' .. OUT)
  emu.log('  spans: ' .. SPANS)
  emu.log('  CDDA map:   ' .. CDDA_OUT)
  emu.log('  CDDA spans: ' .. CDDA_SPANS)
end, emu.eventType.scriptEnded)

emu.log('SUB VRAM-key-map 0.4 loaded -- ADPCM 키 + CD-DA 자막 조각 · 읽기 전용')
emu.log('  ★ 0.4: 신원을 재생 시작에 한 번만 정한다 (프레임마다 다시 안 잰다)')
emu.log('  ★ 0.4: 키가 마스터 형식이다 -- ADPCM_<sector>_<end>_<rate>')
emu.log('  ★ 0.4: 마스터에 없어도 버리지 않는다 -- matched=no 로 기록한다')
emu.log(string.format('  마스터 키 이름 %d 개 적재%s',
                      masterKeyCount,
                      masterKeys == nil and '  ← 0 개다! 전부 matched 로 기록한다' or ''))
emu.log('  BAT 본체 점유 · 스캔 상한 제거 · SATB 는 DVSSR · BAT 매 프레임')
emu.log(string.format('  ADPCM rate $%02X + CD-DA %d조각 · 창 %d word (19 셀) · 정렬 %d',
                      VOICE_RATE, #cddaSegments, NEED_WORDS, ALIGN))
emu.log('  ★ 자막 엔진(0.4.31/0.4.57~0.4.64)과 같이 올리지 말 것')
if subtitleKeys then
  emu.log(string.format('  ADPCM 키 필터 ON · %s의 %d키만 기록',
                        keySourceName or '팩', subtitleKeyCount))
else
  emu.log('  ★ ADPCM 키 필터 OFF · 찢어진 키까지 기록된다 (2026-08-29 주행 참고)')
end
emu.log('  CD-DA 필터 ON · cdda_segments.tsv의 조각만 기록 (트랙 전체로 묶지 않음)')
if STRICT_BAT then
  emu.log('  ★ STRICT BAT ON · 순간 UI도 음성 전체 점유에 누적한다')
end
emu.log('  installed: ' .. tostring(installed))
emu.log('  map:   ' .. OUT)
emu.log('  spans: ' .. SPANS)
emu.log('  CDDA map:   ' .. CDDA_OUT)
emu.log('  CDDA spans: ' .. CDDA_SPANS)
