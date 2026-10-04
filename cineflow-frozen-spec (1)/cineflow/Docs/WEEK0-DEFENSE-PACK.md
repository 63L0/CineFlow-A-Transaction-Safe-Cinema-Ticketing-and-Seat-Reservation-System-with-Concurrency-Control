# CineFlow — Week 0 Defense Pack

Everything in this file must be written, agreed, and memorized before implementation starts.

---

## 1. Title

> **CineFlow: A Transaction-Safe Cinema Ticketing and Seat Reservation System with Concurrency Control**
> *A Three-Tier Windows Application using C# .NET and SQL Server*

The title names a specific technical contribution rather than describing a generic booking system. This pre-empts the standard opening question: *what makes yours different?*

---

## 2. Scope statement

> CineFlow is a single-venue, staff-operated box-office system that manages movie catalogs, showtime scheduling, seat inventory, and ticket sales. Its core contribution is a transaction-safe booking engine that guarantees no seat can be sold twice, even under simultaneous access from multiple counter terminals.

## 3. Delimitations

> CineFlow is deployed exclusively on a trusted single-site cinema LAN. All clients are Windows desktop applications connecting to a central SQL Server instance using a least-privilege login restricted to stored-procedure execution. No component is reachable from the public internet, and the system processes synthetic data only; therefore RA 10173 (Data Privacy Act of 2012) compliance is documented as out of scope rather than implemented. A customer-facing web portal would require a mediating API tier to enforce business rules server-side, since a thick client with an embedded connection string cannot be trusted across an untrusted network. This is identified as Phase 2 future work.

**Explicitly out of scope:**

| Excluded | Reason |
|---|---|
| Public web / mobile booking | Different trust model; requires an API tier |
| Real payment gateway | Payments are *recorded*, not *processed* |
| Multi-branch / multi-venue | Single-site scope |
| SMS / email notifications | No external integrations |
| Real customer personal data | Synthetic seed data only |

Stating limits before being asked reads as maturity. Discovering them during questioning reads as oversight.

---

## 4. Deployment topology

Draw this as a diagram. Three boxes, two arrows, credentials labelled on each arrow.

```
┌──────────────────────┐        ┌──────────────────────┐
│  Cashier Terminal 1  │        │  Cashier Terminal 2  │
│  CineFlow.UI         │        │  CineFlow.UI         │
│  (WinForms, .NET)    │        │  (WinForms, .NET)    │
└──────────┬───────────┘        └──────────┬───────────┘
           │                               │
           │  TCP 1433, cinema LAN only    │
           │  SQL login: cineflow_app      │
           │  GRANT EXECUTE ON SCHEMA::dbo │
           │  DENY SELECT/INSERT/UPDATE/   │
           │       DELETE ON SCHEMA::dbo   │
           └───────────────┬───────────────┘
                           ▼
            ┌──────────────────────────────┐
            │  Cinema Server               │
            │  SQL Server Express          │
            │  Database: CineFlow          │
            │  ── stored procedures only   │
            │  ── owner: dbo               │
            │  ── no external exposure     │
            └──────────────────────────────┘

No component is reachable from outside the LAN.
No API tier exists; business rules are enforced inside the database.
```

**Process types:** exactly one — the WinForms client, role-gated at login into Admin and Cashier views. There is no separate customer application.

---

## 5. The three defense paragraphs

Memorize these. They answer the three questions a sharp panel will ask about the parts of the design that are genuinely unusual.

### 5.1 Why both a primary key and a lock hint?

> The primary key on `(ShowtimeId, SeatId)` and the `UPDLOCK, HOLDLOCK` hint on the showtime row solve two different problems, so neither is redundant. The primary key is the **correctness guarantee** — it makes a duplicate seat sale physically impossible regardless of what the application does, and it holds even if someone connects with SSMS and inserts by hand. The lock hint is a **contention optimization** — it serializes concurrent requests for the same showtime before they do work, so losers fail fast and cleanly rather than racing to the insert and failing with a constraint violation after doing partial work. Without the primary key, a race condition sells the same seat twice. Without the hint, the system is still correct but produces unnecessary rollbacks and noisier errors under load. I kept both: the constraint for correctness, the hint for graceful behaviour.

### 5.2 Why no API tier, and is that safe?

> Because the system is LAN-only and staff-operated, the trust boundary is the cinema network, not the client application. Rather than add an API tier I could not build well in the available time, I moved enforcement into the database. The application login has `EXECUTE` permission on stored procedures and nothing else — `SELECT`, `INSERT`, `UPDATE` and `DELETE` are explicitly denied on every table. Even with a fully decompiled connection string, an attacker cannot craft a query that bypasses my business rules, because there is no path into the data that does not go through a procedure that enforces the invariants. If this system were ever exposed to the public internet, an API tier would become necessary, and that is documented as Phase 2 work.

### 5.3 Why lazy expiry instead of a scheduled job?

> Held seats expire after ten minutes. I purge expired holds on the read and write paths rather than with a scheduled job, for three reasons. First, SQL Server Agent does not exist in SQL Server Express, which is the edition this deploys on, so a scheduled job would require a separate Windows service — an extra deployment dependency and an extra point of failure. Second, the invariant only needs to hold at the moment someone reads or books a seat, and both of those paths purge first, so correctness is equivalent. Third, the purge is guarded by an existence check against a filtered index containing only currently-held bookings — typically fewer than ten rows — so a read path does not take a write lock unless there is actual work to do. A scheduled job is listed as future work for a larger deployment.

---

## 6. Privacy scope paragraph (SRS section)

