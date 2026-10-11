USE reporting;

DROP TABLE IF EXISTS dim_district;

CREATE TABLE dim_district AS
SELECT
    A1  AS district_id,
    A2  AS district_name,
    A3  AS region,
    A4  AS population,
    A9  AS num_cities,
    A10 AS urban_ratio_pct,
    A11 AS avg_salary,
    A12 AS unemployment_rate_1995,
    A13 AS unemployment_rate_1996,
    A14 AS entrepreneurs_per_1000,
    A15 AS crimes_1995,
    A16 AS crimes_1996
FROM staging.district;

CREATE OR REPLACE VIEW vw_client_profile AS
SELECT
    c.client_id,
    CASE WHEN (FLOOR(c.birth_number/100) % 100) > 50 THEN 'F' ELSE 'M' END AS gender,
    STR_TO_DATE(CONCAT('19',
        LPAD(FLOOR(c.birth_number/10000), 2, '0'),
        LPAD(CASE WHEN (FLOOR(c.birth_number/100) % 100) > 50
                  THEN (FLOOR(c.birth_number/100) % 100) - 50
                  ELSE (FLOOR(c.birth_number/100) % 100) END, 2, '0'),
        LPAD(c.birth_number % 100, 2, '0')), '%Y%m%d') AS birth_date,
    c.district_id
FROM staging.client c;

CREATE OR REPLACE VIEW vw_client_profile_full AS
SELECT
    p.client_id, p.gender, p.birth_date,
    TIMESTAMPDIFF(YEAR, p.birth_date, '1999-01-01') AS age,
    CASE WHEN TIMESTAMPDIFF(YEAR, p.birth_date, '1999-01-01') < 31 THEN '18-30'
         WHEN TIMESTAMPDIFF(YEAR, p.birth_date, '1999-01-01') < 46 THEN '31-45'
         WHEN TIMESTAMPDIFF(YEAR, p.birth_date, '1999-01-01') < 61 THEN '46-60'
         ELSE '60+' END AS age_band,
    d.district_name, d.region
FROM vw_client_profile p
LEFT JOIN dim_district d ON d.district_id = p.district_id;

CREATE OR REPLACE VIEW vw_monthly_transactions AS
SELECT
    t.account_id,
    DATE_FORMAT(STR_TO_DATE(CONCAT('19', LPAD(t.date,6,'0')), '%Y%m%d'), '%Y-%m-01') AS month,
    CASE t.type WHEN 'PRIJEM' THEN 'Credit'
                WHEN 'VYDAJ'  THEN 'Withdrawal'
                WHEN 'VYBER'  THEN 'Cash withdrawal'
                ELSE t.type END AS type,
    SUM(t.amount) AS total_amount,
    COUNT(*)      AS txn_count
FROM staging.trans t
GROUP BY t.account_id,
         DATE_FORMAT(STR_TO_DATE(CONCAT('19', LPAD(t.date,6,'0')), '%Y%m%d'), '%Y-%m-01'),
         CASE t.type WHEN 'PRIJEM' THEN 'Credit'
                     WHEN 'VYDAJ'  THEN 'Withdrawal'
                     WHEN 'VYBER'  THEN 'Cash withdrawal'
                     ELSE t.type END;

CREATE OR REPLACE VIEW vw_loan_summary AS
SELECT
    l.loan_id, l.account_id,
    STR_TO_DATE(CONCAT('19', LPAD(l.date,6,'0')), '%Y%m%d') AS loan_date,
    l.amount, l.duration, l.payments,
    CASE l.status WHEN 'A' THEN 'Finished - paid'
                  WHEN 'B' THEN 'Finished - not paid'
                  WHEN 'C' THEN 'Running - OK'
                  WHEN 'D' THEN 'Running - in debt' END AS status
FROM staging.loan l;

