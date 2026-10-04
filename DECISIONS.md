# CineFlow — Decision Log

One entry per architectural decision. **The rejected column is the most valuable part of this file** — without it, an agent re-proposes a discarded option every few sessions and each rediscovery costs a review round.

Format: context → decision → rejected alternatives and why → what would reopen it.

---

## D-001 — A separate `ShowtimeSeatLocks` table is live inventory

**Context.** Seat availability could be derived from `BookingSeats` joined to `Bookings` filtered by status.

**Decision.** A dedicated `ShowtimeSeatLocks` table with `PRIMARY KEY (ShowtimeId, SeatId)`. A row exists **if and only if** a seat is currently unavailable. `BookingSeats` is historical and retains cancelled and expired bookings.

**Why.** This makes double-selling **impossible at the storage engine level** rather than merely unlikely. The second concurrent insert of the same key cannot succeed — no application logic, no isolation level, no hint required. This is the project's thesis and the answer to "what makes this different from a normal CRUD project."

**Rejected:** deriving availability from `BookingSeats` — correctness would then depend on every query remembering the right status filter, and nothing would prevent two sessions both reading "available" and both inserting.

**Reopens if:** never, within this scope. Removing it removes the thesis.

---

## D-002 — Lazy, guarded hold expiry instead of a scheduled job

**Context.** 10-minute holds must be reclaimed when abandoned.

**Decision.** `usp_PurgeExpiredHolds` runs on read and write paths, guarded by `IF EXISTS (SELECT 1 FROM Bookings WHERE Status = 'PENDING' AND ExpiresAt < SYSUTCDATETIME())` against the filtered index `IX_Bookings_PendingExpiry`.

**Why.** **SQL Server Agent does not exist in SQL Server Express.** A scheduled job is not available at all — this is a platform fact, not a preference. The `IF EXISTS` guard exists because an unguarded purge would make every seat-map read a write transaction, putting a write lock on the hottest read path in the system.

**Rejected:** SQL Server Agent job (unavailable in Express); a standalone Windows Service (extra deployment surface, another process to explain and demo); a client-side timer (expiry stops when the app closes).

**Reopens if:** the deployment target changes to Standard edition or above.

---

## D-003 — No API tier; WinForms talks directly to SQL Server

**Context.** A service layer between client and database was proposed.

**Decision.** Two WinForms clients connect directly to SQL Server Express over the LAN, port 1433, no external exposure.

**Why.** The trust model is an **internal cashier terminal**, not a public surface. Staff are authenticated and physically present. An API tier would add a process to deploy, secure, monitor and explain, defending against a threat this topology does not have. The security boundary is instead the `cineflow_app` login: `EXECUTE` only, all DML DENYed, so even a fully exposed connection string cannot read or write a single table directly.

**Rejected:** ASP.NET Core Web API tier — correct for a customer-facing system, unjustified complexity here. Adopting it would also have required rewriting the client.

**Reopens if:** any customer-facing surface enters scope. Then it is mandatory, not optional.

---

## D-004 — Static SQL only; no dynamic SQL anywhere (IS-01)

**Context.** `usp_SearchMovies` has optional filters. Building a `WHERE` clause as a string is the obvious implementation.

**Decision.** Null-coalescing pattern with `OPTION (RECOMPILE)`:

```sql
WHERE (@Genre IS NULL OR m.Genre = @Genre)
  AND (@Rating IS NULL OR m.Rating = @Rating)
OPTION (RECOMPILE)
```

**Why.** Dynamic SQL **breaks ownership chaining**. `cineflow_app` has `EXECUTE` on procedures but no table permissions; ownership chaining is what lets a proc read tables the caller cannot. Dynamic SQL executes in the caller's context, so the statement fails with a permission error at runtime — and only on the path with the filter combination nobody tested. `OPTION (RECOMPILE)` recovers the plan quality that motivated dynamic SQL in the first place.

**Rejected:** `sp_executesql` with parameters — parameterisation solves injection, not ownership chaining. The two problems are unrelated and conflating them is the trap.

**Reopens if:** never.

---

## D-005 — Dual enforcement: procedure validation **and** schema constraint (IS-05)

**Context.** Validating in the procedure seemed sufficient.

**Decision.** Every invariant is enforced twice — in the procedure for a good error message, and as a schema constraint for correctness. `WITH NOCHECK` is never acceptable; gate 2 fails on `is_disabled` or `is_not_trusted`.

**Why.** Procedure validation is bypassed by direct DML, by a bad edit, and by an agent rewriting the proc. The constraint holds regardless. Concretely: `CHECK (ChangeDue >= 0)` holds even when the validation path that should have caught it was forgotten — which is exactly what happened in review.

