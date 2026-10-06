-- V003__stored_procs.sql
-- Apply with: sqlcmd -S .\SQLEXPRESS -E -d CineFlow -b -I -i <this file>
-- Re-runnable: every procedure uses CREATE OR ALTER (D-020).
-- Procedures are added one per step, in D-020 order.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_PurgeExpiredHolds
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

GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_GetSeatMap @ShowtimeId INT
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

GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_CreateBooking
    @UserId      INT,
    @ShowtimeId  INT,
    @SeatIds     dbo.IntList READONLY,
    @CreatedBy   INT
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @SeatCount INT = (SELECT COUNT(*) FROM @SeatIds);
  DECLARE @ScreenId INT, @BasePrice DECIMAL(10,2), @ShowStatus NVARCHAR(20), @StartsAt DATETIME2;
  DECLARE @BookingId INT, @BookingRef NVARCHAR(12), @Total DECIMAL(10,2), @ExpiresAt DATETIME2;
  DECLARE @Expired TABLE (BookingId INT PRIMARY KEY);
  DECLARE @Ordered TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, SeatId INT NOT NULL);

  BEGIN TRY
    -- Input checks first: no transaction and no purge for a request that can never succeed.
    IF @SeatCount = 0  THROW 50002, 'Select at least one seat.', 1;
    IF @SeatCount > 10 THROW 50003, 'A maximum of 10 seats per transaction.', 1;

    -- D-002 / D-025: guarded purge, inlined (no PurgedCount result set), committed
    -- in its own short transaction before the booking transaction starts.
    IF EXISTS (SELECT 1 FROM Bookings
               WHERE Status = 'PENDING' AND ExpiresAt < SYSUTCDATETIME())
    BEGIN
      BEGIN TRANSACTION;
        INSERT INTO @Expired (BookingId)
        SELECT BookingId FROM Bookings WITH (UPDLOCK, HOLDLOCK)
        WHERE Status = 'PENDING' AND ExpiresAt < SYSUTCDATETIME();

        DELETE L FROM ShowtimeSeatLocks L
        INNER JOIN @Expired E ON E.BookingId = L.BookingId;

        -- INV-05: ExpiresAt cleared in the same statement as the status change.
        UPDATE B SET Status = 'EXPIRED', ExpiresAt = NULL
        FROM Bookings B INNER JOIN @Expired E ON E.BookingId = B.BookingId;
      COMMIT TRANSACTION;
    END

    BEGIN TRANSACTION;

      SELECT @ScreenId = ScreenId, @BasePrice = BasePrice,
             @ShowStatus = Status, @StartsAt = StartsAt
      FROM Showtimes WHERE ShowtimeId = @ShowtimeId;

      -- D-027: unknown, not Scheduled, or already started.
      IF @ScreenId IS NULL OR @ShowStatus <> 'Scheduled' OR @StartsAt <= SYSUTCDATETIME()
          THROW 50006, 'This showtime is not open for booking.', 1;

      -- INV-02: every seat exists and is on this showtime's screen.
      IF (SELECT COUNT(*) FROM Seats s
          INNER JOIN @SeatIds i ON i.Value = s.SeatId
          WHERE s.ScreenId = @ScreenId) <> @SeatCount
          THROW 50004, 'One or more seats do not belong to this showtime''s screen.', 1;

      -- INV-03
      IF EXISTS (SELECT 1 FROM Seats s
                 INNER JOIN @SeatIds i ON i.Value = s.SeatId
                 WHERE s.IsUsable = 0)
          THROW 50005, 'One or more selected seats are out of service.', 1;

      -- Fast, clean fail for the common case. Not the guarantee: PK_SeatLock is (LO-01a).
      IF EXISTS (SELECT 1 FROM ShowtimeSeatLocks l
                 INNER JOIN @SeatIds i ON i.Value = l.SeatId
                 WHERE l.ShowtimeId = @ShowtimeId)
          THROW 50001, 'One or more seats were just taken.', 1;

      -- INV-12: unit price snapshot and total computed together.
      SET @Total     = @BasePrice * @SeatCount;
      SET @ExpiresAt = DATEADD(MINUTE, 10, SYSUTCDATETIME());   -- D-002: 10-minute hold

      -- D-026: placeholder ref ('T' is not a hex digit, so it cannot collide
      -- with a final 'CF' ref), replaced by the BookingId-derived ref below.
      INSERT INTO Bookings (BookingRef, UserId, ShowtimeId, Status, TotalAmount, ExpiresAt, CreatedBy)
      VALUES (N'T' + LEFT(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''), 11),
              @UserId, @ShowtimeId, 'PENDING', @Total, @ExpiresAt, @CreatedBy);

      SET @BookingId  = SCOPE_IDENTITY();
      SET @BookingRef = N'CF' + RIGHT(N'0000000000' + CAST(@BookingId AS NVARCHAR(10)), 10);

      UPDATE Bookings SET BookingRef = @BookingRef WHERE BookingId = @BookingId;

      -- LO-01b: materialize ordered, then insert in ascending SeatId.
      INSERT INTO @Ordered (SeatId) SELECT Value FROM @SeatIds ORDER BY Value;

      INSERT INTO ShowtimeSeatLocks (ShowtimeId, SeatId, BookingId, LockedAt)
      SELECT @ShowtimeId, o.SeatId, @BookingId, SYSUTCDATETIME()
      FROM @Ordered o ORDER BY o.Seq;

      INSERT INTO BookingSeats (BookingId, SeatId, UnitPrice)
      SELECT @BookingId, o.SeatId, @BasePrice
      FROM @Ordered o;

      INSERT INTO AuditLogs (UserId, Action, EntityName, EntityId, Details)
      VALUES (@CreatedBy, 'BOOKING_CREATED', 'Booking', @BookingId,
              CONCAT('Ref=', @BookingRef, '; Seats=', @SeatCount, '; Total=', @Total));

    COMMIT TRANSACTION;
    SELECT @BookingId AS BookingId, @BookingRef AS BookingRef,
           @Total AS TotalAmount, @ExpiresAt AS ExpiresAt;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

    -- PC-01 corollary: re-query the fact, never parse the message. A duplicate-key
    -- error is 50001 only if a requested seat is now actually locked; otherwise
    -- (e.g. a BookingRef collision) the original error is rethrown unchanged.
    IF ERROR_NUMBER() IN (2601, 2627)
       AND EXISTS (SELECT 1 FROM ShowtimeSeatLocks l
                   INNER JOIN @SeatIds i ON i.Value = l.SeatId
                   WHERE l.ShowtimeId = @ShowtimeId)
        THROW 50001, 'One or more seats were just taken.', 1;

    THROW;
  END CATCH
