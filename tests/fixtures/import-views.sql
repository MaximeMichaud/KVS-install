-- A section is a separate dump. In its input @db. is the quoted schema
-- and dot (@word. and @ansi. use unquoted and ANSI quoting). In the
-- expected output those bytes are absent. Every other
-- byte between the markers, including literal text, must survive.
-- @padding@ spans one input chunk, so the two readers can stop in different chunks.

-- case stats
/*!50001 CREATE VIEW `v` AS SELECT
 1 AS `id` */;
DROP VIEW `v`;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id`, @db.`t`.`c` from @db.`t` */;

-- case literal
INSERT INTO ktvs_options VALUES ('NOTE','select `oldsite`.`t`.`id`');
CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW INSERT INTO `oldsite`.`u` VALUES (new.c);
-- Host: localhost    Database: oldsite
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id`, 'see `oldsite`.`t` and ''`oldsite`.`t`''' AS x from @db.`t` */;

-- case mixed
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`oldsite`.`id`, `mysql`.`db`.`User` AS `oldsite`, `x``oldsite`.`y` from (@db.`oldsite` join `mysql`.`db` join `x``oldsite`) */;

-- case aliased
-- keep `v` `oldsite`.`c`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select `oldsite`.`c` from @db.`t` `oldsite` */;

-- case derived
-- keep `v` `oldsite`.`id`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select `oldsite`.`id` from (select @db.`t`.`id` from @db.`t`) `oldsite` */;

-- case pair
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id` from (@db.`t`, @db.`u`) */;

-- case date
-- keep `v` `oldsite`.`created`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select extract(year from `oldsite`.`created`) from t AS `oldsite` */;

-- case select_comma
-- keep `v` `oldsite`.`c`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 1, `oldsite`.`c` from t AS `oldsite` */;

-- case group_comma
-- keep `v` `oldsite`.`c`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 1 from t AS `oldsite` group by 1, `oldsite`.`c` */;

-- case bare_alias
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id` from @db.`t` join u `oldsite` */;

-- case alias_function
-- keep `v` `oldsite`.`c`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select `oldsite`.`c`, @db.`f`(@db.`t`.`id`) as n from @db.`t` join u AS `oldsite` on `oldsite`.`c` = @db.`t`.`c` */;

-- case star_slash
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a*/b' as x, @db.`t`.`c` from @db.`t` */;

-- case maria_comment
/*M!100100 CREATE ALGORITHM=UNDEFINED */
/*M!100100 VIEW `v` AS select 'a''*/b' as `x``*/x`, "see */ `oldsite`." as y, @db.`t`.`c` from @db.`t` */;

-- case escaped
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a\'*/b `oldsite`.' as x, @db.`t`.`c` from @db.`t` */;

-- case plain_comment
SELECT /* VIEW `example` AS select `oldsite`.`t`.`c` */ 13;
SELECT /* an unmatched ' */ 17;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a*/b' as x, @db.`t`.`c` from @db.`t` */;
SELECT /*m!100100 VIEW `example` AS select `oldsite`.`t`.`c` */ 19;
SELECT /*m!100100 another unmatched ' */ 23;

-- case ansi ANSI_QUOTES
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a*/b' as "x""*/\", @db.`t`.`c` from @db.`t` */;

-- case no_backslash NO_BACKSLASH_ESCAPES
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a*/b\' as x, @db.`t`.`c` from @db.`t` */;

-- case crlf
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` from @db.`t` */;

-- kept_tail crlf_tail
SET SQL_MODE=CONCAT('','');
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `crlf_tail` AS select "x" AS x from t where length('`old``site`.`u`') > 0 */;

-- case explicit
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id` from @db.`t` where value = 'a\'b' */;

-- case inherited inherited
-- kept_tail v
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` from @db.`t` where value = 'a\'b' */;

-- case after_disagreement inherited
-- disagreement v
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'before `oldsite`.`u`' AS note, @db.`t`.`c` from @db.`t` where value = 'a\'b' and exists (select 1 from @db.`u`) and length('after @db.`u`, .`oldsite`.`u`, x``oldsite`.`u`') > 0 */; INSERT INTO ktvs_options VALUES ('NEXT', 'outside `oldsite`.`u`');

