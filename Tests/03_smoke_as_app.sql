/* ============================================================
   TC-SEC-02  --  IS-01 DEFINITIVE proof of ownership chaining

   Executes every stored procedure under the least-privilege
   cineflow_app login. If any procedure uses dynamic SQL, ownership
   chaining breaks and that procedure throws a permission error HERE.
   This -- not the substring scan -- is the real gate.

   REVERT SAFETY: T-SQL has no TRY/FINALLY. Every EXECUTE AS is wrapped
   so REVERT is guaranteed on the error path, and verify.bat additionally
   runs this file in its own sqlcmd connection so that a severity-20
   error (which terminates the connection before CATCH runs) cannot leak
   a security context into the next gate.
   ============================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;

DECLARE @ShowtimeId INT, @BookingId INT, @UserId INT, @Seats dbo.IntList;
DECLARE @Tok UNIQUEIDENTIFIER;

SELECT TOP 1 @UserId = UserId FROM Users WHERE IsActive = 1;
SELECT TOP 1 @ShowtimeId = ShowtimeId FROM Showtimes
WHERE Status = 'Scheduled' ORDER BY StartsAt DESC;

IF @UserId IS NULL OR @ShowtimeId IS NULL
    THROW 91010, 'Smoke suite needs seed data. Run Database/Migrations/V004__seed.sql first.', 1;

INSERT INTO @Seats (Value)
SELECT TOP 2 s.SeatId FROM Seats s
JOIN Showtimes st ON st.ScreenId = s.ScreenId AND st.ShowtimeId = @ShowtimeId
WHERE s.IsUsable = 1
  AND NOT EXISTS (SELECT 1 FROM ShowtimeSeatLocks l
                  WHERE l.ShowtimeId = @ShowtimeId AND l.SeatId = s.SeatId)
ORDER BY s.RowLabel, s.SeatNumber;

BEGIN TRY
    EXECUTE AS LOGIN = 'cineflow_app';

        EXEC usp_GetSeatMap     @ShowtimeId = @ShowtimeId;
        EXEC usp_SearchMovies   @Genre = 'Action';
        EXEC usp_SearchMovies;                       -- all params NULL
        EXEC usp_GetSalesReport @FromDate = '2020-01-01', @ToDate = '2099-12-31';
        EXEC usp_PurgeExpiredHolds;

        DECLARE @Out TABLE (BookingId INT, BookingRef NVARCHAR(12),
                            TotalAmount DECIMAL(10,2), ExpiresAt DATETIME2);
        INSERT INTO @Out
        EXEC usp_CreateBooking @UserId = @UserId, @ShowtimeId = @ShowtimeId,
                               @SeatIds = @Seats, @CreatedBy = @UserId;
        SELECT @BookingId = BookingId FROM @Out;

        DECLARE @Total DECIMAL(10,2) = (SELECT TotalAmount FROM @Out);
        SET @Tok = NEWID();
        EXEC usp_ConfirmPayment @BookingId = @BookingId, @RequestToken = @Tok,
                                @Method = 'Cash', @AmountTendered = @Total,
                                @ProcessedBy = @UserId;

        EXEC usp_CancelBooking  @BookingId = @BookingId,
                                @Reason = 'verify.bat smoke test',
                                @CancelledBy = @UserId;

    REVERT;
END TRY
BEGIN CATCH
    IF ORIGINAL_LOGIN() <> SUSER_NAME() REVERT;
    PRINT '  [FAIL] TC-SEC-02  a procedure failed under cineflow_app.';
    PRINT '         If this is a permission error, ownership chaining is broken';
    PRINT '         -- almost certainly dynamic SQL in the named procedure (IS-01).';
    THROW;
END CATCH

PRINT '  [OK] TC-SEC-02  all procedures executed under cineflow_app; ownership chaining intact';
