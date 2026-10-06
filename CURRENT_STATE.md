# CineFlow — Current State

**Last updated:** 2026-10-06 · **Phase:** M1 DONE, M2 DONE (2026-10-06), M3 CURRENT · **Owner of this file:** human, with agent-proposed diffs

**This project is sequenced by dependency, not by date.** There is no deadline pressure. A milestone is finished when its gate is green — never because time has passed. If a gate is red, the correct action is always to stop and fix it, never to move on and come back.

This file is the answer to "what already exists?" Read it before starting any task. It exists so you do not re-implement completed work or assume something is done that is not.

---

## Status legend — the only distinction that matters

| Status | Meaning |
|---|---|
| **VERIFIED** | A gate or test proved it against a real engine. Treat as stable foundation. |
| **WRITTEN** | Text exists. Nothing has executed it. **Assume it contains errors.** |
| **NOT STARTED** | Does not exist. |

**Never mark something VERIFIED because it looks correct.** Only a green gate or a passing test promotes WRITTEN → VERIFIED. This distinction is the single most important thing in this file: on 2026-09-25 an entire specification was reviewed six times by two AI models and still contained three real defects, because review is not execution.

---

## 1. Specification — VERIFIED (human-reviewed, frozen)

| Artifact | Status |
|---|---|
| `DATA-CONTRACT.md` | **FROZEN** — schema, constraints, indexes, procedure signatures, error registry, test specs |
| `IMPLEMENTATION-STANDARDS.md` | **FROZEN** — IS-01…IS-05, LO-01 (+ Addendum A), PC-01, VG-01 |
| `DECISIONS.md` | Live decision log, 30 entries (D-023 to D-029 added 2026-10-06; D-030, D-031 added 2026-10-06) |
| `Docs/WEEK0-DEFENSE-PACK.md` | Scope, topology, demo runbook (its day numbers are superseded by §6) |
| `AGENTS.md` | Agent entry point |

Frozen means: propose changes, do not make them.

## 2. Database — M1 VERIFIED 2026-10-04

| Item | Status | Notes |
|---|---|---|
| SQL Server instance | **CONFIRMED 2026-09-28** | `.\SQLEXPRESS` — SQL Server 2025 Express. Proven by a successful `sqlcmd -S .\SQLEXPRESS -Q "SELECT @@SERVERNAME"`. Use this exact string in every migration, gate, and connection string. |
| `CineFlow` database | **VERIFIED** | Tables = 11. Rebuilt from clean 2026-10-04 (prior hand-repaired state dropped: database + `cineflow_app` login). |
| `V001__schema.sql` — 11 tables, `dbo.IntList` | **VERIFIED** | Gate 2(c) green: every frozen constraint/index present. 16 CHECKs, all `is_disabled = 0`, `is_not_trusted = 0`. |
| `V002__indexes.sql` | **VERIFIED** | 26 indexes on user tables (`sys.indexes` type > 0). |
| `V003__stored_procs.sql` — 9 procedures (D-020) | **VERIFIED** | All 9 applied twice (re-runnable); `uses_ansi_nulls` and `uses_quoted_identifier` = 1 on all 9; gate 2 green with the full manifest (D-023). Contract 5 from §5 (D-025..D-028); Login (D-021); SearchMovies (IS-01 pattern); CreateShowtime (D-030); GetSalesReport (D-031). |
| `V004__seed.sql` | NOT STARTED | |
| `V005__security.sql` — `cineflow_app` | **VERIFIED** | Login + user present; 7 permission rows. Gate 4 green. |

**M1 evidence (2026-10-04, `sqlcmd -b -I`, exit codes as observed).** Gate 1 OK (0). Gate 2 OK (0): ownership OK, schema-dbo-owned asserted per D-015 OK, constraints trusted OK, contract OK, signatures/defaults `[--] SKIPPED` per D-016. Gate 4 OK (0). Gate 3 FAIL 91010 (exit 1, expected: no procs/seed). Gate 5 FAIL 91010 (exit 1, expected: no procs/seed). Catalog: 11 tables, 16 CHECKs trusted, 26 indexes, 7 permission rows.

