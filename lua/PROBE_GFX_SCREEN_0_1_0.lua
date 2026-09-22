-- 전면 그래픽 화면을 통째로 뜬다.  0.1.0  (그래픽 한글화 착수용)
--
-- ★ 순수 관측.  아무것도 안 쓰고 화면에도 안 그린다.
--
-- 왜
-- --
-- 면책 화면("<원문 14자>…")은 **텍스트 경로를 안 탄다.**
--
--     마스터 적중        0 행 (`<원문 6자>` 은 다른 문장에서만 나온다)
--     ui_text.tsv        0 행
--     런타임 텍스트 관측  0 건  (dump/runtime_text_audit_raw_v020.tsv)
--
-- 즉 글자처럼 보여도 그림이다.  그러면 마스터로는 못 바꾸고, 타일을 갈아야 한다.
-- 그 첫 단계로 화면을 이루는 것을 전부 뜬다.
--
-- 무엇을 뜨나 -- 전면 이미지는 셋이 다 있어야 복원된다
-- --------------------------------------------------
--     VRAM 64 KB   패턴(타일 그림) + BAT(어느 칸에 어느 타일)
--     CRAM 512 B   팔레트.  이게 없으면 파랑/흰색을 모른다
--
-- ⚠ 세이브스테이트로 들어가지 말 것 -- 이 화면은 부팅 직후에 뜬다.  걸어갈
--   필요가 없으므로 스테이트를 쓸 이유도 없다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에서 게임을 **부팅**한다
--   2) 면책 화면이 떠 있는 상태에서
--   3) ★ Stop 을 누른다  ->  그 순간의 VRAM + CRAM 이 저장된다
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS 가 켜져 있어야 한다
--
-- 산출물  C:/snatcher/dump/gfx_<시각>.vram.bin   64 KB
--         C:/snatcher/dump/gfx_<시각>.cram.bin   512 B
--
-- 다음   python tools/render_gfx_screen.py dump/gfx_<시각>
--        -> PNG 로 그려서 어느 타일이 글자인지 본다

local VRAM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam

local VRAM_BYTES = 0x10000
local CRAM_BYTES = 0x200

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local BASE = "C:/snatcher/dump/gfx_" .. stamp

local function dump(path, memType, count)
  local f = io.open(path, "wb")
  if f == nil then emu.log("파일 열기 실패: " .. path); return false end
  local chunk = {}
  for a = 0, count - 1 do
    local b = emu.read(a, memType)
    chunk[#chunk + 1] = string.char(b or 0)
    if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then f:write(table.concat(chunk)) end
  f:close()
  emu.log(string.format("%d B -> %s", count, path))
  return true
end

local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  -- 심박은 **화면이 서 있는지**만 본다.  BAT 이 안 변하면 정지 화면이다.
  if frame % 180 == 0 then
    emu.log(string.format("프레임 %d -- 면책 화면이 떠 있으면 Stop", frame))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  dump(BASE .. ".vram.bin", VRAM, VRAM_BYTES)
  dump(BASE .. ".cram.bin", CRAM, CRAM_BYTES)
  emu.log("다음:  python tools/render_gfx_screen.py " .. BASE)
end, emu.eventType.scriptEnded)

emu.log("PROBE 그래픽 화면 0.1.0 -- 면책 화면이 뜬 상태에서 Stop 을 눌러라")
emu.log("  " .. BASE .. ".{vram,cram}.bin")
