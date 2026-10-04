# CineFlow — Data Contract

**Status:** FROZEN as of Day 2.
**Scope:** this single file is the source of truth for table DDL, constraints, indexes, procedure signatures, invariants, error numbers, and the test cases that gate them.

## Freeze rules

1. Schema DDL, `CHECK` constraints, indexes and procedure signatures are frozen **together, in this one file**. They are not separate artifacts and must not drift apart.
2. An agent may not add, remove or rename a procedure parameter. If a procedure appears to need a parameter not listed here, stop and escalate.
3. An agent may not implement a procedure validation without its paired schema constraint, or vice versa (IS-05).
4. Every invariant in §3 has a test ID in §6 and is gated by `Deploy/verify.bat`.

---

# 1. Entities

## 1.1 Roles / Users

```sql
CREATE TABLE Roles (
    RoleId       INT IDENTITY PRIMARY KEY,
    RoleName     NVARCHAR(30) NOT NULL UNIQUE          -- Admin, Cashier
);

CREATE TABLE Users (
    UserId       INT IDENTITY PRIMARY KEY,
    Username     NVARCHAR(50)  NOT NULL UNIQUE,
    PasswordHash NVARCHAR(255) NOT NULL,
    FullName     NVARCHAR(120) NOT NULL,
    Email        NVARCHAR(150) NULL,
    Phone        NVARCHAR(20)  NULL,
    RoleId       INT NOT NULL REFERENCES Roles(RoleId),
    IsActive     BIT NOT NULL DEFAULT 1,
    CreatedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
```

BCrypt embeds its own salt in the hash string; no separate salt column.

## 1.2 Movies / Screens / Seats

```sql
CREATE TABLE Movies (
    MovieId      INT IDENTITY PRIMARY KEY,
    Title        NVARCHAR(200) NOT NULL,
    Genre        NVARCHAR(60)  NULL,
    DurationMin  INT NOT NULL,
    Rating       NVARCHAR(10)  NULL,
    Synopsis     NVARCHAR(MAX) NULL,
    PosterPath   NVARCHAR(300) NULL,
    IsActive     BIT NOT NULL DEFAULT 1,
    CONSTRAINT CK_Movies_Duration CHECK (DurationMin > 0)
);

CREATE TABLE Screens (
    ScreenId     INT IDENTITY PRIMARY KEY,
    ScreenName   NVARCHAR(50) NOT NULL UNIQUE,
    TotalSeats   INT NOT NULL,
    CONSTRAINT CK_Screens_Capacity CHECK (TotalSeats > 0)
);

CREATE TABLE Seats (
    SeatId       INT IDENTITY PRIMARY KEY,
    ScreenId     INT NOT NULL REFERENCES Screens(ScreenId),
    RowLabel     CHAR(2) NOT NULL,
    SeatNumber   INT NOT NULL,
    SeatType     NVARCHAR(20) NOT NULL DEFAULT 'Regular',
    IsUsable     BIT NOT NULL DEFAULT 1,
    CONSTRAINT UQ_Seat UNIQUE (ScreenId, RowLabel, SeatNumber),
    CONSTRAINT CK_Seats_Type CHECK (SeatType IN ('Regular','Premium','Accessible'))
);
```

## 1.3 Showtimes

```sql
CREATE TABLE Showtimes (
    ShowtimeId   INT IDENTITY PRIMARY KEY,
    MovieId      INT NOT NULL REFERENCES Movies(MovieId),
    ScreenId     INT NOT NULL REFERENCES Screens(ScreenId),
    StartsAt     DATETIME2 NOT NULL,
    EndsAt       DATETIME2 NOT NULL,
    BasePrice    DECIMAL(10,2) NOT NULL,
    Status       NVARCHAR(20) NOT NULL DEFAULT 'Scheduled',
    CONSTRAINT UQ_Showtime_Slot UNIQUE (ScreenId, StartsAt),
    CONSTRAINT CK_Showtime_Range  CHECK (EndsAt > StartsAt),
    CONSTRAINT CK_Showtime_Price  CHECK (BasePrice >= 0),
    CONSTRAINT CK_Showtime_Status CHECK (Status IN ('Scheduled','Ongoing','Completed','Cancelled'))
);
```

`UQ_Showtime_Slot` prevents identical start times on one screen. Full interval-overlap prevention is procedure-enforced (`usp_CreateShowtime`) because SQL Server has no exclusion constraints; see INV-11.

