/* ============================================================
   TC-SEC-03  --  IS-01 static SQL scan

   HEURISTIC GATE, NOT A PROOF.
   This is a substring search over sys.sql_modules.definition. It may
   false-positive on comments and cannot detect every indirect execution
   pattern. Definitive verification of ownership chaining is
   03_smoke_as_app.sql, which executes every procedure under the
   least-privilege login -- any break surfaces as a permission error there.
   ============================================================ */
SET NOCOUNT ON;

DECLARE @Violations TABLE (ProcName SYSNAME, Pattern NVARCHAR(40));

INSERT INTO @Violations (ProcName, Pattern)
SELECT OBJECT_NAME(m.object_id), v.Pattern
FROM sys.sql_modules m
CROSS APPLY (VALUES
    ('sp_executesql'),
    ('EXEC ('), ('EXEC('),
    ('EXECUTE ('), ('EXECUTE(')
) AS v(Pattern)
WHERE m.definition LIKE '%' + v.Pattern + '%'
  AND OBJECTPROPERTY(m.object_id, 'IsProcedure') = 1;

IF EXISTS (SELECT 1 FROM @Violations)
BEGIN
    SELECT ProcName, Pattern FROM @Violations ORDER BY ProcName;
    THROW 91001, 'IS-01 VIOLATION: dynamic SQL detected. Ownership chaining will break and the EXECUTE-only login will fail at runtime. Use the null-coalescing optional-filter pattern instead.', 1;
END

PRINT '  [OK] TC-SEC-03  no dynamic SQL detected (heuristic)';
