/*------------------------------------------------------------------------
    File        : AuthBE.cls
    Purpose     : Business Entity for the Auth-MVP login/logout/session
                  feature. The ONLY class allowed to reference
                  gebruiker.Password and to create/read/delete
                  authenticationToken rows for auth purposes.
    Schema notes: authenticationToken.userRole is repurposed to carry
                  gebruiker.kode (character x(10), not a role string) -
                  a deliberate, Marc-approved semantic reuse, not a
                  schema change. See docs/architecture/login-auth-ontwerp.md
                  paragraaf 2.3. authenticationToken.uid stays unused/0.
    Syntax      : Called from Luna.Web.LoginHandler (POST /web/login) and
                  Luna.Web.LogoutHandler (POST /web/logout).
    Description : Owns all DB access for auth - no direct DB access is
                  allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes/deletes.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Luna.BusinessLogic.LoginThrottle.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.AuthBE:

    /* Result shape for a successful login - ontwerp paragraaf 1.6.
       SERIALIZE-NAME "items" so LoginHandler can reuse the same
       ResultHandleToJson()+GetJsonArray("items"):GetJsonObject(1)
       unwrap-to-flat-object pattern already used by KlantHandler etc -
       the client-facing response is still the flat top-level object
       the ontwerp specifies. */
    DEFINE TEMP-TABLE ttLoginResult NO-UNDO SERIALIZE-NAME "items":u
        FIELD token               AS CHARACTER   SERIALIZE-NAME "token":u
        FIELD kode                AS CHARACTER   SERIALIZE-NAME "kode":u
        FIELD naam                AS CHARACTER   SERIALIZE-NAME "naam":u
        FIELD niveau              AS INTEGER     SERIALIZE-NAME "niveau":u
        FIELD everyoneAdminActive AS LOGICAL     SERIALIZE-NAME "everyoneAdminActive":u
        FIELD expiresAt           AS DATETIME-TZ SERIALIZE-NAME "expiresAt":u.

    /* Reads the AUTH_EVERYONE_ADMIN OS-environment variable feature flag
       (ontwerp paragraaf 3.1). No caching - read fresh via OS-GETENV() on
       every call so a flag toggle (+ PASOE restart) takes effect
       immediately for new logins and every open session next check.
       Anything other than exactly "true" (case-insensitive) is FALSE -
       fail-closed. */
    METHOD PRIVATE LOGICAL IsEveryoneAdminActive():

        DEFINE VARIABLE cFlag AS CHARACTER NO-UNDO.

        cFlag = OS-GETENV("AUTH_EVERYONE_ADMIN":u).

        IF cFlag EQ ? THEN
            RETURN FALSE.

        RETURN UPPER(TRIM(cFlag)) EQ "TRUE":u.

    END METHOD.

    /* Central "iedereen admin" override point (ontwerp paragraaf 3) -
       called by both Login() and ValidateToken() so a flag toggle applies
       to brand-new logins and to every already-open sessions next
       check, without needing to re-login. */
    METHOD PRIVATE INTEGER GetEffectiveNiveau( INPUT piNiveau AS INTEGER ):

        IF IsEveryoneAdminActive() THEN
            RETURN 9.

        RETURN piNiveau.

    END METHOD.

    /* Generates one random-hex candidate session token: 44 characters
       (matching authenticationToken.token x(44) exactly), each drawn
       independently via RANDOM() from a 16-character hex alphabet - a
       self-written random-hex-generator (no GENERATE-UUID() dependency -
       that built-in is not available/recognized in this OpenEdge
       configuration, confirmed via an isolated compile test; this
       codebase's own RANDOM()-based approach is used instead, per the
       ontwerp's "of een eigen random-hex-generator" fallback wording). */
    METHOD PRIVATE CHARACTER GenerateToken():

        DEFINE VARIABLE cHexChars AS CHARACTER NO-UNDO INITIAL "0123456789abcdef":u.
        DEFINE VARIABLE cToken    AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE i         AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iVal      AS INTEGER   NO-UNDO.

        /* Without an explicit reseed, RANDOM() alone produces the exact
           same sequence in every fresh session/agent (confirmed by an
           isolated test: two separate _progres/PASOE agent sessions
           generated colliding tokens for the very first RANDOM() calls
           of their session). MTIME (milliseconds since midnight, changes
           constantly) is mixed into every character alongside RANDOM()
           and the loop index, so tokens differ both across sessions and
           across repeated calls within the same session. */
        DO i = 1 TO 44:
            iVal   = (MTIME * (i + 1) + RANDOM(1, 16)) MODULO 16 + 1.
            cToken = cToken + SUBSTRING(cHexChars, iVal, 1).
        END.

        RETURN cToken.

    END METHOD.

    /* Generates a session token guaranteed not to collide with an existing
       authenticationToken row. Astronomically unlikely to ever retry
       (44 hex chars of entropy), but fails loudly rather than silently
       reusing/colliding a token. */
    METHOD PRIVATE CHARACTER GenerateUniqueToken():

        DEFINE VARIABLE cCandidate AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iAttempt   AS INTEGER   NO-UNDO.

        DO iAttempt = 1 TO 5:
            cCandidate = GenerateToken().

            FIND FIRST authenticationToken NO-LOCK
                WHERE authenticationToken.token EQ cCandidate NO-ERROR.

            IF NOT AVAILABLE authenticationToken THEN
                RETURN cCandidate.
        END.

        UNDO, THROW NEW Progress.Lang.AppError("Kon geen unieke sessietoken genereren":u, 500).

    END METHOD.

    /* Login beslisboom - ontwerp paragraaf 1.2.1, exacte volgorde, geen
       bypass-pad:
         1. kode/password leeg/ontbrekend -> 400
       1b. 5 mislukte pogingen binnen 15 min voor deze kode -> 429
         2. onbekende kode                -> 401 (generiek)
         3. fout wachtwoord                -> 401 (generiek, identiek aan 2)
         4. gebruiker.passief              -> 403 (NA de wachtwoordcheck)
         5. alles gepasseerd -> token aanmaken, effectief niveau, 200
       Errors: AppError 400/401/403 - Luna.Web.LoginHandler vertaalt deze
       naar de bijbehorende HTTP-statuscode. */
    METHOD PUBLIC HANDLE Login( INPUT pcKode AS CHARACTER, INPUT pcPassword AS CHARACTER ):

        DEFINE VARIABLE cToken    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE dtExpires AS DATETIME-TZ NO-UNDO.
        DEFINE VARIABLE oThrottle AS LoginThrottle NO-UNDO.
        DEFINE VARIABLE iLockMin  AS INTEGER     NO-UNDO.

        EMPTY TEMP-TABLE ttLoginResult.

        /* Stap 1. */
        IF TRIM(pcKode) EQ "":u OR TRIM(pcPassword) EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("Gebruikerskode en wachtwoord zijn verplicht":u, 400).

        /* Stap 1b - inlogbeperking (429): 5 mislukte pogingen per kode binnen
           15 minuten. Geldt voor bestaande EN onbestaande kodes en wordt
           gecontroleerd VOOR het wachtwoord, zodat het antwoord niet
           onthult of een kode bestaat. Zie Luna.BusinessLogic.LoginThrottle. */
        oThrottle = NEW LoginThrottle().
        iLockMin  = oThrottle:GetLockoutMinutes(pcKode).
        IF iLockMin GT 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Te veel mislukte inlogpogingen. Probeer het over &1 &2 opnieuw.":u,
                           iLockMin, IF iLockMin EQ 1 THEN "minuut":u ELSE "minuten":u), 429).

        /* Stap 2 - generieke fout, geen user-enumeratie. */
        FIND FIRST gebruiker NO-LOCK WHERE gebruiker.kode EQ pcKode NO-ERROR.
        IF NOT AVAILABLE gebruiker THEN
        DO:
            oThrottle:RecordFailure(pcKode).
            UNDO, THROW NEW Progress.Lang.AppError("Gebruikersnaam of wachtwoord onjuist":u, 401).
        END.

        /* Stap 3.
           TODO(security, productie-blocker): plaintext-vergelijking - GEEN hashing.
           Bewuste MVP-beslissing van Marc. Moet gehashed worden voor
           een echte productie-rollout met klantdata. Zie
           docs/architecture/login-auth-ontwerp.md paragraaf 5. */
        IF gebruiker.Password NE pcPassword THEN
        DO:
            oThrottle:RecordFailure(pcKode).
            UNDO, THROW NEW Progress.Lang.AppError("Gebruikersnaam of wachtwoord onjuist":u, 401).
        END.

        oThrottle:Reset(pcKode).

        /* Stap 4 - NA de wachtwoordcheck, specifieke melding. */
        IF gebruiker.passief EQ TRUE THEN
            UNDO, THROW NEW Progress.Lang.AppError("Dit account is niet actief. Neem contact op met de beheerder.":u, 403).

        /* Stap 5 - sessie aanmaken. 8 uur vast vanaf login, geen sliding
           expiry (ontwerp paragraaf 6). */
        dtExpires = ADD-INTERVAL(NOW, 8, "hours":u).

        DO TRANSACTION:
            cToken = GenerateUniqueToken().

            CREATE authenticationToken.
            ASSIGN
                authenticationToken.token      = cToken
                /* userRole draagt hier gebruiker.kode, geen rol-string -
                   zie klasse-header en ontwerp paragraaf 2.3. */
                authenticationToken.userRole   = gebruiker.kode
                authenticationToken.uid        = 0
                authenticationToken.expiryDate = dtExpires
                .
        END.

        CREATE ttLoginResult.
        ASSIGN
            ttLoginResult.token               = cToken
            ttLoginResult.kode                = gebruiker.kode
            ttLoginResult.naam                = gebruiker.naam
            ttLoginResult.niveau              = GetEffectiveNiveau(gebruiker.niveau)
            ttLoginResult.everyoneAdminActive = IsEveryoneAdminActive()
            ttLoginResult.expiresAt           = dtExpires
            .

        RETURN TEMP-TABLE ttLoginResult:HANDLE.

    END METHOD.

    /* Logout - valideert dat het token bestaat en niet verlopen is,
       verwijdert het authenticationToken-record (DELETE). Een verlopen
       token wordt ook meteen opgeruimd (passieve cleanup, paragraaf 6)
       maar telt niet als een geldige uitlog-actie.
       Errors: AppError 401 - token ontbreekt/onbekend/verlopen. */
    METHOD PUBLIC VOID Logout( INPUT pcToken AS CHARACTER ):

        DEFINE VARIABLE lExpired AS LOGICAL NO-UNDO INITIAL FALSE.

        IF TRIM(pcToken) EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldige of verlopen sessie":u, 401).

        FIND FIRST authenticationToken NO-LOCK
            WHERE authenticationToken.token EQ pcToken NO-ERROR.

        IF NOT AVAILABLE authenticationToken THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldige of verlopen sessie":u, 401).

        lExpired = authenticationToken.expiryDate LT NOW.

        DO TRANSACTION:
            FIND FIRST authenticationToken EXCLUSIVE-LOCK
                WHERE authenticationToken.token EQ pcToken NO-ERROR.
            IF AVAILABLE authenticationToken THEN
                DELETE authenticationToken.
        END.

        IF lExpired THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldige of verlopen sessie":u, 401).

    END METHOD.

    /* Valideert een sessietoken en levert de gebruikerscontext (kode +
       effectief niveau, na "iedereen admin") - herbruikbaar door andere
       Business Entities in latere iteraties. Controleert expiryDate < NOW
       en ruimt verlopen tokens meteen op (DELETE) - paragraaf 6.
       Returns: TRUE + gevulde OUTPUT-parameters als het token geldig is,
       anders FALSE (en lege/0 OUTPUT-parameters). */
    METHOD PUBLIC LOGICAL ValidateToken(
        INPUT  pcToken  AS CHARACTER,
        OUTPUT pcKode   AS CHARACTER,
        OUTPUT piNiveau AS INTEGER ):

        ASSIGN
            pcKode   = "":u
            piNiveau = 0
            .

        IF TRIM(pcToken) EQ "":u THEN
            RETURN FALSE.

        FIND FIRST authenticationToken NO-LOCK
            WHERE authenticationToken.token EQ pcToken NO-ERROR.

        IF NOT AVAILABLE authenticationToken THEN
            RETURN FALSE.

        IF authenticationToken.expiryDate LT NOW THEN
        DO:
            DO TRANSACTION:
                FIND FIRST authenticationToken EXCLUSIVE-LOCK
                    WHERE authenticationToken.token EQ pcToken NO-ERROR.
                IF AVAILABLE authenticationToken THEN
                    DELETE authenticationToken.
            END.
            RETURN FALSE.
        END.

        FIND FIRST gebruiker NO-LOCK
            WHERE gebruiker.kode EQ authenticationToken.userRole NO-ERROR.

        IF NOT AVAILABLE gebruiker THEN
            RETURN FALSE.

        ASSIGN
            pcKode   = gebruiker.kode
            piNiveau = GetEffectiveNiveau(gebruiker.niveau)
            .

        RETURN TRUE.

    END METHOD.

END CLASS.
