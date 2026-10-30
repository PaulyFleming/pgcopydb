#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# make sure source and target databases are ready
pgcopydb ping

#
# Now create a user that's going to be the owner of our database
#
psql -a ${PGCOPYDB_SOURCE_PGURI} <<EOF
create role pagila NOSUPERUSER CREATEDB NOCREATEROLE LOGIN PASSWORD '0wn3d';
create database pagila owner pagila connection limit 8;
EOF

pgcopydb copy roles

psql -a ${PGCOPYDB_TARGET_PGURI} <<EOF
create database pagila owner pagila connection limit 10;
EOF

PAGILA_SOURCE_PGURI="postgres://pagila:0wn3d@source/pagila"
PAGILA_TARGET_PGURI="postgres://pagila:0wn3d@target/pagila"

# Create extensions in the default and alternative schemas to always
# ensure these copy as expected.
psql -d ${PAGILA_SOURCE_PGURI} <<EOF
create extension ltree;
create extension hstore;
create schema foo;
create extension intarray schema foo cascade;
create schema bar;
create extension pg_trgm schema bar cascade;
create schema "Foo Bar";
create extension pgcrypto schema "Foo Bar" cascade;
create schema "With a space";
create extension seg schema "With a space" cascade;
EOF

# Create a couple of schemas in the target database
# to ensure they get skipped during the clone
psql -d ${PAGILA_TARGET_PGURI} <<EOF
create schema bar;
create schema "With a space";
EOF

grep -v "OWNER TO postgres" /usr/src/pagila/pagila-schema.sql > /tmp/pagila-schema.sql

psql -o /tmp/s.out -d ${PAGILA_SOURCE_PGURI} -1 -f /tmp/pagila-schema.sql
psql -o /tmp/d.out -d ${PAGILA_SOURCE_PGURI} -1 -f /usr/src/pagila/pagila-data.sql

# identity sequence owned by a partitioned table, no filter active
psql -d ${PAGILA_SOURCE_PGURI} <<EOF
create table public.partitioned_identity (
    id bigint generated always as identity,
    created int not null
) partition by range (created);
create table public.partitioned_identity_1
    partition of public.partitioned_identity for values from (0) to (100);
select setval(pg_get_serial_sequence('public.partitioned_identity', 'id'), 2000000);
EOF

pgcopydb clone --notice \
         --skip-ext-comments \
         --skip-db-properties \
         --estimate-table-sizes \
         --use-copy-binary \
         --source ${PAGILA_SOURCE_PGURI} \
         --target ${PAGILA_TARGET_PGURI}

# DEBUG (do not merge): show how the sequence travels through the restore lists
set +e
ls -la /tmp/pgcopydb/schema/
echo "=== grep partitioned_identity in the TOC and restore lists"
for f in /tmp/pgcopydb/schema/*.list; do echo "--- $f"; grep -n 'partitioned_identity' $f; done
pg_restore -l /tmp/pgcopydb/schema/schema.dump | grep -n 'partitioned_identity'
echo "=== s_seq and filter rows"
for db in source filter; do
  echo "--- $db.db"
  sqlite3 -header /tmp/pgcopydb/schema/$db.db "select * from s_seq where relname like 'partitioned_identity%'" 2>&1
done
sqlite3 -header /tmp/pgcopydb/schema/filter.db "select * from filter where restore_list_name like '%partitioned_identity%' or oid in (select oid from s_seq where relname like 'partitioned_identity%')" 2>&1
echo "=== target sequences"
psql -At -d ${PAGILA_TARGET_PGURI} -c "select schemaname, sequencename from pg_sequences where sequencename like 'partitioned_identity%'"
set -e

pgcopydb compare schema \
         --source ${PAGILA_SOURCE_PGURI} \
         --target ${PAGILA_TARGET_PGURI}

pgcopydb compare data \
         --source ${PAGILA_SOURCE_PGURI} \
         --target ${PAGILA_TARGET_PGURI}

test "$(psql -At -d ${PAGILA_TARGET_PGURI} -c 'select last_value, is_called from public.partitioned_identity_id_seq')" = "2000000|t"
