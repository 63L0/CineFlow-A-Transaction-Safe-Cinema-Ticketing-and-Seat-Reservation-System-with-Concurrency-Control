# CineFlow — Implementation Standards

**Status:** FROZEN as of Day 2. Changes require an explicit decision record appended to this file.
**Audience:** every AI agent and human contributor working on CineFlow.
**Usage:** paste this file verbatim into every agent prompt. Do not assume it carries over between sessions.

---

## Why this file exists

The design for this system was reviewed six times. Every round found a real defect, and the defects all had the same shape:

> A mechanism that validates something, so it reads as validated, while a precondition sits unstated.

Examples that actually occurred during design:

- `ChangeDue = @AmountTendered - @Total` with no check that tendered covers the total — committed negative change silently.
- `IF @AmountTendered < @Total THROW` — correct for cash, silently inert for digital payments because `NULL < @Total` evaluates to `UNKNOWN`, not `TRUE`.
- A `CATCH` block that returned the existing payment on any unique-violation — correct for token collisions, returned an **empty result set with no error** for any other constraint.

The standards below exist to make that shape hard to produce. They are not style preferences.

---

## IS-01 — Static SQL only

All stored procedures MUST use static SQL. Dynamic SQL (`EXEC(@sql)`, `EXECUTE(@sql)`, `sp_executesql`) is **prohibited**.

**Rationale.** The application connects with a login that has `EXECUTE` permission only; all table-level DML is explicitly denied. This relies on **ownership chaining**. Dynamic SQL breaks ownership chaining — the dynamic batch is evaluated under the caller's permissions, not the procedure owner's — producing runtime permission errors. The usual fix under time pressure is "just grant SELECT", which silently reopens the exact hole this control closes.

**Required pattern for optional filters:**

```sql
SELECT MovieId, Title, Genre, DurationMin, Rating, IsActive
FROM Movies
WHERE (@Title    IS NULL OR Title LIKE '%' + @Title + '%')
  AND (@Genre    IS NULL OR Genre = @Genre)
  AND (@Rating   IS NULL OR Rating = @Rating)
  AND (@IsActive IS NULL OR IsActive = @IsActive)
ORDER BY Title
OPTION (RECOMPILE);
```

`OPTION (RECOMPILE)` avoids parameter-sniffing pathologies on optional predicates. At this data scale the recompile cost is irrelevant.

**Gated by:** `Tests/01_static_sql_scan.sql` (heuristic) and `Tests/03_smoke_as_app.sql` (definitive).

---

## IS-02 — All writes go through stored procedures

No `INSERT`, `UPDATE`, or `DELETE` may be issued from application code. The application login has no table-level DML permission, so violations fail at runtime rather than silently succeeding.

Reads MAY go through procedures returning result sets. They MAY NOT go through ad-hoc `SELECT` from the application — same permission model.

**Gated by:** `Tests/04_security_denials.sql`.

---

## IS-03 — No business logic in the presentation layer

WinForms code-behind may contain: control wiring, formatting, navigation, and input-shape validation (is this a number, is this field non-empty).

It may NOT contain: SQL, pricing rules, status transitions, permission decisions, or any rule that would still be true if the UI were replaced.

**Rationale.** A rule enforced only in the UI is not enforced. Anyone with the connection string bypasses it.

---

## IS-04 — Transactional procedure skeleton

Every procedure that writes to more than one table, or that must be atomic, MUST follow this skeleton:

```sql
CREATE PROCEDURE usp_Example ...
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;          -- mandatory

  BEGIN TRY
    BEGIN TRANSACTION;
      -- 1. Acquire locks in a consistent order (see LO-01 below)
      -- 2. Validate every precondition, throwing named errors
      -- 3. Perform writes
      -- 4. Write an AuditLogs row
    COMMIT TRANSACTION;

    SELECT ...;               -- exactly one row (see PC-01)
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    -- handle known recoverable cases, then:
    THROW;
  END CATCH
END
```

`SET XACT_ABORT ON` is not optional. Without it, certain errors leave the transaction in a doomed-but-open state.

**LO-01 — Lock ordering.** Where a procedure must lock both a `Bookings` row and `ShowtimeSeatLocks` rows, it MUST acquire the `Bookings` row first, via `WITH (UPDLOCK, HOLDLOCK)`. Consistent ordering across all procedures prevents deadlocks.

---

## IS-05 — Dual enforcement

Every business invariant MUST be enforced in **two** places:

1. A **stored-procedure validation** that produces a specific, user-facing error message.
2. A **schema constraint** (`CHECK`, `UNIQUE`, `FOREIGN KEY`, `NOT NULL`) that makes the invalid state unrepresentable.

An invariant with only one enforcement point is incomplete and MUST NOT be merged.

