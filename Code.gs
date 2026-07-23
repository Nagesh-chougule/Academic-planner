/**
 * Department Academic Planner — Google Apps Script Backend
 * ==========================================================
 * Single backend file (Code.gs) implementing a JSON REST-style API on top
 * of a Google Spreadsheet. Deploy as a Web App (Execute as: Me,
 * Who has access: Anyone) and paste the resulting /exec URL into the
 * APP_CONFIG.API_URL constant near the top of the HTML file.
 *
 * SHEETS (auto-created on first run if missing):
 *   Department   id, name, createdDate, updatedDate
 *   Programs     id, name, type, major, minor, totalTarget, semMin, semMax, semesters, createdDate, updatedDate
 *   Courses      id, programId, programName, sem, code, title, category, L, T, P, credits, createdDate, updatedDate
 *   Faculty      id, name, designation, specialization, maxLoad, createdDate, updatedDate
 *   Assignments  id, courseId, programName, sem, code, facultyId, facultyName, hours, createdDate, updatedDate
 *   Timetable    id, programId, programName, semester, division, day, period, courseId, code, facultyId, facultyName, room, createdDate, updatedDate
 *   Metadata     key, value, updatedDate
 *
 * API SHAPE
 * ---------
 * GET  ?action=getAll
 *      -> { ok:true, data:{ department:[...], programs:[...], courses:[...],
 *                            faculty:[...], assignments:[...], timetable:[...] } }
 *
 * GET  ?action=getRecord&sheet=Faculty&id=xxx
 * GET  ?action=searchRecords&sheet=Faculty&field=name&value=Patil
 *
 * POST body (text/plain, JSON-encoded — avoids CORS preflight):
 *   { action:"saveAll", data:{ department, programs, courses, faculty, assignments, timetable } }
 *      -> full-state bulk sync used by the app after every change (Create/Update/Delete
 *         all flow through this one call, so the whole planner stays in one transaction
 *         per user action instead of many chatty requests).
 *
 *   { action:"createRecord", sheet:"Faculty", record:{...} }
 *   { action:"updateRecord", sheet:"Faculty", id:"...", record:{...} }
 *   { action:"deleteRecord", sheet:"Faculty", id:"..." }
 *
 * All responses: { ok:true, data:... }  or  { ok:false, error:"message" }
 */

/* ============================= CONFIG ============================= */

const SHEET_SCHEMA = {
  Department:  ["id", "name", "createdDate", "updatedDate"],
  Programs:    ["id", "name", "type", "major", "minor", "totalTarget", "semMin", "semMax", "semesters", "createdDate", "updatedDate"],
  Courses:     ["id", "programId", "programName", "sem", "code", "title", "category", "L", "T", "P", "credits", "createdDate", "updatedDate"],
  Faculty:     ["id", "name", "designation", "specialization", "maxLoad", "createdDate", "updatedDate"],
  Assignments: ["id", "courseId", "programName", "sem", "code", "facultyId", "facultyName", "hours", "createdDate", "updatedDate"],
  Timetable:   ["id", "programId", "programName", "semester", "division", "day", "period", "courseId", "code", "facultyId", "facultyName", "room", "createdDate", "updatedDate"],
  Metadata:    ["key", "value", "updatedDate"],
};

const BULK_SHEETS = ["Department", "Programs", "Courses", "Faculty", "Assignments", "Timetable"];

/* ============================= ENTRY POINTS ============================= */

function doGet(e) {
  try {
    ensureAllSheets_();
    const params = (e && e.parameter) || {};
    const action = params.action || "getAll";

    if (action === "getAll") {
      return jsonOut_({ ok: true, data: getAllData_() });
    }
    if (action === "getRecord") {
      validateRequest_(params, ["sheet", "id"]);
      const rec = getRecord_(params.sheet, params.id);
      return jsonOut_(rec ? { ok: true, data: rec } : { ok: false, error: "Record not found" });
    }
    if (action === "searchRecords") {
      validateRequest_(params, ["sheet"]);
      const results = searchRecords_(params.sheet, params.field, params.value);
      return jsonOut_({ ok: true, data: results });
    }
    return jsonOut_({ ok: false, error: "Unknown action: " + action });
  } catch (err) {
    return jsonOut_({ ok: false, error: String(err && err.message || err) });
  }
}