**Rejected:** procedure-only validation (bypassable); constraint-only (unusable error messages for a cashier).

---

## D-006 — Contracts stated as outcomes, not enumerated causes (PC-01)

**Context.** `usp_ConfirmPayment` catches unique-violation errors 2601/2627 and re-queries by `RequestToken` to return the existing payment idempotently.

**Decision.** **PC-01:** a scalar-outcome procedure returns exactly one row or throws. It never returns empty. The `CATCH` re-queries by `RequestToken`; if no row is found it throws 50021. The DAL additionally throws `DataIntegrityException` if a reader returns no rows.

**Why.** The original `CATCH` was written for one cause — `UX_Payments_Token`. A **different** unique index, `UX_Payments_ActiveBooking`, throws the **same error numbers**. The re-query would find nothing, fall to `RETURN`, and produce an **empty result set with no error**: no ticket, no error message, silent data loss on the one path the whole design exists to protect. Enumerating causes fails whenever a cause is missed; asserting the outcome holds for causes nobody enumerated.

**Rejected:** branching on `ERROR_MESSAGE() LIKE '%UX_Payments_Token%'` — couples runtime behavior to a schema object's **name**, so renaming an index silently disables idempotent return with no gate catching it, and it string-matches a localized, format-unstable server message. **Do not reintroduce this.**

**Generalisation.** This is the project's recurring defect shape: *a mechanism that validates something, so it reads as validated, while a precondition sits unstated.* State contracts as outcomes.

---

## D-007 — `usp_ConfirmPayment` derives the total; `@Amount` removed

**Context.** The signature took `@Amount` from the caller and computed `ChangeDue = @AmountTendered - @Total`.

**Decision.** Signature is `@BookingId, @RequestToken, @Method, @AmountTendered = NULL, @ReferenceNumber = NULL, @ProcessedBy`. `@Total` is read from `Bookings`. `@AmountTendered` is cash-only, `@ReferenceNumber` digital-only, each conditionally required. Backed by `CK_Payments_NonNegativeChange` and `CK_Payments_MethodFields`.

**Why.** Two real defects. First, no check that tendered covered the total — a negative `ChangeDue` could commit silently. Second, and worse: the obvious one-line fix `IF @AmountTendered < @Total THROW` is **inert for card and e-wallet payments**, because `@AmountTendered` is `NULL` there and `NULL < @Total` evaluates to `UNKNOWN`, not `TRUE`. A guard that looks like a guard and never fires. Three-valued logic is a standing hazard for agent-written SQL.

**Rejected:** trusting a caller-supplied `@Amount` (client-controlled money); a single nullable amount column for both payment types (no way to require the right one).

---

## D-008 — `verify.bat` runs daily from Day 3, each gate in its own connection

**Context.** Verification was originally scheduled for Days 15–17.

**Decision.** `verify.bat` is built on Day 3 and run at the end of **every** working day. Each gate is a separate `sqlcmd -S %SRV% -d %DB% -b -i …` invocation.

**Why.** A constraint violated on Day 4 would otherwise not surface until Day 15, with eleven days of code built on top of it. Separate connections matter because a severity-20 error terminates the connection before `CATCH` runs, which could leak an `EXECUTE AS` security context into the next gate; `-b` makes `sqlcmd` return a nonzero exit code so failures actually stop the run.

**Rejected:** one connection for all gates (context leakage, and one doomed transaction poisons later gates); verification as a final phase (defeats the purpose).

---

## D-009 — `CK_Bookings_ExpiryLifecycle` makes the filtered index complete

**Context.** The purge guard treats `IX_Bookings_PendingExpiry` (`WHERE Status = 'PENDING'`) as the complete set of purge candidates.

**Decision.**

```sql
CONSTRAINT CK_Bookings_ExpiryLifecycle CHECK (
    (Status =  'PENDING' AND ExpiresAt IS NOT NULL) OR
    (Status <> 'PENDING' AND ExpiresAt IS NULL)
)
```

**Why.** On inspection the design was already correct: confirm sets `Status` and `ExpiresAt` in one statement, so the row leaves the filtered index the instant it stops being PENDING, whatever `ExpiresAt` holds. But that made it correct **by convention** — true of today's code paths, not of tomorrow's. The constraint converts it into an enforced property: a PENDING row cannot hide from the index with a null expiry, and a non-PENDING row cannot linger with a stale one. Same move as D-001, applied to a different invariant.

**Gated by:** TC-PURGE-02, which drives all four invalid `(Status, ExpiresAt)` combinations.

---

## D-010 — Cancellation deletes lock rows synchronously, in the same transaction

**Context.** Could cancellation defer seat release to the purge job?

