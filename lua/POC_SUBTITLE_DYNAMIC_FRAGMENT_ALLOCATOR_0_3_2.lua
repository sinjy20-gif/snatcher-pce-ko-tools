-- Dynamic subtitle VRAM allocator POC 0.3.2 -- preserve current keyed renderer.
--
-- 0.3.1 의 BAT+SATB allocator 는 그대로 사용하되, 디스크가 Track24에서 올린
-- 현재 자막 헬퍼/렌더러를 로컬 bin 으로 통째 교체하지 않는다.  VRAM 주소를 담은
-- 피연산자 네 바이트만 수정하므로 기존 selector와 자막 팩 오프셋이 보존된다.

SUB_ALLOCATOR_VERSION = '0.3.2'
SUB_ALLOCATOR_INPLACE_IMAGES = true
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