**M2 evidence (2026-10-06, `sqlcmd -b -I`, observed by the human).** Gate 1 OK. Gate 2 OK: ownership, schema-dbo, trusted, contract, `[OK] signatures`, `[OK] defaults` (after D-029 fixed the optionality detector). Gate 3 FAIL 91010 (expected: no seed; moves to M3, D-020). Gate 4 OK (TC-SEC-01; last run at the CancelBooking apply).

**M2 exit (2026-10-06, `sqlcmd -b -I`; `verify.bat` run by the human, gates 1 and 4 also by the agent).** All 9 procedures present. Gate 1 OK. Gate 2 OK with the full 9-procedure manifest: `[OK] signatures`, `[OK] defaults`, no SKIPPED or MISSING lines. Gate 4 OK (TC-SEC-01, at the final apply). Gate 3 FAIL 91010 (expected: no seed; M3). Validation calls: Login unknown user 50050; CreateShowtime unknown movie 50041, nothing written; SearchMovies and GetSalesReport return their headers with zero rows.

## 3. Verification harness — M1 gates green 2026-10-04 (gates 1, 2, 4)

| Gate | File | Status |
|---|---|---|
| 1 | `Tests/01_static_sql_scan.sql` | **VERIFIED** — OK (exit 0) 2026-10-04: no dynamic SQL (heuristic) |
| 2 | `Tests/02_ownership_and_constraints.sql` | **VERIFIED** — OK (exit 0) 2026-10-04: ownership OK, schema-dbo asserted (D-015) OK, trusted OK, contract OK, (d)/(e) SKIPPED printed (D-016), zero procs. 2026-10-06: (d) signatures and (e) defaults OK with 5 procs; (e) detector fixed by D-029. 2026-10-06: OK with all 9 procs (full manifest) |
| 3 | `Tests/03_smoke_as_app.sql` | Expected FAIL 91010 (exit 1): needs seed (M3); all 9 procs exist since 2026-10-06. Not a defect. |
| 4 | `Tests/04_security_denials.sql` | **VERIFIED** — OK (exit 0) 2026-10-04: all direct access denied |
| 5 | `Tests/05_invariants.sql` | Expected FAIL 91010 (exit 1): needs seed (M3); all 9 procs exist since 2026-10-06. Not a defect. |
| 6 | `Tests/Concurrency/BookingConcurrencyTests.cs` | WRITTEN, **never compiled** |
| runner | `Deploy/verify.bat` | **VERIFIED** — gates 1, 2 pass, stops at gate 3 (exit 1) as designed; all `sqlcmd` lines carry `-I` (D-017) |

**Known incomplete:** `BookingConcurrencyTests.cs` references `TestFixture` and `ContractScenarios`, which are **declared but not implemented**. They must be built at M3 before gate 6 can run. This is a known gap, not a bug to discover.

## 4. Application code — NOT STARTED

No solution, no projects, no forms. `CineFlow.sln` and the six projects are created **by the human in Visual Studio at the start of M5**, not by an agent — non-SDK-style `.csproj` files are easy to corrupt (see `DECISIONS.md` D-011).

