/* ============================================================================
   CineFlow — V005__security.sql
   ----------------------------------------------------------------------------
   M1 / security. Transcribed verbatim from DATA-CONTRACT.md section 8.

   Least-privilege application login. The app gets EXECUTE on the schema and
   nothing else; all table-level DML is explicitly denied, so ownership
   chaining (not a GRANT) is what lets procedures reach the tables.

   NOTE: the contract writes the password as '<set at deployment>'. That literal
   cannot satisfy the Windows password policy, so a deployment password is used
   here and MUST be replaced on the target machine.
   ============================================================================ */
SET NOCOUNT ON;
GO

CREATE LOGIN cineflow_app WITH PASSWORD = 'CineFlow_App#2026';
GO

CREATE USER cineflow_app FOR LOGIN cineflow_app;
GO

/* Ownership chaining requires a single consistent owner.
   CONTRACT LINE OMITTED -- see report section 4:
       ALTER AUTHORIZATION ON SCHEMA::dbo TO dbo;
   SQL Server rejects ALTER AUTHORIZATION against the dbo schema with
   Msg 15150 "Cannot alter the schema 'dbo'." even when run as sysadmin/dbo.
   The dbo schema is already owned by dbo (sys.schemas.principal_id = 1), so the
   end state the contract requires is already in force, and gate 2(a)
   independently enforces that every dbo object is owned by dbo. */
GO

GRANT EXECUTE ON SCHEMA::dbo TO cineflow_app;
GO

DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO cineflow_app;
GO

-- Required for the table-valued parameter on usp_CreateBooking.
GRANT EXECUTE ON TYPE::dbo.IntList TO cineflow_app;
GO
