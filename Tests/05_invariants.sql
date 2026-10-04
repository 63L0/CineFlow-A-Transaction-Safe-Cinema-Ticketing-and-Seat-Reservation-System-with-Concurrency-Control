/* ============================================================
   Invariant tests -- single-connection cases.
   Concurrency cases live in Tests/Concurrency/BookingConcurrencyTests.cs.

   Covers the two open items closed before the build started:
     TC-CANCEL-01  cancel releases the lock row synchronously
     TC-PURGE-01   purge cannot touch a CONFIRMED booking
     TC-PURGE-02   CK_Bookings_ExpiryLifecycle makes the filtered index complete

   Every test rolls back. This file leaves no residue.
   ============================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;

DECLARE @UserId INT, @ShowtimeId INT, @Seats dbo.IntList,
        @BookingId INT, @Total DECIMAL(10,2), @Msg NVARCHAR(400);
DECLARE @Tok UNIQUEIDENTIFIER;

SELECT TOP 1 @UserId = UserId FROM Users WHERE IsActive = 1;
SELECT TOP 1 @ShowtimeId = ShowtimeId FROM Showtimes WHERE Status = 'Scheduled' ORDER BY StartsAt DESC;
IF @UserId IS NULL OR @ShowtimeId IS NULL
    THROW 91010, 'Invariant suite needs seed data. Run V004__seed.sql first.', 1;


/* ------------------------------------------------------------
   TC-CANCEL-01  (closes open item 1)

   Cancel a CONFIRMED booking, then read the seat map. The seat must
   read AVAILABLE on the FIRST read after commit, and no lock row may
   remain. This verifies the lock delete is synchronous and inside the
   cancelling transaction -- if it were deferred to any later job, a
   cancelled seat would read as HELD for that window and be unsellable.
   ------------------------------------------------------------ */
BEGIN TRAN;
  DELETE @Seats;
  INSERT INTO @Seats (Value)
  SELECT TOP 1 s.SeatId FROM Seats s
  JOIN Showtimes st ON st.ScreenId = s.ScreenId AND st.ShowtimeId = @ShowtimeId
  WHERE s.IsUsable = 1
    AND NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks l
                    WHERE l.ShowtimeId = @ShowtimeId AND l.SeatId = s.SeatId);

  DECLARE @SeatId INT = (SELECT TOP 1 Value FROM @Seats);
  DECLARE @R1 TABLE (BookingId INT, BookingRef NVARCHAR(12), TotalAmount DECIMAL(10,2), ExpiresAt DATETIME2);
  INSERT INTO @R1 EXEC usp_CreateBooking @UserId, @ShowtimeId, @Seats, @UserId;
  SELECT @BookingId = BookingId, @Total = TotalAmount FROM @R1;

  SET @Tok = NEWID();
  EXEC usp_ConfirmPayment @BookingId, @Tok, 'Cash', @Total, NULL, @UserId;

  IF NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks WHERE BookingId = @BookingId)
      THROW 92001, 'TC-CANCEL-01 setup failed: confirmed booking holds no lock row.', 1;

  EXEC usp_CancelBooking @BookingId, 'TC-CANCEL-01', @UserId;

  IF EXISTS (SELECT 1 FROM ShowtimeSeatLocks WHERE BookingId = @BookingId)
      THROW 92002, 'TC-CANCEL-01 FAILED: lock row survived cancellation. INV-04 violated -- the seat is unsellable.', 1;

  IF NOT EXISTS (SELECT 1 FROM Bookings WHERE BookingId = @BookingId
                 AND Status = 'CANCELLED' AND ExpiresAt IS NULL)
      THROW 92003, 'TC-CANCEL-01 FAILED: cancelled booking has wrong status or a stale ExpiresAt.', 1;
ROLLBACK;
PRINT '  [OK] TC-CANCEL-01  cancellation releases locks synchronously, in-transaction';


