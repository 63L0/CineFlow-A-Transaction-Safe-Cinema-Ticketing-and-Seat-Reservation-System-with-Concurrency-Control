/* ============================================================================
   CineFlow — V002__indexes.sql
   ----------------------------------------------------------------------------
   M1 / indexes. Transcribed verbatim from DATA-CONTRACT.md section 2.

   Includes the three filtered indexes:
     IX_Bookings_PendingExpiry  (purge-guard index; see D-009)
     UX_Payments_Token          (idempotency)
     UX_Payments_ActiveBooking  (defence in depth)
   ============================================================================ */
SET NOCOUNT ON;

-- Filtered indexes (and indexed views / computed-column indexes) are only
-- creatable when QUOTED_IDENTIFIER is ON at CREATE time. sqlcmd defaults it
-- OFF, so the contract's filtered indexes fail with Msg 1934 without this.
-- Required SET option, not a design change.
SET QUOTED_IDENTIFIER ON;
GO

-- Purge-guard index. Contains ONLY currently-held bookings (typically single
-- digits), which is what makes the IF EXISTS guard in usp_GetSeatMap free.
CREATE INDEX IX_Bookings_PendingExpiry
    ON Bookings(ExpiresAt) WHERE Status = 'PENDING';
GO

CREATE INDEX IX_Showtimes_StartsAt  ON Showtimes(StartsAt) INCLUDE (MovieId, ScreenId);
GO
CREATE INDEX IX_Showtimes_ScreenDay ON Showtimes(ScreenId, StartsAt, EndsAt);
GO
CREATE INDEX IX_Bookings_Showtime   ON Bookings(ShowtimeId, Status);
GO
CREATE INDEX IX_Bookings_CreatedAt  ON Bookings(CreatedAt);
GO
CREATE INDEX IX_Locks_Booking       ON ShowtimeSeatLocks(BookingId);
GO
CREATE INDEX IX_Payments_PaidAt     ON Payments(PaidAt, Status);
GO

-- Idempotency: the same client request can never create two payment rows.
CREATE UNIQUE INDEX UX_Payments_Token
    ON Payments(RequestToken) WHERE RequestToken IS NOT NULL;
GO

-- Defence in depth: a booking can never have two non-voided payments.
CREATE UNIQUE INDEX UX_Payments_ActiveBooking
    ON Payments(BookingId) WHERE Status <> 'VOID';
GO
