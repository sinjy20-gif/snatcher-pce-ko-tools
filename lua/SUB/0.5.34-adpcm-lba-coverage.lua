-- SUB 0.5.34 -- ADPCM 음성 LBA 의 커버리지와 오차율을 자동 집계한다
--
-- 0.5.33 이 확정한 것
-- ---------------------------------------------------------------------------
-- 음성의 시작 LBA 는 **평범한 RAM** 에 있다.  SCSI CDB 의 LBA 칸이다.
--
--     $224C  opcode ($08 = READ(6))
--     $224D/$224E/$224F   24-bit LBA (MSB first)   <- 시작 섹터
--     $2250  전송 섹터 수
--
-- 그리고 수집기가 적어 온 `sector`(= cdrom.scsi.sector)는 **끝 섹터**였다.
--
--     scsi = first + ceil(audio_length / 2048)      VOICE #2~#5 에서 4/4 정확
--
--     VOICE #2  003057 + 20 = 00306B   len $9F90 -> 20 섹터
--     VOICE #3  00306B + 13 = 003078   len $6794 -> 13 섹터
--     VOICE #4  003078 + 11 = 003083   len $579D -> 11 섹터
--     VOICE #5  003083 + 26 = 00309D   len $CF9B -> 26 섹터
--
-- 즉 둘은 같은 한 번의 읽기다.  어긋남도 프리페치도 아니었다.
-- 파생한 시작 LBA 로 수집표 1055 행을 채점하면 고유값 1053 · 충돌 2 다.
-- **3 바이트가 902 음성을 갈라낸다.**
--
-- 남은 구멍 -- 이 판이 재는 것
-- ---------------------------------------------------------------------------
-- VOICE #1 만 어긋났다.  gap 2192 프레임(36 초) 짜리 **남은 값**이었다.
-- 즉 어떤 음성은 AD_TRANS 를 안 거치거나 훨씬 앞서 적재된다.
--
--     -> 그 빈도가 얼마인가.  그리고 CD_READ 를 같이 잡으면 메워지는가.
--
-- 두 경로를 다 잡는다 (정적으로 확정)
-- ---------------------------------------------------------------------------
-- ```
-- AD_TRANS $E033 -> $F393        $F3C8  JSR $E900     명령 발행
-- CD_READ  $E009 -> $FF10 -> $EC05   $EC4E  JSR $E900     명령 발행
-- ```
-- 둘 다 `$F0EE` 로 CDB 를 지우고 `$F327` 로 같은 자리에 LBA 를 넣는다.
-- 발행 직전에 훅을 걸면 **어느 경로였는지까지** 공짜로 붙는다.
-- ($FF10 은 이 KO 빌드의 래퍼다.  본체는 $EC05 이므로 그쪽을 잡는다)
--
-- ★ 자기 채점 -- 표가 필요 없다
-- ---------------------------------------------------------------------------
-- 명령 자체가 섹터 수를 들고 있다 ($2250).  그리고 재생 시작 때 우리는 그 음성의
-- 길이를 안다.  그러면 표 없이 그 자리에서 채점된다.
--
--     기대 섹터 수 = ceil(adpcmLength / 2048)
--     일치하는 명령 = 그 음성을 실어 온 명령
--
-- 최근 명령 16 개를 링으로 들고 있다가 뒤에서부터 찾는다.  **몇 번째 뒤에서**
-- 찾았는지도 같이 적는다 -- 0 이면 직전 명령이 곧 그 음성이라는 뜻이다.
--
-- 집계 (스크립트 Stop 때 요약 파일)
-- ---------------------------------------------------------------------------
--     음성 수 · AD_TRANS 로 맞은 수 · CD_READ 로 맞은 수 · 못 맞춘 수
--     거리 분포 (직전 명령이 몇 %인가)
--     lba + count == scsi 가 성립한 비율
--     못 맞춘 음성의 상세 (길이 · 기대 섹터 수 · 링 안의 후보들)
--
-- 읽기 전용이다.  ADPCM 포트를 건드리지 않고 아무 주소에도 쓰지 않는다.
-- 화면에 아무것도 그리지 않는다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다 (0.4.93 금지).
--     CUE  build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue
--
-- ★ 수십 음성 장기 주행용이다.  오래 돌릴수록 집계가 단단해진다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local APCM = emu.memType.pceAdpcmRam

local AD_TRANS_ISSUE = 0xF3C8     -- AD_TRANS 안의 JSR $E900
local CD_READ_ISSUE  = 0xEC4E     -- CD_READ($EC05) 안의 JSR $E900
local CDB_OP    = 0x224C
local CDB_LBA   = 0x224D          -- $224D/$224E/$224F
local CDB_COUNT = 0x2250