## 1.4 Bookings — transactional core

```sql
CREATE TABLE Bookings (
    BookingId    INT IDENTITY PRIMARY KEY,
    BookingRef   NVARCHAR(12) NOT NULL UNIQUE,
    UserId       INT NOT NULL REFERENCES Users(UserId),
    ShowtimeId   INT NOT NULL REFERENCES Showtimes(ShowtimeId),
    Status       NVARCHAR(20) NOT NULL,
    TotalAmount  DECIMAL(10,2) NOT NULL,
    CreatedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    ExpiresAt    DATETIME2 NULL,
    CreatedBy    INT NOT NULL REFERENCES Users(UserId),

    CONSTRAINT CK_Bookings_Status CHECK (Status IN ('PENDING','CONFIRMED','CANCELLED','EXPIRED')),
    CONSTRAINT CK_Bookings_Total  CHECK (TotalAmount >= 0),

    -- INV-05. A PENDING booking MUST have an expiry; a non-PENDING booking MUST NOT.
    -- This is what makes IX_Bookings_PendingExpiry a complete index of purge candidates.
    CONSTRAINT CK_Bookings_ExpiryLifecycle CHECK (
        (Status =  'PENDING' AND ExpiresAt IS NOT NULL) OR
        (Status <> 'PENDING' AND ExpiresAt IS NULL)
    )
);

CREATE TABLE BookingSeats (
    BookingId    INT NOT NULL REFERENCES Bookings(BookingId),
    SeatId       INT NOT NULL REFERENCES Seats(SeatId),
    UnitPrice    DECIMAL(10,2) NOT NULL,
    TicketType   NVARCHAR(20) NOT NULL DEFAULT 'Regular',
    CONSTRAINT PK_BookingSeats PRIMARY KEY (BookingId, SeatId),
    CONSTRAINT CK_BookingSeats_Price CHECK (UnitPrice >= 0),
    CONSTRAINT CK_BookingSeats_Type  CHECK (TicketType IN ('Regular','Student','Senior','PWD','Child'))
);
```

`BookingSeats.UnitPrice` and `Bookings.TotalAmount` are **deliberate denormalizations**: a point-in-time price snapshot so historical receipts remain accurate after a price change. Documented, not accidental.

## 1.5 ShowtimeSeatLocks — live seat inventory

```sql
CREATE TABLE ShowtimeSeatLocks (
    ShowtimeId   INT NOT NULL REFERENCES Showtimes(ShowtimeId),
    SeatId       INT NOT NULL REFERENCES Seats(SeatId),
    BookingId    INT NOT NULL REFERENCES Bookings(BookingId),
    LockedAt     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_SeatLock PRIMARY KEY (ShowtimeId, SeatId)
);
```

**This table is the system's thesis.** `BookingSeats` is *historical* — it retains cancelled and expired bookings. `ShowtimeSeatLocks` is *live inventory*: a row exists if and only if the seat is currently unavailable. The primary key on `(ShowtimeId, SeatId)` makes double-selling physically impossible at the storage engine level.

**Lifecycle — a lock row is deleted in exactly three places, always inside the owning transaction:**

| Event | Procedure | Timing |
|---|---|---|
| Hold expires | `usp_PurgeExpiredHolds` | Same transaction as `Status → EXPIRED` |
| Booking cancelled | `usp_CancelBooking` | Same transaction as `Status → CANCELLED` |
| Booking creation fails | — | Rolled back by `XACT_ABORT` |

There is no asynchronous or deferred deletion path. See INV-04 and TC-CANCEL-01.

## 1.6 Payments

