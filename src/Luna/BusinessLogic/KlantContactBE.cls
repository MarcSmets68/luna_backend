/*------------------------------------------------------------------------
    File        : KlantContactBE.cls
    Purpose     : Business Entity for the "klant-contact" (customer contact
                  person) table - a child of `klant` (linked via klnr),
                  backing the "contacten" list on the extended klant info
                  tab. Full CRUD.
    Field map (JSON key -> klant-contact column):
                  klnr        -> klnr        (PK, immutable, from parent klant)
                  lijnnr      -> lijnnr      (PK, from body on create or
                                              auto-allocated, immutable)
                  naam        -> naam
                  voornaam    -> voornaam
                  aanspreking -> aanspreking
                  netTel      -> net-tel
                  tel         -> tel
                  gsm         -> gsm
                  email       -> email
                  standaard   -> standaard
                  opm         -> opm
                  soort       -> soort
    Syntax      : Called from Luna.Web.KlantHandler (GET/POST/PUT/DELETE
                  /web/klant/{klnr}/contact and
                  /web/klant/{klnr}/contact/{lijnnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers are
                  expected to have already validated that the parent klant
                  (klnr) exists - see EnsureKlantExists.
                  "standaard" exclusivity: setting standaard = TRUE on
                  create/update clears standaard on every OTHER
                  klant-contact row for that klnr, in the same transaction
                  (independent of klant-adr's own standaard flag). Setting
                  it to FALSE (or omitting it) never touches other rows.
                  Deleting the standaard row does NOT auto-promote another
                  row - zero standaard rows for a klnr is an accepted state.
    Author(s)   : Devin
    Created     : 2026-08-27
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.KlantContactBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttKlantContact NO-UNDO SERIALIZE-NAME 'items':u
        FIELD klnr        AS INTEGER   SERIALIZE-NAME 'klnr':u
        FIELD lijnnr      AS INTEGER   SERIALIZE-NAME 'lijnnr':u
        FIELD naam        AS CHARACTER SERIALIZE-NAME 'naam':u
        FIELD voornaam    AS CHARACTER SERIALIZE-NAME 'voornaam':u
        FIELD aanspreking AS CHARACTER SERIALIZE-NAME 'aanspreking':u
        FIELD netTel      AS CHARACTER SERIALIZE-NAME 'netTel':u
        FIELD tel         AS CHARACTER SERIALIZE-NAME 'tel':u
        FIELD gsm         AS CHARACTER SERIALIZE-NAME 'gsm':u
        FIELD email       AS CHARACTER SERIALIZE-NAME 'email':u
        FIELD standaard   AS LOGICAL   SERIALIZE-NAME 'standaard':u
        FIELD opm         AS CHARACTER SERIALIZE-NAME 'opm':u
        FIELD soort       AS CHARACTER SERIALIZE-NAME 'soort':u
        INDEX idx-lijnnr IS PRIMARY klnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent klant doesn't exist.
                 Called at the start of every method here so klant-contact
                 CRUD never silently operates on/under a non-existent
                 customer.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureKlantExists( INPUT piKlnr AS INTEGER ):

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.

        IF NOT AVAILABLE klant THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE('Klant &1 not found':u, piKlnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the fields from a `klant-contact` buffer into a
                 ttKlantContact row, for use by every read/write method
                 below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbKlantContact FOR klant-contact, BUFFER pbTt FOR ttKlantContact ):

        ASSIGN
            pbTt.klnr        = pbKlantContact.klnr
            pbTt.lijnnr      = pbKlantContact.lijnnr
            pbTt.naam        = pbKlantContact.naam
            pbTt.voornaam    = pbKlantContact.voornaam
            pbTt.aanspreking = pbKlantContact.aanspreking
            pbTt.netTel      = pbKlantContact.net-tel
            pbTt.tel         = pbKlantContact.tel
            pbTt.gsm         = pbKlantContact.gsm
            pbTt.email       = pbKlantContact.email
            pbTt.standaard   = pbKlantContact.standaard
            pbTt.opm         = pbKlantContact.opm
            pbTt.soort       = pbKlantContact.soort
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field (except `standaard` - see
                 ApplyStandaard) present in the JSON request body onto the
                 given `klant-contact` buffer. Fields absent from the body
                 are left untouched, so this also works for partial updates.
                 `klnr`/`lijnnr` are never touched here - they are set once
                 on create and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbKlantContact FOR klant-contact ):

        IF poBody:Has('naam':u)        THEN pbKlantContact.naam        = poBody:GetCharacter('naam':u).
        IF poBody:Has('voornaam':u)    THEN pbKlantContact.voornaam    = poBody:GetCharacter('voornaam':u).
        IF poBody:Has('aanspreking':u) THEN pbKlantContact.aanspreking = poBody:GetCharacter('aanspreking':u).
        IF poBody:Has('netTel':u)      THEN pbKlantContact.net-tel     = poBody:GetCharacter('netTel':u).
        IF poBody:Has('tel':u)         THEN pbKlantContact.tel         = poBody:GetCharacter('tel':u).
        IF poBody:Has('gsm':u)         THEN pbKlantContact.gsm         = poBody:GetCharacter('gsm':u).
        IF poBody:Has('email':u)       THEN pbKlantContact.email       = poBody:GetCharacter('email':u).
        IF poBody:Has('opm':u)         THEN pbKlantContact.opm         = poBody:GetCharacter('opm':u).
        IF poBody:Has('soort':u)       THEN pbKlantContact.soort       = poBody:GetCharacter('soort':u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies `standaard` from the JSON body (if present) onto
                 the given `klant-contact` buffer, and - only when it's
                 being set to TRUE - clears `standaard` on every OTHER
                 klant-contact row for the same klnr in the same
                 transaction. Uses a separate named buffer (bOther) for that
                 sweep so it never collides with pbKlantContact, which may
                 itself be an alias of the default klant-contact buffer
                 (e.g. when called from Create/UpdateKlantContact).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyStandaard( INPUT poBody AS JsonObject, BUFFER pbKlantContact FOR klant-contact ):

        DEFINE BUFFER bOther FOR klant-contact.
        DEFINE VARIABLE lStandaard AS LOGICAL NO-UNDO.

        IF NOT poBody:Has('standaard':u) THEN RETURN.

        lStandaard = poBody:GetLogical('standaard':u).
        pbKlantContact.standaard = lStandaard.

        IF lStandaard THEN
        DO:
            FOR EACH bOther EXCLUSIVE-LOCK
                WHERE bOther.klnr EQ pbKlantContact.klnr
                  AND bOther.lijnnr NE pbKlantContact.lijnnr
                  AND bOther.standaard EQ TRUE:
                bOther.standaard = FALSE.
            END.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every klant-contact row for the given klnr,
                 ordered by lijnnr.
        Notes  : NO-LOCK read-only.
        Errors : AppError code 404 - the parent klnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlantContacten( INPUT piKlnr AS INTEGER ):

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantContact.

        FOR EACH klant-contact NO-LOCK WHERE klant-contact.klnr EQ piKlnr BY klant-contact.lijnnr:
            CREATE ttKlantContact.
            CopyToTt( BUFFER klant-contact, BUFFER ttKlantContact ).
        END.

        RETURN TEMP-TABLE ttKlantContact:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single klant-contact row by klnr+lijnnr, or an
                 empty ttKlantContact if it doesn't exist (the WebHandler
                 turns that into a 404).
        Errors : AppError code 404 - the parent klnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlantContact( INPUT piKlnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantContact.

        FIND FIRST klant-contact NO-LOCK
            WHERE klant-contact.klnr EQ piKlnr
              AND klant-contact.lijnnr EQ piLijnnr NO-ERROR.

        IF AVAILABLE klant-contact THEN
        DO:
            CREATE ttKlantContact.
            CopyToTt( BUFFER klant-contact, BUFFER ttKlantContact ).
        END.

        RETURN TEMP-TABLE ttKlantContact:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new klant-contact row under the given klnr.
                 - If `lijnnr` is omitted from the body: auto-allocated as
                   MAX(lijnnr for this klnr, default 0) + 10.
                 - If `lijnnr` is provided: must be a positive integer and
                   must not already exist for that klnr.
        Errors : AppError code 404 - the parent klnr doesn't exist.
                 AppError code 400 - naam missing or blank; or lijnnr
                 invalid (explicit mode).
                 AppError code 409 - (explicit mode) lijnnr already exists
                 for this klnr.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateKlantContact( INPUT piKlnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iLijnnr    AS INTEGER NO-UNDO.
        DEFINE VARIABLE lHasLijnnr AS LOGICAL NO-UNDO.

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantContact.

        IF NOT poBody:Has('naam':u) OR poBody:GetCharacter('naam':u) EQ '':u THEN
            UNDO, THROW NEW Progress.Lang.AppError('naam is required':u, 400).

        lHasLijnnr = poBody:Has('lijnnr':u).

        IF lHasLijnnr THEN
        DO:
            iLijnnr = poBody:GetInteger('lijnnr':u) NO-ERROR.
            IF iLijnnr EQ ? OR iLijnnr LE 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError('lijnnr must be a positive integer':u, 400).
        END.

        DO TRANSACTION:
            IF lHasLijnnr THEN
            DO:
                FIND FIRST klant-contact EXCLUSIVE-LOCK
                    WHERE klant-contact.klnr EQ piKlnr
                      AND klant-contact.lijnnr EQ iLijnnr NO-ERROR.
                IF AVAILABLE klant-contact THEN
                    UNDO, THROW NEW Progress.Lang.AppError(
                        SUBSTITUTE('Contact &1/&2 already exists':u, piKlnr, iLijnnr), 409).
            END.
            ELSE
            DO:
                FIND LAST klant-contact EXCLUSIVE-LOCK
                    WHERE klant-contact.klnr EQ piKlnr NO-ERROR.

                iLijnnr = (IF AVAILABLE klant-contact THEN klant-contact.lijnnr ELSE 0) + 10.
            END.

            CREATE klant-contact.
            ASSIGN
                klant-contact.klnr   = piKlnr
                klant-contact.lijnnr = iLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER klant-contact ).
            ApplyStandaard( INPUT poBody, BUFFER klant-contact ).

            CREATE ttKlantContact.
            CopyToTt( BUFFER klant-contact, BUFFER ttKlantContact ).
        END.

        RETURN TEMP-TABLE ttKlantContact:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing klant-contact row. Only fields present
                 in the JSON body are changed (partial update);
                 `klnr`/`lijnnr` are immutable.
        Errors : AppError code 404 - the parent klnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateKlantContact(
        INPUT piKlnr   AS INTEGER,
        INPUT piLijnnr AS INTEGER,
        INPUT poBody   AS JsonObject ):

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantContact.

        DO TRANSACTION:
            FIND FIRST klant-contact EXCLUSIVE-LOCK
                WHERE klant-contact.klnr EQ piKlnr
                  AND klant-contact.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE klant-contact THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Contact &1/&2 not found':u, piKlnr, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER klant-contact ).
            ApplyStandaard( INPUT poBody, BUFFER klant-contact ).

            CREATE ttKlantContact.
            CopyToTt( BUFFER klant-contact, BUFFER ttKlantContact ).
        END.

        RETURN TEMP-TABLE ttKlantContact:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a klant-contact row by klnr+lijnnr. Does NOT auto-
                 promote another row to standaard if the deleted row was the
                 standaard one - zero standaard rows is an accepted state.
        Errors : AppError code 404 - the parent klnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteKlantContact( INPUT piKlnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureKlantExists( piKlnr ).

        DO TRANSACTION:
            FIND FIRST klant-contact EXCLUSIVE-LOCK
                WHERE klant-contact.klnr EQ piKlnr
                  AND klant-contact.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE klant-contact THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Contact &1/&2 not found':u, piKlnr, piLijnnr), 404).

            DELETE klant-contact.
        END.

    END METHOD.

END CLASS.
