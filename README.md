# EO Shorts Auto-Publisher

Weekly n8n workflow that reads "Ready" shorts from the Notion planning DB, schedules each one on YouTube Shorts, Instagram Reels, TikTok, LinkedIn and X via the PostFast API, and marks them as "Posted" in Notion.

## Pipeline

Every Sunday at 20:00 (Europe/Paris):

```
Schedule
  → PostFast GET /social-media/my-social-accounts
  → Code: build {YOUTUBE: uuid, INSTAGRAM: uuid, TIKTOK: uuid, LINKEDIN: uuid, X: uuid}
  → Notion Query (Back-up = Ready AND Date de Publication in next 7 days)
  → Code: parse Description into per-platform blocks, fan out SM → IG+TikTok,
           emit ONE item per (short × platform) with platform-specific controls
  → HTTP POST /social-posts (one call per platform-post — each has its own controls)
  → Dedup by notionPageId
  → Notion: mark short as Posted
```

A short with all four markers (`YT:`/`SM:`/`LI:`/`X:`) fires **5 PostFast calls** (1 YT + 1 IG + 1 TikTok + 1 LI + 1 X), each with the controls that platform needs (`youtubeIsShort: true`, `instagramPublishType: "REEL"`, `tiktokPrivacy: "PUBLIC"`, etc.).

## Files

| Path | Purpose |
|---|---|
| `workflows/eo-shorts-auto-publisher.json` | n8n workflow definition (source of truth) |
| `scripts/deploy-to-n8n.sh` | Idempotent deploy to `http://72.62.187.71:5678` via the n8n REST API |
| `scripts/upload-video.sh` | Uploads a local video to PostFast and prints the media `key` to paste into Notion |

## Notion database contract

