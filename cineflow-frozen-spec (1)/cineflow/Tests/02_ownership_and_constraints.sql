/* ============================================================
   TC-SEC-04  --  IS-05 enforcement integrity + contract freeze

   Checks five ways the frozen contract can be silently hollowed out:
     a) an object owned by a principal other than dbo  -> ownership chain break
     b) a constraint created WITH NOCHECK (is_not_trusted) or disabled
     c) a constraint/index named in DATA-CONTRACT.md that no longer exists
     d) SIGNATURE DRIFT -- parameter name, ordinal, type, length/precision,
        and output flag, per parameter (not just a count)
     e) DEFAULT DRIFT -- a parameter that must be optional (= NULL) or must
        be required, checked against the module text

   (b) and (d) are the realistic agent failure modes. An agent that hits
   stale seed data violating a new constraint will reach for WITH NOCHECK;
   an agent asked to "add the discount" will widen a signature. Both leave
   something that still LOOKS right.
   ============================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

----------------------------------------------------------------
-- (a) Ownership consistency
----------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.objects o
    WHERE o.type IN ('U','P','V','TF','IF','FN')
      AND o.schema_id = SCHEMA_ID('dbo')
      AND OBJECTPROPERTY(o.object_id, 'OwnerId') <> USER_ID('dbo')
)
BEGIN
    SELECT name, type_desc FROM sys.objects o
    WHERE o.type IN ('U','P','V','TF','IF','FN')
      AND o.schema_id = SCHEMA_ID('dbo')
      AND OBJECTPROPERTY(o.object_id, 'OwnerId') <> USER_ID('dbo');
    THROW 91002, 'OWNERSHIP VIOLATION: objects not owned by dbo. Ownership chaining will break. Transfer the object: ALTER AUTHORIZATION ON OBJECT::dbo.<name> TO SCHEMA OWNER;', 1;
END
PRINT '  [OK] ownership  all dbo objects owned by dbo';

-- The dbo schema must be owned by dbo for ownership chaining to hold.
-- This is ASSERTED, never set: SQL Server prohibits changing the owner of
-- sys, dbo or information_schema (Msg 15150). See D-015.
IF NOT EXISTS (
    SELECT 1 FROM sys.schemas s
    JOIN sys.database_principals p ON p.principal_id = s.principal_id
    WHERE s.name = 'dbo' AND p.name = 'dbo'
)
BEGIN
    SELECT s.name AS SchemaName, p.name AS OwnerName
    FROM sys.schemas s
    JOIN sys.database_principals p ON p.principal_id = s.principal_id
    WHERE s.name = 'dbo';
    THROW 91002, 'OWNERSHIP VIOLATION: schema dbo is not owned by dbo. This cannot be repaired in place; the database must be rebuilt.', 1;
END
PRINT '  [OK] ownership  schema dbo is owned by dbo (asserted, not set)';

----------------------------------------------------------------
-- (b) No untrusted or disabled constraints
----------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1)
   OR EXISTS (SELECT 1 FROM sys.foreign_keys   WHERE is_disabled = 1 OR is_not_trusted = 1)
BEGIN
    SELECT 'CHECK' AS Kind, name, is_disabled, is_not_trusted FROM sys.check_constraints
    WHERE is_disabled = 1 OR is_not_trusted = 1
    UNION ALL
    SELECT 'FK', name, is_disabled, is_not_trusted FROM sys.foreign_keys
    WHERE is_disabled = 1 OR is_not_trusted = 1;
    THROW 91003, 'IS-05 VIOLATION: disabled or untrusted constraint found (WITH NOCHECK). Fix the data, not the constraint.', 1;
END
PRINT '  [OK] TC-SEC-04  all constraints enabled and trusted';

----------------------------------------------------------------
-- (c) Contract drift: every constraint/index named in DATA-CONTRACT.md exists
----------------------------------------------------------------
DECLARE @Required TABLE (ObjName SYSNAME, Kind NVARCHAR(20));
INSERT INTO @Required VALUES
    ('CK_Bookings_ExpiryLifecycle',      'CHECK'),
    ('CK_Bookings_Status',               'CHECK'),
    ('CK_Bookings_Total',                'CHECK'),
    ('CK_Payments_NonNegativeChange',    'CHECK'),
    ('CK_Payments_MethodFields',         'CHECK'),
    ('CK_Payments_Method',               'CHECK'),
    ('CK_Payments_Status',               'CHECK'),
    ('CK_Showtime_Range',                'CHECK'),
    ('CK_Movies_Duration',               'CHECK'),
    ('PK_SeatLock',                      'INDEX'),
    ('PK_BookingSeats',                  'INDEX'),
    ('UX_Payments_Token',                'INDEX'),
    ('UX_Payments_ActiveBooking',        'INDEX'),
    ('IX_Bookings_PendingExpiry',        'INDEX'),
    ('UQ_Showtime_Slot',                 'INDEX');

IF EXISTS (
    SELECT 1 FROM @Required r
    WHERE (r.Kind = 'CHECK' AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = r.ObjName))
       OR (r.Kind = 'INDEX' AND NOT EXISTS (SELECT 1 FROM sys.indexes           WHERE name = r.ObjName))
)
BEGIN
    SELECT r.ObjName AS MissingObject, r.Kind FROM @Required r
    WHERE (r.Kind = 'CHECK' AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = r.ObjName))
       OR (r.Kind = 'INDEX' AND NOT EXISTS (SELECT 1 FROM sys.indexes           WHERE name = r.ObjName));
    THROW 91004, 'CONTRACT DRIFT: an object frozen in DATA-CONTRACT.md is missing from the database.', 1;
END
PRINT '  [OK] contract   all frozen constraints and indexes present';

----------------------------------------------------------------
-- (d) SIGNATURE FREEZE -- exact per-parameter manifest
--
--     A count check passes a swap of @AmountTendered DECIMAL(10,2)
--     for @AmountTendered MONEY, or a silent reorder of two INT
--     parameters, or @Reason widened from NVARCHAR(200) to MAX.
--     Ordinal + name + type + size + output flag is the real contract.
--
--     Types are compared as the rendered declaration so the failure
--     message reads like the DDL the developer wrote.
----------------------------------------------------------------
-- Sections (d) and (e) inspect procedures. At M1 no procedure exists yet, so
-- they are SKIPPED -- announced, not silent, and not by weakening them.
-- A PARTIAL set is a harder failure than none: a procedure was dropped or
-- renamed. See D-016.
DECLARE @ContractProcs TABLE (ProcName SYSNAME);
INSERT INTO @ContractProcs VALUES
    ('usp_CreateBooking'), ('usp_ConfirmPayment'), ('usp_CancelBooking'),
    ('usp_GetSeatMap'),    ('usp_PurgeExpiredHolds');

DECLARE @ProcsPresent INT = (
    SELECT COUNT(*) FROM sys.procedures p
    WHERE p.name IN (SELECT ProcName FROM @ContractProcs)
);

IF @ProcsPresent = 0
BEGIN
    PRINT '  [--] signatures SKIPPED - no contract procedures exist yet (expected at M1)';
    PRINT '  [--] defaults   SKIPPED - same reason';
    PRINT '  [OK] TC-SEC-04  gate 2 complete for the current milestone';
    RETURN;
END

IF @ProcsPresent < (SELECT COUNT(*) FROM @ContractProcs)
BEGIN
    SELECT c.ProcName, 'MISSING' AS Problem
    FROM @ContractProcs c
    WHERE NOT EXISTS (SELECT 1 FROM sys.procedures p WHERE p.name = c.ProcName);
    THROW 91007, 'PARTIAL PROCEDURE SET: some contract procedures exist and some do not. A procedure was dropped, renamed, or never created.', 1;
END
DECLARE @Expected TABLE (
    ProcName   SYSNAME,
    Ordinal    INT,
    ParamName  SYSNAME,
    Decl       NVARCHAR(100),
    IsOutput   BIT
);

INSERT INTO @Expected (ProcName, Ordinal, ParamName, Decl, IsOutput) VALUES
-- usp_CreateBooking
 ('usp_CreateBooking',     1, '@UserId',         'int',            0),
 ('usp_CreateBooking',     2, '@ShowtimeId',     'int',            0),
 ('usp_CreateBooking',     3, '@SeatIds',        'IntList',        0),
 ('usp_CreateBooking',     4, '@CreatedBy',      'int',            0),
-- usp_ConfirmPayment
 ('usp_ConfirmPayment',    1, '@BookingId',      'int',            0),
 ('usp_ConfirmPayment',    2, '@RequestToken',   'uniqueidentifier', 0),
 ('usp_ConfirmPayment',    3, '@Method',         'nvarchar(20)',   0),
 ('usp_ConfirmPayment',    4, '@AmountTendered', 'decimal(10,2)',  0),
 ('usp_ConfirmPayment',    5, '@ReferenceNumber','nvarchar(50)',   0),
 ('usp_ConfirmPayment',    6, '@ProcessedBy',    'int',            0),
-- usp_CancelBooking
 ('usp_CancelBooking',     1, '@BookingId',      'int',            0),
 ('usp_CancelBooking',     2, '@Reason',         'nvarchar(200)',  0),
 ('usp_CancelBooking',     3, '@CancelledBy',    'int',            0),
-- usp_GetSeatMap
 ('usp_GetSeatMap',        1, '@ShowtimeId',     'int',            0);
-- usp_PurgeExpiredHolds intentionally takes no parameters.

DECLARE @Actual TABLE (
    ProcName   SYSNAME,
    Ordinal    INT,
    ParamName  SYSNAME,
    Decl       NVARCHAR(100),
    IsOutput   BIT
);

INSERT INTO @Actual (ProcName, Ordinal, ParamName, Decl, IsOutput)
SELECT o.name,
       p.parameter_id,
       p.name,
       t.name +
       CASE
           WHEN t.name IN ('decimal','numeric')
               THEN '(' + CAST(p.precision AS NVARCHAR(10)) + ',' + CAST(p.scale AS NVARCHAR(10)) + ')'
           WHEN t.name IN ('nvarchar','nchar')
               THEN '(' + CASE WHEN p.max_length = -1 THEN 'max'
                               ELSE CAST(p.max_length / 2 AS NVARCHAR(10)) END + ')'
           WHEN t.name IN ('varchar','char','varbinary','binary')
               THEN '(' + CASE WHEN p.max_length = -1 THEN 'max'
                               ELSE CAST(p.max_length AS NVARCHAR(10)) END + ')'
           WHEN t.name IN ('datetime2','time','datetimeoffset')
               THEN '(' + CAST(p.scale AS NVARCHAR(10)) + ')'
           ELSE ''
       END,
       p.is_output
FROM sys.procedures o
JOIN sys.parameters p ON p.object_id = o.object_id
JOIN sys.types      t ON t.user_type_id = p.user_type_id
WHERE o.name IN (SELECT DISTINCT ProcName FROM @Expected)
   OR o.name = 'usp_PurgeExpiredHolds';

IF EXISTS (
    SELECT 1 FROM @Expected e FULL OUTER JOIN @Actual a
      ON a.ProcName = e.ProcName AND a.Ordinal = e.Ordinal
    WHERE e.ProcName IS NULL OR a.ProcName IS NULL
       OR a.ParamName <> e.ParamName
       OR a.Decl      <> e.Decl
       OR a.IsOutput  <> e.IsOutput
)
BEGIN
    SELECT COALESCE(e.ProcName, a.ProcName)                     AS ProcName,
           COALESCE(e.Ordinal,  a.Ordinal)                      AS Ordinal,
           ISNULL(e.ParamName + ' ' + e.Decl, '(none expected)') AS Frozen,
           ISNULL(a.ParamName + ' ' + a.Decl, '(missing)')       AS Actual,
           CASE WHEN e.ProcName IS NULL THEN 'PARAMETER ADDED'
                WHEN a.ProcName IS NULL THEN 'PARAMETER REMOVED'
                WHEN a.ParamName <> e.ParamName THEN 'RENAMED OR REORDERED'
                WHEN a.Decl      <> e.Decl      THEN 'TYPE OR SIZE CHANGED'
                ELSE 'OUTPUT FLAG CHANGED' END                   AS Problem
    FROM @Expected e FULL OUTER JOIN @Actual a
      ON a.ProcName = e.ProcName AND a.Ordinal = e.Ordinal
    WHERE e.ProcName IS NULL OR a.ProcName IS NULL
       OR a.ParamName <> e.ParamName OR a.Decl <> e.Decl OR a.IsOutput <> e.IsOutput
    ORDER BY ProcName, Ordinal;

    THROW 91005, 'SIGNATURE DRIFT: a frozen procedure signature changed (name, order, type, size, or output). Escalate instead of editing. See DATA-CONTRACT.md section 6.', 1;
END
PRINT '  [OK] signatures per-parameter manifest matches DATA-CONTRACT.md';

----------------------------------------------------------------
-- (e) DEFAULT / OPTIONALITY DRIFT
--
--     LIMITATION, STATED PLAINLY: sys.parameters cannot answer this.
--     has_default_value is only populated for CLR objects, and every
--     T-SQL parameter is nullable at the type level regardless of
--     whether the proc requires a value. So optionality can only be
--     read from the module text.
--
--     That makes this check a TEXT HEURISTIC with the same standing as
--     the IS-01 scan in 01_static_sql_scan.sql -- it catches the
--     realistic drift (an agent removing '= NULL' or adding one), but
--     it is defeated by unusual whitespace or comments. The BINDING
--     guarantee that optional parameters behave correctly is TC-PAY-03
--     and TC-PAY-04 in 05_invariants.sql, which call the procedure with
--     those arguments omitted and assert the documented error numbers.
----------------------------------------------------------------
DECLARE @Optionality TABLE (ProcName SYSNAME, ParamName SYSNAME, MustBeOptional BIT);
INSERT INTO @Optionality VALUES
    ('usp_ConfirmPayment', '@AmountTendered',  1),   -- cash only
    ('usp_ConfirmPayment', '@ReferenceNumber', 1),   -- digital only
    ('usp_ConfirmPayment', '@BookingId',       0),
    ('usp_ConfirmPayment', '@RequestToken',    0),   -- idempotency key: never optional
    ('usp_ConfirmPayment', '@Method',          0),
    ('usp_ConfirmPayment', '@ProcessedBy',     0),
    ('usp_CreateBooking',  '@UserId',          0),
    ('usp_CreateBooking',  '@ShowtimeId',      0),
    ('usp_CreateBooking',  '@SeatIds',         0),
    ('usp_CancelBooking',  '@BookingId',       0),
    ('usp_CancelBooking',  '@Reason',          0);

DECLARE @OptViolations TABLE (ProcName SYSNAME, ParamName SYSNAME, Problem NVARCHAR(60));

INSERT INTO @OptViolations
SELECT o.ProcName, o.ParamName,
       CASE WHEN o.MustBeOptional = 1
            THEN 'lost its = NULL default (now required)'
            ELSE 'gained a default (now silently optional)' END
FROM @Optionality o
JOIN sys.procedures p  ON p.name = o.ProcName
JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE
    -- matches "@Param <type> = NULL" allowing one or two spaces around '='
    -- T-SQL has no boolean type; materialise the predicate through CASE.
    CASE WHEN m.definition LIKE '%' + o.ParamName + '%= NULL%'
              OR m.definition LIKE '%' + o.ParamName + '%=NULL%'
         THEN 1 ELSE 0 END
    <> o.MustBeOptional;

IF EXISTS (SELECT 1 FROM @OptViolations)
BEGIN
    SELECT * FROM @OptViolations ORDER BY ProcName, ParamName;
    THROW 91006, 'OPTIONALITY DRIFT: a parameter gained or lost its = NULL default. A required parameter turning optional is silent scope loss; see DATA-CONTRACT.md section 6.', 1;
END
PRINT '  [OK] defaults   optionality matches contract (heuristic; TC-PAY-03/04 are the binding proof)';