The procedure validation exists for the user; the constraint exists for correctness. The constraint must hold even if the procedure is later edited badly, bypassed by a future code path, or executed by hand in SSMS.

**Corollary — no `WITH NOCHECK`.** Constraints MUST be created trusted. An agent that hits existing seed data violating a new constraint MUST fix the seed data, not weaken the constraint. `is_not_trusted = 1` is a build failure.

**Gated by:** `Tests/02_ownership_and_constraints.sql`.

---

## PC-01 — Procedure result contract

Every stored procedure MUST either **return exactly one result row** or **raise an error**.

No code path — including every branch of every `CATCH` block — may `RETURN` with an empty result set.

Callers MUST treat an empty result as a fault:

```csharp
if (!reader.Read())
    throw new DataIntegrityException(
        $"{procName} returned no rows — violates PC-01.");
```

**Rationale.** This is the single most important standard in this file. It is stated as an **outcome**, not as a list of causes. Error-handling paths get validated against the cause the author had in mind, not against the class of causes the mechanism actually catches. A contract phrased as "never return empty" is unfalsifiable by a cause nobody enumerated; a contract phrased as "handle the duplicate case" is not.

**Corollary — do not branch on `ERROR_MESSAGE()` text.** Error message text is not a contract. It is localized, format-unstable, and matching on an embedded index name couples runtime behavior to a schema object's *name*, so a rename silently changes behavior and no gate catches it. Where a `CATCH` must distinguish outcomes, **re-query for the fact you care about** rather than parsing why you failed.

---

## PC-02 — Errors are numbered and named

All `THROW` statements use an error number from the registry in `DATA-CONTRACT.md` §7. Do not invent numbers ad hoc; add them to the registry first.

Messages are user-facing: they say what happened and what to do, and they never leak schema object names, connection details, or internal identifiers.

---

## VG-01 — Verification gates run daily from Day 3

`Deploy/verify.bat` MUST pass green before any day's work is considered done. It is not a week-3 activity.

A constraint violated by an agent on Day 4 that is not caught until Day 15 means eleven days of code built on a broken assumption.

Each gate runs in **its own `sqlcmd` connection** with `-b`, so a leaked security context or a doomed transaction cannot affect the next gate.

---

## Notes for AI agents specifically

1. **Dynamic SQL is the default wrong answer.** When you see an optional filter, your first instinct will be to build the `WHERE` clause as a string. IS-01 prohibits this. Use the null-coalescing pattern.
2. **Do not weaken a constraint to make a test pass.** Fix the data or fix the procedure. `WITH NOCHECK` is a build failure.
3. **Do not add parameters to a frozen signature.** If a procedure needs a parameter that `DATA-CONTRACT.md` does not list, stop and raise it. The signature list is frozen precisely so that scope cannot be lost or added silently.
4. **Three-valued logic.** `NULL` compared to anything is `UNKNOWN`, which is not `TRUE`, so the guarded statement does not execute. Every comparison against a nullable parameter needs an explicit `IS NULL` branch.
5. **When you write a `CATCH` branch, ask what else can throw that error class.** If you cannot enumerate it exhaustively, fall through to `THROW` rather than returning.


---

# Addendum A — LO-01 restated (supersedes the LO-01 wording above)

**Why this addendum exists.** LO-01 was written as "always lock the `Bookings` row first." That sentence is imprecise in a way that matters, and it was caught by asking a question this document could not answer: *what lock does `usp_CreateBooking` actually take that serializes against `usp_CancelBooking`?*

The honest answer is **not** "an explicit `UPDLOCK, HOLDLOCK` on `Bookings`." `usp_CreateBooking` **inserts** a `Bookings` row. That row is brand new and its key is uncontended — no other session can be waiting on it, so locking it first guarantees nothing. The serialization against cancel comes from somewhere else entirely, and the previous wording obscured that.

This is the same defect shape the whole design process kept producing: a mechanism that sounds like it provides a guarantee, sitting on an unstated precondition.

## LO-01a — The real serialization point is `PK_SeatLock`

Concurrency between booking and cancellation is enforced by the **engine's key lock on the `ShowtimeSeatLocks` primary key `(ShowtimeId, SeatId)`**, automatically, with no hint required:

- `usp_CancelBooking` takes an X key lock when it `DELETE`s the lock row, held to commit.
- `usp_CreateBooking` needs that same key to `INSERT`, so it blocks until the cancelling transaction commits or rolls back — then either succeeds (row gone) or fails cleanly with 50001 (row still there).

There is no interleaving in which a seat is both released and still owned, because both outcomes are decided by which transaction holds one key. This is engine-enforced, not code-enforced. **Do not add hints to `ShowtimeSeatLocks` expecting them to provide this; they are not what provides it.**

## LO-01b — Ordering rule, corrected and narrowed

