\pset pager off

SELECT
    clock_timestamp() AS measured_at,
    wal_records,
    wal_fpi,
    wal_bytes,
    wal_buffers_full
FROM pg_stat_wal;

SELECT
    clock_timestamp() AS measured_at,
    num_timed,
    num_requested,
    num_done,
    write_time,
    sync_time,
    buffers_written
FROM pg_stat_checkpointer;
