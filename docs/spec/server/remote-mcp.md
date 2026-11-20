# Server の Remote MCP

採択: 2026-08-29〜09-01。

## Transport

Remote MCP は stateless で modern-only の `/mcp` とする。HTTP request は 12 MiB を上限とし、JSON 解析の前に拒否する。これを超える大容量の本体は REST に残す。

## 認証

accounts は MCP resource audience の DPoP-bound token を使い、issuer、audience、expiry、subject、workspace claim、scope、sender constraint を検証する。scope は [共通 OAuth](../shared/oauth.md#scope) に従う。

## Client 登録

Node の CIMD（Client ID Metadata Document）は、DNS resolve-once、非公開 address の拒否、connection pinning、redirect refusal を満たす secure fetch を使う。DCR（動的 client 登録）は有効にしない。

Cloudflare accounts はこの transport がないため、CIMD を advertise せず、remote client を onboarding しない。

## Header mode と Origin

Apps header mode は proxy 確定 identity を使い、Server の OAuth challenge を重ねない。browser の Origin は configured origin と一致させ、Origin のない non-browser client は許可する。

## ログ

tool input/output、content、token、storage URL を log しない。

## 未適合・未検証

- 未検証: CIMD の DNS resolve-once と redirect refusal の詳細は、実装で確認していない。README は pinned public-address fetching とだけ記す。