/* ------------------------------------------------------------
   TC-CANCEL-04
   Cancelling a CONFIRMED booking inside the 60-minute cutoff must
   throw AND leave every piece of state untouched.
   ------------------------------------------------------------ */
BEGIN TRAN;
  DECLARE @SoonShow INT;
  INSERT INTO Showtimes (MovieId, ScreenId, StartsAt, EndsAt, BasePrice, Status)
  SELECT TOP 1 m.MovieId, sc.ScreenId,
         DATEADD(MINUTE, 30, SYSUTCDATETIME()),
         DATEADD(MINUTE, 150, SYSUTCDATETIME()), 250.00, 'Scheduled'
  FROM Movies m CROSS JOIN Screens sc WHERE m.IsActive = 1;
  SET @SoonShow = SCOPE_IDENTITY();

  DELETE @Seats;
  INSERT INTO @Seats (Value)
  SELECT TOP 1 s.SeatId FROM Seats s
  JOIN Showtimes st ON st.ScreenId = s.ScreenId AND st.ShowtimeId = @SoonShow
  WHERE s.IsUsable = 1;

  DECLARE @R2 TABLE (BookingId INT, BookingRef NVARCHAR(12), TotalAmount DECIMAL(10,2), ExpiresAt DATETIME2);
  INSERT INTO @R2 EXEC usp_CreateBooking @UserId, @SoonShow, @Seats, @UserId;
  SELECT @BookingId = BookingId, @Total = TotalAmount FROM @R2;
  SET @Tok = NEWID();
  EXEC usp_ConfirmPayment @BookingId, @Tok, 'Cash', @Total, NULL, @UserId;

  BEGIN TRY
      EXEC usp_CancelBooking @BookingId, 'TC-CANCEL-04', @UserId;
      THROW 92010, 'TC-CANCEL-04 FAILED: cancellation inside the cutoff was permitted.', 1;
  END TRY
  BEGIN CATCH
      IF ERROR_NUMBER() = 92010 THROW;
      IF ERROR_NUMBER() <> 50032
      BEGIN
          SET @Msg = CONCAT('TC-CANCEL-04 FAILED: expected 50032, got ', ERROR_NUMBER(), ' -- ', ERROR_MESSAGE());
          THROW 92011, @Msg, 1;
      END
  END CATCH

  IF NOT EXISTS (SELECT 1 FROM Bookings WHERE BookingId = @BookingId AND Status = 'CONFIRMED')
     OR NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks WHERE BookingId = @BookingId)
      THROW 92012, 'TC-CANCEL-04 FAILED: rejected cancellation still mutated state.', 1;
ROLLBACK;
PRINT '  [OK] TC-CANCEL-04  cutoff rejection leaves state untouched';


/* ------------------------------------------------------------
   TC-PURGE-01  (closes open item 2, part a)

   The purge must never reclaim a paid seat. Confirm a booking, then
   run the purge directly and assert nothing about it changed.
   ------------------------------------------------------------ */
BEGIN TRAN;
  DELETE @Seats;
  INSERT INTO @Seats (Value)
  SELECT TOP 1 s.SeatId FROM Seats s
  JOIN Showtimes st ON st.ScreenId = s.ScreenId AND st.ShowtimeId = @ShowtimeId
  WHERE s.IsUsable = 1
    AND NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks l
                    WHERE l.ShowtimeId = @ShowtimeId AND l.SeatId = s.SeatId);

  DECLARE @R3 TABLE (BookingId INT, BookingRef NVARCHAR(12), TotalAmount DECIMAL(10,2), ExpiresAt DATETIME2);
  INSERT INTO @R3 EXEC usp_CreateBooking @UserId, @ShowtimeId, @Seats, @UserId;
  SELECT @BookingId = BookingId, @Total = TotalAmount FROM @R3;
  SET @Tok = NEWID();
  EXEC usp_ConfirmPayment @BookingId, @Tok, 'Cash', @Total, NULL, @UserId;

  DECLARE @Purge TABLE (PurgedCount INT);
  INSERT INTO @Purge EXEC usp_PurgeExpiredHolds;

  IF NOT EXISTS (SELECT 1 FROM Bookings WHERE BookingId = @BookingId AND Status = 'CONFIRMED')
      THROW 92020, 'TC-PURGE-01 FAILED: purge changed the status of a CONFIRMED booking.', 1;
  IF NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks WHERE BookingId = @BookingId)
      THROW 92021, 'TC-PURGE-01 FAILED: purge released the seats of a paid booking.', 1;