-- case possible_row inherited
-- possible_data v
INSERT INTO ktvs_options VALUES ('PATH','C:\');
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select `oldsite`.`t`.`id` from `oldsite`.`t` */;

-- case empty_header
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select `oldsite`.`t`.`id` from `oldsite`.`t` */;

-- case no_header
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select `oldsite`.`t`.`id` from `oldsite`.`t` */;

-- case introducer
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select _utf8mb4'`oldsite`.`t`.`c`' AS x, X'41' AS h, @db.`t`.`c` from @db.`t` */;

-- case hash_comment
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` AS c # `oldsite`.`t`.`c`
 from @db.`t` */;

-- case subquery
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id` from @db.`t` where @db.`t`.`c` in (select @db.`u`.`c` from @db.`u`) */;

-- case derived_comma
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select x.c from (select 1 AS c, @db.`t`.`c` AS d from @db.`t`) x */;

-- case join_on
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`id` from (@db.`t` join @db.`oldsite` on ((@db.`oldsite`.`id` = @db.`t`.`id`))) */;

-- case union_view
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` from @db.`t` union select @db.`u`.`c` from @db.`u` */;

-- case ordering
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` AS `oldsite` from @db.`t` order by @db.`t`.`c` limit 1 */;

-- case window_view
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select row_number() over (order by @db.`t`.`c`) AS r from @db.`t` */;

-- case cte
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS with w as (select @db.`t`.`c` from @db.`t`) select w.c from w */;

-- case inherited_plain inherited
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'see `oldsite`.`t`.`c`' AS x, @db.`t`.`c` from @db.`t` */;

-- case doubled_quotes
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a''`oldsite`.`t`.`c`''\\' AS x, @db.`t`.`c` from @db.`t` */;

-- case double_quoted
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select "see `oldsite`.`t`.`c`" AS x, @db.`t`.`c` from @db.`t` */;

-- case double_identifier ANSI_QUOTES
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` AS "see `oldsite`.`t`.`c`" from @db.`t` */;

-- case two_warnings
-- keep `oldsite`.`v` `oldsite`.`c`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW @db.`v` AS select `oldsite`.`c` from @db.`t` AS `oldsite` */;
-- keep `other` `oldsite`.`id`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `other` AS select `oldsite`.`id` from @db.`t` AS `oldsite` */;

-- case stored_view inherited
-- possible_data stored
INSERT INTO ktvs_options VALUES ('NOTE', 'C:\');
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `stored` AS select `oldsite`.`t`.`id` from `oldsite`.`t` */;
-- ');
CREATE VIEW v AS SELECT value FROM ktvs_options WHERE variable='NOTE';

-- case inherited_backslash inherited
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select 'a\\b' as x, @db.`t`.`c` from @db.`t` */;

-- case unquoted_schema
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @word.t.c, 'oldsite.t.c' AS x from @word.t */;

-- case ansi_schema ANSI_QUOTES
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @ansi."t"."c", '"oldsite"."t"."c"' AS x from @ansi."t" */;

-- case ansi_disagreement
-- disagreement v
SET @chosen_mode = CONCAT('','');
SET SQL_MODE=@chosen_mode;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select t.c from t where "x" = 'x' and exists (select 1 from @db.`u`) */;
-- kept_tail alias_guard
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `alias_guard` AS select c from `t` `oldsite` where "x" = 'x' and length('`oldsite`.`u`') > 0 */;
-- kept_tail multiline
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `multiline` AS select t.c from t where "x" = 'x'
 and length('`oldsite`.`u`') > 0 */;
-- kept_tail inline_guard
/*!50001 CREATE ALGORITHM=UNDEFINED */ /*!50001 VIEW `inline_guard` AS select "x" as x from t where length('`oldsite`.`u`') > 0 */;
-- kept_tail maria_tail
/*M!100100 CREATE ALGORITHM=UNDEFINED */
/*M!100100 VIEW `maria_tail` AS select "x" as x from t where length('`oldsite`.`u`') > 0 */;
-- disagreement early_close
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `early_close` AS select @padding@ 'common `oldsite`.`u` a\' */; b' as x, @padding@ @db.`t`.`c` from @db.`t` */;

-- case sequences
CREATE SEQUENCE s START WITH 100;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select nextval(@db.`s`) AS nv, lastval(@db.`s`) AS lv, setval(@db.`s`,500,1,0) AS sv */;

-- case control_name
-- keep `odd\x09name` `oldsite`.`c`
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `odd	name` AS select `oldsite`.`c` from @db.`t` AS `oldsite` */;
CREATE VIEW v AS SELECT c FROM `odd	name`;

-- case contested_span inherited
-- disagreement v
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50001 VIEW `v` AS select @db.`t`.`c` from @db.`t` where length('a\'@db.b') > 0 */;
