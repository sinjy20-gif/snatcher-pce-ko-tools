-- SUB 0.5.18 -- 창에 "렌더만" 남기면 정상이 되는가 (§6 이후 세계의 예행)
--
-- 여기까지 (둘 다 깨끗한 Power Cycle)
-- ---------------------------------------------------------------------------
--     0.5.16  SEI 전체 off        -> 둘 다 소멸.  "완벽히 정상"
--     0.5.17  복사만 Lua 로 이관   -> 번쩍임 남음
--
-- 즉 창 가설은 확정이고, **창의 일부만 비워서는 안 된다.**
-- 남은 일(helper save/restore + 렌더)만으로도 분할을 놓치기에 충분하다.
--
-- 이 판이 묻는 것
-- ---------------------------------------------------------------------------
-- §6 allocator 가 들어오면 **백업/복원이 통째로 사라진다** (안전한 자리를 고르면
-- 지킬 게 없다).  그러면 창에는 복사와 렌더만 남는다.  복사도 없앨 수 있다면
-- 남는 것은 렌더뿐이다.
--
--     그 세계가 정상인가?
--
--     정상이면   §6 + 복사 수정으로 끝.  로드맵이 확정된다
--     남으면     렌더 자체도 쪼개야 한다 (VBlank 분할).  작업이 하나 더 는다
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
--   1) 복사 둘을 Lua 로 이관 (0.5.17 과 동일)
--        $7F5B JSR copy_helper    -> NOP x3
--        $7F6F JSR copy_renderer  -> NOP x3
--   2) 헬퍼의 save / restore **본문**을 건너뛴다.  꼬리는 반드시 실행한다
--        save    +$008 -> JMP $5BBF   (set_ac(다음 슬롯) + status=1 은 남긴다)
--        restore +$067 -> JMP $5C27   (JSR wipe_sprites 는 남기고 그 뒤부터, status=2 유지)
--
-- ★ 0.5.6 의 교훈: **경로를 건너뛰되 상태 플래그는 반드시 써야 한다.**
--   안 그러면 상주부가 플래그를 기다리다 멈춘다.  그래서 꼬리로 점프한다.
-- ★ 헬퍼는 매번 AC 에서 새로 복사되므로 **AC 이미지($1F1C00)를 패치**한다.
--
-- 부작용 (예정된 것)
--     백업도 복원도 안 하므로 $1600 의 원래 배경이 안 돌아온다.
--     국장실은 0.4.91 실측으로 BG 가 $1600 을 안 쓰므로(겹침 0) 눈에 안 띈다.
--     판정은 오직 "뒷화면 소환 / 떨림" 두 가지만 본다.
--
-- ★ 오염 감지: 0.5.16 의 SEI->NOP 이 남아 있으면 판정 무효다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.17-reviewed.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local AC = emu.memType.pceArcadeCardRam

local ENGINE = 0x5B80
local HELPER_AC = 0x1F1C00
local NOP = 0xEA

-- 1) 상주부의 복사 두 곳
local SITES = {
  helper   = { at = 0x7F5B, orig = { 0x20, 0xA2, 0x7F }, src = 0x1F1C00, len = 448 },
  renderer = { at = 0x7F6F, orig = { 0x20, 0xBB, 0x7F }, src = 0x1F1F00, len = 671 },
}

-- 2) 헬퍼 AC 이미지의 두 지점 (subtitle_vram_helper.json + 디스어셈)
--    JMP 대상은 각 경로의 꼬리다.  상태 플래그를 반드시 지나게 한다.
local SKIPS = {
  { off = 0x008, want = { 0x4C, 0xBF, 0x5B }, name = 'save 본문 건너뜀 -> $5BBF' },
  { off = 0x067, want = { 0x4C, 0x27, 0x5C }, name = 'restore 본문 건너뜀 -> $5C27' },
}

local patched, copies, skipped = 0, 0, 0

-- 교차 오염 가드
local SEI_AT = 0x7F4A
local dirty = false
local function checkForeign()
  if dirty then return end
  if (emu.read(SEI_AT, MEM) or -1) == NOP then
    dirty = true
    emu.log('SUB 0.5.18 ★★ 오염 감지 -- $7F4A 가 NOP 이다 (0.5.16 잔재)')
    emu.log('   Power Cycle 하고 이 파일만 다시 로드할 것.  지금 판정은 무효다')
  end
end

local function doCopy(s)
  for i = 0, s.len - 1 do
    emu.write(ENGINE + i, emu.read(s.src + i, AC) or 0, MEM)
  end
  copies = copies + 1
end

for _, name in ipairs({ 'helper', 'renderer' }) do
  local s = SITES[name]
  emu.addMemoryCallback(function() doCopy(s) end,
    emu.callbackType.exec, s.at, s.at, CPU, MEM)
end

emu.addEventCallback(function()
  checkForeign()

  -- 상주부의 JSR 두 곳을 NOP 으로
  for _, name in ipairs({ 'helper', 'renderer' }) do
    local s = SITES[name]
    local isOrig = true
    for i = 1, 3 do
      if (emu.read(s.at + i - 1, MEM) or -1) ~= s.orig[i] then isOrig = false; break end
    end
    if isOrig then
      for i = 1, 3 do emu.write(s.at + i - 1, NOP, MEM) end
      patched = patched + 1
      if patched <= 4 then
        emu.log(string.format('SUB 0.5.18 ★ OFFLOAD %s · $%04X JSR -> NOP x3 (%d B)',
                              name, s.at, s.len))
      end
    end
  end

  -- 헬퍼 AC 이미지에 JMP 를 박는다 (매번 새로 복사되므로 원본을 고쳐야 한다)
  for _, k in ipairs(SKIPS) do
    local at = HELPER_AC + k.off
    local same = true
    for i = 1, 3 do
      if (emu.read(at + i - 1, AC) or -1) ~= k.want[i] then same = false; break end
    end
    if not same then
      for i = 1, 3 do emu.write(at + i - 1, k.want[i], AC) end
      skipped = skipped + 1
      if skipped <= 4 or skipped % 40 == 0 then
        emu.log(string.format('SUB 0.5.18 ★ SKIP #%d · AC $%06X · %s',
                              skipped, at, k.name))
      end
    end
  end

  emu.drawString(4, 84, string.format(
    '0.5.18 창=렌더만 · offload %d · Lua복사 %d · skip패치 %d%s',
    patched, copies, skipped, dirty and ' · ★오염 판정무효' or ''),
    dirty and 0x4040FF or ((patched > 0 and skipped > 0) and 0x80FF80 or 0x4040FF),
    0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.18-window-render-only armed -- 복사 이관 + save/restore 본문 건너뜀')
emu.log('  창에 남는 것: 게이트 판정 · 매직/상태 검사 · wipe_sprites · 렌더')
emu.log('  ★ 상태 플래그와 wipe 는 유지된다 (0.5.6 처럼 멈추지 않아야 한다)')
emu.log('  ⚠ 배경 복원을 안 하므로 $1600 은 글리프가 남는다.  예정된 부작용')
emu.log('  ★ offload/skip 이 0 이면 판정 불가')