The workflow queries the [Shorts EO — Weekly Posting Planning](https://www.notion.so/45328224657182cfafe181046d7f5d2c) DB (`collection://0bd28224-6571-827b-8a89-07fed5b4cd84`). Each short (Notion page) is expected to have:

| Property | Type | Purpose |
|---|---|---|
| `Titre` | Title | Display title |
| `Description` | Text | Captions for each platform, prefixed by `YT:` / `SM:` / `LI:` / `X:` on their own line |
| `Date de Publication` | Date | When to schedule (time defaults to 09:00 UTC if only a date is set) |
| `Back-up` | Status | Must be `Ready` for the workflow to pick it up; set to `Posted` after scheduling |
| `PostFast Media Key` | Text | Path key of the uploaded video on PostFast, e.g. `video/a7b8c9d1-e2f3-4567-8901-23456789abcd.mp4`. Produce it via `scripts/upload-video.sh`. |

The `PostFast Media Key` column was added automatically to the DB — just fill it in before setting a short to `Ready`.

### Upload a video → get a key

```bash
export POSTFAST_API_KEY="tuk7TzAI..."     # PostFast Workspace Settings → API
bash scripts/upload-video.sh path/to/short-42.mp4
```

Output:
```
✓ Upload complete.

Paste this into the 'PostFast Media Key' column of the corresponding
Notion short (https://www.notion.so/45328224657182cfafe181046d7f5d2c):

  video/a7b8c9d1-e2f3-4567-8901-23456789abcd.mp4
```

One video = one key = one PostFast upload, reused across all 5 platform posts for that short.

## One-time setup

### 1. Create the Notion credential in n8n

The n8n public API can't create Notion credentials programmatically, so this is a one-time UI action:

1. Go to <https://www.notion.so/my-integrations> → **+ New integration**, workspace-internal, with **Read + Update content** capabilities.
2. Copy the **Internal Integration Secret**.
3. Open the DB page <https://www.notion.so/45328224657182cfafe181046d7f5d2c> → `⋯` → **Connections → Connect to →** your new integration.
4. In n8n (`http://72.62.187.71:5678/home/credentials`) → **+ Add credential → Notion API**, paste the secret, name it exactly `Notion API`.

### 2. Copy the Notion credential UUID

n8n's public API has no `GET /credentials` endpoint, so the deploy script needs the UUID passed in.

1. Open `http://72.62.187.71:5678/home/credentials`
2. Click your `Notion API` credential
3. The URL becomes `.../home/credentials/<uuid>` — copy the `<uuid>`.

### 3. Deploy

```bash
export N8N_API_KEY="eyJhbGciOi..."                # Settings → n8n API → Create API Key
export POSTFAST_API_KEY="tuk7TzAI..."             # PostFast Workspace Settings → API
export NOTION_CRED_ID="<uuid from step 2>"
export N8N_PROJECT_ID="bnK2w5BUU8YLwyol"          # optional
export TARGET_WORKFLOW_ID="VztWOvTejsjBV4Vh8tL2o" # optional: overwrite an existing workflow

bash scripts/deploy-to-n8n.sh
```

The script:
- Pings n8n to catch auth/URL mistakes early.
- Creates a fresh `PostFast API` Header Auth credential (`pf-api-key: ${POSTFAST_API_KEY}`), unless you pass `POSTFAST_CRED_ID=<uuid>` to reuse one.
- Substitutes both credential UUIDs into the workflow JSON on the fly.
- Overwrites the target workflow or creates a new one.

Re-run any time you edit the workflow JSON — fully idempotent. `DEBUG=1 bash scripts/deploy-to-n8n.sh` enables tracing.

## Testing end-to-end

1. Upload a test video:
   ```bash
   bash scripts/upload-video.sh path/to/a-test-clip.mp4
   ```
   Copy the returned key.
2. In Notion, duplicate an existing short and set:
   - `Back-up = Ready`
   - `Date de Publication = today`
   - `PostFast Media Key = <the key from step 1>`
   - `Description` containing all four markers, e.g.
     ```
     YT: Test caption for YouTube Shorts. #test | Tags: test
     SM: Test caption for Instagram + TikTok. #test
     LI: Test caption for LinkedIn, slightly longer to match the platform vibe.
     X: Test caption for X.
     ```
3. Open the deployed workflow → **Execute Workflow**.
4. Check each node's output:
   - `PostFast — Fetch Social Accounts` returns your connected accounts.
   - `Code — Build Platform Map` shows a `platformMap` with UPPERCASE platform keys.
   - `Notion — Query Shorts` returns your test page.
   - `Code — Explode Per Platform` emits **5 items** and `missingPlatforms: []` (if any platform is missing from your PostFast workspace, it shows up there).
   - `PostFast — Schedule Post (per platform)` returns HTTP 2xx with the scheduled post id on each of the 5 calls.
   - `Notion — Mark as Posted` shows the page updated.
5. Verify in PostFast that 5 scheduled posts exist for today across the 5 accounts.
6. Revert/delete the test short so the cron doesn't re-fire it Sunday.
7. Toggle the workflow **Active**.

## Known gotchas / next iterations

- **Time of day.** Publication date is a calendar date (no hour). The code defaults to 09:00 UTC. To override, edit the `scheduledAt` expression in `Code — Explode Per Platform`.
- **Platform naming.** The code normalises platform strings to UPPERCASE (`YOUTUBE`, `INSTAGRAM`, `TIKTOK`, `LINKEDIN`, `X`). If PostFast ever returns a different casing/spelling, the `missingPlatforms` array in the Code node output will show what's unmatched.
- **PostFast controls per platform.** Current defaults:
  - YouTube: `youtubeIsShort: true`
  - Instagram: `instagramPublishType: "REEL"`, `instagramPostToGrid: true`
  - TikTok: `tiktokPrivacy: "PUBLIC"`, `tiktokAllowComments: true`, `tiktokAllowDuet: true`
  - LinkedIn: no controls
  - X: no controls
  Edit `PLATFORM_CONFIG` in the `Code — Explode Per Platform` node if you want different defaults (e.g. `FOLLOWER_OF_CREATOR` for TikTok).
- **No thumbnail customisation.** YouTube uses auto-generated thumbnails. If you want custom covers, upload an image with `scripts/upload-video.sh` (set `CONTENT_TYPE=image/jpeg`), paste that key, and add `youtubeThumbnailKey` to the YouTube controls in the Code node.
- **First comment not used.** You can add a `firstComment` property per post (X/Instagram/Facebook/YouTube/Threads only) if you want an automatic first comment — plumb it from a new Notion column.
- **HTTP traffic to n8n.** The deploy script runs over plain HTTP on `http://72.62.187.71:5678`. Fine from your laptop on a trusted network; wrap Caddy/nginx in front if you want HTTPS.
