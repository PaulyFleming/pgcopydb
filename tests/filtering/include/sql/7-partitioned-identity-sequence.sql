-- With include-only-table, a partitioned parent none of whose partitions are
-- selected is not copied, so its identity sequence must not be either.
select string_agg(format('%s.%s', n.nspname, c.relname), ', '
                  order by n.nspname, c.relname) as sequences
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where c.relkind = 'S'
   and c.relname like 'partitioned_identity%'
   and n.nspname in ('schema_name_20_chars');
