# Department Academic Planner — Google Sheets Backend
## Deployment & Testing Guide

## What changed
- The frontend (`dept-academic-planner.html`) is still one file. Its only local
  browser storage (`window.storage`) was removed and replaced with `fetch()`
  calls to a Google Apps Script Web App, which reads/writes a Google
  Spreadsheet.
- Every existing action in the app (add/edit/delete a program, course,
  faculty member, assignment, or timetable slot) already funneled through one
  function, `saveProject()`. That function now POSTs the entire current state
  in one request (`action:"saveAll"`) — a "Saving…" / "✓ Saved successfully"
  toast appears bottom-right. This keeps the UI, layout and every feature
  identical, and keeps API calls to a minimum (one bulk call per action
  instead of many small ones).
- `Code.gs` also exposes true single-record `createRecord` / `updateRecord`
  / `deleteRecord` / `getRecord` / `searchRecords` endpoints per sheet, for
  direct testing or future extension — see the Testing section below.

## Part 1 — Create the Google Spreadsheet
1. Go to [sheets.google.com](https://sheets.google.com) and create a **new
   blank spreadsheet**. Name it e.g. `Dept Academic Planner DB`.
2. You do not need to create any tabs by hand — the script creates
   `Department`, `Programs`, `Courses`, `Faculty`, `Assignments`,
   `Timetable`, and `Metadata` automatically the first time it runs.

## Part 2 — Create the Apps Script project
1. In the spreadsheet, go to **Extensions → Apps Script**.
2. Delete the placeholder `myFunction()` code in `Code.gs`.
3. Paste in the full contents of the provided **`Code.gs`** file.
4. Click **Save** (the disk icon), then rename the project (top left) to
   something like `Dept Planner API`.
5. In the function dropdown at the top, select `setupSpreadsheet` and click
   **Run** once. The first run will ask you to authorize the script —
   accept the permissions (it only needs access to this spreadsheet). This
   pre-creates all sheets with header rows; you'll see them appear as tabs.

## Part 3 — Deploy as a Web App
1. Click **Deploy → New deployment**.
2. Click the gear icon next to "Select type" and choose **Web app**.
3. Configure:
   - **Description:** `Dept Planner API v1`
   - **Execute as:** `Me (your account)`
   - **Who has access:** `Anyone` (required so the HTML file, opened in any
     browser, can call it — the URL itself is the only "secret")
4. Click **Deploy**, then **Authorize access** again if prompted.
5. Copy the **Web app URL** shown (it ends in `/exec`).

> If you edit `Code.gs` later, you must create a **new deployment version**
> (Deploy → Manage deployments → pencil icon → New version → Deploy) for the
> changes to take effect on the same URL.

## Part 4 — Connect the HTML file
1. Open `dept-academic-planner.html` in a text editor.
2. Find this near the top of the `<script>` block:
   ```js
   const APP_CONFIG = {
     API_URL: "PASTE_YOUR_APPS_SCRIPT_WEB_APP_URL_HERE",
   };
   ```
3. Replace the placeholder with the URL you copied, e.g.:
   ```js
   const APP_CONFIG = {
     API_URL: "https://script.google.com/macros/s/AKfycb.../exec",
   };
   ```
4. Save the file. That's the only configuration needed — everything else
   (sheet names, columns, sheet creation) is handled automatically.

## Part 5 — Test the application
1. Open the HTML file in a browser (double-click it, or serve it from any
   static host — no build step is required).
2. On load you should briefly see a **"Loading…"** toast, then **"✓ Loaded
   from Google Sheets"**. On a brand-new spreadsheet this loads an empty
   project — that's expected.
3. Go to **Department & Programs**, add a program. You should see
   **"Saving…"** then **"✓ Saved successfully"**. Check the spreadsheet — a
   new row should appear in the `Programs` tab within a couple of seconds,
   with `id`, `createdDate`, and `updatedDate` filled in.
4. **Reload the page.** Your program should still be there — confirming
   persistence through the backend rather than the browser.

### Functional test checklist
| Area | Steps | Expected |
|---|---|---|
| Create | Add a Program, Course, Faculty member, Assignment, Timetable slot | Each appears immediately in the UI and in the matching sheet tab after the "Saved" toast |
| Read | Reload the page | All data reloads exactly as left it |
| Update | Edit a faculty member's max load / an assignment's hours | Sheet row's `hours`/`maxLoad` and `updatedDate` change; `createdDate` stays the same |
| Delete | Delete a faculty member (cascades to their assignments/timetable slots per existing app logic) | Rows disappear from `Faculty`, `Assignments`, `Timetable` sheets |
| Multiple records | Add 5+ programs, several courses per semester | All rows persist correctly, no data loss or duplication on reload |
| Search/Filter | Use the existing semester tabs / program selector | Filtering still works (this is unchanged client-side logic operating on the loaded data) |
| Excel import/export | Export to `.xlsx`, then re-import it | Import replaces state locally and then syncs to Google Sheets (same as any other change) |
| Error handling | Temporarily set `API_URL` to an invalid string, try to save | A red **"⚠ Network Error…"** style toast appears instead of the app breaking |

### Testing the Apps Script API directly (optional, for the single-record endpoints)
You can test these with `curl`, Postman, or your browser (for GET requests),
using your deployed `/exec` URL:

```bash
# Read everything
curl "https://script.google.com/macros/s/XXX/exec?action=getAll"

# Get one record
curl "https://script.google.com/macros/s/XXX/exec?action=getRecord&sheet=Faculty&id=id_123"

# Search
curl "https://script.google.com/macros/s/XXX/exec?action=searchRecords&sheet=Faculty&field=name&value=Patil"

# Create (note: text/plain body, not application/json, to avoid CORS preflight)
curl -X POST "https://script.google.com/macros/s/XXX/exec" \
  -H "Content-Type: text/plain" \
  -d '{"action":"createRecord","sheet":"Faculty","record":{"name":"Dr. Test","designation":"Lecturer","specialization":"Testing","maxLoad":16}}'

# Update
curl -X POST "https://script.google.com/macros/s/XXX/exec" \
  -H "Content-Type: text/plain" \
  -d '{"action":"updateRecord","sheet":"Faculty","id":"id_123","record":{"maxLoad":18}}'

# Delete
curl -X POST "https://script.google.com/macros/s/XXX/exec" \
  -H "Content-Type: text/plain" \
  -d '{"action":"deleteRecord","sheet":"Faculty","id":"id_123"}'
```
Every response is JSON shaped as `{"ok":true,"data":...}` or
`{"ok":false,"error":"..."}` — check `ok` before trusting `data`.

## Spreadsheet structure reference
| Sheet | Columns |
|---|---|
| Department | id, name, createdDate, updatedDate |
| Programs | id, name, type, major, minor, totalTarget, semMin, semMax, semesters, createdDate, updatedDate |
| Courses | id, programId, programName, sem, code, title, category, L, T, P, credits, createdDate, updatedDate |
| Faculty | id, name, designation, specialization, maxLoad, createdDate, updatedDate |
| Assignments | id, courseId, programName, sem, code, facultyId, facultyName, hours, createdDate, updatedDate |
| Timetable | id, programId, programName, semester, division, day, period, courseId, code, facultyId, facultyName, room, createdDate, updatedDate |
| Metadata | key, value, updatedDate (used internally, e.g. `lastSync`) |

`programId`/`courseId`/`facultyId` are the relational links between tables;
the `*Name` columns are denormalized for readability when you open the sheet
directly — the app itself always resolves by ID first, falling back to name
matching only when an ID is missing (e.g. after a manual edit in the sheet).

## Notes on the design decisions
- **Bulk sync instead of per-field API calls:** the original app already
  treats a save as "the whole project state" (it called one `saveProject()`
  after every change). Keeping that shape and just changing what
  `saveProject()`/`loadProject()` talk to was the smallest, safest way to
  swap the backend without touching any of the 15+ UI/CRUD call sites or
  risking regressions — while still fully satisfying "no manual save
  button" and "sync immediately after every change." The single-record
  `createRecord`/`updateRecord`/`deleteRecord` endpoints are provided in
  `Code.gs` for direct API use or future incremental-sync work.
- **`LockService`** in `Code.gs` prevents two overlapping saves from
  corrupting a sheet if you ever have two browser tabs open at once.
- **CORS:** POST bodies are sent as `text/plain` (containing JSON text) on
  purpose — Apps Script Web Apps cannot answer the `OPTIONS` preflight that
  browsers send for `application/json` POST bodies, so this avoids that
  entirely without needing any special server-side CORS headers.