**Decision.** `usp_CancelBooking` deletes the `ShowtimeSeatLocks` rows in the **same transaction** as the status change, holding `UPDLOCK, HOLDLOCK` on the `Bookings` row first.

**Why.** Any deferral creates a window in which a cancelled seat still reads as HELD and is therefore unsellable. Atomic commit means no reader can observe that intermediate state. There is no asynchronous release path anywhere in the design; `DATA-CONTRACT.md` §1.5 enumerates the complete three-place lock lifecycle so no agent invents a fourth.

**Gated by:** TC-CANCEL-01 (synchronous release) and TC-CANCEL-02 (cancel racing rebook).

### D-010a — LO-01 corrected: serialization comes from `PK_SeatLock`, not a `Bookings` lock

LO-01 originally said "always lock the `Bookings` row first," which was imprecise in a way that mattered. `usp_CreateBooking` **inserts** its `Bookings` row — a new, uncontended key, so locking it first guarantees nothing. What actually serializes booking against cancellation is the **engine's X key lock on `PK_SeatLock (ShowtimeId, SeatId)`**, automatically and without hints.

Pushing on that surfaced a **real deadlock path** that no review round had found: two multi-seat bookings taking overlapping seats in opposite order deadlock, and the loser dies with error **1205**, not a clean 50001. LO-01b therefore requires ordered materialization before insert in every procedure touching multiple seat keys, and TC-CONC-02 must assert `ErrorNumber != 1205`. **Any 1205 in the suite is an LO-01b violation, never a retryable flake.**

---

## D-011 — Humans own `.sln`, `.csproj`, `*.Designer.cs`, `*.resx`

**Context.** Could the agent scaffold the solution?

**Decision.** The human creates all six projects in Visual Studio and owns project files and designer-generated files. Agents write logic files only.

**Why.** Non-SDK-style `.csproj` is verbose XML where agents produce plausible-but-broken output — wrong `TargetFrameworkVersion`, missing references, malformed XML. Five minutes of clicking beats an hour of debugging XML. The WinForms designer **regenerates** `InitializeComponent()`, so hand-edited `.Designer.cs` is either overwritten or crashes at runtime with duplicate controls.

**Consequence to remember:** a file created in VS Code is **not in the build** until it has a `<Compile Include>` entry. The symptom is "type or namespace not found" for a class that exists. Include the file; do not rewrite the class.

---

## D-012 — Encrypted `App.config` cut from scope

**Context.** Encrypting the connection string was proposed as a security feature.

**Decision.** Cut. `App.config` ships plaintext, is git-ignored, and `App.config.template` is committed. `Deploy/encrypt-config.bat` exists as an **optional post-install step only**, never a build artifact.

**Why.** DPAPI machine-key encryption is **machine-tied**: a config encrypted on the dev machine cannot be decrypted anywhere else, so it would break the app on a lab or panel-provided machine. "Our security feature broke our demo" is a bad way to lose points. The real credential control is the least-privilege `cineflow_app` login, which cannot touch a table even with a fully exposed connection string — encryption here would be largely security theater.

**Rejected:** shipping DPAPI encryption as a required build step (demo-day risk with little real gain).

---

## D-013 — Two-AI review is exhausted; verification replaces it

**Context.** Six rounds of adversarial review between two AI models converged on agreement.

**Decision.** Stop reviewing. Move to execution against a real engine. Reserve second-opinion review for cases where the first read is confident but the human cannot follow **why** it is right.

**Why.** Two models with shared training-derived priors converging is evidence that **this review method is exhausted**, not that the design is correct. All three real defects (D-006, D-007, D-010a) were found by someone starting from an angle no prior round had used — not by a closer read of the same material. Continuing to find smaller things to justify another pass is its own over-fitting problem. The structural replacement is `verify.bat`: gates that run every day regardless of who remembers to look.

**Consequence:** `CURRENT_STATE.md` distinguishes **WRITTEN** from **VERIFIED**, and only a green gate promotes one to the other.

---

## D-015 — `ALTER AUTHORIZATION ON SCHEMA::dbo` removed; ownership is asserted, not set

**Context.** DATA-CONTRACT.md §8 instructed `ALTER AUTHORIZATION ON SCHEMA::dbo TO dbo;`. It fails on every SQL Server with Msg 15150: the owner of `sys`, `dbo` and `information_schema` cannot be changed.

**Decision.** Removed from V005 and the contract. Gate 2 asserts `dbo` owns schema `dbo` and throws 91002 if not. The 91002 remedy text now names `ALTER AUTHORIZATION ON OBJECT::dbo.<name> TO SCHEMA OWNER`, which actually repairs a misowned object.

**Rejected.** Wrapping the impossible statement in TRY/CATCH: it hides failing DDL.

