-- PROBE CD읽기 0.1.1 -- 그 화면이 읽는 **절대 섹터**를 잡는다
--
-- 0.1.0 이 왜 틀렸나
-- ---------------------------------------------------------------------------
-- $E009 진입 시점에 $FD/$FE 를 섹터로, $FF 를 뱅크로 읽었다.  둘 다 틀렸다.
-- BIOS 코드를 떠서 규약을 확인했다:
--
--     $EC05 CD_READ 본체
--       $EC08  JSR $F309     <- $F8..$FF 8 바이트를 $2260 에 통째로 보관
--       $EC13  JSR $F104     <- ★ 여기서 상대 섹터에 CD_BASE 를 더한다
--       $EC1D  LDA $FF       <- $FF 는 **모드** (0/1/2/FE/FF).  뱅크가 아니다
--       $EC35  LDA $F8       <- $F8 은 섹터 수
--
--     $F104:
--       LDA $FE / ADC $2276,Y / STA $FE
--       LDA $FD / ADC $2275,Y / STA $FD
--       LDA $FC / ADC $2274,Y / STA $FC
--
--   즉 섹터는 **$FC/$FD/$FE 3 바이트**(상위→하위)이고, $2274~$2276 이 CD_BASE 다.
--   `$F104` 가 끝난 **직후**에는 $FC/$FD/$FE 에 **절대 LBA** 가 들어 있다.
--
-- 그래서 이 판은 `$F123`(=$F104 의 RTS) 에 훅을 건다.  거기서 읽으면 변환이
-- 이미 끝나 있어 base 를 따로 알 필요가 없다.
--
-- 무엇을 대조하나
-- ---------------------------------------------------------------------------
-- 우리가 Track 02 에서 건드린 파일 섹터: **250 · 253 · 254 · 255 · 258**
-- (0.4.5.2 기준.  0.2.26 도 같은 대역이다 -- 공통 6구간이 거기 있다)
--
-- 쇼핑 목록이 뜰 때 그 섹터를 읽으면 충돌 확정이다.  화면에도 실시간으로
-- "★겹침" 이 뜬다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   일본 원판이든 우리 빌드든 상관없다 (BIOS 규약은 같다).
--   상점 앞에서 켜고 -> 쇼핑하기 -> 목록이 뜨면 정지.
--   출력: C:\snatcher\dump\probe_cd_reads_0_1_1.tsv

local OUT = "C:\\snatcher\\dump\\probe_cd_reads_0_1_1.tsv"
local mem = emu.memType.pceMemory

local AFTER_BASE_ADD = 0xF123   -- $F104 의 RTS.  여기서 $FC/$FD/$FE 가 절대 LBA
local CD_READ = 0xE009
local ZP = 0x2000
local STACK = 0x2100

-- 우리가 Track 02 에서 바꾼 파일 섹터
local OURS = { [250] = true, [253] = true, [254] = true, [255] = true, [258] = true }

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tlba\tcount\tmode\tcaller\t겹침\n")

local frame, reads, overlaps, dirty = 0, 0, 0, false
local pending = nil

local function byte(a) return emu.read(a, mem) or 0 end

local function caller()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return 0 end
  local sp = s["cpu.sp"] or 0
  return (byte(STACK + ((sp + 3) % 256)) * 256
          + byte(STACK + ((sp + 2) % 256)) + 1) % 0x10000
end

-- $F104 가 끝난 직후: $FC/$FD/$FE = 절대 LBA
emu.addMemoryCallback(function()
  local lba = byte(ZP + 0xFC) * 65536 + byte(ZP + 0xFD) * 256 + byte(ZP + 0xFE)
  local count = byte(ZP + 0xF8)
  if count == 0 then count = 1 end
  local hit = nil
  for s = lba, lba + count - 1 do
    if OURS[s] then hit = s break end
  end
  pending = { lba = lba, count = count, mode = byte(ZP + 0xFF), hit = hit }
  reads = reads + 1
  if hit then overlaps = overlaps + 1 end
  file:write(string.format("READ\t%d\t%06X\t%02X\t%02X\t%04X\t%s\n",
    frame, lba, count, pending.mode, caller(),
    hit and ("★겹침 섹터" .. hit) or ""))
  dirty = true
end, emu.callbackType.exec, AFTER_BASE_ADD, AFTER_BASE_ADD, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("CD 읽기 %d 건 · ★겹침 %d", reads, overlaps),
    overlaps > 0 and 0xFF6060 or 0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, "쇼핑하기 -> 목록 뜨면 정지", 0xFFFF80, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("\n-- CD 읽기 %d 건 · 우리 섹터와 겹친 것 %d 건\n", reads, overlaps))
  file:write("-- 우리가 바꾼 Track 02 파일 섹터: 250 253 254 255 258\n")
  if reads == 0 then
    file:write("-- panjeong bulga: CD read 0 gon = nothing measured\n")
    file:write("--   savestate ro deuleogass geona, geu gugane CD jeobgeuni eopseossda\n")
    file:write("--   POWER CYCLE ro sijakhamyeon buting ttae susip geoni jjikhyeoya jeongsang\n")
    file:write("--   geuraedo 0 imyeon hook($F123)i jalmot geollin geosida\n")
  elseif overlaps > 0 then
    file:write("-- 판정: ★ 그 화면이 우리가 고친 섹터를 읽는다.  충돌 확정\n")
  else
    file:write("-- 판정: 겹치지 않는다.  Track 02 수정과 무관 -> Track 24/다른 경로\n")
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE CD읽기 0.1.1 -- $F104 직후에서 절대 LBA 를 읽는다")
emu.log("  화면의 '★겹침' 이 0 이 아니면 우리가 고친 섹터를 그 화면이 읽는 것")
emu.log("  출력: " .. OUT)