```sql
CREATE TABLE Payments (
    PaymentId       INT IDENTITY PRIMARY KEY,
    BookingId       INT NOT NULL REFERENCES Bookings(BookingId),
    RequestToken    UNIQUEIDENTIFIER NULL,
    Method          NVARCHAR(30) NOT NULL,
    Amount          DECIMAL(10,2) NOT NULL,
    AmountTendered  DECIMAL(10,2) NULL,
    ChangeDue       DECIMAL(10,2) NOT NULL,
    ReferenceNumber NVARCHAR(50) NULL,
    Status          NVARCHAR(20) NOT NULL,
    PaidAt          DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    ProcessedBy     INT NOT NULL REFERENCES Users(UserId),

    CONSTRAINT CK_Payments_Method CHECK (Method IN ('Cash','Card','GCash','Maya')),
    CONSTRAINT CK_Payments_Status CHECK (Status IN ('PAID','REFUNDED','VOID')),
    CONSTRAINT CK_Payments_Amount CHECK (Amount >= 0),

    -- INV-07. Change can never be negative, regardless of which validation path was forgotten.
    CONSTRAINT CK_Payments_NonNegativeChange CHECK (ChangeDue >= 0),

    -- INV-08. Cash and digital payments carry mutually exclusive fields.
    CONSTRAINT CK_Payments_MethodFields CHECK (
        (Method =  'Cash' AND AmountTendered IS NOT NULL AND ReferenceNumber IS NULL) OR
        (Method <> 'Cash' AND AmountTendered IS NULL     AND ReferenceNumber IS NOT NULL)
    )
);
```

## 1.7 AuditLogs

```sql
CREATE TABLE AuditLogs (
    AuditId      BIGINT IDENTITY PRIMARY KEY,
    UserId       INT NULL REFERENCES Users(UserId),
    Action       NVARCHAR(60) NOT NULL,
    EntityName   NVARCHAR(60) NOT NULL,
    EntityId     NVARCHAR(40) NULL,
    Details      NVARCHAR(MAX) NULL,
    OccurredAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
```

---

# 2. Indexes

```sql
-- Purge-guard index. Contains ONLY currently-held bookings (typically single digits),
-- which is what makes the IF EXISTS guard in usp_GetSeatMap effectively free.
-- Completeness of this index as the set of purge candidates depends on
-- CK_Bookings_ExpiryLifecycle (INV-05). See TC-PURGE-02.
CREATE INDEX IX_Bookings_PendingExpiry
    ON Bookings(ExpiresAt) WHERE Status = 'PENDING';

CREATE INDEX IX_Showtimes_StartsAt  ON Showtimes(StartsAt) INCLUDE (MovieId, ScreenId);
CREATE INDEX IX_Showtimes_ScreenDay ON Showtimes(ScreenId, StartsAt, EndsAt);
CREATE INDEX IX_Bookings_Showtime   ON Bookings(ShowtimeId, Status);
CREATE INDEX IX_Bookings_CreatedAt  ON Bookings(CreatedAt);
CREATE INDEX IX_Locks_Booking       ON ShowtimeSeatLocks(BookingId);
CREATE INDEX IX_Payments_PaidAt     ON Payments(PaidAt, Status);

-- Idempotency: the same client request can never create two payment rows.
CREATE UNIQUE INDEX UX_Payments_Token
    ON Payments(RequestToken) WHERE RequestToken IS NOT NULL;

-- Defence in depth: a booking can never have two non-voided payments.
-- NOT the primary mechanism -- UPDLOCK/HOLDLOCK on the Bookings row serialises
-- same-booking confirms so the second sees Status='CONFIRMED' and throws 50016.
-- This index catches any path that bypasses that reasoning.
CREATE UNIQUE INDEX UX_Payments_ActiveBooking
    ON Payments(BookingId) WHERE Status <> 'VOID';
```

---

# 3. Invariant registry (IS-05 dual enforcement)

| ID | Invariant | Procedure enforcement | Schema enforcement | Test |
|---|---|---|---|---|
| INV-01 | A seat cannot be held by two bookings for one showtime | `usp_CreateBooking` insert into locks | `PK_SeatLock` | TC-CONC-01, TC-CONC-02 |
| INV-02 | A booking's seats all belong to the showtime's screen | `usp_CreateBooking` validation | `FK` + screen check in proc | TC-BOOK-03 |
| INV-03 | An unusable seat cannot be booked | `usp_CreateBooking` validation | `Seats.IsUsable` filter in `usp_GetSeatMap` | TC-BOOK-04 |
| INV-04 | A cancelled or expired booking holds no lock rows | `usp_CancelBooking`, `usp_PurgeExpiredHolds` delete in-transaction | `IX_Locks_Booking` + TC gate | **TC-CANCEL-01, TC-CANCEL-02** |
| INV-05 | PENDING ⇔ `ExpiresAt IS NOT NULL` | Set on insert, cleared on confirm/cancel | `CK_Bookings_ExpiryLifecycle` | **TC-PURGE-02** |
| INV-06 | Purge never affects a non-PENDING booking | `WHERE Status='PENDING'` in purge | `CK_Bookings_ExpiryLifecycle` | **TC-PURGE-01** |
| INV-07 | Change due is never negative | `usp_ConfirmPayment` cash branch | `CK_Payments_NonNegativeChange` | TC-PAY-02 |
| INV-08 | Cash and digital payments carry exclusive fields | `usp_ConfirmPayment` branch validation | `CK_Payments_MethodFields` | TC-PAY-03, TC-PAY-04 |
| INV-09 | One client request creates at most one payment | Pre-check + CATCH re-query | `UX_Payments_Token` | TC-PAY-05 |
| INV-10 | A booking has at most one active payment | `Status='CONFIRMED'` check under `UPDLOCK` | `UX_Payments_ActiveBooking` | TC-PAY-06 |
| INV-11 | Showtimes on one screen never overlap | `usp_CreateShowtime` interval check under `UPDLOCK` | `UQ_Showtime_Slot` (partial) | TC-SHOW-01 |
| INV-12 | Total charged equals the sum of seat prices | `usp_CreateBooking` computes both | `CK_Bookings_Total` | TC-BOOK-05 |
| PC-01 | Every procedure returns exactly one row or throws | Every `CATCH` branch | — (test-gated) | **TC-PC-01** |

