-- 一键执行：清洗知识条目中的“坏码点”（2026-10-29）
-- ---------------------------------------------------------------------------
-- 背景：线上坐席台（Flutter Web，CanvasKit 渲染）在「推荐回复」「参考来源」里
-- 显示大量方框（豆腐块 □）。根因是 knowledge_entry / message 里的某些字符是
-- “死码点”——任何随包字体都不含其字形，CanvasKit 就渲染成方框：
--   * U+FFFD          替换符（UTF-8 断在坏字节边界上产生）
--   * E000–F8FF       私有区 PUA（图标字体/富文本复制而来，BMP）
--   * F0000–FFFFD     私有区 PUA（补充平面，少见）
--   * C0/C1 控制符    0x00–0x1F（保留 制表/换行/回车）、0x7F–0x9F
-- 本脚本“只删不改”：仅剔除上述码点，正常中文/英文/数字/标点/emoji 一律不动。
-- 幂等：清洗后的干净行不会被再次改动（带 WHERE 命中判断），可重复执行。
-- 配套：Go 侧新增 internal/ai/sanitize.go，LLM 出口与知识入库前已做同样清洗，
--       防止新数据再次引入坏码点。
-- 注意：这是对线上数据的写操作。请先在只读副本或低峰期执行；执行前用下方
--       “诊断”查询评估影响面。仅删除类改动，无数据丢失风险。

\set ON_ERROR_STOP on

-- ============ 1. 诊断：执行前评估影响面（先跑这条，再决定是否 UPDATE） ==========
-- 命中任意坏码点即计数。
select 'knowledge_entry' as tbl, count(*) as affected
from knowledge_entry
where title ~ '[' || chr(1)||'-'||chr(8) || chr(11)||'-'||chr(31)
                          || chr(0x7F)||'-'||chr(0x9F)
                          || chr(0xE000)||'-'||chr(0xF8FF)
                          || chr(0xFFFD) || ']'
   or content ~ '[' || chr(1)||'-'||chr(8) || chr(11)||'-'||chr(31)
                            || chr(0x7F)||'-'||chr(0x9F)
                            || chr(0xE000)||'-'||chr(0xF8FF)
                            || chr(0xFFFD) || ']'
   or coalesce(question_examples,'') ~ '[' || chr(1)||'-'||chr(8)
                                              || chr(11)||'-'||chr(31)
                                              || chr(0x7F)||'-'||chr(0x9F)
                                              || chr(0xE000)||'-'||chr(0xF8FF)
                                              || chr(0xFFFD) || ']';

-- 抽样看具体是哪些字符（把命中字符转成 U+XXXX 便于定位，而非盲猜）：
select id,
       regexp_matches(coalesce(title, ''), '[' || chr(0xE000)||'-'||chr(0xF8FF)||'']')          as pua_in_title,
       regexp_matches(coalesce(content,''), '[\uFFFD]')                                        as fffd_in_content,
       regexp_matches(coalesce(content,''), '[' || chr(0xE000)||'-'||chr(0xF8FF)||'']')         as pua_in_content
from knowledge_entry
where coalesce(content,'') ~ '[' || chr(0xE000)||'-'||chr(0xF8FF)||chr(0xFFFD)||']'
limit 20;

-- ============ 2. 清洗：knowledge_entry（主污染源，喂给 LLM 与「参考来源」） ==========
do $$
declare
  bad text := '[' || chr(1)||'-'||chr(8)          -- C0（删 0x01–0x08）
              || chr(11)||'-'||chr(31)            -- C0（删 0x0B–0x1F；保留 9/10/13）
              || chr(0x7F)||'-'||chr(0x9F)        -- C1
              || chr(0xE000)||'-'||chr(0xF8FF)    -- PUA-BMP
              || chr(0xFFFD)                      -- 替换符
              || ']';
begin
  update knowledge_entry
  set  title             = regexp_replace(title,             bad, '', 'g'),
       content           = regexp_replace(content,           bad, '', 'g'),
       question_examples = regexp_replace(coalesce(question_examples,''), bad, '', 'g')
  where title ~ bad
     or content ~ bad
     or coalesce(question_examples,'') ~ bad;
end
$$;

-- 补充平面 PUA-A（F0000–FFFFD）很少出现；如诊断里有命中的企业，再放开执行：
-- do $$
-- declare
--   bad text := '[' || chr(0xF0000)||'-'||chr(0xFFFFD) || ']';
-- begin
--   update knowledge_entry
--   set  content = regexp_replace(coalesce(content,''), bad, '', 'g')
--   where coalesce(content,'') ~ bad;
-- end
-- $$;

-- ============ 3.（可选）清洗：message.content（历史会话，改动面更大） ==========
-- 默认已注释。若「推荐回复」是落在历史消息里显示方框，再放开这段。
-- 仅删除类改动，可重复执行。
-- do $$
-- declare
--   bad text := '[' || chr(1)||'-'||chr(8)
--               || chr(11)||'-'||chr(31)
--               || chr(0x7F)||'-'||chr(0x9F)
--               || chr(0xE000)||'-'||chr(0xF8FF)
--               || chr(0xFFFD) || ']';
-- begin
--   update message
--   set content = regexp_replace(coalesce(content,''), bad, '', 'g')
--   where coalesce(content,'') ~ bad;
-- end
-- $$;

-- ============ 4. 校验：执行后应全部为 0 ==========
select 'knowledge_entry' as tbl, count(*) as remaining
from knowledge_entry
where title ~ '[' || chr(0xE000)||'-'||chr(0xF8FF)||chr(0xFFFD)||']'
   or content ~ '[' || chr(0xE000)||'-'||chr(0xF8FF)||chr(0xFFFD)||']'
   or coalesce(question_examples,'') ~ '[' || chr(0xE000)||'-'||chr(0xF8FF)||chr(0xFFFD)||']';

-- 若第 3 段执行过，再核对 message：
-- select 'message' as tbl, count(*) as remaining from message
-- where coalesce(content,'') ~ '[' || chr(0xE000)||'-'||chr(0xF8FF)||chr(0xFFFD)||']';

\echo 完成：知识条目坏码点已清洗（仅删除，正常文字与 emoji 保持不变）