Deadlock requires two transactions acquiring two resources in opposite order. Two orderings must therefore hold:

1. **Across tables** — any procedure that touches both `Bookings` and `ShowtimeSeatLocks` acquires `Bookings` **first**. This binds `usp_CancelBooking`, `usp_PurgeExpiredHolds`, and the guarded purge inside `usp_GetSeatMap`, all of which update an existing `Bookings` row. It is vacuous for `usp_CreateBooking`, whose `Bookings` row is new — stated here so nobody claims it as protection it does not provide.

2. **Within `ShowtimeSeatLocks`** — when a procedure inserts more than one seat key, keys are acquired in **ascending `SeatId` order**. This clause was missing, and its absence is a real deadlock path: booking A taking seats 1,2,3 while booking B takes 3,2,1 deadlocks, and the losing session dies with error **1205**, not a clean 50001. Deletes of lock rows a booking already owns are exempt (D-019).

> `INSERT … SELECT … ORDER BY` does **not** guarantee acquisition order. The `ORDER BY` constrains the result set, not the order the engine takes locks.
>
> **Required pattern** — materialize ordered, then insert from the ordered set, in every procedure that inserts multiple seat keys (`usp_CreateBooking`). Cancel and purge only delete lock rows the booking already owns, so they need no ordering (D-019):
>
> ```sql
> DECLARE @Ordered TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, SeatId INT NOT NULL);
> INSERT INTO @Ordered (SeatId) SELECT Value FROM @SeatIds ORDER BY Value;
>
> INSERT INTO ShowtimeSeatLocks (ShowtimeId, SeatId, BookingId, LockedAt)
> SELECT @ShowtimeId, o.SeatId, @BookingId, SYSUTCDATETIME()
> FROM @Ordered o ORDER BY o.Seq;
> ```
>
> Multi-row DML is still not a hard ordering guarantee at the engine level. The binding check is **TC-CONC-02**, which must assert `ErrorNumber != 1205` on every participant. Treat any 1205 in the suite as an LO-01b violation, never as a retryable flake.

## LO-01c — Registry of acquisition orders

Every write path, in the order it takes locks. Adding a procedure that touches these tables requires adding a row here first.

| Procedure | 1st | 2nd | 3rd | Notes |
|---|---|---|---|---|
| `usp_CreateBooking` | `Bookings` (new row, uncontended) | `ShowtimeSeatLocks` asc `SeatId` | — | Serialization is `PK_SeatLock`, not the `Bookings` insert. The guarded purge (D-025) runs first, in its own committed transaction, in `usp_PurgeExpiredHolds` order |
| `usp_ConfirmPayment` | `Bookings` (`UPDLOCK, HOLDLOCK`) | `Payments` | — | Never touches `ShowtimeSeatLocks` |
| `usp_CancelBooking` | `Bookings` (`UPDLOCK, HOLDLOCK`) | `ShowtimeSeatLocks` (deletes owned rows only; no ordering required, D-019) | — | Delete is in the same transaction as the status change |
| `usp_PurgeExpiredHolds` | `Bookings` (`UPDLOCK, HOLDLOCK`) | `ShowtimeSeatLocks` (deletes owned rows only; no ordering required, D-019) | — | Matches the §5.1 body. `READPAST` cannot be combined with `HOLDLOCK` (D-019) |
| `usp_GetSeatMap` | guard: `SELECT … READCOMMITTED` (no lock held) | then `usp_PurgeExpiredHolds` order if work exists | — | The guard exists so a clean read takes no write lock |
| `usp_CreateShowtime` | `Showtimes` (`UPDLOCK, HOLDLOCK`, range on `ScreenId`) | — | — | Never touches `Bookings` or `ShowtimeSeatLocks` (D-030) |

**`usp_ConfirmPayment` never touching `ShowtimeSeatLocks` is itself a deadlock-avoidance property**, not an omission. Confirmation changes a booking's status and inserts a payment; the seats are already locked and stay locked. Any future edit that makes confirm touch the lock table must be added to this registry and re-checked against every other row.

---

# Addendum B — What this package has and has not been run against

Stated once, plainly, because the distinction is the thread's main lesson.

| Artifact | Status |
|---|---|
| DDL, constraints, procedure bodies | **Written, reviewed, never executed.** No SQL Server instance has parsed them. |
| `verify.bat` and `Tests/*.sql` | **Written, never executed.** |
| `BookingConcurrencyTests.cs` | **Written, never compiled.** Depends on a `TestFixture` and `ContractScenarios` that are declared, not implemented. |

Everything in this package is a **specification**, and specifications carry syntax errors, wrong column names, and wrong assumptions until an engine rejects them. Day 3 exists to convert this from reviewed to executed. Until `verify.bat` returns green on real hardware, no claim in this document has been verified — including the claims in Addendum A.
