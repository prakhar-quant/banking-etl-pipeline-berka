SELECT operation, type,
       COUNT(*) AS txns,
       SUM(bank IS NULL OR TRIM(bank) = '')       AS blank_bank,
       SUM(account IS NULL OR TRIM(account) = '') AS blank_account
FROM staging.trans
GROUP BY operation, type
ORDER BY txns DESC;

SELECT operation,
       COUNT(*) AS txns,
       ROUND(100 * SUM(bank IS NULL OR TRIM(bank) = '') / COUNT(*), 1) AS pct_blank_bank
FROM staging.trans
GROUP BY operation
ORDER BY txns DESC;

SELECT account, COUNT(*) AS txns
FROM staging.trans
WHERE operation = 'VYBER KARTOU'
GROUP BY account ORDER BY txns DESC LIMIT 5;

SELECT account, COUNT(*) AS txns
FROM staging.trans
WHERE operation = 'VYBER' AND type = 'VYDAJ'
  AND NOT (account IS NULL OR TRIM(account) = '')
GROUP BY account ORDER BY txns DESC LIMIT 5;

SELECT k_symbol, COUNT(*) AS txns
FROM staging.trans
WHERE operation IS NULL OR TRIM(operation) = ''
GROUP BY k_symbol ORDER BY txns DESC;

SELECT 1900 + FLOOR(date / 10000) AS yr,
       COUNT(*) AS txns,
       ROUND(100 * SUM(operation IS NULL OR TRIM(operation) = '') / COUNT(*), 1) AS pct_blank_operation
FROM staging.trans
GROUP BY yr ORDER BY yr;

SELECT operation, type, COUNT(*) AS txns
FROM staging.trans
WHERE k_symbol IS NULL OR TRIM(k_symbol) = ''
GROUP BY operation, type
ORDER BY txns DESC;

SELECT COUNT(DISTINCT account_id) AS accounts_with_negative_balance,
       COUNT(*) AS negative_rows
FROM staging.trans
WHERE balance < 0;

SELECT account_id, COUNT(*) AS negative_rows, MIN(balance) AS lowest_balance
FROM staging.trans
WHERE balance < 0
GROUP BY account_id
ORDER BY negative_rows DESC
LIMIT 10;

SELECT operation, type, COUNT(*) AS txns
FROM staging.trans
WHERE operation = 'VYBER'
GROUP BY operation, type;