**Found by.** First real execution, M1, SQL Server 2025 Express.

---

## D-016 — Gate 2 skips procedure checks when none exist; a partial set fails hard

**Context.** Gate 2 (d)/(e) read sys.procedures. At M1 none exist, so 91005 fired and the M1 exit condition was impossible.

**Decision.** Count the five contract procedures first. Zero → printed `[--] SKIPPED`, green. Some but not all → `THROW 91007 PARTIAL PROCEDURE SET`. All five → full manifest.

**Why.** The real failure is four out of five, which looks like progress. Skips are always printed, never silent. During M2, 91007 firing between procedure creations is expected.

**Found by.** Agent report, M1. The agent refused to edit the frozen test and escalated.

---

## D-017 — Every `sqlcmd` invocation passes `-I`

**Context.** sqlcmd defaults QUOTED_IDENTIFIER OFF. Bookings and Payments carry filtered indexes, so CREATE INDEX and any DML on them fail Msg 1934. `ALTER DATABASE … SET QUOTED_IDENTIFIER ON` does not override sqlcmd.

**Decision.** (1) verify.bat passes `-I` on all gates. (2) Every Tests/ file sets `SET QUOTED_IDENTIFIER ON;`. (3) Every migration is applied with `-I`.

**Critical for M2.** A procedure created under QI OFF stores that setting and fails at runtime the first time it writes to Bookings or Payments. Every CREATE PROCEDURE must be applied with `-I`.

**Consequence.** Msg 1934 is a runner misconfiguration, never a test result. Never "fix" it by dropping a filtered index.

**Found by.** Agent report, M1. `err=229` proved the security model intact underneath.

---

## D-018 — `usp_ConfirmPayment.@Method` is `NVARCHAR(30)`

**Context.** Gate 2's manifest froze `nvarchar(20)`; the contract body (§5.4) and the `Payments.Method` column both say 30.
**Decision.** 30. The manifest was the defect. A parameter narrower than its column is a latent truncation bug.
**Found by.** M2 planning, agent report S1.

---

## D-019 — Purge locks `Bookings` with `UPDLOCK, HOLDLOCK`; ordered acquisition applies to inserts

**Context.** The LO-01c registry listed `UPDLOCK, READPAST` for `usp_PurgeExpiredHolds`; the contract body uses `UPDLOCK, HOLDLOCK`. They cannot coexist: READPAST is only valid under READ COMMITTED / REPEATABLE READ, and HOLDLOCK is SERIALIZABLE.
**Decision.** HOLDLOCK, matching the body and LO-01's own wording. The registry row was the defect. Ascending-`SeatId` acquisition (LO-01b) binds INSERTS into `ShowtimeSeatLocks`. Deletes in purge and cancel touch only lock rows the booking already owns; a concurrent `usp_CreateBooking` can hold only previously free keys, never those, so no wait cycle can form.
**Proof obligation.** This is reasoning. TC-CANCEL-02 at M4 is the evidence.
**Found by.** M2 planning, agent report S2.

---

## D-020 — V003 scope, form, and M2 exit

**Decision.**
1. V003 contains all 9 procedures in DATA-CONTRACT.md §4. ("6" in CURRENT_STATE.md was wrong.)
2. Each procedure is its own batch: `SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; GO`, then `CREATE OR ALTER PROCEDURE ...`, then `GO`. Re-applying the whole file is safe. Procedure bodies are not altered by this.
3. The 4 bodies in §5 are transcribed as written. `usp_CreateBooking`'s body is supplied by the reviewer. The other 4 are drafted by the agent from §4 + IMPLEMENTATION-STANDARDS.md, one per step, reviewed before apply.
4. M2 exit = gates 1, 2 (full manifest, no SKIPPED lines) and 4 green. Gate 3 needs seed data (91010) and moves to the M3 exit, the same impossible-exit defect D-016 fixed for M1.
**Carried forward.** `usp_Login` and `usp_CreateShowtime` are exercised by no gate. Add test cases at M3.

---

## D-021 — `usp_Login` takes only `@Username`; the password is verified in C#

**Context.** §4 froze `usp_Login(@Username, @PasswordHash)`. BCrypt salts every hash, so a hash computed in C# never equals the stored hash. SQL cannot compare them; only `BCrypt.Verify` can.
**Decision.** `usp_Login(@Username NVARCHAR(50))` returns 1 row: `UserId, FullName, RoleName, PasswordHash, IsActive`. It never returns an empty result (PC-01). An unknown username THROWs the same error the BLL raises for a wrong password, so the response never reveals which usernames exist. The error number is 50050. The BLL calls `BCrypt.Verify` and rejects inactive users.
**Found by.** Reviewer, M2 planning.