END

GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_CancelBooking
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

GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_ConfirmPayment
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
        END;

        -- Some other unique constraint fired. Never return empty (PC-01).
        THROW 50021, 'Payment could not be recorded: this booking already has an active payment.', 1;
    END;

    THROW;
  END CATCH
END

GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_Login
    @Username NVARCHAR(50)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @UserId INT, @FullName NVARCHAR(120), @RoleName NVARCHAR(30),
          @PasswordHash NVARCHAR(255), @IsActive BIT;

  SELECT @UserId = u.UserId, @FullName = u.FullName, @RoleName = r.RoleName,
         @PasswordHash = u.PasswordHash, @IsActive = u.IsActive
  FROM Users u
  INNER JOIN Roles r ON r.RoleId = u.RoleId
  WHERE u.Username = @Username;

  -- PC-01: one row or an error, never empty. Same message as wrong password (D-021).
  IF @UserId IS NULL
    THROW 50050, 'Invalid username or password.', 1;

  SELECT @UserId AS UserId, @FullName AS FullName, @RoleName AS RoleName,
         @PasswordHash AS PasswordHash, @IsActive AS IsActive;
END

GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE usp_SearchMovies
    @Title    NVARCHAR(200) = NULL,
    @Genre    NVARCHAR(60)  = NULL,
    @Rating   NVARCHAR(10)  = NULL,
    @IsActive BIT           = NULL
AS
BEGIN
  SET NOCOUNT ON;

  -- IS-01 / D-004: static optional filters. Result set, may be empty (not PC-01).
  SELECT MovieId, Title, Genre, DurationMin, Rating, IsActive
  FROM Movies
  WHERE (@Title    IS NULL OR Title LIKE '%' + @Title + '%')
    AND (@Genre    IS NULL OR Genre = @Genre)
    AND (@Rating   IS NULL OR Rating = @Rating)
    AND (@IsActive IS NULL OR IsActive = @IsActive)
  ORDER BY Title
  OPTION (RECOMPILE);
END

GO
