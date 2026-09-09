UPDATE account_settings
SET summary = json_set(summary, '$.detail', CASE json_extract(summary, '$.detail')
    WHEN 'concise' THEN 'low' WHEN 'standard' THEN 'medium'
    WHEN 'detailed' THEN 'high' WHEN 'eventSession' THEN 'xhigh' END), revision = revision + 1
WHERE json_extract(summary, '$.detail') IN ('concise', 'standard', 'detailed', 'eventSession');
