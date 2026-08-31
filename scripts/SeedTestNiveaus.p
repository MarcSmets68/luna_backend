/*------------------------------------------------------------------------
    File        : SeedTestNiveaus.p
    Purpose     : Standalone batch script that sets gebruiker.niveau to a
                  small, explicit, hand-picked set of values on a NAMED list
                  of existing gebruiker.kode rows only - so per-user
                  differences (dashboard/rechten) can be exercised through
                  the login feature (docs/architecture/login-auth-ontwerp.md,
                  Luna.BusinessLogic.AuthBE:GetEffectiveNiveau()). This is a
                  predictable, documentable data fix, NOT a bulk/random
                  reassignment - every row it touches and the value it gets
                  is listed below and nowhere else changes.
                  DELIBERATELY NOT wired into compile.ps1 or any scheduled
                  task - this is a one-off, manually-run operational
                  script, never part of an automated pipeline.

    Assignments (per docs/database-analysis.md, gebruiker.niveau is a
    single-digit INTEGER, default 0; AuthBE:GetEffectiveNiveau() hardcodes
    9 as the "iedereen admin" override value, so 9 is the practical max):
      - ABNA -> 5  (the documented login test account - kept at a mid
                    "gewone gebruiker" level, not 1 and not admin, so it
                    stays useful as an ordinary-user test case)
      - MS   -> 9  (Marc Smets - simulates an admin-level user)
      - JS   -> 9  (Jo Sannen - second admin-level user, non-passief)
    Every other gebruiker row is left untouched.

    Usage       : _progres -b -p SeedTestNiveaus.p -param CONFIRM
                  The literal -param value must be exactly CONFIRM (ABL's
                  default case-insensitive CHARACTER comparison applies) -
                  anything else (including no -param at all) refuses to
                  touch the database. This is a deliberate, explicit guard
                  against running this accidentally against a real/
                  production database - see SeedTestNiveaus.ps1 for a
                  second, PowerShell-level confirmation gate on top of
                  this one.
  ----------------------------------------------------------------------*/

DEFINE VARIABLE cConfirm AS CHARACTER NO-UNDO.
DEFINE VARIABLE iCount   AS INTEGER   NO-UNDO INITIAL 0.

/* Named kode -> niveau assignments. Extent-matched arrays kept deliberately
   short and explicit - add pairs here if more test users are ever needed,
   never switch this to a bulk/looping/random assignment. */
DEFINE VARIABLE cKodes   AS CHARACTER EXTENT 3 NO-UNDO INITIAL ["ABNA", "MS", "JS"].
DEFINE VARIABLE iNiveaus AS INTEGER   EXTENT 3 NO-UNDO INITIAL [5, 9, 9].
DEFINE VARIABLE i        AS INTEGER   NO-UNDO.

cConfirm = SESSION:PARAMETER.

IF cConfirm NE "CONFIRM":u THEN
DO:
    MESSAGE "Guard: this script overwrites gebruiker.niveau on a named list of test users.":u.
    MESSAGE "Refusing to run without the exact confirmation flag.":u.
    MESSAGE "Usage: _progres -b -p SeedTestNiveaus.p -param CONFIRM":u.
    QUIT.
END.

DO TRANSACTION:
    DO i = 1 TO EXTENT(cKodes):
        FIND FIRST gebruiker EXCLUSIVE-LOCK
            WHERE gebruiker.kode EQ cKodes[i] NO-ERROR.
        IF AVAILABLE gebruiker THEN
        DO:
            ASSIGN gebruiker.niveau = iNiveaus[i].
            iCount = iCount + 1.
        END.
        ELSE
            MESSAGE SUBSTITUTE("Warning: gebruiker.kode '&1' not found, skipped.":u, cKodes[i]).
    END.
END.

MESSAGE SUBSTITUTE("Seeded test niveau for &1 gebruiker row(s).":u, iCount).
QUIT.
