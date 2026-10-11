SELECT table_name, column_name, data_type, ordinal_position
FROM information_schema.columns
WHERE table_schema = 'reporting'
  AND table_name IN ('client_profile', 'account_summary', 'monthly_transactions',
                     'loan_summary', 'dim_district', 'dq_results', 'refresh_log')
ORDER BY table_name, ordinal_position;