local RING = 16                   -- 최근 명령 보관 수
local SECTOR = 2048

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT_T = 'C:/snatcher/dump/adpcm_lba_cov_0_5_34_' .. STAMP .. '.tsv'
local OUT_S = 'C:/snatcher/dump/adpcm_lba_cov_summary_0_5_34_' .. STAMP .. '.txt'

local out = io.open(OUT_T, 'w')
if out then
  out:write('voice\tframe\tkey\tlen\twant_sectors\tmatched\tsource\tdistance\t' ..
            'lba\tcount\tgap\tend_eq_scsi\tscsi\n')
end

local function rb(a) return emu.read(a, MEM) or 0 end
local function lba24(b) return (rb(b) << 16) | (rb(b + 1) << 8) | rb(b + 2) end

local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function num(s, k)
  local v = s and s[k]
  return type(v) == 'number' and math.floor(v) or -1
end

-- ---------------------------------------------------------------------------
-- 명령 링버퍼 -- 두 경로를 한 곳에 모은다
-- ---------------------------------------------------------------------------
local frame = 0
local ring, ringN = {}, 0
local cmdCount = { AD_TRANS = 0, CD_READ = 0 }

local function record(src)
  cmdCount[src] = cmdCount[src] + 1
  ringN = ringN + 1
  ring[(ringN - 1) % RING + 1] = {
    n = ringN, src = src, frame = frame,
    op = rb(CDB_OP), lba = lba24(CDB_LBA), count = rb(CDB_COUNT),
  }
end

emu.addMemoryCallback(function() record('AD_TRANS') end,
  emu.callbackType.exec, AD_TRANS_ISSUE, AD_TRANS_ISSUE, CPU, MEM)
emu.addMemoryCallback(function() record('CD_READ') end,
  emu.callbackType.exec, CD_READ_ISSUE, CD_READ_ISSUE, CPU, MEM)

-- ---------------------------------------------------------------------------
-- 집계
-- ---------------------------------------------------------------------------
local voices = 0
local hit = { AD_TRANS = 0, CD_READ = 0 }
local miss = 0
local distDist = {}          -- 거리 -> 횟수
local endEqScsi, endChecked = 0, 0
local misses = {}            -- 못 맞춘 음성 상세