function doPost(e) {
  try {
    ensureAllSheets_();
    if (!e || !e.postData || !e.postData.contents) {
      throw new Error("Missing request body");
    }
    const body = JSON.parse(e.postData.contents);
    const action = body.action;

    if (action === "saveAll") {
      validateRequest_(body, ["data"]);
      const result = saveAllData_(body.data);
      return jsonOut_({ ok: true, data: result });
    }
    if (action === "createRecord") {
      validateRequest_(body, ["sheet", "record"]);
      const rec = createRecord_(body.sheet, body.record);
      return jsonOut_({ ok: true, data: rec });
    }
    if (action === "updateRecord") {
      validateRequest_(body, ["sheet", "id", "record"]);
      const rec = updateRecord_(body.sheet, body.id, body.record);
      return jsonOut_(rec ? { ok: true, data: rec } : { ok: false, error: "Record not found" });
    }
    if (action === "deleteRecord") {
      validateRequest_(body, ["sheet", "id"]);
      const deleted = deleteRecord_(body.sheet, body.id);
      return jsonOut_({ ok: deleted, data: { id: body.id, deleted } });
    }
    return jsonOut_({ ok: false, error: "Unknown action: " + action });
  } catch (err) {
    return jsonOut_({ ok: false, error: String(err && err.message || err) });
  }
}

/* ============================= BULK SYNC (used by the app) ============================= */

/** Reads every data sheet into { department, programs, courses, faculty, assignments, timetable } */
function getAllData_() {
  const out = {};
  BULK_SHEETS.forEach(name => { out[toKey_(name)] = sheetToObjects_(name); });
  return out;
}

/**
 * Overwrites all six data sheets from the payload the frontend sends after every
 * create/update/delete. Existing row IDs keep their original createdDate; new rows
 * (no id, or an id not seen before) get a fresh id + createdDate. Runs inside a
 * script lock so two overlapping saves can't interleave and corrupt the sheets.
 */
function saveAllData_(data) {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const now = nowIso_();
    const counts = {};
    BULK_SHEETS.forEach(name => {
      const key = toKey_(name);
      const incomingRows = Array.isArray(data[key]) ? data[key] : [];
      const existingById = indexById_(name);
      const headers = SHEET_SCHEMA[name];

      const rows = incomingRows.map(row => {
        const id = row.id || generateUniqueId_();
        const prior = existingById[id];
        const merged = Object.assign({}, row, {
          id: id,
          createdDate: (prior && prior.createdDate) || row.createdDate || now,
          updatedDate: now,
        });
        return headers.map(h => (merged[h] === undefined || merged[h] === null) ? "" : merged[h]);
      });

      writeSheet_(name, headers, rows);
      counts[key] = rows.length;
    });
    setMetadata_("lastSync", now);
    return { savedAt: now, counts: counts };
  } finally {
    lock.releaseLock();
  }
}

/* ============================= SINGLE-RECORD CRUD ============================= */

function getRecord_(sheetName, id) {
  assertKnownSheet_(sheetName);
  return sheetToObjects_(sheetName).find(r => String(r.id) === String(id)) || null;
}

function searchRecords_(sheetName, field, value) {
  assertKnownSheet_(sheetName);
  const rows = sheetToObjects_(sheetName);
  if (!field) return rows;
  const needle = String(value || "").toLowerCase();
  return rows.filter(r => String(r[field] || "").toLowerCase().indexOf(needle) !== -1);
}

function createRecord_(sheetName, record) {
  assertKnownSheet_(sheetName);
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const headers = SHEET_SCHEMA[sheetName];
    const now = nowIso_();
    const existing = indexById_(sheetName);
    let id = record.id || generateUniqueId_();
    if (existing[id]) id = generateUniqueId_(); // never silently overwrite on create
    const full = Object.assign({}, record, { id: id, createdDate: now, updatedDate: now });
    const sheet = getSheet_(sheetName);
    sheet.appendRow(headers.map(h => full[h] === undefined || full[h] === null ? "" : full[h]));
    return full;
  } finally {
    lock.releaseLock();
  }
}

function updateRecord_(sheetName, id, record) {
  assertKnownSheet_(sheetName);
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const sheet = getSheet_(sheetName);
    const headers = SHEET_SCHEMA[sheetName];
    const values = sheet.getDataRange().getValues();
    const idCol = headers.indexOf("id");
    for (let r = 1; r < values.length; r++) {
      if (String(values[r][idCol]) === String(id)) {
        const prior = rowToObject_(headers, values[r]);
        const merged = Object.assign({}, prior, record, {
          id: id, createdDate: prior.createdDate, updatedDate: nowIso_(),
        });
        const rowArr = headers.map(h => merged[h] === undefined || merged[h] === null ? "" : merged[h]);
        sheet.getRange(r + 1, 1, 1, headers.length).setValues([rowArr]);
        return merged;
      }
    }
    return null;
  } finally {
    lock.releaseLock();
  }
}

