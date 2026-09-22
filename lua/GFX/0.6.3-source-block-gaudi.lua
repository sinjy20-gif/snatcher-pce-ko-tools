-- GFX 0.6.3 -- 가우디 키패드용.  0.6.2 와 훅·매핑은 같다.  ★순수 관측 · 쓰기 0 B
--
-- 0.6.1 이 무엇을 알려줬나 (2026-09-09 실측)
-- ---------------------------------------------------------------------------
--   ★ 레코드는 6 바이트 고정: [뱅크][종류][VRAM lo][VRAM hi][P lo][P hi] · FF 로 끝
--   ★ 뱅크 -> 디스크:  논리오프셋 = (247 + 4*뱅크)*2048 + (P - $8000)   (3 점 검증)
--   ★ 헌정 화면의 MAWR 은 **$1100** 이다 ($16A0 은 지문 타일 하나의 주소일 뿐)
--   ✗ 그런데 히트가 5,981 이었다 -- `$7061` 은 블록 진입점이 아니라 **루프 머리**다
--     (`$7152 JMP $7061` 이 명령마다 돌아온다). 게다가 압축 해제기가 `$00` 을
--     카운터로 쓴다 (`$70D0 STA $00`). 그래서 첫 명령 뒤엔 P 가 파괴된다.
--     "P=$8001/$8002/$8003" 은 포인터가 아니라 덮어써진 카운트였다.
--
-- 0.6.2 가 바꾼 것
-- ---------------------------------------------------------------------------
--   훅을 `JSR $7061` **호출부 셋**으로 옮긴다 -- $6FA1 · $700E · $7056.
--   그 시점엔 zp 가 온전하고 압축 해제기가 아직 안 돌았다.  **한 히트 = 한 블록**.
--
--   그리고 뜬 자리마다 위 매핑으로 **디스크 논리 오프셋을 같이 찍는다.**
--   맞으면 그대로 제자리 치환 대상이 된다.
--
-- 무엇을 보나
--   키패드 글자 타일은 VRAM 워드 $2000 (= 타일 $200) 으로 올라간다.  이미 디스크
--   위치를 안다 ($02EF3BE 등 사본 4).  이번에 찾는 것은 **타일맵(BAT)** 이다.
--   BAT 은 VRAM 워드 $0000-$0FFF 이므로, 목적지가 그 범위인 블록에 ★ 를 찍는다.
--   그런 블록이 나오면 배치도 디스크 데이터이고 제자리 치환으로 끝난다.
--   안 나오면 코드가 BAT 을 만드는 것이 확정된다 -- 그때는 다른 프로브로 간다.
--
-- 쓰는 법  이것만 로드 -> **가우디 검색 화면(자판)까지 들어갔다가** 한 번 나오고 · Stop
-- 산출물   C:/snatcher/dump/gfxsrc_0_6_3_<시각>_hits.tsv
--          C:/snatcher/dump/gfxsrc_0_6_3_<시각>_blk_<뱅크>_<P>.bin   블록 앞 2 KB
--          C:/snatcher/dump/gfxsrc_0_6_3_<시각>_summary.txt

local ZP     = 0x2000
local CALL   = { 0x6FA1, 0x700E, 0x7056 }    -- ★ JSR $7061 호출부
local H_DEF, H_08, H_04 = 0x6F60, 0x6FC8, 0x7019
local BLIT80, BLIT20 = 0x71EE, 0x7256
local BUF    = 0x3B00
local WIN_END = 0xE000
local DUMP_BYTES = 2048
local MAX_DUMPS  = 200
local BASE_SECTOR, SECTOR = 247, 2048        -- 뱅크 -> 디스크 매핑

local BAT_LO, BAT_HI = 0x0000, 0x0FFF        -- BAT 은 VRAM 워드 이 범위
local TILE_DEST      = 0x2000                -- 키패드 글자 타일 (타일 $200)

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxsrc_0_6_3_' .. STAMP

local function say(m) emu.log(m); print(m) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end
local function rd16(a) return rd(a) + rd(a + 1) * 256 end
local function zp(a) return rd(ZP + a) end
local function zp16(a) return rd16(ZP + a) end

local function regs()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end

local hits, dumps, batBlocks, tileBlocks = 0, 0, 0, 0
local pend, frame = nil, 0
local seen = {}

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.startFrame)

