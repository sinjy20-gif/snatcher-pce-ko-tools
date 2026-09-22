-- GFX 0.6.0 -- 헌정 화면의 **원본 그래픽 블록**을 통째로 뜬다  ★순수 관측 · 쓰기 0 B
--
-- 왜 이걸 재나 (2026-09-09)
-- ---------------------------------------------------------------------------
-- 주입(injection) 노선은 죽었다. tick 이 `$FC07` = **인터럽트 안**에서 도는데
-- 게임은 자기 루프에서 MAWR 을 잡고 워드를 흘린다. 그 사이에 끼어들어 MAWR 을
-- 옮기면 게임이 남은 워드를 엉뚱한 데 쏟는다. HuC6270 의 MAWR 은 쓰기 전용이라
-- 저장->복구도 안 된다. 그래서 **원본 데이터를 디스크에서 갈아끼우는** 쪽으로 간다.
--
-- 포맷은 정적으로 다 풀었다 (`docs/handoff/SNATCHER_GFX_ROUTE_C_2026-09-09.md`):
--
--     P[0]      플래그 + 표 길이 N       P[1..N] 니블 변환표
--     P[N+1..]  RLE 압축된 플레이너 4bpp
--     $7061     압축 해제 (명령 10 종)
--     $71C5     픽셀 단위 16색 재매핑
--
-- 못 찾은 건 **그 블록이 디스크 어디 있는가** 하나뿐이다. 논리 이미지 70 MB 를
-- 훑었지만 `A0 16` 앵커로는 ADPCM 잡음만 나왔다.
--
-- 그래서 이렇게 잡는다
-- ---------------------------------------------------------------------------
-- 그래픽 핸들러가 셋인데 ($6F60 기본 · $6FC8 종류$08 · $7019 종류$04) **전부**
-- `JSR $7061` 로 모인다. 그 한 곳만 걸면 다 잡힌다. 그 시점엔
--
--     $00/$01  P (소스 포인터, $8000-$DFFF 에 이미 뱅크 매핑됨)
--     $10      N (표 길이)          $16  헤더 원본
--     $12/$13  본문 시작            $14/$15  변환표
--
-- 이 다 세워져 있다. 그리고 `$3B00` 버퍼가 원본 지문과 맞는 순간 (= 헌정 화면이
-- 확실한 순간) 을 잡아 **그때 돌고 있던 블록**을 통째로 뜬다.
--
-- 뜬 바이트를 디스크에서 그대로 바이트 검색하면 위치가 확정된다 -- 추측이 0 이 된다.
--
-- 판정
--   ★ 지문 일치 + 블록 덤프 나옴  -> 디스크에서 찾아 제자리 치환으로 간다
--   히트는 있는데 지문이 안 뜸     -> 헌정이 이 경로가 아니다. hits.tsv 로 다시 짠다
--   히트가 0                       -> $7061 이 안 돈다. 오버레이 자체가 다르다
--
-- 쓰는 법  이것만 로드 · 부팅 -> **헌정 화면을 지나고** 조금 더 · Stop
--          ⚠ 다른 Lua 와 같이 올리지 말 것 (관측이 관측을 흔든다)
-- 산출물   C:/snatcher/dump/gfxsrc_0_6_0_<시각>_hits.tsv
--          C:/snatcher/dump/gfxsrc_0_6_0_<시각>_block<n>.bin      원본 블록
--          C:/snatcher/dump/gfxsrc_0_6_0_<시각>_buf<n>.bin        $3B00 128 B
--          C:/snatcher/dump/gfxsrc_0_6_0_<시각>_summary.txt

local DECOMP = 0x7061          -- 압축 해제 진입 (핸들러 셋이 여기로 모인다)
local BLIT80 = 0x71EE          -- 128 B 업로드
local BLIT20 = 0x7256          -- 32 B 업로드 (지문을 이걸로 쟀다)
local BUF    = 0x3B00
local WINDOW_END = 0xE000      -- 뱅크 창 끝. 여기까지만 읽는다
local DUMP_MAX   = 0x2000      -- 블록 한 개당 최대 8 KB
local MAX_DUMPS  = 6           -- 지문이 여러 번 떠도 이만큼만

-- $7061 자리 확인용 원본 바이트 (C2 B1 12 10 03 = CLY / LDA ($12),Y / BPL)
local IDENT = { 0xC2, 0xB1, 0x12, 0x10, 0x03 }
local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxsrc_0_6_0_' .. STAMP

local function say(m) emu.log(m); print(m) end

local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

local function rd16(a) return rd(a) + rd(a + 1) * 256 end

local function mprs()
  local ok, s = pcall(emu.getState)
  local t = {}
  for i = 0, 7 do
    t[i] = (ok and s) and (s['cpu.mpr[' .. i .. ']'] or s['mpr' .. i]
                           or s['memoryManager.mpr[' .. i .. ']']) or -1
  end
  return t