function deleteRecord_(sheetName, id) {
  assertKnownSheet_(sheetName);
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const sheet = getSheet_(sheetName);
    const headers = SHEET_SCHEMA[sheetName];
    const values = sheet.getDataRange().getValues();
    const idCol = headers.indexOf("id");
    for (let r = 1; r < values.length; r++) {
      if (String(values[r][idCol]) === String(id)) {
        sheet.deleteRow(r + 1);
        return true;
      }
    }
    return false;
  } finally {
    lock.releaseLock();
  }
}

/* ============================= SHEET HELPERS ============================= */

function ss_() { return SpreadsheetApp.getActiveSpreadsheet(); }

function toKey_(sheetName) {
  // Sheet "Department" -> "department", "Timetable" -> "timetable", etc.
  const map = { Department: "department", Programs: "programs", Courses: "courses", Faculty: "faculty", Assignments: "assignments", Timetable: "timetable" };
  return map[sheetName] || sheetName.toLowerCase();
}

function assertKnownSheet_(name) {
  if (!SHEET_SCHEMA[name]) throw new Error("Unknown sheet: " + name);
}

/** Creates every configured sheet (with header row) if it does not already exist. */
function ensureAllSheets_() {
  Object.keys(SHEET_SCHEMA).forEach(name => getSheet_(name));
}

function getSheet_(name) {
  assertKnownSheet_(name);
  const spreadsheet = ss_();
  let sheet = spreadsheet.getSheetByName(name);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(name);
    sheet.getRange(1, 1, 1, SHEET_SCHEMA[name].length).setValues([SHEET_SCHEMA[name]]);
    sheet.setFrozenRows(1);
  } else if (sheet.getLastRow() === 0) {
    sheet.getRange(1, 1, 1, SHEET_SCHEMA[name].length).setValues([SHEET_SCHEMA[name]]);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function rowToObject_(headers, rowArr) {
  const obj = {};
  headers.forEach((h, i) => { obj[h] = rowArr[i]; });
  return obj;
}

function sheetToObjects_(name) {
  const sheet = getSheet_(name);
  const values = sheet.getDataRange().getValues();
  if (values.length < 2) return [];
  const headers = values[0];
  return values.slice(1)
    .filter(row => row.some(cell => cell !== "" && cell !== null && cell !== undefined))
    .map(row => rowToObject_(headers, row));
}

function indexById_(name) {
  const idx = {};
  sheetToObjects_(name).forEach(r => { idx[String(r.id)] = r; });
  return idx;
}

/** Clears all data rows (keeps header) and writes the given 2D array of values. */
function writeSheet_(name, headers, rows) {
  const sheet = getSheet_(name);
  const lastRow = sheet.getLastRow();
  if (lastRow > 1) {
    sheet.getRange(2, 1, lastRow - 1, headers.length).clearContent();
  }
  if (rows.length > 0) {
    sheet.getRange(2, 1, rows.length, headers.length).setValues(rows);
  }
}

function setMetadata_(key, value) {
  const sheet = getSheet_("Metadata");
  const values = sheet.getDataRange().getValues();
  for (let r = 1; r < values.length; r++) {
    if (values[r][0] === key) {
      sheet.getRange(r + 1, 2, 1, 2).setValues([[value, nowIso_()]]);
      return;
    }
  }
  sheet.appendRow([key, value, nowIso_()]);
}

/* ============================= UTILITIES ============================= */

function generateUniqueId_() {
  return "id_" + new Date().getTime() + "_" + Math.random().toString(36).slice(2, 9);
}

function nowIso_() {
  return new Date().toISOString();
}

function validateRequest_(obj, requiredFields) {
  const missing = requiredFields.filter(f => obj[f] === undefined || obj[f] === null || obj[f] === "");
  if (missing.length) {
    throw new Error("Missing required field(s): " + missing.join(", "));
  }
}

function jsonOut_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

/* ============================= ONE-TIME SETUP ============================= */

/**
 * Run this once manually from the Apps Script editor (select it in the
 * function dropdown and click Run) to pre-create all sheets with headers
 * before the first deployment. doGet/doPost also call ensureAllSheets_()
 * automatically, so this is a convenience, not a requirement.
 */
function setupSpreadsheet() {
  ensureAllSheets_();
  setMetadata_("schemaVersion", "1");
  Logger.log("Sheets ready: " + Object.keys(SHEET_SCHEMA).join(", "));
}
