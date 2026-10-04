/* ============================================================================
   CineFlow — V001__schema.sql
   ----------------------------------------------------------------------------
   M1 / schema. Transcribed verbatim from DATA-CONTRACT.md section 1 (entities)
   and section 8 (dbo.IntList). No stored procedures, no seed data.

   Tables are created in dependency order so every inline FOREIGN KEY has its
   target already present. Statement text, column order, names, types,
   nullability and defaults are exactly as written in the contract.
   ============================================================================ */
SET NOCOUNT ON;
GO

/* --- dbo.IntList  (DATA-CONTRACT.md section 8) ----------------------------- */
CREATE TYPE dbo.IntList AS TABLE (Value INT PRIMARY KEY);
GO

/* --- 1.1 Roles / Users ----------------------------------------------------- */
CREATE TABLE Roles (
    RoleId       INT IDENTITY PRIMARY KEY,
    RoleName     NVARCHAR(30) NOT NULL UNIQUE          -- Admin, Cashier
);
GO

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
GO

/* --- 1.2 Movies / Screens / Seats ------------------------------------------ */
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
GO

CREATE TABLE Screens (
    ScreenId     INT IDENTITY PRIMARY KEY,
    ScreenName   NVARCHAR(50) NOT NULL UNIQUE,
    TotalSeats   INT NOT NULL,
    CONSTRAINT CK_Screens_Capacity CHECK (TotalSeats > 0)
);
GO

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
GO

/* --- 1.3 Showtimes --------------------------------------------------------- */
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
GO

/* --- 1.4 Bookings — transactional core ------------------------------------- */
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
GO

CREATE TABLE BookingSeats (
    BookingId    INT NOT NULL REFERENCES Bookings(BookingId),
    SeatId       INT NOT NULL REFERENCES Seats(SeatId),
    UnitPrice    DECIMAL(10,2) NOT NULL,
    TicketType   NVARCHAR(20) NOT NULL DEFAULT 'Regular',
    CONSTRAINT PK_BookingSeats PRIMARY KEY (BookingId, SeatId),
    CONSTRAINT CK_BookingSeats_Price CHECK (UnitPrice >= 0),
    CONSTRAINT CK_BookingSeats_Type  CHECK (TicketType IN ('Regular','Student','Senior','PWD','Child'))
);
GO

/* --- 1.5 ShowtimeSeatLocks — live seat inventory --------------------------- */
CREATE TABLE ShowtimeSeatLocks (
    ShowtimeId   INT NOT NULL REFERENCES Showtimes(ShowtimeId),
    SeatId       INT NOT NULL REFERENCES Seats(SeatId),
    BookingId    INT NOT NULL REFERENCES Bookings(BookingId),
    LockedAt     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_SeatLock PRIMARY KEY (ShowtimeId, SeatId)
);
GO

/* --- 1.6 Payments ---------------------------------------------------------- */
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
GO

/* --- 1.7 AuditLogs --------------------------------------------------------- */
CREATE TABLE AuditLogs (
    AuditId      BIGINT IDENTITY PRIMARY KEY,
    UserId       INT NULL REFERENCES Users(UserId),
    Action       NVARCHAR(60) NOT NULL,
    EntityName   NVARCHAR(60) NOT NULL,
    EntityId     NVARCHAR(40) NULL,
    Details      NVARCHAR(MAX) NULL,
    OccurredAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
