-- ★ HQ 0.2.0 -- 국장실: UI 복귀 실패 + 국장 스프라이트 실종 (2026-09-06)
--
-- 0.1.0 에서 무엇이 늘었나
-- -----------------------
-- 소유자 추가 증언:
--     "애초에 진입시점에 국장님께서 앉아계셔야하는데 국장님 실종 되셧어"
--
-- 즉 스프라이트가 **들어갈 때부터** 없다.  그러면 용의자가 하나 더 붙는다 --
-- 헬퍼의 `저장 -> 그리기 -> 복원`.  저장한 뒤에 게임이 그 자리에 국장님 패턴을
-- 올리면, 우리 복원이 **옛 내용으로 되돌려 지워 버린다.**  안전자리표 문서가
-- 이미 적어 둔 함정이다 (build_vram_key_bases.py):
--
--     "allocator 가 고를 때는 비어 있었고, 그 뒤에 게임이 가져갔다.
--      allocator 는 미래를 모른다."
--
-- 그래서 0.2.0 은 STATE 와 함께 **우리 글리프 블록 안의 VRAM 을 같이 샘플링**
-- 한다.  게임이 거기에 뭘 올렸다가 우리가 되돌리는 순간이 로그에 남는다.
--
-- 0.5.14 의 트랙 3 자리 (build/patch/0.5.14/ 기준)
--     구간 0..4    base $7B00
--     구간 5..21   base $6300      ← 국장실은 이쪽이다
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 -> 트랙 3 을 국장실까지 진행
--     막히면 그대로 20 초쯤 더 둔다 (STALL300 이 찍히게)
--
-- 산출  dump/hq_0_2_0_ui_return_vram_<시각>.tsv
--
-- ⚠ 판을 고치면 버전과 산출 경로를 같이 올릴 것.

local VERSION = '0.2.0'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local STATE_AT   = 0x7FDF
local SLOT       = 0x5B80
local CD_RAW     = 0x26F9
local CD_BCD     = 0x20A2
local ADPCM_ST   = 0x180D
local FRAME_CLK  = 0x201B
local SKIP_INPUT = 0x222D
local SCHED_LO   = 0x2100

-- 우리 글리프 블록.  word 주소다.  Mesen 의 VRAM 은 바이트 주소라 x2 한다.
local BASES = { 0x7B00, 0x6300 }
local PROBE_WORDS = { 0, 0x40, 0x100, 0x300, 0x4BF }   -- 블록 앞·둘째칸·중간·끝

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_ui_return_vram_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tclk\twhy\tstate\tslot\tcd_raw\tcd_bcd\tadpcm\tskip\t'
       .. 'v7B00\tv6300\tsched\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end
local function vw(word)
  -- 한 word = 2 B.  상위/하위를 붙여 돌려준다.
  local at = word * 2
  return (emu.read(at, VRAM) or 0) * 256 + (emu.read(at + 1, VRAM) or 0)
end

local function blockHex(base)
  local t = {}
  for _, off in ipairs(PROBE_WORDS) do
    t[#t + 1] = string.format('%04X', vw(base + off))
  end
  return table.concat(t, ',')
end

local function slotHex()
  local t = {}
  for i = 0, 3 do t[#t + 1] = string.format('%02X', rb(SLOT + i)) end
  return table.concat(t)
end

local function schedHex()
  local t = {}
  for i = 0, 15 do t[#t + 1] = string.format('%02X', rb(SCHED_LO + i)) end
  return table.concat(t)
end

local frame, prev, lastChange, stalled, rows = 0, nil, 0, false, 0

local function snap()
  local s = emu.getState() or {}
  return {
    state = rb(STATE_AT), slot = slotHex(),
    raw = rb(CD_RAW), bcd = rb(CD_BCD),
    adpcm = rb(ADPCM_ST), skip = rb(SKIP_INPUT), clk = rb(FRAME_CLK),
    v1 = blockHex(BASES[1]), v2 = blockHex(BASES[2]),
    sched = schedHex(),
    pc = s['cpu.pc'] or s['cpu.programCounter'] or 0,
  }
end

local function key(v)
  -- clk 와 pc 는 매 프레임 바뀌므로 변화 판정에서 뺀다.
  return table.concat({ v.state, v.slot, v.raw, v.bcd, v.adpcm, v.skip,
                        v.v1, v.v2, v.sched }, '|')
end

local function emit(v, why)
  out:write(string.format('%d\t%d\t%s\t%02X\t%s\t%02X\t%02X\t%02X\t%02X\t%s\t%s\t%s\t%04X\n',
    frame, v.clk, why, v.state, v.slot, v.raw, v.bcd, v.adpcm, v.skip,
    v.v1, v.v2, v.sched, v.pc))
  out:flush()
  rows = rows + 1
end

emu.addEventCallback(function()
  frame = frame + 1
  local v = snap()
  local k = key(v)
  if prev == nil then
    emit(v, 'start'); prev, lastChange = k, frame; return
  end
  if k ~= prev then
    emit(v, 'change'); prev, lastChange = k, frame; stalled = false; return
  end
  if not stalled and frame - lastChange > 300 then
    emit(v, 'STALL300'); stalled = true
    emu.log(string.format('★ STALL -- state=%02X slot=%s cd_raw=%02X cd_bcd=%02X',
                          v.state, v.slot, v.raw, v.bcd))
  end
  if frame % 300 == 0 then emit(v, 'beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 국장실 UI 복귀 실패 + 스프라이트 실종 · 읽기 전용')
emu.log('  STATE $7FDF · 슬롯 $5B80 · CD $26F9/$20A2 · 글리프 블록 $7B00/$6300')
emu.log('  -> ' .. OUT)