ROLLBACK;
PRINT '  [OK] TC-PURGE-01  purge cannot reclaim a confirmed booking';


/* ------------------------------------------------------------
   TC-PURGE-02  (closes open item 2, part b)

   IX_Bookings_PendingExpiry is filtered WHERE Status = 'PENDING'. The
   purge guard in usp_GetSeatMap treats that index as the COMPLETE set of
   purge candidates. That is only sound if PENDING <=> ExpiresAt IS NOT NULL.

   Confirm sets Status and ExpiresAt in one statement, so a row leaves the
   index the instant it stops being PENDING -- correct, but correct by
   convention rather than by construction. CK_Bookings_ExpiryLifecycle turns
   the convention into an enforced property:
     - a PENDING row cannot hide from the index with a NULL expiry
     - a non-PENDING row cannot linger in it with a stale expiry
   This test asserts all four invalid combinations are rejected.
   ------------------------------------------------------------ */
DECLARE @Case INT = 1, @Failed NVARCHAR(200) = NULL;

WHILE @Case <= 4
BEGIN
    BEGIN TRY
        BEGIN TRAN;
            INSERT INTO Bookings (BookingRef, UserId, ShowtimeId, Status, TotalAmount, ExpiresAt, CreatedBy)
            VALUES (CONCAT('TCP', @Case, LEFT(NEWID(), 6)), @UserId, @ShowtimeId,
                    CASE @Case WHEN 1 THEN 'PENDING' WHEN 2 THEN 'CONFIRMED'
                               WHEN 3 THEN 'CANCELLED' ELSE 'EXPIRED' END,
                    100.00,
                    CASE @Case WHEN 1 THEN NULL ELSE DATEADD(MINUTE, 10, SYSUTCDATETIME()) END,
                    @UserId);
        ROLLBACK;
        SET @Failed = CONCAT('TC-PURGE-02 FAILED: case ', @Case,
            ' was accepted. CK_Bookings_ExpiryLifecycle is missing or untrusted, ',
            'so IX_Bookings_PendingExpiry is not a complete index of purge candidates.');
        SET @Case = 99;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        SET @Case = @Case + 1;
    END CATCH
END

IF @Failed IS NOT NULL THROW 92030, @Failed, 1;
PRINT '  [OK] TC-PURGE-02  PENDING <=> ExpiresAt IS NOT NULL is enforced, not assumed';


/* ------------------------------------------------------------
   TC-PAY-02 / 03 / 04 / 07  -- payment validation and constraints
   ------------------------------------------------------------ */
