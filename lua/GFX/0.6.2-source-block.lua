-- GFX 0.6.2 -- 원본 그래픽 블록 뜨기 (훅 지점 고침)  ★순수 관측 · 쓰기 0 B
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
-- 판정
--   VRAM $1100 인 블록들이 몇 개 나온다 -> 그중 지문을 품은 것이 헌정
--   지문이 어디에도 없다                -> 지문 자체가 낡았다. 타일 $16A 를 다시 잰다
--
-- 쓰는 법  이것만 로드 · 부팅 -> **헌정 화면을 지나고** 조금 더 · Stop
-- 산출물   C:/snatcher/dump/gfxsrc_0_6_2_<시각>_hits.tsv
--          C:/snatcher/dump/gfxsrc_0_6_2_<시각>_blk_<뱅크>_<P>.bin   블록 앞 1 KB
--          C:/snatcher/dump/gfxsrc_0_6_2_<시각>_summary.txt

local ZP     = 0x2000
local CALL   = { 0x6FA1, 0x700E, 0x7056 }    -- ★ JSR $7061 호출부
local H_DEF, H_08, H_04 = 0x6F60, 0x6FC8, 0x7019
local BLIT80, BLIT20 = 0x71EE, 0x7256
local BUF    = 0x3B00
local WIN_END = 0xE000
local DUMP_BYTES = 1024
local MAX_DUMPS  = 200
local BASE_SECTOR, SECTOR = 247, 2048        -- 뱅크 -> 디스크 매핑

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxsrc_0_6_2_' .. STAMP

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

local hits, dumps, sigSeen = 0, 0, 0
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
    say(string.format(
      '블록 #%d  %s  VRAM $%04X  P=$%04X  헤더 $%02X  N=%d  뱅크 $%02X  디스크 논리 $%07X (섹터 %d)',
      dumps, kind, vram % 65536, p, hdr, n, bank, disc, math.floor(disc / SECTOR)))
  end

  hout:write(string.format('%d\t%d\t%s\t$%04X\t$%04X\t$%02X\t%d\t$%04X\t$%04X\t$%02X\t$%07X\t%d\n',
    hits, frame, kind, vram % 65536, p, hdr, n, body, tbl, bank, disc, did))
end

for _, a in ipairs(CALL) do
  emu.addMemoryCallback(onCall, emu.callbackType.exec, a, a, CPU, MEM)
end

local function onBlit()
  return function()
    for i = 1, #SIG do
      if rd(BUF + i - 1) ~= SIG[i] then return end
    end
    sigSeen = sigSeen + 1
    if sigSeen <= 3 then say(string.format('★ $3B00 이 원본 지문과 일치 (프레임 %d)', frame)) end
  end
end
emu.addMemoryCallback(onBlit(), emu.callbackType.exec, BLIT80, BLIT80, CPU, MEM)
emu.addMemoryCallback(onBlit(), emu.callbackType.exec, BLIT20, BLIT20, CPU, MEM)

emu.addEventCallback(function()
  hout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function w(m) s:write(m .. '\n'); say(m) end
  w('GFX 0.6.2 -- 원본 그래픽 블록 뜨기')
  w(string.format('블록 히트 %d · 서로 다른 블록 %d · 지문 일치 %d', hits, dumps, sigSeen))
  w('★ 다음: VRAM $1100 인 블록들을 tools/gfx_block_codec.py 로 풀어 지문을 찾는다.')
  w('  hits.tsv 의 disc 칸이 디스크 논리 오프셋이다 (검증된 매핑).')
  s:close()
end, emu.eventType.scriptEnded)

say('GFX 0.6.2 로드됨 -- 헌정 화면을 지나가고 Stop. 덤프: ' .. BASE)
