UPDATE account_settings SET summary = json_object(
  'method', summary_method,
  'detail', CASE WHEN summary_method = 'audio' THEN json_extract(audio_summary, '$.detail') ELSE json_extract(transcript_summary, '$.detail') END,
  'methodSettings', json_object('transcript', json_remove(transcript_summary, '$.detail'), 'audio', json_remove(audio_summary, '$.detail'))
);
