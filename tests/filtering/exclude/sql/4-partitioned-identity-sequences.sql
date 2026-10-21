-- Identity sequences owned by partitioned parents must be copied with their
-- position when a table filter is active, and must stay excluded when the
-- parent's schema is excluded.
select last_value, is_called from partitioned_identity.range_always_id_seq;
select last_value, is_called from partitioned_identity.list_by_default_id_seq;
select last_value, is_called from partitioned_identity.nested_always_id_seq;
select count(*)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where c.relkind = 'S'
   and n.nspname = 'bar'
   and c.relname = 'partitioned_identity_id_seq';
