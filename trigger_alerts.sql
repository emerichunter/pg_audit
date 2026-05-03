-- 🚨 ALERT TRIGGER PROFILE FOR PG_AUDIT 🚨

-- 1. Create Bloat
CREATE TABLE bloat_test AS SELECT generate_series(1,100000) as id, md5(random()::text) as data;
DELETE FROM bloat_test WHERE id > 10000;
VACUUM bloat_test; -- Ensure stats are updated but space isn't necessarily reclaimed if there's no anchor
ANALYZE bloat_test;

-- 2. Duplicate Indexes
CREATE INDEX idx_bloat_id_1 ON bloat_test(id);
CREATE INDEX idx_bloat_id_2 ON bloat_test(id);

-- 3. Inefficient / Missing Index Candidate
CREATE TABLE missing_idx_test AS SELECT generate_series(1,200000) as id, md5(random()::text) as data;
ANALYZE missing_idx_test;
-- Trigger many seq scans
DO $$ 
BEGIN 
    FOR i IN 1..100 LOOP 
        PERFORM count(*) FROM missing_idx_test WHERE data = 'no_match';
    END LOOP; 
END $$;

-- 4. Sequence Exhaustion
CREATE SEQUENCE seq_exhausted START 2147483640 MAXVALUE 2147483647;
SELECT nextval('seq_exhausted');

-- 5. Unsafe Settings (Mocking via pg_settings if possible, or actual alter)
ALTER SYSTEM SET fsync = off;
ALTER SYSTEM SET full_page_writes = off;
SELECT pg_reload_conf();

-- 6. Security Risks
CREATE ROLE weak_user LOGIN PASSWORD '123'; -- Weak password
CREATE ROLE nopass_user LOGIN; -- No password

-- 7. Locks & Long Transactions (Will need a background process)
-- We'll trigger this in a separate psql call

-- 8. Replication Slot (Inactive)
SELECT pg_create_physical_replication_slot('stale_slot');

-- 9. XID Wraparound (Mocking age is hard, but we can check the query)
-- We'll just ensure the reports can see the database age

-- 10. Cache Misses (Triggering read pressure)
CREATE TABLE cache_pressure AS SELECT generate_series(1,1000000) as id, md5(random()::text) as data;
-- We'll read it after dropping from cache if we could, but just a large table helps.