---

# 4. Frozen procedure signatures

Conditional rules are part of the signature. A parameter's nullability in the declaration is **not** its contract.

| Procedure | Parameters | Conditional rules | Returns |
|---|---|---|---|
| `usp_Login` | `@Username NVARCHAR(50)` | Never an empty result (PC-01): an unknown username THROWs 50050, the same message the BLL raises for a wrong password. The password is verified in C# with `BCrypt.Verify`, never in SQL (D-021). | 1 row: `UserId, FullName, RoleName, PasswordHash, IsActive` |
| `usp_SearchMovies` | `@Title=NULL`, `@Genre=NULL`, `@Rating=NULL`, `@IsActive=NULL` | all optional; static SQL only (IS-01) | result set (may be empty — see PC-01 note) |
| `usp_CreateShowtime` | `@MovieId`, `@ScreenId`, `@StartsAt`, `@BasePrice` | `EndsAt` derived from duration + 20 min buffer; overlap check under `UPDLOCK` | 1 row: `ShowtimeId` |
| `usp_GetSeatMap` | `@ShowtimeId` | guarded purge runs first | result set: one row per seat |
| `usp_CreateBooking` | `@UserId`, `@ShowtimeId`, `@SeatIds dbo.IntList READONLY`, `@CreatedBy` | `@SeatIds` must be non-empty and ≤ 10; all seats must belong to the showtime's screen and be usable | 1 row: `BookingId, BookingRef, TotalAmount, ExpiresAt` |
| `usp_ConfirmPayment` | `@BookingId`, `@RequestToken`, `@Method`, `@AmountTendered=NULL`, `@ReferenceNumber=NULL`, `@ProcessedBy` | **`@AmountTendered`: REQUIRED when `@Method='Cash'`, MUST be NULL otherwise, MUST be ≥ booking total.** **`@ReferenceNumber`: REQUIRED when `@Method<>'Cash'`, MUST be NULL otherwise.** Total is derived from `Bookings`, never passed in. | 1 row: `PaymentId, WasDuplicate` |
| `usp_CancelBooking` | `@BookingId`, `@Reason`, `@CancelledBy` | deletes lock rows in the same transaction | 1 row: `BookingId, RefundAmount` |
| `usp_PurgeExpiredHolds` | — | affects `Status='PENDING'` rows only | 1 row: `PurgedCount` |
| `usp_GetSalesReport` | `@FromDate`, `@ToDate` | — | result set |

**Note on result sets vs PC-01.** PC-01 governs *scalar-outcome* procedures — those returning an identity or an outcome flag. Query procedures (`usp_SearchMovies`, `usp_GetSeatMap`, `usp_GetSalesReport`) may legitimately return zero rows, because "no matches" is a valid answer rather than a fault. The distinction is fixed here and is not an agent judgement call: the procedures listed above as returning **"1 row"** are PC-01 procedures. Those listed as returning **"result set"** are not.

---

# 5. Core procedure implementations

These four are canonical. Implement them as written.

## 5.1 `usp_PurgeExpiredHolds`