> CineFlow collects username, full name, email address and contact number for registered accounts, and records discount eligibility categories (Student, Senior Citizen, PWD) at the ticket level. Under RA 10173, discount eligibility linked to an identified individual would constitute sensitive personal information. This system is evaluated using synthetic seed data exclusively; no real personal data is collected, processed, or stored at any point. RA 10173 compliance is therefore out of scope for this implementation. Were the system deployed with real customer data, the following controls would be required: a documented privacy notice and consent mechanism at registration, encryption of personal data at rest, a defined retention and disposal schedule, a data subject access and correction procedure, registration of the data processing system with the National Privacy Commission, and appointment of a Data Protection Officer. These are identified as prerequisites for production deployment.

---

## 7. Live demo runbook

Rehearse until boring. Three clean runs before defense day.

| # | Demo | What you say |
|---|---|---|
| 1 | **Two terminals, same seat, simultaneous click** | "Both cashiers select seat A5 and confirm at the same moment. One prints a ticket. The other gets a clean message and a refreshed map — no error dialog, no duplicate, no partial booking." |
| 2 | **Permission denial, live in SSMS** | Connect as `cineflow_app`, run `SELECT * FROM Bookings`, show the permission error. "This is the account my application uses. It cannot read a single table directly." |
| 3 | **Double-click Confirm Payment** | "Same request token, so the second click returns the existing payment instead of creating a second one. One payment row, one ticket." |
| 4 | **Hold expiry** | Hold seats, wait out the timer (or use the admin release button), show the seats return to available. |
| 5 | **Failure narration** | Pull the network cable. Status bar goes red. Reconnect. "The client detects loss of database connectivity and blocks transactional actions rather than failing halfway through one." |
| 6 | **verify.bat** | Run it live. Green in under 30 seconds. "This gate ran every day of the build." |

---

## 8. Anticipated questions

| Question | Answer |
|---|---|
| Is your database normalized? | Third normal form. I can walk through the UNF → 1NF → 2NF → 3NF derivation. There are two deliberate denormalizations — `BookingSeats.UnitPrice` and `Bookings.TotalAmount` — which are point-in-time price snapshots so historical receipts stay accurate after a price change. Both are documented. |
| Why store a price snapshot instead of computing it? | Because a receipt is a record of what was actually charged, not what the price is today. Recomputing from current prices would silently rewrite history. |
| What if the application crashes mid-booking? | `SET XACT_ABORT ON` rolls the entire transaction back. There is no half-booked state. Any seats held by an abandoned booking are released by the expiry purge. |
| How are passwords stored? | BCrypt with a per-user salt. Never plaintext, never reversible. |
| Why ADO.NET instead of Entity Framework? | Explicit control over transaction isolation and locking hints, which the concurrency guarantee depends on. The data access layer is interface-based, so Entity Framework could be substituted without touching the business layer. |
| Your config file has a plaintext connection string. | Deliberate. DPAPI encryption is machine-tied, so encrypting on the development machine would break the application on any other machine — an unnecessary demo-day risk. An encryption script is provided as a deployment step. The actual credential control is least-privilege: that login cannot do anything harmful even if fully exposed. |
| What is the weakest part of your system? | Single-venue with no real payment gateway, and no API tier — which means it cannot safely be exposed beyond the LAN. I scoped deliberately to guarantee correctness in the core transactional domain rather than spread thin. |
| How do you know it works under concurrency? | An automated test suite that runs twenty parallel bookings against one seat, overlapping multi-seat requests, cancel-versus-rebook races, and duplicate payment submissions. It ran on every day of the build. I can run it now. |
| What would you do differently? | Freeze the data contract earlier. Several defects during design came from procedure validation and schema constraints being specified in separate documents that drifted apart. |

---

## 9. Twenty-one day schedule

| Days | Work | Gate |
|---|---|---|
| 1–2 | Spec lockdown: topology, scope, `IMPLEMENTATION-STANDARDS.md`, `DATA-CONTRACT.md` with DDL, constraints and frozen procedure signatures | Signature and constraint review before freeze |
| 3 | Schema, constraints, least-privilege login, **`verify.bat` built** | `verify.bat` green on empty schema |
| 4–6 | All stored procedures, seed data, concurrency test suite including TC-CANCEL and TC-PURGE | `verify.bat` daily |
| 7–10 | Models → DAL → BLL → authentication | `verify.bat` daily |
| 11–14 | UI: login, admin CRUD, scheduler, seat map, booking, payment, receipt | `verify.bat` daily |
| 15–16 | Verification **and fix** — full sweep, repair what it finds | All gates green |
| 17 | **Buffer — deliberately unallocated** | — |
| 18–19 | SRS, ERD, DFD levels 0 and 1, use case, sequence, class diagrams, user manual | — |
| 20 | **Codebase review** — read your own code, especially the four core procedures | You can explain every line |
| 21 | Rehearsal: all six demos, three clean runs | Demo runs boring |

Day 17 is empty on purpose. If verification finds nothing, it becomes a rest day before defense week. If it finds something real, there is somewhere to put it.

---

## 10. A note on how this design was produced

Worth being able to say out loud, because it is true and it is a good answer:

> The design went through six review rounds. Every round found a real defect, and the defects all had the same shape — a mechanism that validated something, so it read as validated, while a precondition sat unstated. A negative change amount that no check prevented. A null comparison that made a validation silently inert for three of four payment methods. An error handler that returned an empty result set instead of an error for causes its author had not enumerated.
>
> What finally worked was not more review. It was restating the contracts in terms of **outcomes** rather than **causes**: every procedure returns exactly one row or throws, regardless of what went wrong; change due is never negative, regardless of which validation path was forgotten. That is the same principle as the seat-locking primary key at the centre of this system — make the invalid state unrepresentable rather than trying to enumerate every way it could be reached. The design process converged on the system's own thesis.
