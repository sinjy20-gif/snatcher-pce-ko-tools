-- ★ HQ 0.9.0 -- **이사가 제대로 되는가**만 잰다 (2026-09-06 저녁)
--
-- 왜 이 판인가
-- ------------
-- 소유자 지적:
--
--     "어떤 자막에서 이사가 이루어지는건지 그런것도 지금 정확히 안쟀잖아
--      이사가 제대로 된건지도 안보고, 막 뭐 무장이 풀려서 그렇다는 둥
--      자꾸 추측성만 늘어놓고 지금 벌써 빌드를 5개정도 뽑은거 같은데"
--
-- 맞다.  0.5.14~0.5.18 을 이사를 한 번도 안 재보고 구웠다.  이 판은 굽지 않고
-- **이사 하나만** 잰다.
--
-- 이사가 하는 일 (설계상)
-- ----------------------
--   1  스케줄러의 `cdda_move` ($EFA2) 가 돈다
--   2  AC 헬퍼 제어블록에 새 base 4 B 를 쓴다
--   3  **CPU 렌더러의 즉치 3 개**를 새 base 로 바꾼다
--          $5C4B  vram_base_hi_imm
--          $5C6E  pattern_base_lo_imm
--          $5C73  pattern_attr_imm
--   4  AC 렌더러 이미지의 이사 바이트($5E15 에 대응)를 0 으로 지운다 (1 회용)
--   5  `STATE = 1` 을 쓴다 -> 상주부가 헬퍼·렌더러를 **AC 에서 다시 복사**한다
--
-- ★ 여기 의심이 있다.  5 의 재복사는 AC 이미지를 CPU 로 덮는다.  그런데 3 은
--   **CPU 쪽만** 고쳤다.  AC 이미지의 즉치가 옛 base 그대로라면, 재복사가
--   3 을 **되돌린다.**  그러면 렌더러는 옛 자리에 그리고 헬퍼는 새 자리를
--   지우게 된다 -- 서로 엇갈린다.
--
--   이 판은 그것을 직접 본다: **STATE=1 전후로 $5C4B 가 어떻게 변하는가.**
--
-- 0.5.18 의 기대값
--     옛 base $4B00 -> hi=$4B  lo=$58  attr=$AF
--     새 base $6B00 -> hi=$6B  lo=$58  attr=$BF      (lo 는 우연히 같다)
--
-- 판정
--     이사 뒤 $5C4B 가 $6B 로 바뀌고 **그대로 남는다**   -> 이사 정상
--     $6B 로 바뀌었다가 **$4B 로 돌아간다**              -> ★재복사가 되돌린다
--     아예 안 바뀐다                                     -> 이사가 안 돈다
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 -> 트랙 3 을 자동 진행으로 국장실까지
--
-- 산출  dump/hq_0_9_0_move_verify_<시각>.tsv

local VERSION = '0.9.0'
local MEM = emu.memType.pceMemory

local IMM_HI   = 0x5C4B      -- vram_base_hi_imm
local IMM_LO   = 0x5C6E      -- pattern_base_lo_imm
local IMM_ATTR = 0x5C73      -- pattern_attr_imm
local MOVE_BYTE = 0x5E15
local TRACK_BCD = 0x5E14
local STATE_AT  = 0x7FDF
local READY_AT  = 0x5CC6
local CD_RAW    = 0x26F9

local CDDA_MOVE = 0xEFA2     -- 0.5.18 의 cdda_move (cdda_scheduler.json)

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_move_verify_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\thi\tlo\tattr\tmove\tstate\tready\tcd_raw\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, rows = 0, 0
local armFrame = nil          -- 트랙 3 무장 프레임 (경과 초 계산용)
local prev = nil
local moveSeen = 0

local function line(event)
  local s = emu.getState() or {}
  local el = armFrame and string.format('%.2f', (frame - armFrame) / 60) or '-'
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%04X\n',
    frame, el, event, rb(IMM_HI), rb(IMM_LO), rb(IMM_ATTR), rb(MOVE_BYTE),
    rb(STATE_AT), rb(READY_AT), rb(CD_RAW), s['cpu.pc'] or 0))
  out:flush(); rows = rows + 1
end

-- ★ 이사 코드가 실제로 실행되는 순간
emu.addMemoryCallback(function()
  moveSeen = moveSeen + 1
  line('MOVE_EXEC#' .. moveSeen)
  emu.log(string.format('★ cdda_move 실행 #%d  frame=%d  경과=%s초  hi=$%02X',
    moveSeen, frame, armFrame and string.format('%.2f', (frame - armFrame) / 60) or '?',
    rb(IMM_HI)))
end, emu.callbackType.exec, CDDA_MOVE, CDDA_MOVE, emu.cpuType.pce, MEM)

-- 즉치 3 개를 누가 바꾸는가
local function immWrite(name)
  return function(address, value)
    local s = emu.getState() or {}
    line(string.format('%s<-%02X@%04X', name, value or 0, s['cpu.pc'] or 0))
  end
end
emu.addMemoryCallback(immWrite('hi'), emu.callbackType.write, IMM_HI, IMM_HI,
  emu.cpuType.pce, MEM)
emu.addMemoryCallback(immWrite('attr'), emu.callbackType.write, IMM_ATTR, IMM_ATTR,
  emu.cpuType.pce, MEM)
emu.addMemoryCallback(immWrite('move'), emu.callbackType.write, MOVE_BYTE, MOVE_BYTE,
  emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  local s = emu.getState() or {}
  if value == 1 and rb(CD_RAW) == 3 and armFrame == nil then armFrame = frame end
  line(string.format('STATE<-%02X@%04X', value or 0, s['cpu.pc'] or 0))
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local k = string.format('%02X%02X%02X%02X%02X', rb(IMM_HI), rb(IMM_LO),
                          rb(IMM_ATTR), rb(MOVE_BYTE), rb(STATE_AT))
  if k ~= prev then line('change'); prev = k end
  if frame % 900 == 0 then line('beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d moveExec=%d\n', rows, frame, moveSeen))
  out:close()
  emu.log(string.format('★ 이사 실행 %d 회 · %d 프레임 -> %s', moveSeen, frame, OUT))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 이사만 잰다 · 읽기 전용')
emu.log('  cdda_move $EFA2 실행 · 즉치 $5C4B/$5C73 변화 · 이사바이트 $5E15')
emu.log('  0.5.18 기대: hi $4B -> $6B · attr $AF -> $BF')
emu.log('  -> ' .. OUT)
