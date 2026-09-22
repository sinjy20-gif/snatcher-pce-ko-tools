-- SUB 0.5.86 -- 0.4.6.54 에서 자막이 왜 안 뜨는지 가른다 (save 경로 핸드셰이크)
--
-- 무엇이 벌어졌나
-- ---------------------------------------------------------------------------
-- ```
-- 0.4.6.53   64x38 재분할 + 스냅샷   -> 자막 없음 + 챕터1 깨짐
-- 0.4.6.54   128x19 원본  + 스냅샷   -> 자막 없음 + 챕터1 깨짐
-- ```
-- 전송 리듬은 범인이 아니다.  공통분모는 **스냅샷 리팩터** 하나뿐이고,
-- 자막이 처음부터 안 나오므로 깨진 곳은 restore 가 아니라 **save 경로**다.
--
-- save 에서 바뀐 것은 두 가지뿐이다.
--     · 복사 본체를 `JSR snapshot_vram` 으로 부른다  (전에는 인라인)
--     · 꼬리를 restore 와 공유한다  (`LDA #1 / JMP finish`)
--
-- 둘 다 "당연히 같아야" 하는 변경이다.  그러니 내가 모르는 계약이 하나 더 있다.
-- 추측하지 말고 어디까지 도는지 본다.
--
-- 무엇을 보나 -- 0.4.6.54 헬퍼의 실제 주소 (산출물 json)
-- ---------------------------------------------------------------------------
-- ```
-- $5B83 entry   $5B88 save   $5BAC restore   $5BB9 restore_from_backup
-- $5C03 finish  $5C09 finish 의 RTS          $5C0A snapshot_vram
-- $5C4A wipe_sprites          $5CAE stage
-- ```
-- 슬롯($5B80)에는 헬퍼와 렌더러가 번갈아 올라온다.  그래서 모든 적중은
-- **슬롯 서명**으로 검증한다 -- 헬퍼면 $5B83 이 `AD 30 5D` 다.
--
-- 답이 나오는 방식
-- ---------------------------------------------------------------------------
-- ```
-- entry 0            resident 가 헬퍼를 아예 안 부른다  -> 문제는 헬퍼 밖
-- entry>0 save 0     command 가 늘 0 이 아니다          -> 명령 전달이 깨졌다
-- save>0 snapshot 0  JSR 가 안 걸린다                   -> 주소/뱅킹 문제
-- snapshot>0 rts 0   서브루틴에서 안 돌아온다           -> ★ 스택/RTS 계약
-- rts>0 status!=1    꼬리 공유가 status 를 안 쓴다      -> ★ JMP finish 경로
-- status=1 인데 렌더러가 안 올라옴                      -> resident 쪽 계약
-- ```
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 600 프레임마다 중간집계가 나온다 -- 언로드 불필요.
--
--   BIOS  build/patch/0.4.6.54/Syscard3_galmuri_0.4.6.54.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA 재생까지
--
--   ※ 비교가 필요하면 같은 파일을 0.4.6.48 로도 한 번 돌린다.  거기서는
--     snapshot 이 0 이고 나머지가 다 도는 그림이 나와야 한다 (주소는 다르지만
--     entry/save/status 는 같은 자리다).
--
-- 산출물  C:/snatcher/dump/helper_handshake_0_5_86_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/helper_handshake_0_5_86_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

-- 0.4.6.54 헬퍼 주소
local A_ENTRY, A_SAVE, A_RESTORE = 0x5B83, 0x5B88, 0x5BAC
local A_FROM_BACKUP, A_FINISH, A_FINISH_RTS = 0x5BB9, 0x5C03, 0x5C09
local A_SNAPSHOT, A_WIPE = 0x5C0A, 0x5C4A

local CTL_CMD, CTL_STATUS = 0x5D30, 0x5D31
local CTL_LO, CTL_HI = 0x5D34, 0x5D35
local STATE = 0x7FDF
local SLOT = 0x5B80