```sql
CREATE PROCEDURE usp_PurgeExpiredHolds
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Purged INT = 0;

  BEGIN TRY
    BEGIN TRANSACTION;

      DECLARE @Expired TABLE (BookingId INT PRIMARY KEY);

      INSERT INTO @Expired (BookingId)
      SELECT BookingId FROM Bookings WITH (UPDLOCK, HOLDLOCK)
      WHERE Status = 'PENDING' AND ExpiresAt < SYSUTCDATETIME();

      DELETE L FROM ShowtimeSeatLocks L
      INNER JOIN @Expired E ON E.BookingId = L.BookingId;

      -- ExpiresAt must be cleared in the same statement as the status change
      -- to satisfy CK_Bookings_ExpiryLifecycle (INV-05).
      UPDATE B SET Status = 'EXPIRED', ExpiresAt = NULL
      FROM Bookings B INNER JOIN @Expired E ON E.BookingId = B.BookingId;

      SET @Purged = (SELECT COUNT(*) FROM @Expired);

    COMMIT TRANSACTION;
    SELECT @Purged AS PurgedCount;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH
END
```

## 5.2 `usp_GetSeatMap`

```sql
CREATE PROCEDURE usp_GetSeatMap @ShowtimeId INT
AS
BEGIN
  SET NOCOUNT ON;

  -- Cheap seek against IX_Bookings_PendingExpiry. Opens a write transaction
  -- only when expired holds actually exist -- not once per read.
  IF EXISTS (SELECT 1 FROM Bookings
             WHERE Status = 'PENDING' AND ExpiresAt < SYSUTCDATETIME())
      EXEC usp_PurgeExpiredHolds;

  SELECT s.SeatId, s.RowLabel, s.SeatNumber, s.SeatType,
         CASE WHEN s.IsUsable = 0        THEN 'UNUSABLE'
              WHEN b.Status = 'CONFIRMED' THEN 'SOLD'
              WHEN l.SeatId IS NOT NULL   THEN 'HELD'
              ELSE 'AVAILABLE' END AS SeatStatus
  FROM Seats s
  INNER JOIN Showtimes st ON st.ScreenId = s.ScreenId AND st.ShowtimeId = @ShowtimeId
  LEFT  JOIN ShowtimeSeatLocks l ON l.SeatId = s.SeatId AND l.ShowtimeId = @ShowtimeId
  LEFT  JOIN Bookings b ON b.BookingId = l.BookingId
  ORDER BY s.RowLabel, s.SeatNumber;
END
```

## 5.3 `usp_CancelBooking`

Lock rows are deleted **synchronously, in the same transaction** as the status change. There is no window in which a cancelled seat reads as held: the transaction that clears `Status` is the same transaction that removes the lock row, so no reader can observe one without the other. See TC-CANCEL-01.

```sql
CREATE PROCEDURE usp_CancelBooking
    @BookingId    INT,
    @Reason       NVARCHAR(200),
    @CancelledBy  INT
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  BEGIN TRY
    BEGIN TRANSACTION;

      -- LO-01: Bookings row locked first, consistently with every other procedure.
      DECLARE @Status NVARCHAR(20), @Total DECIMAL(10,2), @StartsAt DATETIME2;
      SELECT @Status = b.Status, @Total = b.TotalAmount, @StartsAt = st.StartsAt
      FROM Bookings b WITH (UPDLOCK, HOLDLOCK)
      INNER JOIN Showtimes st ON st.ShowtimeId = b.ShowtimeId
      WHERE b.BookingId = @BookingId;

      IF @Status IS NULL         THROW 50010, 'Booking not found.', 1;
      IF @Status = 'CANCELLED'   THROW 50030, 'Booking is already cancelled.', 1;
      IF @Status = 'EXPIRED'     THROW 50031, 'Booking already expired.', 1;
      IF @Status = 'CONFIRMED' AND DATEDIFF(MINUTE, SYSUTCDATETIME(), @StartsAt) < 60
          THROW 50032, 'Cancellation is not allowed within one hour of the showtime.', 1;

      -- Refund only applies to money actually taken.
      DECLARE @Refund DECIMAL(10,2) = CASE WHEN @Status = 'CONFIRMED' THEN @Total ELSE 0 END;

      IF @Status = 'CONFIRMED'
          UPDATE Payments SET Status = 'REFUNDED'
          WHERE BookingId = @BookingId AND Status = 'PAID';

      -- INV-04: seats return to inventory in this same transaction.
      DELETE FROM ShowtimeSeatLocks WHERE BookingId = @BookingId;

      -- INV-05: ExpiresAt cleared alongside the status change.
      UPDATE Bookings SET Status = 'CANCELLED', ExpiresAt = NULL
      WHERE BookingId = @BookingId;

      INSERT INTO AuditLogs (UserId, Action, EntityName, EntityId, Details)
      VALUES (@CancelledBy, 'BOOKING_CANCELLED', 'Booking', @BookingId,
              CONCAT('Prior=', @Status, '; Refund=', @Refund, '; Reason=', @Reason));

    COMMIT TRANSACTION;
    SELECT @BookingId AS BookingId, @Refund AS RefundAmount;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH
END
```

