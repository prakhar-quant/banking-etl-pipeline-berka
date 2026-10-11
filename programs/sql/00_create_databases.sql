CREATE DATABASE IF NOT EXISTS staging;
CREATE DATABASE IF NOT EXISTS reporting;

CREATE TABLE IF NOT EXISTS staging.run_log (
    run_id        INT AUTO_INCREMENT PRIMARY KEY,
    run_time      DATETIME DEFAULT CURRENT_TIMESTAMP,
    table_name    VARCHAR(50),
    rows_loaded   INT,
    status        VARCHAR(10),
    error_message TEXT
);