local frame = 0
local function rd(a) return emu.read(a, MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end

-- 슬롯에 헬퍼가 올라와 있나 (렌더러도 같은 주소를 쓰므로 반드시 확인한다)
local function isHelper()
  return rd(A_ENTRY) == 0xAD and rd(A_ENTRY + 1) == 0x30 and rd(A_ENTRY + 2) == 0x5D
end

local n = { entry = 0, save = 0, restore = 0, snapshot = 0, wipe = 0,
            from_backup = 0, finish = 0, rts = 0, other_occupant = 0 }
local shown = {}

local function hit(name, extra)
  if not isHelper() then n.other_occupant = n.other_occupant + 1; return end
  n[name] = n[name] + 1
  if not shown[name] then
    shown[name] = true
    say('0.5.86 · %df  첫 %s   %s', frame, name, extra or '')
    rec('first_' .. name, '%s', extra or '')
  end
end

local function watch(addr, name, detail)
  emu.addMemoryCallback(function()
    hit(name, detail and detail() or nil)
  end, emu.callbackType.exec, addr, addr, CPU, MEM)
end

watch(A_ENTRY, 'entry', function()
  return string.format('cmd=$%02X base=$%02X%02X', rd(CTL_CMD), rd(CTL_HI), rd(CTL_LO))
end)
watch(A_SAVE, 'save')
watch(A_RESTORE, 'restore', function()
  return string.format('base=$%02X%02X', rd(CTL_HI), rd(CTL_LO))
end)
watch(A_SNAPSHOT, 'snapshot')
watch(A_WIPE, 'wipe')
watch(A_FROM_BACKUP, 'from_backup')
watch(A_FINISH, 'finish')
watch(A_FINISH_RTS, 'rts')

-- status / state 쓰기
emu.addMemoryCallback(function(_a, v)
  v = (v or 0) & 0xFF
  rec('status', 'value=%d', v)
  say('0.5.86 · %df  status <- %d', frame, v)
end, emu.callbackType.write, CTL_STATUS, CTL_STATUS, CPU, MEM)

local lastState = -1
emu.addMemoryCallback(function(_a, v)
  v = (v or 0) & 0xFF
  if v ~= lastState then
    lastState = v
    rec('state', 'value=%d', v)
    say('0.5.86 · %df  STATE <- %d', frame, v)
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

-- 슬롯 점유자가 바뀌는 순간 (헬퍼 -> 렌더러가 실제로 일어나는지)
local lastOcc = nil
emu.addEventCallback(function()
  frame = frame + 1
  local occ
  if rd(SLOT) == 0x53 and isHelper() then occ = 'helper'
  elseif rd(SLOT) == 0x53 then occ = 'renderer'
  else occ = string.format('none($%02X)', rd(SLOT) & 0xFF) end
  if occ ~= lastOcc then
    lastOcc = occ
    rec('occupant', '%s', occ)
    say('0.5.86 · %df  슬롯 점유자 = %s', frame, occ)
  end
  if frame % 600 == 0 then
    say('0.5.86 ===== %df  entry %d · save %d · snapshot %d · rts %d · restore %d ' ..
        '· wipe %d · from_backup %d · finish %d  (헬퍼 아닌 적중 %d)',
        frame, n.entry, n.save, n.snapshot, n.rts, n.restore, n.wipe,
        n.from_backup, n.finish, n.other_occupant)
    rec('tally', 'entry=%d save=%d snapshot=%d rts=%d restore=%d wipe=%d from_backup=%d finish=%d other=%d',
        n.entry, n.save, n.snapshot, n.rts, n.restore, n.wipe,
        n.from_backup, n.finish, n.other_occupant)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  rec('end', 'entry=%d save=%d snapshot=%d rts=%d restore=%d', n.entry, n.save,
      n.snapshot, n.rts, n.restore)
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.86-helper-handshake armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  0.4.6.54 에서 save 경로가 어디까지 도는지 본다')
say('  entry -> save -> snapshot -> rts -> status=1 -> 렌더러 적재')
say('  덤프 : ' .. PATH)