## 5.4 `usp_ConfirmPayment`

```sql
CREATE PROCEDURE usp_ConfirmPayment
    @BookingId       INT,
    @RequestToken    UNIQUEIDENTIFIER,
    @Method          NVARCHAR(30),
    @AmountTendered  DECIMAL(10,2) = NULL,
    @ReferenceNumber NVARCHAR(50)  = NULL,
    @ProcessedBy     INT
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  -- Fast path: this exact request already succeeded.
  DECLARE @ExistingId INT;
  SELECT @ExistingId = PaymentId FROM Payments WHERE RequestToken = @RequestToken;
  IF @ExistingId IS NOT NULL
  BEGIN
      SELECT @ExistingId AS PaymentId, CAST(1 AS BIT) AS WasDuplicate;
      RETURN;
  END

  IF @Method NOT IN ('Cash','Card','GCash','Maya')
      THROW 50015, 'Unknown payment method.', 1;

  BEGIN TRY
    BEGIN TRANSACTION;

      DECLARE @Status NVARCHAR(20), @Total DECIMAL(10,2);
      SELECT @Status = Status, @Total = TotalAmount
      FROM Bookings WITH (UPDLOCK, HOLDLOCK)
      WHERE BookingId = @BookingId;

      IF @Status IS NULL       THROW 50010, 'Booking not found.', 1;
      IF @Status = 'CANCELLED' THROW 50011, 'Booking was cancelled.', 1;
      IF @Status = 'EXPIRED'   THROW 50012, 'Hold expired. Please reselect seats.', 1;
      IF @Status = 'CONFIRMED' THROW 50016, 'Booking is already paid.', 1;

      DECLARE @ChangeDue DECIMAL(10,2);

      IF @Method = 'Cash'
      BEGIN
          IF @AmountTendered IS NULL
              THROW 50017, 'Amount tendered is required for cash payments.', 1;
          IF @AmountTendered < @Total
              THROW 50014, 'Amount tendered is less than total due.', 1;
          IF @ReferenceNumber IS NOT NULL
              THROW 50018, 'Reference number is not applicable to cash payments.', 1;
          SET @ChangeDue = @AmountTendered - @Total;
      END
      ELSE
      BEGIN
          IF @ReferenceNumber IS NULL OR LTRIM(RTRIM(@ReferenceNumber)) = ''
              THROW 50019, 'Reference number is required for digital payments.', 1;
          IF @AmountTendered IS NOT NULL
              THROW 50020, 'Amount tendered applies to cash payments only.', 1;
          SET @ChangeDue = 0;
      END

      INSERT INTO Payments (BookingId, RequestToken, Method, Amount, AmountTendered,
                            ChangeDue, ReferenceNumber, Status, ProcessedBy)
      VALUES (@BookingId, @RequestToken, @Method, @Total, @AmountTendered,
              @ChangeDue, @ReferenceNumber, 'PAID', @ProcessedBy);

      DECLARE @PaymentId INT = SCOPE_IDENTITY();

      -- INV-05: ExpiresAt cleared in the same statement as the status change.
      UPDATE Bookings SET Status = 'CONFIRMED', ExpiresAt = NULL
      WHERE BookingId = @BookingId;

      INSERT INTO AuditLogs (UserId, Action, EntityName, EntityId, Details)
      VALUES (@ProcessedBy, 'PAYMENT_CONFIRMED', 'Booking', @BookingId,
              CONCAT('PaymentId=', @PaymentId, '; Method=', @Method, '; Total=', @Total));

    COMMIT TRANSACTION;
    SELECT @PaymentId AS PaymentId, CAST(0 AS BIT) AS WasDuplicate;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

    IF ERROR_NUMBER() IN (2601, 2627)
    BEGIN
        -- Do NOT branch on ERROR_MESSAGE() text (PC-01 corollary): that couples
        -- behaviour to an index NAME, so a rename silently changes behaviour.
        -- Ask the only question that matters instead.
        DECLARE @Winner INT;
        SELECT @Winner = PaymentId FROM Payments WHERE RequestToken = @RequestToken;

        IF @Winner IS NOT NULL
        BEGIN
            SELECT @Winner AS PaymentId, CAST(1 AS BIT) AS WasDuplicate;
            RETURN;
        END

        -- Some other unique constraint fired. Never return empty (PC-01).
        THROW 50021, 'Payment could not be recorded: this booking already has an active payment.', 1;
    END

    THROW;
  END CATCH
END
```