CREATE OR REPLACE VIEW vw_account_summary AS
WITH last_bal AS (
    SELECT account_id, balance,
           ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY date DESC, trans_id DESC) AS rn
    FROM staging.trans
),
cnt AS (
    SELECT account_id, COUNT(*) AS txn_count FROM staging.trans GROUP BY account_id
)
SELECT
    a.account_id,
    d.client_id AS owner_client_id,
    a.district_id,
    a.frequency,
    STR_TO_DATE(CONCAT('19', LPAD(a.date,6,'0')), '%Y%m%d') AS open_date,
    c.txn_count,
    b.balance AS latest_balance
FROM staging.account a
LEFT JOIN staging.disp d ON d.account_id = a.account_id AND d.type = 'OWNER'
LEFT JOIN cnt c ON c.account_id = a.account_id
LEFT JOIN last_bal b ON b.account_id = a.account_id AND b.rn = 1;

CREATE TABLE IF NOT EXISTS refresh_log (
    log_id      INT AUTO_INCREMENT PRIMARY KEY,
    run_time    DATETIME DEFAULT CURRENT_TIMESTAMP,
    table_name  VARCHAR(50),
    rows_loaded INT
);

CREATE TABLE IF NOT EXISTS dq_results (
    dq_id         INT AUTO_INCREMENT PRIMARY KEY,
    run_id        INT,
    run_date      DATETIME DEFAULT CURRENT_TIMESTAMP,
    check_name    VARCHAR(100),
    table_name    VARCHAR(50),
    failed_rows   BIGINT,
    total_rows    BIGINT,
    failure_pct   DECIMAL(6,2),
    threshold_pct DECIMAL(6,2),
    status        VARCHAR(4)
);

CREATE OR REPLACE VIEW vw_dq_latest AS
SELECT * FROM dq_results WHERE run_id = (SELECT MAX(run_id) FROM dq_results);

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_refresh_reporting$$
CREATE PROCEDURE sp_refresh_reporting()
BEGIN
    DROP TABLE IF EXISTS client_profile;
    CREATE TABLE client_profile AS SELECT * FROM vw_client_profile_full;
    INSERT INTO refresh_log (table_name, rows_loaded) SELECT 'client_profile', COUNT(*) FROM client_profile;

    DROP TABLE IF EXISTS account_summary;
    CREATE TABLE account_summary AS SELECT * FROM vw_account_summary;
    INSERT INTO refresh_log (table_name, rows_loaded) SELECT 'account_summary', COUNT(*) FROM account_summary;

    DROP TABLE IF EXISTS monthly_transactions;
    CREATE TABLE monthly_transactions AS
        SELECT account_id, CAST(month AS DATE) AS month, type, total_amount, txn_count
        FROM vw_monthly_transactions;
    INSERT INTO refresh_log (table_name, rows_loaded) SELECT 'monthly_transactions', COUNT(*) FROM monthly_transactions;

    DROP TABLE IF EXISTS loan_summary;
    CREATE TABLE loan_summary AS SELECT * FROM vw_loan_summary;
    INSERT INTO refresh_log (table_name, rows_loaded) SELECT 'loan_summary', COUNT(*) FROM loan_summary;
END$$

DROP PROCEDURE IF EXISTS sp_add_dq$$
CREATE PROCEDURE sp_add_dq(IN p_run INT, IN p_check VARCHAR(100), IN p_table VARCHAR(50),
                           IN p_failed BIGINT, IN p_total BIGINT, IN p_threshold DECIMAL(6,2))
BEGIN
    INSERT INTO dq_results (run_id, check_name, table_name, failed_rows, total_rows,
                            failure_pct, threshold_pct, status)
    VALUES (p_run, p_check, p_table, p_failed, p_total,
            ROUND(100 * p_failed / NULLIF(p_total, 0), 2), p_threshold,
            CASE WHEN 100 * p_failed / NULLIF(p_total, 0) > p_threshold THEN 'FAIL' ELSE 'PASS' END);
END$$

