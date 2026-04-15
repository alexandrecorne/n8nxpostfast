# EO Shorts Auto-Publisher

Weekly n8n workflow that reads "Ready" shorts from the Notion planning DB, schedules them on every target social platform via the PostFast API, and marks them as "Posted" in Notion.

## Pipeline

Every Sunday at 20:00 (Europe/Paris):

```
Schedule → PostFast GET /social-accounts → Code: build platform map
        → Notion Query (Ready, this week) → Code: build posts per short
        → PostFast POST /social-posts → Notion: mark as Posted
```

1. **Schedule Trigger** — weekly cron `0 20 * * 0`.
2. **PostFast — Fetch Social Accounts** — `GET https://api.postfa.st/social-accounts` with `pf-api-key` header, returns every connected account (YouTube, TikTok, Instagram, LinkedIn, X) with its UUID.
3. **Code — Build Platform Map** — turns the response into `{ YOUTUBE: <uuid>, TIKTOK: <uuid>, INSTAGRAM: <uuid>, LINKEDIN: <uuid>, X: <uuid> }`.
4. **Notion — Query Shorts** — returns every page in the [Shorts EO — Weekly Posting Planning](https://www.notion.so/34028224657180d8951bcc555a2c66b8) DB where `Back-up = Ready` and `Date de Publication` falls in the next 7 days.
5. **Code — Build Posts Per Short** — parses the `Description` field (which is structured with `YT:` / `SM:` / `LI:` / `X:` prefixes), fans `SM` out to both `INSTAGRAM` and `TIKTOK`, resolves each platform to a `socialMediaId` via the map, and produces the full PostFast POST body `{ posts: [...], controls: {} }`. A short with all four prefixes produces **5 PostFast posts** (1 YT + 1 IG + 1 TikTok + 1 LI + 1 X).
6. **PostFast — Schedule Posts** — `POST https://api.postfa.st/social-posts` once per short, with the batched body from step 5.
7. **Notion — Mark as Posted** — flips `Back-up` from `Ready` to `Posted`.

## Files

| Path | Purpose |
|---|---|
| `workflows/eo-shorts-auto-publisher.json` | n8n workflow definition (source of truth, versioned here) |
| `scripts/deploy-to-n8n.sh` | Idempotent deploy: auto-creates the PostFast credential, resolves Notion credential, substitutes IDs, POSTs or PUTs the workflow |

## One-time setup

### 1. Create the Notion integration + credential

The deploy script can't do this one for you — n8n's public API doesn't accept credentials of type `notionApi` through the CLI (the OAuth/token flow is UI-bound).

1. Go to <https://www.notion.so/my-integrations> → **+ New integration**, workspace-internal, with **Read + Update content** capabilities.
2. Copy the **Internal Integration Secret**.
3. Open the Notion page [Shorts EO — Weekly Posting Planning](https://www.notion.so/34028224657180d8951bcc555a2c66b8) → `⋯` menu → **Connections → Connect to →** your new integration.
4. In n8n UI: **Credentials → + Add credential → Notion API**, paste the secret, name it exactly `Notion API` (the script searches for this name).

### 2. Grab the Notion credential UUID from the n8n UI

n8n's public API has no `GET /credentials` endpoint — you can create and delete credentials but not list them. So we can't auto-discover the Notion credential ID. Copy it once, pass it as an env var.

1. Open `http://72.62.187.71:5678/home/credentials`
2. Click the `Notion API` credential you just created
3. The URL becomes `.../home/credentials/<uuid>` — copy that UUID

### 3. Deploy — one command

```bash
export N8N_API_KEY="eyJhbGciOi..."                # Settings → n8n API → Create API Key
export POSTFAST_API_KEY="tuk7TzAI..."             # PostFast workspace settings → API
export NOTION_CRED_ID="<uuid from step 2>"
export N8N_PROJECT_ID="bnK2w5BUU8YLwyol"          # optional
export TARGET_WORKFLOW_ID="VztWOvTejsjBV4Vh8tL2o" # optional: overwrite the empty workflow you already have open

bash scripts/deploy-to-n8n.sh
```

The script:
- **Pings** the n8n API first to catch auth/URL mistakes early.
- **Creates a fresh `PostFast API` Header Auth credential** (`pf-api-key: ${POSTFAST_API_KEY}`) on every run, unless you pass `POSTFAST_CRED_ID=<uuid>` to reuse one.
- **Substitutes** both credential IDs into the workflow JSON on the fly.
- **Overwrites** the target workflow (via `TARGET_WORKFLOW_ID` or name lookup) or creates a new one.
- **Transfers** freshly-created workflows into the project set by `N8N_PROJECT_ID` (ignored on Community edition).

If the PostFast credential creation fails with a "duplicate name" error, the script prints exact instructions to copy the existing credential's UUID and re-run with `POSTFAST_CRED_ID=<uuid>`.

Run the script with `DEBUG=1` to see every request (`set -x`).

### 3. Test E2E

1. In Notion, duplicate an existing short and set:
   - `Back-up = Ready`
   - `Date de Publication = today`
   - `Description` containing all four markers, e.g.
     ```
     YT: Test caption for YouTube. #shorts | Tags: test
     SM: Test caption for Instagram + TikTok. #test
     LI: Test caption for LinkedIn, slightly longer.
     X: Test caption for X.
     ```
2. Open the deployed workflow → **Execute Workflow** (top-right).
3. Inspect each node's output:
   - `PostFast — Fetch Social Accounts` should return your connected accounts.
   - `Code — Build Platform Map` should produce a `platformMap` with 4–5 UPPERCASE platform keys.
   - `Code — Build Posts Per Short` should output `postCount: 5` and no `missingPlatforms`.
   - `PostFast — Schedule Posts` should return HTTP 2xx with scheduled post IDs.
   - `Notion — Mark as Posted` should show the page updated to `Posted`.
4. Verify in PostFast that 5 scheduled posts exist for today across the 5 accounts.
5. Revert the test short (or delete) so the cron doesn't re-run it Sunday.
6. Toggle the workflow **Active**.

## Known gotchas / next iterations

- **No `mediaItems` yet.** PostFast may reject text-only posts on video-first platforms (YouTube Shorts, TikTok). Videos are assumed pre-uploaded in PostFast; once you know how to reference the uploaded video (its `key`), add a `PostFast Media Key` column to Notion and extend the `Code — Build Posts Per Short` node to include:
  ```js
  mediaItems: mediaKey ? [{ key: mediaKey, type: 'VIDEO', sortOrder: 0 }] : undefined
  ```
  The first E2E run will tell you exactly what PostFast expects (the HTTP Request node's output shows the raw error body).
- **Date has no time.** `Date de Publication` is a Notion `date` (no hour). The code defaults to `09:00 UTC`. Edit `scheduledAt` logic in `Code — Build Posts Per Short` if you want another hour or a per-short time.
- **Platform naming.** The code normalises platform strings returned by PostFast to UPPERCASE (`INSTAGRAM`, `TIKTOK`, `YOUTUBE`, `LINKEDIN`, `X`/`TWITTER`). If PostFast returns something else (`YOUTUBE_SHORTS`?), the `Code — Build Posts Per Short` node will throw with a clear `missingPlatforms` message — easy to fix.
- **HTTP instead of HTTPS for n8n.** The script talks to n8n over plain HTTP on `http://72.62.187.71:5678`. That's fine for a deploy-from-laptop flow, but be aware the `N8N_API_KEY` travels in the clear on whatever network you run the script from. Don't run it from coffee-shop wifi; alternatively put Caddy/nginx in front of n8n and switch to HTTPS.
- **Notion credential name is magic.** The script looks for an exact match on the credential name `Notion API`. If you name it differently, edit `NOTION_CRED_NAME` in `scripts/deploy-to-n8n.sh`.