local function hex6(k)
  return (k:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

local prevPlaying = false

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end

  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not prevPlaying then
    voices = voices + 1

    local ra   = num(s, 'cdrom.adpcm.readAddress')
    local len  = num(s, 'cdrom.adpcm.adpcmLength')
    local rate = num(s, 'cdrom.adpcm.playbackRate') & 0xFF
    local scsi = num(s, 'cdrom.scsi.sector')
    local fin  = (ra + len) & 0xFFFF
    local key  = string.char(fin & 0xFF, (fin >> 8) & 0xFF, rate,
                             emu.read(fin // 4, APCM) or 0,
                             emu.read(fin // 2, APCM) or 0,
                             emu.read((fin * 5) // 8, APCM) or 0)

    local want = (len >= 0) and math.ceil(len / SECTOR) or -1

    -- 링을 최신부터 훑어 섹터 수가 맞는 명령을 찾는다
    local found, dist = nil, -1
    local seen = {}
    for back = 0, math.min(RING, ringN) - 1 do
      local e = ring[(ringN - back - 1) % RING + 1]
      if e and e.n == ringN - back then
        seen[#seen + 1] = e
        if found == nil and e.count == want then found, dist = e, back end
      end
    end

    local endok = '-'
    if found and scsi >= 0 then
      endChecked = endChecked + 1
      if (found.lba + found.count) == scsi then
        endok = '1'; endEqScsi = endEqScsi + 1
      else
        endok = '0'
      end
    end

    if found then
      hit[found.src] = hit[found.src] + 1
      distDist[dist] = (distDist[dist] or 0) + 1
    else
      miss = miss + 1
      if #misses < 20 then
        local cand = {}
        for i = 1, math.min(#seen, 6) do
          cand[#cand + 1] = string.format('%s:%06X/%d', seen[i].src, seen[i].lba, seen[i].count)
        end
        misses[#misses + 1] = string.format(
          'VOICE #%d f%d key %s len $%04X 기대 %d섹터 · 링후보: %s',
          voices, frame, hex6(key), len, want, table.concat(cand, ' '))
      end
    end

    if out then
      out:write(string.format('%d\t%d\t%s\t%04X\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n',
        voices, frame, hex6(key), len, want,
        found and '1' or '0', found and found.src or '-', dist,
        found and string.format('%06X', found.lba) or '-',
        found and tostring(found.count) or '-',
        found and tostring(frame - found.frame) or '-',
        endok, scsi >= 0 and string.format('%06X', scsi) or '??????'))
      out:flush()
    end

    if found then
      emu.log(string.format(
        'SUB 0.5.34 #%d %s · %s %06X/%d섹터 · 뒤로%d · %d프레임 전 · end=scsi %s',
        voices, hex6(key), found.src, found.lba, found.count, dist,
        frame - found.frame, endok))
    else
      emu.log(string.format('SUB 0.5.34 #%d %s · ✗ 못찾음 (기대 %d섹터)',
                            voices, hex6(key), want))
    end

    if voices % 10 == 0 then
      emu.log(string.format('SUB 0.5.34 === %d 음성 · AD_TRANS %d · CD_READ %d · 실패 %d',
                            voices, hit.AD_TRANS, hit.CD_READ, miss))
    end
  end
  prevPlaying = playing
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------------------
-- 요약
-- ---------------------------------------------------------------------------
emu.addEventCallback(function()
  if out then out:close() end
  local f = io.open(OUT_S, 'w')
  if not f then return end
  f:write('SUB 0.5.34 -- ADPCM 음성 LBA 커버리지 집계\n')
  f:write(string.format('프레임 %d · 음성 %d\n', frame, voices))
  f:write(string.format('CD 명령: AD_TRANS %d · CD_READ %d (합 %d)\n\n',
                        cmdCount.AD_TRANS, cmdCount.CD_READ, ringN))

  local ok = hit.AD_TRANS + hit.CD_READ
  f:write('== 커버리지 ==\n')
  f:write(string.format('  AD_TRANS 로 맞음   %d\n', hit.AD_TRANS))
  f:write(string.format('  CD_READ  로 맞음   %d\n', hit.CD_READ))
  f:write(string.format('  못 맞춤            %d\n', miss))
  if voices > 0 then
    f:write(string.format('  적중률             %.1f%% (%d/%d)\n',
                          100 * ok / voices, ok, voices))
  end

  f:write('\n== 거리 분포 (0 = 직전 명령) ==\n')
  local ds = {}
  for d in pairs(distDist) do ds[#ds + 1] = d end
  table.sort(ds)
  for _, d in ipairs(ds) do
    f:write(string.format('  뒤로 %-3d  %d 회%s\n', d, distDist[d],
            d == 0 and '   <- 직전 명령' or ''))
  end

  f:write('\n== lba + count == scsi 성립 여부 ==\n')
  if endChecked > 0 then
    f:write(string.format('  %d/%d (%.1f%%)\n', endEqScsi, endChecked,
                          100 * endEqScsi / endChecked))
    f:write('  이것이 100%% 면 수집표의 sector 는 끝섹터이고,\n')
    f:write('  시작LBA = sector - ceil(len/2048) 로 오프라인 파생이 안전하다.\n')
  else
    f:write('  판정 불가 (scsi 상태 키 없음)\n')
  end

  if #misses > 0 then
    f:write('\n== 못 맞춘 음성 (최대 20) ==\n')
    for _, l in ipairs(misses) do f:write('  ' .. l .. '\n') end
    f:write('\n  ★★ 여기 있는 것이 곧 실패는 아니다.\n')
    f:write('     **효과음(has_subtitle=0)은 여기 나오는 것이 정상이다.**\n')
    f:write('     효과음은 재생 직전에 적재하지 않고 미리 올려두므로 직전 명령이 없다.\n')
    f:write('     그리고 팩에 키가 없으므로 네이티브 조회가 fail-closed 한다 (§9.1-5).\n')
    f:write('     0.5.33 주행에서도 유일한 miss 가 has_subtitle=0 인 효과음이었고,\n')
    f:write('     자막 대상 음성은 4/4 정확했다.\n\n')
    f:write('     진짜 지표는 **자막 대상 음성만의 실패율**이다.  위 key 를\n')
    f:write('     snatcher_tool/translation/voice_console_keys.tsv 와 조인해\n')
    f:write('     has_subtitle=1 인 것만 세어야 한다 (런타임에는 알 수 없다).\n\n')
    f:write('  has_subtitle=1 인데도 못 맞췄다면 그때가 진짜 문제다:\n')
    f:write('    링에 후보가 있는데 섹터 수가 다르면 -> 여러 명령으로 쪼개 읽는다는 뜻\n')
    f:write('    링이 비었으면 -> 훨씬 앞서 적재된다.  RING 을 키워 다시 잰다\n')
  end
  f:close()
  emu.log('SUB 0.5.34 요약: ' .. OUT_S)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.34-adpcm-lba-coverage armed -- 읽기 전용')
emu.log('  AD_TRANS $F3C8 · CD_READ $EC4E 두 발행 지점을 다 잡는다')
emu.log('  ★ 채점: 명령의 섹터 수($2250) == ceil(음성길이/2048) 이면 그 명령이다')
emu.log('  ★ 수십 음성 장기 주행용.  10 음성마다 중간 집계를 찍는다')
emu.log('  ★ 끝나면 Lua 창 Stop -- 그때 요약이 닫힌다')
emu.log('  로그: ' .. OUT_T)
emu.log('  요약: ' .. OUT_S)
