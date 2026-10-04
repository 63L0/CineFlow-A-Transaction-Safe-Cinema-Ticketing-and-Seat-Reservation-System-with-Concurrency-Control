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
