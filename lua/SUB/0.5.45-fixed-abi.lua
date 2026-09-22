-- SUB 0.5.45 -- 표가 **읽는 그 순간까지 살아 있는가** (0.5.40 + 무결성 확인)
--
-- 왜 이 판이 필요한가 -- 0.5.41 이 뒤집은 것
-- ---------------------------------------------------------------------------
-- 0.5.41 로 AC 포트 접근을 그 순간에 잡았더니 **포트는 멀쩡했다.**
--
--     실패  $1B02=00 $1B03=24 $1B04=1F -> base $1F2400 · 제어 $11 · 읽기 FF
--     성공  $1B02=D2 $1B03=33 $1B04=1F -> base $1F33D2 · 제어 $11 · 읽기 $24
--
-- 같은 관용구 · 같은 MPR(`FF F8 68 6A 82 72 73 01`) · 주소만 다른데 한쪽은 읽힌다.
-- 읽기 콜백이 걸리므로 도달도 한다.  base 도 정확히 세운다.
--     -> "문맥(MPR)" 도 "설정(base 미설정)" 도 아니다.  둘 다 기각.
--
--     ★ 남은 설명은 하나 -- **읽을 때 그 주소에 표가 없다.**
--
-- 그리고 0.5.41 은 표를 올리지 않는 판이었다.  그런데도 $1F2400 을 직접 읽으니
-- 우리 표가 아닌 값이 들어 있었다.  **이 구역이 한가한 자리가 아닐 수 있다.**
--
-- 0.5.40 의 되읽기는 이 의심을 못 막는다 -- 그것은 **스크립트 로드 시점**이고
-- 디스패처가 읽는 것은 3,600 프레임 뒤다.
--
-- 이 판이 더한 것
-- ---------------------------------------------------------------------------
--     · 60 프레임마다 앞 64 B 대조 -> **처음 깨진 프레임**을 남긴다
--     · 음성마다 관측 직후에도 대조 -> 그 음성을 읽던 순간의 표 상태
--
-- 판정
--     표 살아있음 + BIOS 가 FF     -> 진짜 포트/타이밍 문제.  더 파야 한다
--     표가 깨져 있음               -> **자리 문제.**  FF 는 정상이고 옮기면 끝난다
--
-- (아래는 0.5.40 에서 이어받은 설명)
--
-- 무엇을 시험하나
-- ---------------------------------------------------------------------------
-- BIOS 0.4.7.0 이 AD_PLAY 도중 SCSI CDB 의 LBA 3 B 로 색인을 이분 검색해
-- **결과만 AC 에 적는다.**  자막을 켜지 않고 state 도 안 건드린다.
-- 그러므로 이 시험은 게임 동작에 위험이 없다 (BASELINE §12 · 0.4.7.0 docstring).
--
--     ★ 앞선 dual-detect 판(지금은 폐기·번호 재사용됨)은 감지·가드·조회를
--       한꺼번에 넣어 원인이 안 갈렸다.
--       이 판은 **조회 하나만** 켠다.
--
-- 왜 0.5.45 인가 -- 0.5.35 가 남긴 것
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
--   1) LBA 색인 표(902 x 9 B)를 AC $1F2800 에 올린다  (옛 자리 $1F2400 은 지워졌다)
--        -- 팩을 다시 굽지 않으려고 Lua 가 대신 올린다.  디스크는 0.4.6.22 그대로다
--   2) 관측 슬롯 AC $1F2700 을 0 으로 지운다  (옛 자리 $1F2200 도 같은 섹터였다)
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
--     BIOS  build/patch/0.4.6.27/Syscard3_galmuri_0.4.6.27.pce
--     CUE   build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue   (그대로)

local MEM = emu.memType.pceMemory
local AC  = emu.memType.pceArcadeCardRam
local APCM = emu.memType.pceAdpcmRam

local AC_SLOT  = 0x1F2700
local AC_INDEX = 0x1F2800
local TABLE = 'C:/snatcher/build/cutscene_subs/lba_index.bin'
local STRIDE = 9

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/fixed_abi_0_5_45_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('voice\tframe\tstatus\tlba\tnative_key\ttrue_key\tprobes\tverdict\n')
end

-- ---------------------------------------------------------------------------
-- 1) 표를 AC 로 올린다
-- ---------------------------------------------------------------------------
local fh = io.open(TABLE, 'rb')
if not fh then
  emu.log('SUB 0.5.45 ★★ 표가 없다: ' .. TABLE)
  emu.log('   python tools/build_snatcher_0_4_7_0_lba_probe.py 를 먼저 돌릴 것')
  return
