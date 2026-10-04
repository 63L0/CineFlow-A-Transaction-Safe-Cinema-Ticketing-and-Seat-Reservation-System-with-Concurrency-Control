/* ============================================================
   TC-SEC-01  --  IS-02 direct table access must be denied

   Asserts the negative: the application login cannot touch a table
   directly. Error 90001 is reserved for "a denial that should have
   fired did not".
   ============================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @Leaks TABLE (Statement NVARCHAR(100));

BEGIN TRY
    EXECUTE AS LOGIN = 'cineflow_app';

        BEGIN TRY  SELECT TOP 1 1 FROM Bookings;
                   INSERT INTO @Leaks VALUES ('SELECT FROM Bookings');
        END TRY BEGIN CATCH END CATCH

        BEGIN TRY  SELECT TOP 1 1 FROM Payments;
                   INSERT INTO @Leaks VALUES ('SELECT FROM Payments');
        END TRY BEGIN CATCH END CATCH

        BEGIN TRY  SELECT TOP 1 1 FROM Users;
                   INSERT INTO @Leaks VALUES ('SELECT FROM Users');
        END TRY BEGIN CATCH END CATCH

        BEGIN TRY  DELETE FROM ShowtimeSeatLocks WHERE 1 = 0;
                   INSERT INTO @Leaks VALUES ('DELETE FROM ShowtimeSeatLocks');
        END TRY BEGIN CATCH END CATCH

        BEGIN TRY  UPDATE Bookings SET Status = Status WHERE 1 = 0;
                   INSERT INTO @Leaks VALUES ('UPDATE Bookings');
        END TRY BEGIN CATCH END CATCH

        BEGIN TRY  INSERT INTO AuditLogs (Action, EntityName) VALUES ('x','y');
                   INSERT INTO @Leaks VALUES ('INSERT INTO AuditLogs');
        END TRY BEGIN CATCH END CATCH

    REVERT;
END TRY
BEGIN CATCH
    IF ORIGINAL_LOGIN() <> SUSER_NAME() REVERT;
    THROW;
END CATCH

IF EXISTS (SELECT 1 FROM @Leaks)
BEGIN
    SELECT Statement AS UnexpectedlyPermitted FROM @Leaks;
    THROW 90001, 'SECURITY: direct table access succeeded when it should be denied. Check GRANT/DENY on schema dbo.', 1;
END

PRINT '  [OK] TC-SEC-01  all direct table access denied for cineflow_app';
