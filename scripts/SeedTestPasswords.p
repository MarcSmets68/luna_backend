/*------------------------------------------------------------------------
    File        : SeedTestPasswords.p
    Purpose     : Standalone batch script that sets gebruiker.Password to a
                  single shared test password (supplied at run time, never
                  stored in the repo) on EVERY existing gebruiker row - for Auth-MVP testing only (see
                  docs/architecture/login-auth-ontwerp.md paragraaf 8).
                  DELIBERATELY NOT wired into compile.ps1 or any scheduled
                  task - this is a one-off, manually-run operational
                  script, never part of an automated pipeline.
    Usage       : _progres -b -p SeedTestPasswords.p -param "CONFIRM|<password>"
                  The -param value is "<guard>|<password>": everything before
                  the first "|" must be exactly CONFIRM (ABL's default
                  case-insensitive CHARACTER comparison applies) and the
                  password (everything after it) is mandatory and must not
                  be empty - anything else (including no -param at all) refuses to
                  touch the database. This is a deliberate,
                  explicit guard against running this accidentally against
                  a real/production database - see SeedTestPasswords.ps1
                  for a second, PowerShell-level confirmation gate on top
                  of this one.
  ----------------------------------------------------------------------*/

DEFINE VARIABLE cParam    AS CHARACTER NO-UNDO.
DEFINE VARIABLE cConfirm  AS CHARACTER NO-UNDO.
DEFINE VARIABLE cPassword AS CHARACTER NO-UNDO.
DEFINE VARIABLE iCount    AS INTEGER   NO-UNDO INITIAL 0.

cParam = SESSION:PARAMETER.
IF cParam = ? THEN cParam = "":u.
cConfirm  = ENTRY(1, cParam, "|":u).
cPassword = SUBSTRING(cParam, INDEX(cParam, "|":u) + 1).
IF INDEX(cParam, "|":u) = 0 THEN cPassword = "":u.

IF cConfirm NE "CONFIRM":u THEN
DO:
    MESSAGE "Guard: this script overwrites gebruiker.Password on EVERY row with a shared test password.":u.
    MESSAGE "Refusing to run without the exact confirmation flag.":u.
    MESSAGE "Usage: _progres -b -p SeedTestPasswords.p -param CONFIRM|<password>":u.
    QUIT.
END.

IF cPassword = "":u THEN
DO:
    MESSAGE "Guard: a non-empty test password is required (-param CONFIRM|<password>). Refusing to run.":u.
    QUIT.
END.

DO TRANSACTION:
    FOR EACH gebruiker EXCLUSIVE-LOCK:
        ASSIGN gebruiker.Password = cPassword.
        iCount = iCount + 1.
    END.
END.

MESSAGE SUBSTITUTE("Seeded test password for &1 gebruiker row(s).":u, iCount).
QUIT.