end
local data = fh:read('*a')
fh:close()
if #data % STRIDE ~= 0 then
  emu.log(string.format('SUB 0.5.45 ★★ 표 크기가 %d B -- %d 의 배수가 아니다', #data, STRIDE))
  return
end
for i = 1, #data do
  emu.write(AC_INDEX + i - 1, data:byte(i), AC)
end
for i = 0, 12 do emu.write(AC_SLOT + i, 0, AC) end

local entries = #data // STRIDE
emu.log(string.format('SUB 0.5.45 표 %d 항목(%d B)을 AC $%06X 에 올렸다 · 슬롯 $%06X 초기화',
                      entries, #data, AC_INDEX, AC_SLOT))

-- ★ 되읽기 자기점검 -- Lua 가 쓴 것이 정말 그 자리에 있는가
do
  local bad = 0
  for i = 1, math.min(#data, 64) do
    if (emu.read(AC_INDEX + i - 1, AC) or -1) ~= data:byte(i) then bad = bad + 1 end
  end
  if bad > 0 then
    emu.log(string.format('SUB 0.5.45 ★★ AC 되읽기 불일치 %d/64 -- 표가 그 자리에 없다', bad))
  else
    local e = {}
    for i = 1, 9 do e[#e + 1] = string.format('%02X', data:byte(i)) end
    emu.log('SUB 0.5.45 AC 되읽기 OK · 첫 항목 ' .. table.concat(e, ' '))
  end
end

-- ---------------------------------------------------------------------------
-- ★ 0.5.45 가 더한 것 -- 표가 **읽는 그 순간까지 살아 있는가**
-- ---------------------------------------------------------------------------
-- 0.5.40 은 스크립트 로드 시점에만 되읽기를 했다.  그런데 디스패처가 읽는 것은
-- 3,600 프레임 뒤다.  그 사이에 누가 덮으면 BIOS 가 FF 를 읽는 것이 **정상**이고,
-- 그러면 포트가 아니라 **자리**가 문제다.
--
-- 0.5.41 이 그 의심을 키웠다: 표를 안 올린 판에서 $1F2400 을 직접 읽었더니
-- 우리 표가 아닌 값이 들어 있었다.  이 구역이 한가한 자리가 아닐 수 있다.
--
-- 그래서 여기서는 주기적으로 앞 64 B 를 대조하고, **처음 깨진 프레임**을 남긴다.
local CHECK_BYTES = math.min(#data, 64)

local function tableBad()
  local bad = 0
  for i = 1, CHECK_BYTES do
    if (emu.read(AC_INDEX + i - 1, AC) or -1) ~= data:byte(i) then bad = bad + 1 end
  end
  return bad
end

local brokeAt, brokeShown = nil, false
local checkFrame = 0

emu.addEventCallback(function()
  checkFrame = checkFrame + 1
  if checkFrame % 60 ~= 0 then return end
  local bad = tableBad()
  if bad > 0 and not brokeAt then
    brokeAt = checkFrame
    emu.log(string.format(
      'SUB 0.5.45 ★★ 표가 깨졌다 -- %d 프레임 근처 · 앞 %d B 중 %d B 불일치',
      checkFrame, CHECK_BYTES, bad))
    local g = {}
    for i = 1, 9 do g[#g + 1] = string.format('%02X', emu.read(AC_INDEX + i - 1, AC) or 0) end
    emu.log('   지금 그 자리의 값: ' .. table.concat(g, ' '))
    emu.log('   => 새 자리($1F2800)에서도 깨진다.  선적재 섹터 밖인데도 누가 덮는다')
  elseif bad == 0 and brokeAt and not brokeShown then
    brokeShown = true
    emu.log('SUB 0.5.45 (표가 다시 맞다 -- 덮은 쪽이 되돌렸거나 일시적이었다)')
  end
end, emu.eventType.endFrame)

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
  for i = 0, 12 do slot[i] = emu.read(AC_SLOT + i, AC) or 0 end
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
    -- ★ 정답을 미리 아는 시험.  판정은 해석이 아니라 바이트 비교로 한다.
    --   0.4.7.4 슬롯: +7~10 = 고정주소에서 읽은 4 B · +11 단계수 · +12 build
    local fx = { slot[7], slot[8], slot[9], slot[10] }
    local w = { data:byte(1), data:byte(2), data:byte(3), data:byte(4) }
    local aligned = (fx[1] == w[1] and fx[2] == w[2] and fx[3] == w[3] and fx[4] == w[4])
    local shifted = (fx[2] == w[1] and fx[3] == w[2] and fx[4] == w[3])
    local readLba = (r0 << 16) | (r1 << 8) | r2
    local fxs = string.format('%02X %02X %02X %02X', fx[1], fx[2], fx[3], fx[4])
    local ws = string.format('%02X %02X %02X %02X', w[1], w[2], w[3], w[4])
    -- ★ 옛 진단 문구 두 개는 폐기됐다 (인계서 2026-08-30 밤 §2-3).
    --
    --   (X) '동적 %06X 는 표에 있다  -> 비교/분기 논리 문제'
    --   (X) '동적 %06X 가 표에 없다  -> mid*9 주소 계산이 틀렸다'
    --
    -- 둘 다 "마지막으로 읽은 항목이 표에 있으면/없으면 이상하다" 는 어림짐작에서
    -- 나왔는데, 그 전제가 틀렸다.  이분검색이 경계에서 어느 항목에 내려앉는지는
    -- 정답 여부와 무관하다.  판정은 **고정 4B 바이트 비교** 하나로 한다.
    -- 그대로 두면 정상 주행에서 매번 거짓 경보가 떠서 진짜 오류와 안 갈린다.
    local tableMin, tableMax
    for lba in pairs(byLba) do
      if not tableMin or lba < tableMin then tableMin = lba end
      if not tableMax or lba > tableMax then tableMax = lba end
    end
    local why
    if aligned then
      local where
      if tableMin and lba < tableMin then
        where = string.format('표 최소 %06X 보다 작다', tableMin)
      elseif tableMax and lba > tableMax then
        where = string.format('표 최대 %06X 보다 크다', tableMax)
      else
        where = '표 범위 안이지만 항목이 없다'
      end
      why = string.format('고정 4B %s = 정답 · %s', fxs, where)
      -- 양성 하나: 목표가 표 범위 밖이면 탐색이 표 끝을 한 칸 넘어 읽는다.
      -- 결과는 miss 로 옳다 (인계서 §5-2).  상한을 물리면 없어진다.
      if not byLba[readLba] then
        why = why .. string.format(' (동적 %06X 는 표 밖 -- 양성, §5-2)', readLba)
      end
    elseif shifted then
      why = string.format('★ 고정 4B %s = 정답이 한 칸 밀림 (%s)'
                          .. ' -> 포인터 세운 뒤 첫 읽기가 더미다', fxs, ws)
    else
      why = string.format('고정 4B %s · 기대 %s -> 둘 다 아니다', fxs, ws)
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
  emu.log(string.format('SUB 0.5.45 #%d  BUILD $%02X (기대 $1B)  st $%02X  lba %06X  %d단계',
    voices, slot[12], status, lba, slot[11]))
  emu.log('            ' .. verdict)

  -- ★ 이 음성을 읽던 그 순간에 표가 살아 있었는가.  이것이 0.5.45 의 요점이다.
  do
    local bad = tableBad()
    if bad == 0 then
      emu.log(string.format('            표 살아있음 (앞 %d B 일치)', CHECK_BYTES))
    else
      local g = {}
      for i = 1, 9 do g[#g + 1] = string.format('%02X', emu.read(AC_INDEX + i - 1, AC) or 0) end
      emu.log(string.format(
        '            ★ 표가 깨져 있다 -- %d/%d B 불일치 · 지금 값 %s',
        bad, CHECK_BYTES, table.concat(g, ' ')))
      emu.log('              => BIOS 가 FF 를 읽은 것은 정상이다.  자리 문제다')
    end
  end

  -- 다음 음성을 위해 슬롯을 지운다 (안 지우면 직전 값이 남아 오판한다)
  for i = 0, 12 do emu.write(AC_SLOT + i, 0, AC) end

  if voices % 10 == 0 then
    emu.log(string.format('SUB 0.5.45 === %d 음성 · OK %d · 오답 %d · miss %d · 훅없음 %d',
                          voices, okN, badN, missN, silentN))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close() end
  emu.log(string.format(
    'SUB 0.5.45 끝 -- 음성 %d · OK %d · 오답 %d · miss(정상) %d · 훅없음 %d',
    voices, okN, badN, missN, silentN))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.45-table-integrity armed')
emu.log('  ★ BIOS 는 0.4.6.27 (BUILD $1B) · CUE 는 0.4.6.22 것 그대로')
emu.log('  ★ 자막은 안 뜬다.  이 판은 조회만 켠 관측용이다')
emu.log('  판정: OK = 네이티브가 찾은 키 == 진짜 키')
emu.log('  로그: ' .. OUT)