end

local function sigMatches()
  for i = 1, #SIG do
    if rd(BUF + i - 1) ~= SIG[i] then return false end
  end
  return true
end

local frame = 0
emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.startFrame)

local hits = 0
local dumps = 0
local sigSeen = 0
local identOk = nil
local cur = nil                -- 지금 돌고 있는 블록의 파라미터

local hout = assert(io.open(BASE .. '_hits.tsv', 'w'))
hout:write('hit\tframe\tP\theader\tN\tbody\ttable\tzp0A\tzp0E0F\tbank04\tmpr4\tmpr5\tmpr6\n')

emu.addMemoryCallback(function()
  -- 같은 주소에 다른 오버레이가 올 수 있다.  바이트로 신원을 확인한다.
  if identOk == nil then
    identOk = true
    for i = 1, #IDENT do
      if rd(DECOMP + i - 1) ~= IDENT[i] then identOk = false end
    end
    say(identOk and '★ $7061 신원 확인됨'
                 or '⚠ $7061 바이트가 다르다 -- 다른 오버레이다. 히트를 믿지 말 것')
  end
  if not identOk then return end

  hits = hits + 1
  local m = mprs()
  cur = {
    n     = hits,
    frame = frame,
    p     = rd16(0x00),
    hdr   = rd(0x16),
    nlen  = rd(0x10),
    body  = rd16(0x12),
    tbl   = rd16(0x14),
    a     = rd(0x0A),
    ef    = rd16(0x0E),
    bank  = rd(0x04),
  }
  hout:write(string.format(
    '%d\t%d\t$%04X\t$%02X\t%d\t$%04X\t$%04X\t$%02X\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\n',
    cur.n, cur.frame, cur.p, cur.hdr, cur.nlen, cur.body, cur.tbl,
    cur.a, cur.ef, cur.bank, m[4], m[5], m[6]))
end, emu.callbackType.exec, DECOMP, DECOMP, CPU, MEM)

local function onBlit(which)
  return function()
    if not sigMatches() then return end
    sigSeen = sigSeen + 1
    if dumps >= MAX_DUMPS or not cur then return end
    dumps = dumps + 1

    -- 지금 돌고 있는 블록을 통째로 뜬다 (뱅크가 아직 매핑돼 있는 시점이다)
    local p = cur.p
    local len = math.min(DUMP_MAX, WINDOW_END - p)
    if p < 0x8000 or len <= 0 then
      say(string.format('⚠ P=$%04X 가 뱅크 창 밖이다 -- 덤프 못 함', p))
      return
    end
    local f = assert(io.open(BASE .. '_block' .. dumps .. '.bin', 'wb'))
    for i = 0, len - 1 do f:write(string.char(rd(p + i) % 256)) end
    f:close()

    local g = assert(io.open(BASE .. '_buf' .. dumps .. '.bin', 'wb'))
    for i = 0, 127 do g:write(string.char(rd(BUF + i) % 256)) end
    g:close()

    say(string.format(
      '★ 지문 일치 (%s) -- 블록 #%d 덤프: P=$%04X 헤더=$%02X N=%d 본문=$%04X %d B',
      which, cur.n, p, cur.hdr, cur.nlen, cur.body, len))
  end
end

emu.addMemoryCallback(onBlit('$71EE 128B'), emu.callbackType.exec,
                      BLIT80, BLIT80, CPU, MEM)
emu.addMemoryCallback(onBlit('$7256 32B'), emu.callbackType.exec,
                      BLIT20, BLIT20, CPU, MEM)

emu.addEventCallback(function()
  hout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function w(m) s:write(m .. '\n'); say(m) end
  w('GFX 0.6.0 -- 원본 그래픽 블록 뜨기')
  w(string.format('$7061 히트 %d', hits))
  w(string.format('$3B00 이 원본 지문과 맞은 횟수 %d', sigSeen))
  w(string.format('덤프한 블록 %d', dumps))
  if hits == 0 then
    w('★ 히트 0 -- $7061 이 안 돈다. 오버레이(섹터 251-254)가 그 장면에 없다는 뜻이다.')
  elseif sigSeen == 0 then
    w('★ 히트는 있는데 지문이 안 떴다 -- 헌정이 이 경로가 아니거나 지문이 틀렸다.')
    w('  hits.tsv 의 P/헤더/N 분포를 보고 다시 짠다.')
  else
    w('★ 블록을 떴다. 다음: tools/gfx_block_codec.py 로 디코드해 지문을 재확인하고,')
    w('  그 바이트열을 디스크 논리 이미지에서 그대로 바이트 검색해 위치를 확정한다.')
  end
  s:close()
end, emu.eventType.scriptEnded)

say('GFX 0.6.0 로드됨 -- 헌정 화면을 지나가고 Stop. 덤프: ' .. BASE)
