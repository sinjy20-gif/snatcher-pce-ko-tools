-- SUB 0.5.96 -- 반환 직전에 MARR / MAWR 을 되돌려 본다 (개입 시험 · 0.4.6.48 전용)
--
-- 0.5.94 가 찾은 것
-- ---------------------------------------------------------------------------
-- ```
-- 4693f  우리 엔진이 $01 MARR 을 건드림
--        안 되돌림 :  진입 $0000 -> 반환 $7900
--        반환 뒤 첫 게임 VDC 접근  pc $60AC
-- 6907f  $00 MAWR   진입 $1000 -> 반환 $7D40
-- 우리가 건드리는 레지스터는 MARR / MAWR / VWR 셋뿐이다 (스크롤·창·CR 안 건드림)
-- ```
--
-- MARR 은 **VRAM 읽기 주소**다.  오늘 한 측정은 전부 쓰기만 봤기 때문에 안 보였다.
-- 게임 `$60Ax` 는 MARR 로 읽고 MAWR 로 쓰는 VRAM->VRAM 복사 루틴으로 보인다
-- (0.5.82 가 잡은 writer $60AE/60B2/60B6/60BA 와 같은 자리).  우리가 MARR 을
-- $7900 에 세워두고 나오면 게임이 **엉뚱한 원본에서 읽어다** 목적지에 쓴다.
--
-- 그러면 오늘 안 맞던 게 전부 설명된다.
-- ```
-- 우리 대역 VRAM 은 멀쩡      -> 우리가 그걸 원본으로 읽혔을 뿐이니까
-- 복원/생략/검은칠 결과가 다 달랐다 -> 복사 원본 내용이 그때마다 달랐으니까
-- "게임이 다시 안 그리는 자리" -> 실은 그렸는데 잘못된 것을 그렸다
-- ```
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- 헬퍼/렌더러가 **RTS 하기 직전**에 VDC 포트로 두 값을 되돌린다.
--
-- ```
-- MARR = $0000   (0.5.94 가 잰 진입값)
-- MAWR = $1000   (0.5.85 census 2,685/2,685 회 진입값)
-- 레지스터 선택 = $02 (VWR)   진입 때와 같게
-- ```
--
-- ★ 게임 코드는 한 바이트도 안 고친다.  VRAM/RAM/AC/state 에도 안 쓴다.
--   건드리는 것은 VDC 주소 레지스터 두 개뿐이고, 그것도 **원래 값으로** 돌린다.
-- ★ 화면에 아무것도 그리지 않는다.
--
-- MODE 로 무엇을 되돌릴지 고른다.  한 번에 하나씩 보면 원인이 갈린다.
-- ```
-- 'marr'  MARR 만          <- ★ 먼저 이것부터
-- 'mawr'  MAWR 만
-- 'both'  둘 다
-- ```
--
--   BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA -> 챕터1 까지
--
-- 판정 :  챕터1 화면이 멀쩡하면 -> 원인 확정.  네이티브 14 B 로 옮기면 끝난다
--
-- 산출물  C:/snatcher/dump/marr_0_5_96_<시각>.tsv

local MODE = 'both'        -- ★ 'marr' / 'mawr' / 'both'

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/marr_0_5_96_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

-- 0.4.6.48 실물에서 확인한 반환 지점 (디스크의 헬퍼/렌더러 이미지)
local SITES = { 0x5BEB, 0x5C3F, 0x5CB6 }      -- save 끝 · restore 끝 · 렌더러 push 끝
local SLOT  = 0x5B80

local MARR_VALUE = 0x0000
local MAWR_VALUE = 0x1000

local frame, hits = 0, 0
local perSite = {}
local function rd(a) return emu.read(a, MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end

-- VDC 포트에 직접 쓴다.  CPU 가 ST0/ST1/ST2 로 하는 것과 같은 순서다.
local function setReg(r, value)
  emu.write(0x0000, r, MEM)
  emu.write(0x0002, value & 0xFF, MEM)
  emu.write(0x0003, (value >> 8) & 0xFF, MEM)
end

local function fix()
  if MODE == 'marr' or MODE == 'both' then setReg(0x01, MARR_VALUE) end
  if MODE == 'mawr' or MODE == 'both' then setReg(0x00, MAWR_VALUE) end
  emu.write(0x0000, 0x02, MEM)                 -- 진입 때와 같게 VWR 선택
end

for _, site in ipairs(SITES) do
  emu.addMemoryCallback(function(address)
    -- ★ 0.5.95 의 결함: 헬퍼 꼬리는 `STZ $5B80 / RTS` 라 RTS 시점엔 매직 'S' 가
    --   이미 지워져 있다.  그래서 매직으로 거르면 **헬퍼 반환이 통째로 빠진다.**
    --   MARR 을 $7900 으로 세우는 것은 헬퍼의 save/wipe 이므로 정작 필요한
    --   자리가 빠졌었다.  이제 그 자리가 진짜 RTS 인지로만 거른다.
    if rd(address) ~= 0x60 then return end
    fix()
    hits = hits + 1
    perSite[address] = (perSite[address] or 0) + 1
    -- ★ 자리별 첫 적중은 무조건 찍는다.  전에는 필터가 TSV 까지 막아서
    --   `$5C3F`(복원 끝) 가 실제로 걸렸는지 확인할 방법이 없었다.
    if perSite[address] == 1 or hits <= 8 or hits % 400 == 0 then
      say('0.5.96 · %df  $%04X 반환 직전 복원 (그 자리 %d 번째 · 전체 %d · %s)',
          frame, address, perSite[address], hits, MODE)
      rec('fix', 'site=$%04X site_n=%d total=%d mode=%s',
          address, perSite[address], hits, MODE)
    end
  end, emu.callbackType.exec, site, site, CPU, MEM)
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 3600 == 0 then rec('tally', 'fixes=%d', hits) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local t = {}
  for a, c in pairs(perSite) do t[#t + 1] = string.format('$%04X x%d', a, c) end
  say('0.5.96 끝 -- 복원 %d 회 (%s) · 자리별 %s', hits, MODE, table.concat(t, ' · '))
  rec('end', 'fixes=%d mode=%s', hits, MODE)
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.96-restore-marr-fixed armed [%s] -- 게임 코드 무수정 · 화면 무간섭', MODE)
say('  반환 직전에 MARR=$%04X / MAWR=$%04X 를 되돌린다 (0.5.94 · 0.5.85 실측값)',
    MARR_VALUE, MAWR_VALUE)
say('  판정 : 챕터1 화면이 멀쩡한가')
say('  덤프 : ' .. PATH)