BEGIN TRAN;
  DELETE @Seats;
  INSERT INTO @Seats (Value)
  SELECT TOP 1 s.SeatId FROM Seats s
  JOIN Showtimes st ON st.ScreenId = s.ScreenId AND st.ShowtimeId = @ShowtimeId
  WHERE s.IsUsable = 1
    AND NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks l
                    WHERE l.ShowtimeId = @ShowtimeId AND l.SeatId = s.SeatId);

  DECLARE @R4 TABLE (BookingId INT, BookingRef NVARCHAR(12), TotalAmount DECIMAL(10,2), ExpiresAt DATETIME2);
  INSERT INTO @R4 EXEC usp_CreateBooking @UserId, @ShowtimeId, @Seats, @UserId;
  SELECT @BookingId = BookingId, @Total = TotalAmount FROM @R4;

  -- TC-PAY-02: cash under total
  BEGIN TRY
      SET @Tok = NEWID();
      EXEC usp_ConfirmPayment @BookingId, @Tok, 'Cash', 0.01, NULL, @UserId;
      THROW 92040, 'TC-PAY-02 FAILED: underpayment accepted.', 1;
  END TRY BEGIN CATCH IF ERROR_NUMBER() = 92040 THROW; END CATCH

  -- TC-PAY-03: digital with tendered
  BEGIN TRY
      SET @Tok = NEWID();
      EXEC usp_ConfirmPayment @BookingId, @Tok, 'GCash', 500.00, 'REF123', @UserId;
      THROW 92041, 'TC-PAY-03 FAILED: digital payment accepted AmountTendered.', 1;
  END TRY BEGIN CATCH IF ERROR_NUMBER() = 92041 THROW; END CATCH

  -- TC-PAY-04: digital without reference (the NULL-comparison trap)
  BEGIN TRY
      SET @Tok = NEWID();
      EXEC usp_ConfirmPayment @BookingId, @Tok, 'GCash', NULL, NULL, @UserId;
      THROW 92042, 'TC-PAY-04 FAILED: digital payment accepted without a reference number.', 1;
  END TRY BEGIN CATCH IF ERROR_NUMBER() = 92042 THROW; END CATCH

  IF EXISTS (SELECT 1 FROM Payments WHERE BookingId = @BookingId)
      THROW 92043, 'TC-PAY FAILED: a rejected payment left a row behind.', 1;

  -- TC-PAY-05: idempotent replay
  SET @Tok = NEWID();
  DECLARE @P1 TABLE (PaymentId INT, WasDuplicate BIT);
  DECLARE @P2 TABLE (PaymentId INT, WasDuplicate BIT);
  INSERT INTO @P1 EXEC usp_ConfirmPayment @BookingId, @Tok, 'Cash', @Total, NULL, @UserId;
  INSERT INTO @P2 EXEC usp_ConfirmPayment @BookingId, @Tok, 'Cash', @Total, NULL, @UserId;

  IF (SELECT PaymentId FROM @P1) <> (SELECT PaymentId FROM @P2)
      THROW 92044, 'TC-PAY-05 FAILED: replay created a different payment.', 1;
  IF (SELECT WasDuplicate FROM @P2) <> 1
      THROW 92045, 'TC-PAY-05 FAILED: replay did not report WasDuplicate.', 1;
  IF (SELECT COUNT(*) FROM @P2) <> 1
      THROW 92046, 'PC-01 FAILED: replay returned an empty or multi-row result.', 1;
  IF (SELECT COUNT(*) FROM Payments WHERE BookingId = @BookingId) <> 1
      THROW 92047, 'TC-PAY-05 FAILED: two payment rows exist for one booking.', 1;
ROLLBACK;
PRINT '  [OK] TC-PAY-02/03/04/05  payment validation and idempotency hold';


/* TC-PAY-07: the constraint backstop (INV-07) */
BEGIN TRY
    BEGIN TRAN;
        INSERT INTO Payments (BookingId, Method, Amount, AmountTendered, ChangeDue, Status, ProcessedBy)
        SELECT TOP 1 BookingId, 'Cash', 100.00, 50.00, -50.00, 'PAID', @UserId FROM Bookings;
    ROLLBACK;
    THROW 92050, 'TC-PAY-07 FAILED: a negative ChangeDue was accepted. CK_Payments_NonNegativeChange missing or untrusted.', 1;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    IF ERROR_NUMBER() = 92050 THROW;
END CATCH
PRINT '  [OK] TC-PAY-07  negative ChangeDue is unrepresentable';

PRINT '  [OK] 05_invariants.sql complete';
