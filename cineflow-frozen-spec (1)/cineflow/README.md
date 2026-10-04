# CineFlow — Frozen Specification Package

**CineFlow: A Transaction-Safe Cinema Ticketing and Seat Reservation System with Concurrency Control**
A Three-Tier Windows Application using C# .NET and SQL Server

---

## What is in this package

| File | Purpose |
|---|---|
| `DATA-CONTRACT.md` | **Frozen Day 2.** Table DDL, CHECK constraints, indexes, procedure signatures with conditional rules, invariant registry, test registry, error numbers, security model. One file so schema and procedure contracts cannot drift apart. |
| `IMPLEMENTATION-STANDARDS.md` | **Frozen Day 2.** IS-01 through IS-05 and PC-01. Paste verbatim into every agent prompt. |
| `Docs/WEEK0-DEFENSE-PACK.md` | Title, scope, delimitations, deployment topology, the three memorized defense paragraphs, privacy scope, demo runbook, anticipated questions, 21-day schedule. |
| `Deploy/verify.bat` | The daily gate. Runs from Day 3. No day's work is done until it is green. |
| `Tests/01..05*.sql` | Static-SQL scan, ownership and constraint integrity, runtime smoke suite under the least-privilege login, security denials, invariant tests. |
| `Tests/Concurrency/BookingConcurrencyTests.cs` | The differentiator. Parallel booking races, cancel-versus-rebook, payment idempotency, and the PC-01 contract sweep. |

---

## How to use it with AI agents

1. Paste `IMPLEMENTATION-STANDARDS.md` into **every** agent session. Do not assume it carries over.
2. Paste the relevant section of `DATA-CONTRACT.md` with each task.
3. Run `Deploy\verify.bat` at the end of every working day, from Day 3 onward.
4. If an agent asks to add a procedure parameter or weaken a constraint, refuse. Escalate instead.

### The three rules agents break most

| Rule | Why agents break it |
|---|---|
| **IS-01** no dynamic SQL | Building a `WHERE` clause as a string is the obvious way to write an optional filter. It silently breaks ownership chaining. |
| **IS-05** no `WITH NOCHECK` | When stale seed data violates a new constraint, weakening the constraint is faster than fixing the data. It leaves the constraint present but unenforced. |
| **PC-01** never return empty | A `CATCH` branch gets written against the one cause the author had in mind, and returns silently for every other cause in the same error class. |

---

## Quick start

```bat
set SRV=.\SQLEXPRESS
set DB=CineFlow

sqlcmd -S %SRV% -b -i Database\Migrations\V001__schema.sql
sqlcmd -S %SRV% -b -i Database\Migrations\V002__indexes.sql
sqlcmd -S %SRV% -b -i Database\Migrations\V003__stored_procs.sql
sqlcmd -S %SRV% -b -i Database\Migrations\V004__seed.sql
sqlcmd -S %SRV% -b -i Database\Migrations\V005__security.sql

Deploy\verify.bat
```

---

## Design notes worth knowing before you read the SQL

**`ShowtimeSeatLocks` is the thesis.** `BookingSeats` is historical and retains cancelled and expired bookings. `ShowtimeSeatLocks` is live inventory: a row exists if and only if a seat is currently unavailable. Its primary key on `(ShowtimeId, SeatId)` makes double-selling impossible at the storage engine level, not merely unlikely.

**Contracts are stated as outcomes, not causes.** `CHECK (ChangeDue >= 0)` holds no matter which validation path was forgotten. PC-01 holds for failure causes nobody enumerated. This is the same principle as the seat-lock primary key applied to the design process itself — make the invalid state unrepresentable rather than trying to enumerate every route to it.

**Every invariant is enforced twice** (IS-05): once in a procedure, for a good error message, and once in the schema, for correctness when the procedure is bypassed, edited badly, or run by hand.

**Lazy expiry, not a scheduled job.** SQL Server Agent does not exist in Express. The purge runs on the read and write paths, guarded by an existence check against a filtered index of currently-held bookings, so a read does not take a write lock unless there is real work to do.

---

## Out of scope — stated deliberately

Public web or mobile booking; real payment gateway integration; multi-branch operation; SMS or email notifications; real customer personal data. LAN-only, staff-operated, synthetic data. RA 10173 compliance is documented as out of scope rather than implemented — see `Docs/WEEK0-DEFENSE-PACK.md` §6.