DROP PROCEDURE IF EXISTS sp_run_dq_checks$$
CREATE PROCEDURE sp_run_dq_checks()
BEGIN
    DECLARE v_run INT;
    DECLARE v_total BIGINT;
    DECLARE v_failed BIGINT;

    SELECT COALESCE(MAX(run_id), 0) + 1 INTO v_run FROM dq_results;

    SELECT COUNT(*) INTO v_total FROM staging.trans;

    SELECT COUNT(*) INTO v_failed FROM staging.trans WHERE bank IS NULL OR TRIM(bank) = '';
    CALL sp_add_dq(v_run, 'Blank bank in trans', 'trans', v_failed, v_total, 5);

    SELECT COUNT(*) INTO v_failed FROM staging.trans WHERE account IS NULL OR TRIM(account) = '';
    CALL sp_add_dq(v_run, 'Blank counterparty account in trans', 'trans', v_failed, v_total, 5);

    SELECT COUNT(*) INTO v_failed FROM staging.trans WHERE operation IS NULL OR TRIM(operation) = '';
    CALL sp_add_dq(v_run, 'Blank operation in trans', 'trans', v_failed, v_total, 5);

    SELECT COUNT(*) INTO v_failed FROM staging.trans WHERE k_symbol IS NULL OR TRIM(k_symbol) = '';
    CALL sp_add_dq(v_run, 'Blank k_symbol in trans', 'trans', v_failed, v_total, 5);

    SELECT COUNT(*) - COUNT(DISTINCT trans_id) INTO v_failed FROM staging.trans;
    CALL sp_add_dq(v_run, 'Duplicate trans_id', 'trans', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_failed
    FROM staging.trans t LEFT JOIN staging.account a ON a.account_id = t.account_id
    WHERE a.account_id IS NULL;
    CALL sp_add_dq(v_run, 'Orphan transactions (no account)', 'trans', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_total FROM staging.loan;
    SELECT COUNT(*) INTO v_failed
    FROM staging.loan l LEFT JOIN staging.account a ON a.account_id = l.account_id
    WHERE a.account_id IS NULL;
    CALL sp_add_dq(v_run, 'Orphan loans (no account)', 'loan', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_total FROM staging.trans;
    SELECT COUNT(*) INTO v_failed
    FROM staging.trans t JOIN staging.account a ON a.account_id = t.account_id
    WHERE t.date < a.date;
    CALL sp_add_dq(v_run, 'Transaction before account open date', 'trans', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_failed FROM staging.trans WHERE balance < 0;
    CALL sp_add_dq(v_run, 'Negative balance', 'trans', v_failed, v_total, 1);

    SELECT COUNT(*) INTO v_total FROM staging.client;
    SELECT COUNT(*) INTO v_failed FROM vw_client_profile WHERE birth_date IS NULL;
    CALL sp_add_dq(v_run, 'Birth date could not be decoded', 'client', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_total FROM client_profile;
    SELECT COUNT(*) INTO v_failed FROM client_profile WHERE age < 10 OR age > 100;
    CALL sp_add_dq(v_run, 'Implausible client age', 'client_profile', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_total FROM staging.client;
    SELECT ABS(v_total - COUNT(*)) INTO v_failed FROM client_profile;
    CALL sp_add_dq(v_run, 'Row count: client vs client_profile', 'client_profile', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_total FROM staging.account;
    SELECT ABS(v_total - COUNT(*)) INTO v_failed FROM account_summary;
    CALL sp_add_dq(v_run, 'Row count: account vs account_summary', 'account_summary', v_failed, v_total, 0);

    SELECT COUNT(*) INTO v_total FROM staging.trans;
    SELECT ABS(v_total - COALESCE(SUM(txn_count), 0)) INTO v_failed FROM monthly_transactions;
    CALL sp_add_dq(v_run, 'Row count: trans vs monthly_transactions', 'monthly_transactions', v_failed, v_total, 0);
END$$

DROP PROCEDURE IF EXISTS sp_run_all$$
CREATE PROCEDURE sp_run_all()
BEGIN
    CALL sp_refresh_reporting();
    CALL sp_run_dq_checks();
END$$

DELIMITER ;