local hout = assert(io.open(BASE .. '_hits.tsv', 'w'))
hout:write('hit\tframe\tkind\tvram\tP\theader\tN\tbody\ttable\tbank\tdisc\tdumped\n')

-- 핸들러 입구에서 스크립트 스트림의 레코드를 직접 읽는다 (Y 가 VRAM 바이트를 가리킨다)
local function onHandler(kind)
  return function()
    local s = regs()
    local y = s['cpu.y'] or s['y'] or -1
    local base = zp16(0x08)
    if y < 0 or base < 0 then pend = nil; return end
    pend = { kind = kind,
             vram = rd(base + y) + rd(base + y + 1) * 256,
             p    = rd(base + y + 2) + rd(base + y + 3) * 256 }
  end
end
emu.addMemoryCallback(onHandler('def'), emu.callbackType.exec, H_DEF, H_DEF, CPU, MEM)
emu.addMemoryCallback(onHandler('$08'), emu.callbackType.exec, H_08, H_08, CPU, MEM)
emu.addMemoryCallback(onHandler('$04'), emu.callbackType.exec, H_04, H_04, CPU, MEM)

local function onCall()
  hits = hits + 1
  local p    = zp16(0x00)
  local bank = zp(0x04)
  local hdr  = zp(0x16)
  local n    = zp(0x10)
  local body = zp16(0x12)
  local tbl  = zp16(0x14)
  local kind = pend and pend.kind or '?'
  local vram = pend and pend.vram or -1
  local disc = (BASE_SECTOR + 4 * (bank % 256)) * SECTOR + (p - 0x8000)

  if vram >= BAT_LO and vram <= BAT_HI then batBlocks = batBlocks + 1 end
  if vram == TILE_DEST then tileBlocks = tileBlocks + 1 end

  local key = string.format('%02X_%04X', bank % 256, p % 65536)
  local did = 0
  if not seen[key] and dumps < MAX_DUMPS and p >= 0x8000 and p < WIN_END then
    seen[key] = true
    dumps = dumps + 1
    did = 1
    local len = math.min(DUMP_BYTES, WIN_END - p)
    local f = assert(io.open(BASE .. '_blk_' .. key .. '.bin', 'wb'))
    for i = 0, len - 1 do f:write(string.char(rd(p + i) % 256)) end
    f:close()
    local tag = ''
    if vram >= BAT_LO and vram <= BAT_HI then tag = '  ★타일맵(BAT) 후보'
    elseif vram == TILE_DEST then tag = '  ← 키패드 글자 타일' end
    say(string.format(
      '블록 #%d  %s  VRAM $%04X  P=$%04X  헤더 $%02X  N=%d  뱅크 $%02X  디스크 논리 $%07X (섹터 %d)%s',
      dumps, kind, vram % 65536, p, hdr, n, bank, disc, math.floor(disc / SECTOR), tag))
  end

  hout:write(string.format('%d\t%d\t%s\t$%04X\t$%04X\t$%02X\t%d\t$%04X\t$%04X\t$%02X\t$%07X\t%d\n',
    hits, frame, kind, vram % 65536, p, hdr, n, body, tbl, bank, disc, did))
end

for _, a in ipairs(CALL) do
  emu.addMemoryCallback(onCall, emu.callbackType.exec, a, a, CPU, MEM)
end

emu.addEventCallback(function()
  hout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function w(m) s:write(m .. '\n'); say(m) end
  w('GFX 0.6.3 -- 가우디 키패드 원본 블록 뜨기')
  w(string.format('블록 히트 %d · 서로 다른 블록 %d', hits, dumps))
  w(string.format('타일맵(BAT) 목적지 블록 %d · 키패드 글자 타일 블록 %d', batBlocks, tileBlocks))
  if batBlocks == 0 then
    w('BAT 목적지 블록이 0 이다 -> 배치는 코드가 만든다.')
  else
    w('★ BAT 블록이 있다 -> 제자리 치환으로 끝난다. hits.tsv 의 disc 칸이 위치다.')
  end
  s:close()
end, emu.eventType.scriptEnded)

say('GFX 0.6.3 로드됨 -- 가우디 자판까지 들어갔다 나오고 Stop. 덤프: ' .. BASE)
