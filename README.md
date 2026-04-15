# EO Shorts Auto-Publisher

Weekly n8n workflow that reads "Ready" shorts from the Notion planning DB, fans them out to PostFast on all target social platforms, and marks them as "Posted" in Notion.

## What it does

Every Sunday at 20:00 (Europe/Paris):

1. **Schedule Trigger** fires the run.
2. **Notion — Query Shorts** returns every page in the [Shorts EO — Weekly Posting Planning](https://www.notion.so/34028224657180d8951bcc555a2c66b8) database where `Back-up = Ready` and `Date de Publication` falls in the next 7 days.
3. **Code — Explode Platforms** parses the `Description` field, which contains per-platform captions prefixed by `YT:`, `SM:`, `LI:`, `X:`. It emits one item per (short × platform), expanding `SM` into both `instagram` and `tiktok`. A short with all four prefixes produces **5 PostFast posts**.
4. **HTTP — PostFast Schedule** POSTs each item to the PostFast scheduling API.
5. **Deduplicate by Notion Page ID** collapses back to one item per short.
6. **Notion — Mark as Posted** flips `Back-up` from `Ready` to `Posted`.

```
Schedule → Notion Query → Code (parse) → HTTP PostFast → Dedup → Notion Update
```

## Files

| Path | Purpose |
|---|---|
| `workflows/eo-shorts-auto-publisher.json` | n8n workflow definition (source of truth, versioned here) |
| `scripts/deploy-to-n8n.sh` | Deploys the JSON to `http://72.62.187.71:5678` via the n8n REST API |

## One-time setup

### 1. Generate an n8n API key

1. Open `http://72.62.187.71:5678`.
2. **Settings → n8n API → Create an API key**.
3. Copy the JWT token (shown only once).

### 2. Create the Notion integration + credential

1. Go to <https://www.notion.so/my-integrations> → **+ New integration**, workspace-internal, read + update permissions.
2. Copy the **Internal Integration Secret**.
3. Open the Notion page [Shorts EO — Weekly Posting Planning](https://www.notion.so/34028224657180d8951bcc555a2c66b8) → `⋯` menu → **Connections → Add connection →** your new integration.
4. In n8n: **Credentials → New → Notion API**, paste the secret, name it `Notion API`.

### 3. Create the PostFast HTTP Header Auth credential

In n8n: **Credentials → New → Header Auth**.

| Field | Value |
|---|---|
| Credential name | `PostFast API` |
| Header Name | `Authorization` |
| Header Value | `Bearer KWn4JvZyT6HwerFf+SPdFX56OiIhuykHJmGGfWsnmpg=` |

### 4. Set the PostFast endpoint variable

The workflow reads the endpoint from `$env.POSTFAST_API_URL` so that you can rotate it without editing the JSON.

1. In PostFast: **Settings → API** → copy the scheduling endpoint URL.
2. In n8n: **Settings → Variables → New variable**, key `POSTFAST_API_URL`, value = the URL from step 1.

> If your n8n instance doesn't expose the Variables pane (community edition), you can inline the URL directly into the `HTTP — PostFast Schedule` node's `URL` field.

## Deploy

```bash
export N8N_API_KEY="eyJhbGciOi..."              # from step 1
export N8N_PROJECT_ID="bnK2w5BUU8YLwyol"        # optional: project scope
# optional: export N8N_BASE_URL="http://72.62.187.71:5678"
# optional: export TARGET_WORKFLOW_ID="VztWOvTejsjBV4Vh8tL2o"  # overwrite a specific existing workflow

bash scripts/deploy-to-n8n.sh
```

The script is idempotent: first run POSTs the workflow and prints its ID; subsequent runs PUT the updated definition over the existing one. Set `TARGET_WORKFLOW_ID` to overwrite a specific workflow you already opened in the UI (e.g. the empty workflow you created at `/workflow/<id>`).

After deployment, open the workflow in the n8n UI to **(a)** map the two Notion nodes to your `Notion API` credential, **(b)** map the HTTP node to your `PostFast API` credential, then **(c)** run once manually to validate. Finally toggle the workflow Active.

## Testing end-to-end

1. In Notion, create a **test short** with:
   - `Back-up = Ready`
   - `Date de Publication = today`
   - `Description` containing all four markers, e.g.
     ```
     YT: Test caption for YouTube. #shorts | Tags: test
     SM: Test caption for Instagram + TikTok. #test
     LI: Test caption for LinkedIn, slightly longer.
     X: Test caption for X.
     ```
2. Open the workflow in n8n → **Execute Workflow**.
3. Verify in the execution log that the **HTTP — PostFast Schedule** step produced **5 successful calls** (1×YT + 1×IG + 1×TikTok + 1×LI + 1×X).
4. Verify in PostFast that 5 scheduled posts exist for today.
5. Verify in Notion that the test page now reads `Back-up = Posted`.
6. Delete the test short (or set it back to `Not started`) so it doesn't fire next Sunday.

## Known gotchas

- **`Date de Publication` is a date, not a datetime.** The short is sent to PostFast with only the calendar date; PostFast will default to its own posting time (check your PostFast defaults). If you need a specific hour, append a time in the Code node (e.g. `scheduledAt = dateRaw + 'T09:00:00+02:00'`).
- **PostFast API shape is an assumption.** The HTTP body sends `{ scheduledAt, caption, platform, title }`. If the actual PostFast API expects different field names, edit `jsonBody` in `HTTP — PostFast Schedule`.
- **Videos are assumed pre-uploaded.** The workflow only schedules posts that reference videos already uploaded manually in PostFast. If PostFast requires a `mediaId` in the body, add a `PostFast Media ID` column to the Notion DB and reference it in the Code node output.
- **`continueRegularOutput` on HTTP.** If one platform call fails (bad caption, rate limit, etc.), the remaining platforms still run, and the short is still marked Posted. If you'd rather have a failed platform block the Notion update, remove `onError` from the HTTP node and insert an `IF` before `Notion — Mark as Posted` that checks every call succeeded.
