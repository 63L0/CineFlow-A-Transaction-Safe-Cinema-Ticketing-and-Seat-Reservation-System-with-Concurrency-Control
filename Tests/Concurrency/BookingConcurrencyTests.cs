using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.SqlClient;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace CineFlow.Tests.Concurrency
{
    /// <summary>
    /// The project's differentiator. These tests are the evidence that the
    /// transactional design actually holds, and they are demonstrated live
    /// during defense.
    ///
    /// Run from verify.bat daily from Day 5, not as a week-3 activity.
    /// </summary>
    [TestClass]
    [TestCategory("Concurrency")]
    public class BookingConcurrencyTests
    {
        private TestFixture _fx = null!;

        [TestInitialize]
        public void Setup() => _fx = TestFixture.Create();

        [TestCleanup]
        public void Teardown() => _fx.Dispose();

        // ---------------------------------------------------------------
        // TC-CONC-01  Twenty clients, one seat, exactly one winner.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_CONC_01_TwentyParallelBookings_SameSeat_OnlyOneSucceeds()
        {
            int seat = _fx.FreeSeat();
            int succeeded = 0, rejected = 0;

            Parallel.For(0, 20, i =>
            {
                var r = _fx.TryCreateBooking(_fx.UserId, _fx.ShowtimeId, new[] { seat });
                if (r.Success) Interlocked.Increment(ref succeeded);
                else if (r.ErrorNumber == 50001) Interlocked.Increment(ref rejected);
                else Assert.Fail($"Unexpected error {r.ErrorNumber}: {r.Message}");
            });

            Assert.AreEqual(1, succeeded, "exactly one booking must win");
            Assert.AreEqual(19, rejected, "all losers must fail cleanly with 50001");
            Assert.AreEqual(1, _fx.LockCount(_fx.ShowtimeId, seat));
        }

        // ---------------------------------------------------------------
        // TC-CONC-02  Overlapping seat sets. Catches partial commits that
        // the single-seat test cannot see: if XACT_ABORT is off or the
        // error is caught in the wrong place, the loser leaves an orphaned
        // PENDING booking and/or partial lock rows behind.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_CONC_02_OverlappingSeatSets_NoPartialCommits()
        {
            var seats = _fx.FreeSeats(5);
            var setA = new[] { seats[0], seats[1], seats[2] };
            var setB = new[] { seats[2], seats[3], seats[4] };   // share seats[2]

            var a = Task.Run(() => _fx.TryCreateBooking(_fx.UserId, _fx.ShowtimeId, setA));
            var b = Task.Run(() => _fx.TryCreateBooking(_fx.UserId2, _fx.ShowtimeId, setB));
            Task.WaitAll(a, b);

            var results = new[] { a.Result, b.Result };
            Assert.AreEqual(1, results.Count(r => r.Success), "exactly one set must win");

            int held = seats.Count(s => _fx.LockCount(_fx.ShowtimeId, s) == 1);
            Assert.AreEqual(3, held, "winner holds exactly 3 seats; never 4 or 5");

            var loser = results.Single(r => !r.Success);
            Assert.AreEqual(50001, loser.ErrorNumber);
            Assert.AreEqual(0, _fx.OrphanedPendingBookings(_fx.ShowtimeId),
                "the loser must leave no booking row behind");
        }

        // ---------------------------------------------------------------
        // TC-CANCEL-02  (closes open item 1, concurrent half)
        //
        // Cancel and rebook race for the same seat. Two things are asserted:
        // no deadlock (LO-01 lock ordering holds), and the final state is
        // one of exactly two legal outcomes -- never a seat that is both
        // released and still owned, and never two owners.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_CANCEL_02_CancelAndRebook_SameSeat_NoLostOrDoubleLock()
        {
            int seat = _fx.FreeSeat();
            var original = _fx.CreateAndConfirm(_fx.UserId, _fx.ShowtimeId, new[] { seat });

            var cancel = Task.Run(() => _fx.TryCancel(original.BookingId));
            var rebook = Task.Run(() => _fx.TryCreateBooking(_fx.UserId2, _fx.ShowtimeId, new[] { seat }));
            Task.WaitAll(cancel, rebook);

            Assert.IsFalse(cancel.Result.ErrorNumber == 1205 || rebook.Result.ErrorNumber == 1205,
                "deadlock detected -- LO-01 lock ordering is violated somewhere");
            Assert.IsTrue(cancel.Result.Success, "cancellation must always succeed here");

            int locks = _fx.LockCount(_fx.ShowtimeId, seat);
            Assert.IsTrue(locks <= 1, "a seat can never carry two lock rows");

            if (rebook.Result.Success)
            {
                Assert.AreEqual(1, locks, "rebook won: the new booking must own the lock");
                Assert.AreEqual(rebook.Result.BookingId, _fx.LockOwner(_fx.ShowtimeId, seat));
            }
            else
            {
                Assert.AreEqual(50001, rebook.Result.ErrorNumber, "rebook must fail cleanly, not silently");
                Assert.AreEqual(0, locks,
                    "cancel committed, so the seat must be free -- a surviving lock means " +
                    "the release is not synchronous and the seat is now unsellable");
            }

            Assert.AreEqual("CANCELLED", _fx.BookingStatus(original.BookingId));
        }

        // ---------------------------------------------------------------
        // TC-PURGE-03  An expired hold releases its seats on the next read.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_PURGE_03_ExpiredHold_IsReleasedOnNextSeatMapRead()
        {
            int seat = _fx.FreeSeat();
            var booking = _fx.CreateBooking(_fx.UserId, _fx.ShowtimeId, new[] { seat });
            _fx.ForceExpire(booking.BookingId);

            var map = _fx.GetSeatMap(_fx.ShowtimeId);

            Assert.AreEqual("AVAILABLE", map[seat]);
            Assert.AreEqual("EXPIRED", _fx.BookingStatus(booking.BookingId));
            Assert.IsNull(_fx.BookingExpiresAt(booking.BookingId),
                "INV-05: a non-PENDING booking must not retain an ExpiresAt");
            Assert.AreEqual(0, _fx.LockCount(_fx.ShowtimeId, seat));
        }

        // ---------------------------------------------------------------
        // TC-PURGE-04  The guarded purge does not write on a clean read.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_PURGE_04_SeatMapRead_WithNoExpiredHolds_PerformsNoWrites()
        {
            _fx.PurgeNow();                                  // start clean
            long before = _fx.TotalPurgedEver();

            for (int i = 0; i < 10; i++) _fx.GetSeatMap(_fx.ShowtimeId);

            Assert.AreEqual(before, _fx.TotalPurgedEver(),
                "a read path must not take a write lock when there is nothing to purge");
        }

        // ---------------------------------------------------------------
        // TC-PAY-06  Same booking, two DIFFERENT tokens, concurrent.
        //
        // This is the test that would have caught the silent-empty-result
        // bug. The loser must THROW. Returning an empty result set with no
        // error means no ticket printed and no error shown.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_PAY_06_SameBooking_DifferentTokens_LoserFailsLoudly()
        {
            var booking = _fx.CreateBooking(_fx.UserId, _fx.ShowtimeId, new[] { _fx.FreeSeat() });

            var a = Task.Run(() => _fx.TryConfirmCash(booking.BookingId, Guid.NewGuid(), booking.Total));
            var b = Task.Run(() => _fx.TryConfirmCash(booking.BookingId, Guid.NewGuid(), booking.Total));
            Task.WaitAll(a, b);

            var results = new[] { a.Result, b.Result };
            Assert.AreEqual(1, results.Count(r => r.Success), "exactly one payment must succeed");
            Assert.AreEqual(1, results.Count(r => r.ThrewError), "the loser must throw");
            Assert.AreEqual(0, results.Count(r => r.ReturnedNoRows),
                "PC-01: no path may return an empty result set");

            var loser = results.Single(r => !r.Success);
            Assert.IsTrue(loser.ErrorNumber == 50016 || loser.ErrorNumber == 50021,
                $"loser must fail with 50016 or 50021, got {loser.ErrorNumber}");

            Assert.AreEqual(1, _fx.PaymentCount(booking.BookingId));
        }

        // ---------------------------------------------------------------
        // TC-PAY-05  Same token twice: idempotent replay.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_PAY_05_SameToken_Twice_ReturnsSamePaymentId()
        {
            var booking = _fx.CreateBooking(_fx.UserId, _fx.ShowtimeId, new[] { _fx.FreeSeat() });
            var token = Guid.NewGuid();

            var first = _fx.TryConfirmCash(booking.BookingId, token, booking.Total);
            var second = _fx.TryConfirmCash(booking.BookingId, token, booking.Total);

            Assert.IsTrue(first.Success && second.Success);
            Assert.AreEqual(first.PaymentId, second.PaymentId);
            Assert.IsFalse(first.WasDuplicate);
            Assert.IsTrue(second.WasDuplicate);
            Assert.AreEqual(1, _fx.PaymentCount(booking.BookingId));
        }

        // ---------------------------------------------------------------
        // TC-PC-01  Contract sweep: drive every PC-01 procedure through
        // every failure branch and assert none returns an empty result.
        // Stated as an OUTCOME, so it holds for causes nobody enumerated.
        // ---------------------------------------------------------------
        [TestMethod]
        public void TC_PC_01_NoProcedureEverReturnsAnEmptyResultSet()
        {
            var violations = new List<string>();

            foreach (var scenario in ContractScenarios.All(_fx))
            {
                var outcome = scenario.Invoke();
                if (outcome.ReturnedNoRows && !outcome.ThrewError)
                    violations.Add(scenario.Name);
            }

            Assert.AreEqual(0, violations.Count,
                "PC-01 violated -- these returned empty without throwing: " +
                string.Join(", ", violations));
        }
    }
}
