/*------------------------------------------------------------------------
    File        : SeedTestPasswords.p
    Purpose     : Standalone batch script that sets gebruiker.Password to a
                  single shared test password ("Welkom123":u) on EVERY existing
                  gebruiker row - for Auth-MVP testing only (see
                  docs/architecture/login-auth-ontwerp.md paragraaf 8).
                  DELIBERATELY NOT wired into compile.ps1 or any scheduled
                  task - this is a one-off, manually-run operational
                  script, never part of an automated pipeline.
    Usage       : _progres -b -p SeedTestPasswords.p -param CONFIRM
                  The literal -param value must be exactly CONFIRM (ABL's
                  default case-insensitive CHARACTER comparison applies) -
                  anything else (including no -param at all) refuses to
                  touch the database. This is a deliberate,
                  explicit guard against running this accidentally against
                  a real/production database - see SeedTestPasswords.ps1
                  for a second, PowerShell-level confirmation gate on top
                  of this one.
  ----------------------------------------------------------------------*/

DEFINE VARIABLE cConfirm AS CHARACTER NO-UNDO.
DEFINE VARIABLE iCount   AS INTEGER   NO-UNDO INITIAL 0.

cConfirm = SESSION:PARAMETER.

IF cConfirm NE "CONFIRM":u THEN
DO:
    MESSAGE "Guard: this script overwrites gebruiker.Password on EVERY row with a shared test password.":u.
    MESSAGE "Refusing to run without the exact confirmation flag.":u.
    MESSAGE "Usage: _progres -b -p SeedTestPasswords.p -param CONFIRM":u.
    QUIT.
END.

DO TRANSACTION:
    FOR EACH gebruiker EXCLUSIVE-LOCK:
        ASSIGN gebruiker.Password = "Welkom123":u.
        iCount = iCount + 1.
    END.
END.

MESSAGE SUBSTITUTE("Seeded test password for &1 gebruiker row(s).":u, iCount).
QUIT.