---

# 6. Test registry

Every test below is executed by `Deploy/verify.bat`. SQL tests live in `Tests/`; concurrency tests live in `Tests/Concurrency/BookingConcurrencyTests.cs`.

## 6.1 Concurrency

| ID | Test | Assertion |
|---|---|---|
| TC-CONC-01 | 20 parallel bookings, same single seat | exactly 1 succeeds, 19 throw `SeatUnavailable`, 1 lock row |
| TC-CONC-02 | Overlapping multi-seat sets: A wants {1,2,3}, B wants {3,4,5} | exactly 1 succeeds; loser leaves **no** booking row and **no** partial locks; lock count is exactly 3, never 4 or 5 |

## 6.2 Cancel / rebook — *closes open item 1*

| ID | Test | Assertion |
|---|---|---|
| **TC-CANCEL-01** | Cancel a CONFIRMED booking, then immediately read the seat map in a **separate connection** | seat reads `AVAILABLE` on the first read after commit. No lock row for that booking remains. Verifies the delete is synchronous and in-transaction, not deferred. |
| **TC-CANCEL-02** | Concurrent `usp_CancelBooking(B1)` and `usp_CreateBooking` for the same seat, launched in parallel | no deadlock (LO-01 holds); final state is exactly one of: cancel-then-rebook succeeds with 1 lock row owned by the new booking, or rebook fails cleanly with `SeatUnavailable` and 1 lock row owned by B1. **Never** 0 lock rows with B1 still active, and never 2 lock rows. |
| TC-CANCEL-03 | Cancel a PENDING booking (never paid) | `RefundAmount = 0`; no `Payments` row is touched; lock rows deleted |
| TC-CANCEL-04 | Cancel a CONFIRMED booking < 60 min before showtime | throws 50032; **no** state change — lock rows still present, status still CONFIRMED |

## 6.3 Purge / expiry — *closes open item 2*

| ID | Test | Assertion |
|---|---|---|
| **TC-PURGE-01** | Confirm a booking, then force-run `usp_PurgeExpiredHolds` | CONFIRMED booking is untouched: status still CONFIRMED, lock rows still present, `PurgedCount` excludes it. Proves the purge cannot reclaim a paid seat. |
| **TC-PURGE-02** | Attempt to write each of the four invalid `(Status, ExpiresAt)` combinations directly | every one fails on `CK_Bookings_ExpiryLifecycle`. This is what makes `IX_Bookings_PendingExpiry` a *complete* index of purge candidates: a PENDING row cannot hide from the filtered index by having a NULL expiry, and a non-PENDING row cannot linger in it. The property is enforced, not assumed. |
| TC-PURGE-03 | Expire a PENDING hold, then read the seat map | seats read `AVAILABLE`; booking status is `EXPIRED` with `ExpiresAt IS NULL` |
| TC-PURGE-04 | Read the seat map with no expired holds present | zero rows written; verified by comparing `AuditLogs` count and purge count before/after |

## 6.4 Payment

| ID | Test | Assertion |
|---|---|---|
| TC-PAY-01 | Cash, tendered > total | `ChangeDue = tendered - total`; booking CONFIRMED |
| TC-PAY-02 | Cash, tendered < total | throws 50014; no `Payments` row |
| TC-PAY-03 | GCash with `@AmountTendered` supplied | throws 50020 |
| TC-PAY-04 | GCash with no `@ReferenceNumber` | throws 50019 |
| TC-PAY-05 | Same `@RequestToken` submitted twice | one `Payments` row; second call returns same `PaymentId` with `WasDuplicate = 1` |
| TC-PAY-06 | Same booking, **two different** tokens, concurrent | exactly 1 succeeds; the loser **throws** (50016 or 50021). One payment row. |
| TC-PAY-07 | Direct insert of a negative `ChangeDue` | fails on `CK_Payments_NonNegativeChange` |