The original `Movie-Ticket-Booking-Management-System` repo is archived read-only in `legacy\` (D-022). Do not reference, migrate, or copy any of it.

## 5. Environment

| Item | Value |
|---|---|
| Repo root | `C:\Users\gelos\Downloads\Movie-Ticket-Booking-Management-System-main` (original project in `legacy\`, D-022) |
| Agent | WorkBuddy AI IDE: commands via its Bash tool (Git Bash); its PowerShell tool returns no output |
| Agent editor | WorkBuddy AI IDE (not Visual Studio) |
| Designer / run / debug | Visual Studio (from M5 onward), operated by the human |
| Shell | PowerShell — see the invocation note below |
| Target | .NET Framework 4.7.2, WinForms |
| Database | SQL Server 2025 **Express**, instance `.\SQLEXPRESS`, LAN only |
| SQL client | `sqlcmd` (authoritative for all gates) · SSMS 22 for browsing only |
| Terminals | 2 cashier stations for the concurrency demo |

**PowerShell invocation note.** Gates are Windows batch and `sqlcmd`. From PowerShell:

```powershell
.\Deploy\verify.bat          # the .\ prefix is required; `verify.bat` alone will not resolve
echo $LASTEXITCODE            # 0 = all gates green; non-zero = a gate failed
```

PowerShell does not surface `ERRORLEVEL`. Always read `$LASTEXITCODE` immediately after the call — before running anything else, since the next command overwrites it. A gate failure that is not read is indistinguishable from a pass.

**Edition note — D-002 stands.** This is Express, so SQL Server Agent is absent and the lazy guarded expiry decision (`DECISIONS.md` D-002) is unchanged. If the edition ever changes to Developer or Standard, Agent becomes available and D-002's reopening condition is met — the recorded position is to **retain lazy purge deliberately**, so that the purge mechanism never depends on the edition.

**SSMS connection settings.** Server name `.\SQLEXPRESS`, Windows Authentication, and **Trust Server Certificate ticked** — SSMS 20+ defaults `Encrypt=Mandatory`, which rejects the local self-signed certificate. The same applies to the eventual .NET connection string (`TrustServerCertificate=True`). The Server Name dropdown stays empty on Express because SQL Browser is off by default; that is not a fault.

**Agent memory vs. this repo.** The agent may carry memory across sessions. If that memory conflicts with any file in this repo, **the file wins.** Recalled state is not verified state; only a gate promotes WRITTEN → VERIFIED.

**Non-SDK `.csproj` reminder:** a file created in VS Code is **not in the build** until it has a `<Compile Include>` entry. Symptom is "type or namespace not found" for a class that plainly exists. Do not rewrite the class — include the file.

---

## 6. Milestone gates

Each phase ends at a gate. **Do not begin a phase until the previous gate is green.** Milestones are ordered by dependency: each one is unbuildable until the one above it is proven. Ignore any day numbers found elsewhere in the docs — this table is the authority on ordering.

| # | Phase | Depends on | Exit gate | Status |
|---|---|---|---|---|
| M0 | Specification frozen | — | Four artifacts written and reviewed | **DONE** |
| M1 | Schema + security | M0 | `verify.bat` gates 1, 2, 4 pass | **DONE (2026-10-04)** |
| M2 | Stored procedures | M1 (tables must exist) | gates 1, 2 (no SKIPPED lines) and 4 pass; gate 3 moves to M3 (D-020) | **DONE (2026-10-06)** |
| M3 | Seed + invariants | M2 (procs write the data) | all 5 SQL gates pass | **CURRENT** |
| M4 | **Concurrency proof** | M3 (needs real rows) | TC-CONC-01/02, TC-CANCEL-01/02, TC-PURGE, TC-PAY all green | pending |
| M5 | Data + business layers | M4 (contract proven before wrapping it) | unit tests pass; no SQL above the DAL | pending |
| M6a | UI design tokens (D-014) | M5 | palette, type scale, spacing, library decision recorded | pending |
| M6b | UI — seat map first | M6a | booking flow works end to end on two terminals | pending |
| M7 | Full verification + fix | M6b | full suite green from a clean database | pending |
| M8 | Documentation | M7 | SRS, ERD, diagrams | pending |
| M9 | Codebase read-through | M8 | human can explain every file unaided | pending |
| M10 | Defense rehearsal | M9 | demo runbook executed twice without notes | pending |

**M4 is the project's thesis.** Everything below it is presentation; everything above it is prerequisite. M4 is never cut, never deferred, and never marked done on inspection.

**With no deadline, the failure mode changes.** Time pressure causes skipped verification; unlimited time causes scope creep and endless polishing. The guard is the same table: do not add work to a milestone that is already green, and do not start a milestone whose predecessor is not.

---

## 7. Known open risks

| Risk | Mitigation | Status |
|---|---|---|
| Agent reaches for dynamic SQL in `usp_SearchMovies` (optional filters make it the natural approach) | Gate 1 + IS-01 example pattern | **Resolved 2026-10-06**: static IS-01 pattern; gate 1 OK |
| Agent uses `WITH NOCHECK` when seed data violates a constraint | Gate 2 `is_not_trusted` check | Watch at M3 |
| `TestFixture` / `ContractScenarios` unimplemented | Build at M3 | Open |
| Agent edits `*.Designer.cs` | `AGENTS.md` §5 prohibition | Watch at M6b |
| Files created in VS Code missing from `.csproj` | Human includes in VS | Watch from M5 |
| No deadline → scope creep, endless UI polish, reopening settled decisions | §6 rule: no work added to a green milestone; `DECISIONS.md` reopening criteria | Open |
| Multi-seat lock ordering not guaranteed by `INSERT…SELECT…ORDER BY` | TC-CONC-02 asserts no error 1205 | Open until M4 |
| `usp_GetSeatMap` returns an extra `PurgedCount` result set when its guard fires (D-024) | DAL reads it through one helper that skips to the seat rows; an M3 test covers both cases | Open until M5 |
| Concurrent retries of one `RequestToken` in `usp_ConfirmPayment`: the loser gets 50016, not `WasDuplicate=1` | Check TC-PAY-05's expected outcome; if it requires `WasDuplicate=1`, re-check the token after the `Bookings` lock | Open until M4 |
| Tests that call Confirm/Cancel via `INSERT ... EXEC` and expect a THROW get 3915 from the procedure's ROLLBACK | Check when gate 5 first runs | Watch at M3 |
| Line endings differ by file (V003, CURRENT_STATE: CRLF; DECISIONS, DATA-CONTRACT, Tests/02: LF); `core.autocrlf` warns on every diff | Add `.gitattributes` | Open |
| M6a cites D-014, but `DECISIONS.md` has no D-014 | Record it or re-cite before M6a | Open |
| `usp_Login`, `usp_SearchMovies`, `usp_CreateShowtime`, `usp_GetSalesReport` happy paths unproven (only error or empty paths observed) | Tests with seed data at M3 (D-020 carried forward) | Open until M3 |
| No procedures add or edit movies, screens or users; the EXECUTE-only login cannot write them any other way | Decide before M5: admin procedures (each with a D-record) or seed-only reference data | Open |
| `usp_SearchMovies` does not return `PosterPath` (IS-01 column list); M6 movie cards need it | Add with a D-record at M6 | Watch at M6 |

---

## 8. How to update this file

Agents **propose** a diff in the task report; the human applies it. Rules:

- Promote WRITTEN → VERIFIED **only** with the gate output that proves it, pasted in the report.
- Never delete a risk row. Move it to resolved with the date and the test that closed it.
- Update the phase header line at the top on every change.
- Record milestones by **gate result**, never by elapsed time.

**Unproven / carried forward (M1, 2026-10-04).**

a. V001/V002/V005 apply exit codes were not captured (state verified by gate 2, not by apply log). Covered by rebuild script at M7.

b. Gate 2 path 91007 (partial procedure set): first exercised at M2. Exercised at M2: fired correctly while 2-4 of the 5 contract procs existed.

c. Gate 2 section (e) default/optional check: compiles, first runs at M2. First ran at M2: false positives, fixed by D-029; now OK.

d. `verify.bat` failure banner still says 'today's work': cosmetic.

- Keep this file **short**. It is read every session; if it grows past ~200 lines it stops being read, which defeats its purpose. Detail belongs in `DATA-CONTRACT.md` or `DECISIONS.md`.
