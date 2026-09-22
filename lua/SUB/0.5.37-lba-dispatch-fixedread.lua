-- SUB 0.5.37 -- 디스패처가 **실제로 무엇을 읽었는가** (1차 실패 진단)
--
-- 무엇을 시험하나
-- ---------------------------------------------------------------------------
-- BIOS 0.4.7.0 이 AD_PLAY 도중 SCSI CDB 의 LBA 3 B 로 색인을 이분 검색해
-- **결과만 AC 에 적는다.**  자막을 켜지 않고 state 도 안 건드린다.
-- 그러므로 이 시험은 게임 동작에 위험이 없다 (BASELINE §12 · 0.4.7.0 docstring).
--
--     ★ 0.4.6.26/27 은 감지·가드·조회를 한꺼번에 넣어 원인이 안 갈렸다.
--       이 판은 **조회 하나만** 켠다.
--
-- 왜 0.5.37 인가 -- 0.5.35 가 남긴 것
-- ---------------------------------------------------------------------------
-- 1차: 지역변수 PROBE 가 T+1 과 겹쳐 카운터가 깨졌다 -> 0단계로 전부 miss (수정됨)
-- 2차: 단계 수는 9~11 로 정상 깊이인데 **여전히 전부 miss**.
--      즉 검색은 도는데 비교가 안 맞는다.  원인 후보가 둘이다.
--
-- 3차(0.5.36): 읽은값이 FF 3C F7 -- 표도 아니고 같은 값 반복도 아니다.
--      자동증가는 먹는데 주소가 딴 곳이다.  남은 후보 둘을 가른다.
--        (a) AC 포트 관용구 자체가 틀렸다
--        (b) 관용구는 맞고 mid*9 주소 계산이 틀렸다
--
--      -> BIOS 가 **고정 주소($1F2400)에서도 3 B 를 읽어** 슬롯 +7~9 에 남긴다.
--         그게 표 첫 항목(00 30 6B)이면 관용구는 맞고 (b) 다.
--
--      추측하지 않는다.  BIOS 가 **마지막으로 읽은 entry 3 B 를 그대로 뱉게** 했다.
--      슬롯 +4~6 에 그 값이 온다 (+7~9 는 00).
--
--          세 값이 서로 같다        -> (a) 자동증가 문제
--          표에 없는 값이다          -> (b) 주소 문제
--          표에 있는 값인데 miss    -> 비교/분기 논리 문제
--
-- 이 스크립트가 하는 일
-- ---------------------------------------------------------------------------
--   1) LBA 색인 표(902 x 9 B)를 AC $1F2400 에 올린다
--        -- 팩을 다시 굽지 않으려고 Lua 가 대신 올린다.  디스크는 0.4.6.22 그대로다
--   2) 관측 슬롯 AC $1F2200 을 0 으로 지운다
--   3) 음성이 시작될 때마다 슬롯을 읽어 **진짜 키와 대조**한다
--
-- 관측 슬롯
--     +0    $A1 찾음 · $A0 못찾음 · $00 아직
--     +1~3  디스패처가 읽은 LBA (MSB first)
--     +4~9  찾은 6 B 키
--     +10   탐색 단계 수
--
-- 판정
--     자막 대상 음성   -> $A1 이고 키가 일치해야 한다
--     효과음           -> $A0 가 정상 (표에 없다)
--     status 가 $00 그대로 -> 훅이 안 걸렸다
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.
--     BIOS  build/patch/0.4.7.0-lba-probe/Syscard3_galmuri_0.4.7.0-lba-probe.pce
--     CUE   build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue   (그대로)

local MEM = emu.memType.pceMemory
local AC  = emu.memType.pceArcadeCardRam
local APCM = emu.memType.pceAdpcmRam