## 6.5 Contract

| ID | Test | Assertion |
|---|---|---|
| **TC-PC-01** | Invoke every PC-01 procedure from §4 across all of its failure branches | every invocation either returns exactly one row or raises an error. **Zero invocations return an empty result set.** |
| TC-SEC-01 | As `cineflow_app`: `SELECT * FROM Bookings` | permission denied |
| TC-SEC-02 | As `cineflow_app`: execute every procedure in §4 | all succeed — definitive proof ownership chaining is intact (IS-01) |
| TC-SEC-03 | Scan `sys.sql_modules` for dynamic SQL | zero matches (heuristic gate) |
| TC-SEC-04 | Scan `sys.check_constraints` and `sys.foreign_keys` | zero rows with `is_disabled = 1` or `is_not_trusted = 1` |

---

# 7. Error number registry

| Number | Message | Raised by |
|---|---|---|
| 50001 | One or more seats were just taken. | `usp_CreateBooking` |
| 50002 | Select at least one seat. | `usp_CreateBooking` |
| 50003 | A maximum of 10 seats per transaction. | `usp_CreateBooking` |
| 50004 | One or more seats do not belong to this showtime's screen. | `usp_CreateBooking` |
| 50005 | One or more selected seats are out of service. | `usp_CreateBooking` |
| 50010 | Booking not found. | confirm, cancel |
| 50011 | Booking was cancelled. | `usp_ConfirmPayment` |
| 50012 | Hold expired. Please reselect seats. | `usp_ConfirmPayment` |
| 50014 | Amount tendered is less than total due. | `usp_ConfirmPayment` |
| 50015 | Unknown payment method. | `usp_ConfirmPayment` |
| 50016 | Booking is already paid. | `usp_ConfirmPayment` |
| 50017 | Amount tendered is required for cash payments. | `usp_ConfirmPayment` |
| 50018 | Reference number is not applicable to cash payments. | `usp_ConfirmPayment` |
| 50019 | Reference number is required for digital payments. | `usp_ConfirmPayment` |
| 50020 | Amount tendered applies to cash payments only. | `usp_ConfirmPayment` |
| 50021 | Payment could not be recorded: this booking already has an active payment. | `usp_ConfirmPayment` |
| 50030 | Booking is already cancelled. | `usp_CancelBooking` |
| 50031 | Booking already expired. | `usp_CancelBooking` |
| 50032 | Cancellation is not allowed within one hour of the showtime. | `usp_CancelBooking` |
| 50040 | This screen already has a showtime overlapping that slot. | `usp_CreateShowtime` |
| 50050 | Invalid username or password. | `usp_Login` |
| 90001 | SECURITY: direct table access succeeded when it should be denied. | test harness only |

---

# 8. Security model

```sql
CREATE LOGIN cineflow_app WITH PASSWORD = '<set at deployment>';
GO
USE CineFlow;
CREATE USER cineflow_app FOR LOGIN cineflow_app;

-- Ownership chaining requires a single consistent owner.
-- REMOVED (D-015): Msg 15150, the dbo schema owner cannot be altered. Gate 2 asserts it instead.

GRANT EXECUTE ON SCHEMA::dbo TO cineflow_app;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO cineflow_app;

-- Required for the table-valued parameter on usp_CreateBooking.
GRANT EXECUTE ON TYPE::dbo.IntList TO cineflow_app;
```

```sql
CREATE TYPE dbo.IntList AS TABLE (Value INT PRIMARY KEY);
```

**Every `sqlcmd` invocation against this database must pass `-I`** (D-017). Without it QUOTED_IDENTIFIER is OFF and any statement touching a table with a filtered index fails Msg 1934. A procedure created under QUOTED_IDENTIFIER OFF stores that setting and fails at runtime.

**Connection string handling.** Plaintext in `App.config`; `App.config` is gitignored and `App.config.template` is committed instead. `Deploy/encrypt-config.bat` is available as a post-install step on the target machine. It is deliberately **not** a build artifact: DPAPI machine-key encryption is not portable, so encrypting on the development machine would break the application anywhere else. The primary credential control is the least-privilege grant above, which holds regardless of config encryption state.
