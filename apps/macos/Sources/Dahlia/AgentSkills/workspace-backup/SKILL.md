---
name: workspace-backup
description: Create a Dahlia Local Workspace backup and save it to My Drive's Dahlia/Backup folder using Google Drive MCP. Use when asked to back up Dahlia or save a backup to Google Drive.
---

Use `dahlia_create_backup` to create the current chat's Workspace backup. It calls the same service as Settings → Data Protection and returns a verified `.tar.gz` file path. Never copy the live SQLite database or build an archive yourself. Server Workspaces and unprocessed batch audio are rejected; explain the returned error without discarding recordings or changing account ownership.

Use the configured Google Drive MCP server for all Drive writes, following chat's approval policy:

1. Discover the server's tools and verify it supports uploading a local binary file. If no such tool is available, explain which MCP connection/capability is missing and keep the local backup. Never send archive bytes through model context or claim a local path is a completed upload.
2. In My Drive, resolve the exact folder `Dahlia` under `root`, then `Backup` directly inside it. Create missing folders using MCP. Exclude trashed folders, shared drives, and shortcuts. If there are multiple matches at a level, ask which folder to use; do not pick one arbitrarily.
3. Upload the returned local file with its existing unique filename into that `Backup` folder. Do not overwrite or prune existing backups. Do not use Unity Gateway connections for writes; `system_ai_agent_google_drive` is a read route.
4. Confirm upload completion from the MCP response (file ID/link and size where available). Report the local backup separately if upload failed. Include the destination `My Drive/Dahlia/Backup` and the uploaded filename in the result.

The archive contains the selected Workspace's database records and original images, plus a checksum manifest. It excludes audio, credentials, and app settings. Cloud backup listing and download are in Settings → Data Protection through Google Drive read authorization. Restore goes through Dahlia's normal validation and restart workflow; do not edit the live database.