local AC_SLOT  = 0x1F2200
local AC_INDEX = 0x1F2400
local TABLE = 'C:/snatcher/build/cutscene_subs/lba_index_0_4_7_0.bin'
local STRIDE = 9

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/lba_dispatch_diag_0_5_36_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('voice\tframe\tstatus\tlba\tnative_key\ttrue_key\tprobes\tverdict\n')
end

-- ---------------------------------------------------------------------------
-- 1) 표를 AC 로 올린다
-- ---------------------------------------------------------------------------
local fh = io.open(TABLE, 'rb')
if not fh then
  emu.log('SUB 0.5.37 ★★ 표가 없다: ' .. TABLE)
  emu.log('   python tools/build_snatcher_0_4_7_0_lba_probe.py 를 먼저 돌릴 것')
  return
end
local data = fh:read('*a')
fh:close()
if #data % STRIDE ~= 0 then
  emu.log(string.format('SUB 0.5.37 ★★ 표 크기가 %d B -- %d 의 배수가 아니다', #data, STRIDE))
  return
end
for i = 1, #data do
  emu.write(AC_INDEX + i - 1, data:byte(i), AC)
end
for i = 0, 10 do emu.write(AC_SLOT + i, 0, AC) end

local entries = #data // STRIDE
emu.log(string.format('SUB 0.5.37 표 %d 항목(%d B)을 AC $%06X 에 올렸다 · 슬롯 $%06X 초기화',
                      entries, #data, AC_INDEX, AC_SLOT))

-- ★ 되읽기 자기점검 -- Lua 가 쓴 것이 정말 그 자리에 있는가
do
  local bad = 0
  for i = 1, math.min(#data, 64) do
    if (emu.read(AC_INDEX + i - 1, AC) or -1) ~= data:byte(i) then bad = bad + 1 end
  end
  if bad > 0 then
    emu.log(string.format('SUB 0.5.37 ★★ AC 되읽기 불일치 %d/64 -- 표가 그 자리에 없다', bad))
  else
    local e = {}
    for i = 1, 9 do e[#e + 1] = string.format('%02X', data:byte(i)) end
    emu.log('SUB 0.5.37 AC 되읽기 OK · 첫 항목 ' .. table.concat(e, ' '))
  end
end

-- 표를 Lua 쪽에도 들고 있어 대조에 쓴다
local byLba = {}
for i = 0, entries - 1 do
  local o = i * STRIDE
  local lba = (data:byte(o + 1) << 16) | (data:byte(o + 2) << 8) | data:byte(o + 3)
  byLba[lba] = data:sub(o + 4, o + 9)
end

-- ---------------------------------------------------------------------------
-- 2) 음성 시작마다 채점
-- ---------------------------------------------------------------------------
local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function num(s, k)
  local v = s and s[k]
  return type(v) == 'number' and math.floor(v) or -1
end

local function hex6(k)
  return (k:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

local voices, prevPlaying = 0, false
local okN, badN, missN, silentN = 0, 0, 0, 0

emu.addEventCallback(function()
  local s = st()
  if not s then return end
  local playing = s['cdrom.adpcm.playing'] == true
  if not (playing and not prevPlaying) then prevPlaying = playing; return end
  prevPlaying = playing
  voices = voices + 1

  local frame = emu.getState() and (num(s, 'ppu.frameCount')) or -1

  -- 진짜 키 (수집기/0.4.31 과 같은 정의)
  local ra   = num(s, 'cdrom.adpcm.readAddress')
  local len  = num(s, 'cdrom.adpcm.adpcmLength')
  local rate = num(s, 'cdrom.adpcm.playbackRate') & 0xFF
  local fin  = (ra + len) & 0xFFFF
  local truekey = string.char(fin & 0xFF, (fin >> 8) & 0xFF, rate,
                              emu.read(fin // 4, APCM) or 0,
                              emu.read(fin // 2, APCM) or 0,
                              emu.read((fin * 5) // 8, APCM) or 0)

  local slot = {}
  for i = 0, 10 do slot[i] = emu.read(AC_SLOT + i, AC) or 0 end
  local status = slot[0]
  local lba = (slot[1] << 16) | (slot[2] << 8) | slot[3]
  local nkey = string.char(slot[4], slot[5], slot[6], slot[7], slot[8], slot[9])

  local expect = byLba[lba]              -- 표 기준 정답 (LBA 로)
  local verdict
  if status == 0 then
    silentN = silentN + 1
    verdict = 'NO-HOOK'
  elseif status == 0xA0 then
    -- 못 찾음.  진짜 키가 표에 없으면 정상이다
    local inTable = false
    for _, k in pairs(byLba) do if k == truekey then inTable = true break end end
    -- ★ 진단: slot[4..6] = 디스패처가 마지막으로 읽은 entry 3 B
    local r0, r1, r2 = slot[4], slot[5], slot[6]
    local f0, f1, f2 = slot[7], slot[8], slot[9]
    local readLba = (r0 << 16) | (r1 << 8) | r2
    -- ★ 고정주소($1F2400) 읽기가 표의 첫 항목 00 30 6B 와 같은가
    local want0, want1, want2 = data:byte(1), data:byte(2), data:byte(3)
    local fixedOk = (f0 == want0 and f1 == want1 and f2 == want2)
    local why
    if not fixedOk then
      why = string.format(
        '★ 고정주소 읽기가 %02X %02X %02X (기대 %02X %02X %02X) -> AC 포트 관용구가 틀렸다',
        f0, f1, f2, want0, want1, want2)
    elseif byLba[readLba] then
      why = string.format('고정 OK · 동적 %06X 는 표에 있다 -> 비교/분기 논리 문제', readLba)
    else
      why = string.format('고정 OK · 동적 %06X 가 표에 없다 -> mid*9 주소 계산이 틀렸다', readLba)
    end
    if inTable then badN = badN + 1; verdict = 'MISS-BUT-IN-TABLE · ' .. why
    else missN = missN + 1; verdict = 'miss(정상) · ' .. why end
  elseif status == 0xA1 then
    if nkey == truekey then okN = okN + 1; verdict = 'OK'
    elseif expect and nkey == expect then
      badN = badN + 1; verdict = 'TABLE-vs-TRUE 불일치'
    else badN = badN + 1; verdict = 'WRONG-KEY' end
  else
    badN = badN + 1
    verdict = string.format('status $%02X ?', status)
  end

  if out then
    out:write(string.format('%d\t%d\t%02X\t%06X\t%s\t%s\t%d\t%s\n',
      voices, frame, status, lba, hex6(nkey), hex6(truekey), slot[10], verdict))
    out:flush()
  end
  emu.log(string.format('SUB 0.5.37 #%d  st $%02X  lba %06X  native %s  true %s  %d단계  %s',
    voices, status, lba, hex6(nkey), hex6(truekey), slot[10], verdict))

  -- 다음 음성을 위해 슬롯을 지운다 (안 지우면 직전 값이 남아 오판한다)
  for i = 0, 10 do emu.write(AC_SLOT + i, 0, AC) end

  if voices % 10 == 0 then
    emu.log(string.format('SUB 0.5.37 === %d 음성 · OK %d · 오답 %d · miss %d · 훅없음 %d',
                          voices, okN, badN, missN, silentN))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close() end
  emu.log(string.format(
    'SUB 0.5.37 끝 -- 음성 %d · OK %d · 오답 %d · miss(정상) %d · 훅없음 %d',
    voices, okN, badN, missN, silentN))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.37-lba-dispatch-check armed')
emu.log('  ★ BIOS 는 0.4.7.0-lba-probe · CUE 는 0.4.6.22 것 그대로')
emu.log('  ★ 자막은 안 뜬다.  이 판은 조회만 켠 관측용이다')
emu.log('  판정: OK = 네이티브가 찾은 키 == 진짜 키')
emu.log('  로그: ' .. OUT)
