# Changelog - Lead Merger

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 1.4 - Newest-first deduplication
### Added
- Normalized-phone deduplication so the newest lead wins when duplicate
  phones appear across sources.
- `deduplicateMasterLeads()` for manual or web-app cleanup of existing
  `All Leads` rows.

### Changed
- `mergeLeads()` now sorts source rows newest-first before writing the
  master table.
- Date values are preserved as sheet dates, with display/phone formatting
  applied after each write.
- Updated README behavior, API, and limitation notes for deduplication.

## 1.3 - Web app authorization helper
### Added
- `authorizeWebApp()` to force the spreadsheet, trigger-management, and
  email permission prompts before using the deployed web app.
- Clearer `needsAuthorization` JSON response when Apps Script returns a
  missing-permission error from `doPost(e)`.

### Changed
- Updated README setup and troubleshooting notes for
  `ScriptApp.getProjectTriggers` authorization errors.

## 1.2 - Web app doPost trigger manager
### Added
- `doPost(e)` so the project can be deployed as an Apps Script web app.
- JSON actions for `run`, `trigger`, `delete`, and `list`, matching the
  trigger-manager pattern used by the lead sorting scripts.
- `appsscript.json` with V8 runtime, web app settings, and
  spreadsheet/trigger/email scopes.

### Changed
- Restricted remote runs and time-based trigger creation to `mergeLeads`
  and `applyLeadColors`; `sendLeadEmail` remains internal to the merge
  pipeline.
- Updated README deployment notes and web app API documentation.

## 1.1 - Bajaj-style documentation pass
### Changed
- Reworked `README.md` to follow the Bajaj documentation shape: workflow
  diagram, first-time setup, recommended triggers, function reference,
  sheet layout, known limitations, and file list.
- Documented the notification resend risk when `mergeLeads()` is run on a
  schedule.
- Behavior unchanged; this is a documentation-only update.

## 1.0 - Initial archive documentation
### Added
- Project README with setup, configuration, behavior, and operational
  notes.
- Changelog to start tracking documentation and script changes.
