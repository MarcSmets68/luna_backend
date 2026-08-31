/*------------------------------------------------------------------------
    File        : LeverancierBE.cls
    Purpose     : Business Entity for the "lever" (supplier master) table -
                  owns full CRUD access for a curated core subset of fields
                  (identification, contact, address, financial, status).
                  The `lever` table has more fields in total; only the
                  commonly-used subset below is exposed via the API for now.
    Field map (JSON key -> lever column):
                  levnr            -> levnr             (PK, immutable)
                  naam             -> naam
                  naam1            -> naam1
                  contact          -> contact
                  adres            -> adres
                  postnr           -> postnr
                  stad             -> stad
                  land             -> land
                  tel              -> tel
                  fax              -> fax
                  email            -> email
                  taal             -> taal
                  munt             -> munt
                  btwNr            -> btw-nr
                  saldo            -> saldo
                  opm              -> opm
                  tekst            -> tekst
                  type             -> type
                  controle         -> controle
                  minBestel        -> min-bestel
                  btwRegime        -> btw-reg
                  levnrOld         -> levnr-old      (read-only)
                  netTel           -> net-tel        (read-only)
                  netFax           -> net-fax        (read-only)
                  btermijn         -> btermijn       (read-only)
                  transport        -> transport      (read-only)
                  condities        -> condities      (read-only)
                  omzhuibj         -> omzhuibj       (read-only)
                  omzvobj          -> omzvobj        (read-only)
                  besteld          -> besteld        (read-only)
                  klassementmap    -> klassementmap  (read-only)
                  dagenLever       -> dagen_lever    (read-only)
                  banknr           -> banknr         (read-only)
                  bicnr            -> bicnr          (read-only)
                  controleBank     -> controle-bank  (read-only)
                  (read-only fields above are exposed for GET/list/create/update
                  responses only - ApplyFields intentionally does not support
                  writing them yet, see LeverancierHandler design notes)
    Syntax      : Called from Luna.Web.LeverancierHandler (GET/POST/PUT/DELETE
                  /web/leverancier and /web/leverancier/{levnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes.
    Author(s)   : Devin
    Created     : 2026-08-10
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LeverancierBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttLeverancier NO-UNDO SERIALIZE-NAME "items":u
        FIELD levnr     AS INTEGER   SERIALIZE-NAME "levnr":u
        FIELD naam      AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD naam1     AS CHARACTER SERIALIZE-NAME "naam1":u
        FIELD contact   AS CHARACTER SERIALIZE-NAME "contact":u
        FIELD adres     AS CHARACTER SERIALIZE-NAME "adres":u
        FIELD postnr    AS CHARACTER SERIALIZE-NAME "postnr":u
        FIELD stad      AS CHARACTER SERIALIZE-NAME "stad":u
        FIELD land      AS CHARACTER SERIALIZE-NAME "land":u
        FIELD tel       AS CHARACTER SERIALIZE-NAME "tel":u
        FIELD fax       AS CHARACTER SERIALIZE-NAME "fax":u
        FIELD email     AS CHARACTER SERIALIZE-NAME "email":u
        FIELD taal      AS CHARACTER SERIALIZE-NAME "taal":u
        FIELD munt      AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD btwNr     AS CHARACTER SERIALIZE-NAME "btwNr":u
        FIELD saldo     AS DECIMAL   SERIALIZE-NAME "saldo":u
        FIELD opm       AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD tekst     AS CHARACTER SERIALIZE-NAME "tekst":u
        FIELD type      AS LOGICAL   SERIALIZE-NAME "type":u
        FIELD controle  AS LOGICAL   SERIALIZE-NAME "controle":u
        FIELD minBestel AS DECIMAL   SERIALIZE-NAME "minBestel":u
        FIELD btwRegime AS INTEGER  SERIALIZE-NAME "btwRegime":u
        FIELD levnrOld      AS CHARACTER SERIALIZE-NAME "levnrOld":u
        FIELD netTel        AS CHARACTER SERIALIZE-NAME "netTel":u
        FIELD netFax        AS CHARACTER SERIALIZE-NAME "netFax":u
        FIELD btermijn      AS CHARACTER SERIALIZE-NAME "btermijn":u
        FIELD transport     AS CHARACTER SERIALIZE-NAME "transport":u
        FIELD condities     AS CHARACTER SERIALIZE-NAME "condities":u
        FIELD omzhuibj      AS DECIMAL   SERIALIZE-NAME "omzhuibj":u
        FIELD omzvobj       AS DECIMAL   SERIALIZE-NAME "omzvobj":u
        FIELD besteld       AS DECIMAL   SERIALIZE-NAME "besteld":u
        FIELD klassementmap AS CHARACTER SERIALIZE-NAME "klassementmap":u
        FIELD dagenLever    AS INTEGER   SERIALIZE-NAME "dagenLever":u
        FIELD banknr        AS CHARACTER SERIALIZE-NAME "banknr":u
        FIELD bicnr         AS CHARACTER SERIALIZE-NAME "bicnr":u
        FIELD controleBank  AS DATE      SERIALIZE-NAME "controleBank":u
        INDEX idx-levnr IS PRIMARY levnr.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from a `lever` buffer into a
                 ttLeverancier row, for use by every read/write method below.
        Notes  : Kept private - callers always go through GetLeverancier(en)/
                 Create/Update so this mapping stays in one place.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbLever FOR lever, BUFFER pbTt FOR ttLeverancier ):

        ASSIGN
            pbTt.levnr     = pbLever.levnr
            pbTt.naam      = pbLever.naam
            pbTt.naam1     = pbLever.naam1
            pbTt.contact   = pbLever.contact
            pbTt.adres     = pbLever.adres
            pbTt.postnr    = pbLever.postnr
            pbTt.stad      = pbLever.stad
            pbTt.land      = pbLever.land
            pbTt.tel       = pbLever.tel
            pbTt.fax       = pbLever.fax
            pbTt.email     = pbLever.email
            pbTt.taal      = pbLever.taal
            pbTt.munt      = pbLever.munt
            pbTt.btwNr     = pbLever.btw-nr
            pbTt.saldo     = pbLever.saldo
            pbTt.opm       = pbLever.opm
            pbTt.tekst     = pbLever.tekst
            pbTt.type      = pbLever.type
            pbTt.controle  = pbLever.controle
            pbTt.minBestel = pbLever.min-bestel
            pbTt.btwRegime = pbLever.btw-reg
            pbTt.levnrOld      = pbLever.levnr-old
            pbTt.netTel        = pbLever.net-tel
            pbTt.netFax        = pbLever.net-fax
            pbTt.btermijn      = pbLever.btermijn
            pbTt.transport     = pbLever.transport
            pbTt.condities     = pbLever.condities
            pbTt.omzhuibj      = pbLever.omzhuibj
            pbTt.omzvobj       = pbLever.omzvobj
            pbTt.besteld       = pbLever.besteld
            pbTt.klassementmap = pbLever.klassementmap
            pbTt.dagenLever    = pbLever.dagen_lever
            pbTt.banknr        = pbLever.banknr
            pbTt.bicnr         = pbLever.bicnr
            pbTt.controleBank  = pbLever.controle-bank
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto the
                 given `lever` buffer. Fields absent from the body are left
                 untouched, so this also works for partial updates. `levnr` is
                 never touched here - it is set once on create and is immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbLever FOR lever ):

        IF poBody:Has("naam":u)      THEN pbLever.naam       = poBody:GetCharacter("naam":u).
        IF poBody:Has("naam1":u)     THEN pbLever.naam1      = poBody:GetCharacter("naam1":u).
        IF poBody:Has("contact":u)   THEN pbLever.contact    = poBody:GetCharacter("contact":u).
        IF poBody:Has("adres":u)     THEN pbLever.adres      = poBody:GetCharacter("adres":u).
        IF poBody:Has("postnr":u)    THEN pbLever.postnr     = poBody:GetCharacter("postnr":u).
        IF poBody:Has("stad":u)      THEN pbLever.stad       = poBody:GetCharacter("stad":u).
        IF poBody:Has("land":u)      THEN pbLever.land       = poBody:GetCharacter("land":u).
        IF poBody:Has("tel":u)       THEN pbLever.tel        = poBody:GetCharacter("tel":u).
        IF poBody:Has("fax":u)       THEN pbLever.fax        = poBody:GetCharacter("fax":u).
        IF poBody:Has("email":u)     THEN pbLever.email      = poBody:GetCharacter("email":u).
        IF poBody:Has("taal":u)      THEN pbLever.taal       = poBody:GetCharacter("taal":u).
        IF poBody:Has("munt":u)      THEN pbLever.munt       = poBody:GetCharacter("munt":u).
        IF poBody:Has("btwNr":u)     THEN pbLever.btw-nr     = poBody:GetCharacter("btwNr":u).
        IF poBody:Has("saldo":u)     THEN pbLever.saldo      = poBody:GetDecimal("saldo":u).
        IF poBody:Has("opm":u)       THEN pbLever.opm        = poBody:GetCharacter("opm":u).
        IF poBody:Has("tekst":u)     THEN pbLever.tekst      = poBody:GetCharacter("tekst":u).
        IF poBody:Has("type":u)      THEN pbLever.type       = poBody:GetLogical("type":u).
        IF poBody:Has("controle":u)  THEN pbLever.controle   = poBody:GetLogical("controle":u).
        IF poBody:Has("minBestel":u) THEN pbLever.min-bestel = poBody:GetDecimal("minBestel":u).
        IF poBody:Has("btwRegime":u) THEN pbLever.btw-reg    = poBody:GetInteger("btwRegime":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns TRUE if every whitespace-separated word in pcFilter
                 occurs (as a substring, case-insensitive, in any order)
                 somewhere across naam + naam1 combined - e.g. filter "Smets
                 Marc" matches naam "Smets" / naam1 "Marc" as well as naam
                 "Marc Smets", so searching on "achternaam voornaam" or
                 vice versa both work. An empty filter always matches.
        Notes  : Own private copy for this class - same algorithm as
                 Luna.BusinessLogic.KlantBE:MatchesNaamFilter().
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL MatchesNaamFilter(
        INPUT pcFilter AS CHARACTER,
        INPUT pcNaam   AS CHARACTER,
        INPUT pcNaam1  AS CHARACTER ):

        DEFINE VARIABLE cHaystack AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iWord     AS INTEGER   NO-UNDO.

        IF pcFilter EQ "":u THEN
            RETURN TRUE.

        cHaystack = UPPER(pcNaam) + " ":u + UPPER(pcNaam1).

        DO iWord = 1 TO NUM-ENTRIES(pcFilter, " ":u):
            IF ENTRY(iWord, pcFilter, " ":u) EQ "":u THEN NEXT.
            IF INDEX(cHaystack, ENTRY(iWord, pcFilter, " ":u)) EQ 0 THEN
                RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of lever rows, optionally filtered by naam
                 (every whitespace-separated word in the filter must occur,
                 case-insensitive, somewhere across naam + naam1 - see
                 MatchesNaamFilter() - so "Smets Marc" matches naam "Smets"
                 / naam1 "Marc" regardless of word order).
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already be
                 validated/clamped by the caller (page >= 1, 1 <= pageSize <= 200).
                 This deliberately does NOT compute an exact total count -
                 instead it stops scanning as soon as it has one extra row
                 beyond the requested page and reports that via plHasMore, same
                 approach as Luna.BusinessLogic.KlantBE:GetKlanten().
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetLeveranciers(
        INPUT  piPage     AS INTEGER,
        INPUT  piPageSize AS INTEGER,
        INPUT  pcNaam     AS CHARACTER,
        OUTPUT plHasMore  AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLeverancier.

        ASSIGN
            pcNaam    = UPPER(TRIM(pcNaam))
            iSkip     = (piPage - 1) * piPageSize
            iSeen     = 0
            iTaken    = 0
            plHasMore = FALSE
            .

        FOR EACH lever NO-LOCK BY lever.levnr:

            IF NOT MatchesNaamFilter(pcNaam, lever.naam, lever.naam1) THEN NEXT.

            iSeen = iSeen + 1.

            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLeverancier.
            CopyToTt( BUFFER lever, BUFFER ttLeverancier ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLeverancier:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single lever by levnr, or an empty ttLeverancier if
                 it doesn't exist (the WebHandler turns that into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetLeverancier( INPUT piLevnr AS INTEGER ):

        EMPTY TEMP-TABLE ttLeverancier.

        FIND FIRST lever NO-LOCK WHERE lever.levnr EQ piLevnr NO-ERROR.

        IF AVAILABLE lever THEN
        DO:
            CREATE ttLeverancier.
            CopyToTt( BUFFER lever, BUFFER ttLeverancier ).
        END.

        RETURN TEMP-TABLE ttLeverancier:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new lever. `levnr` is computed server-side as
                 (last levnr, via the lever-x1 index) + 1, held under the same
                 EXCLUSIVE-LOCK/transaction as the CREATE so there is no race
                 between the FIND LAST and the CREATE. `levnr` in the request
                 body (if any) is ignored - see ApplyFields.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateLeverancier( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iNewLevnr AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLeverancier.

        DO TRANSACTION:
            FIND LAST lever USE-INDEX lever-x1 EXCLUSIVE-LOCK NO-ERROR.

            iNewLevnr = (IF AVAILABLE lever THEN lever.levnr ELSE 0) + 1.

            CREATE lever.
            ASSIGN lever.levnr = iNewLevnr.

            ApplyFields( INPUT poBody, BUFFER lever ).

            CREATE ttLeverancier.
            CopyToTt( BUFFER lever, BUFFER ttLeverancier ).
        END.

        RETURN TEMP-TABLE ttLeverancier:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing lever. Only fields present in the JSON body
                 are changed (partial update); `levnr` itself is immutable.
        Errors : AppError code 404 - levnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateLeverancier( INPUT piLevnr AS INTEGER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLeverancier.

        DO TRANSACTION:
            FIND FIRST lever EXCLUSIVE-LOCK WHERE lever.levnr EQ piLevnr NO-ERROR.
            IF NOT AVAILABLE lever THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Leverancier &1 not found":u, piLevnr), 404).

            ApplyFields( INPUT poBody, BUFFER lever ).

            CREATE ttLeverancier.
            CopyToTt( BUFFER lever, BUFFER ttLeverancier ).
        END.

        RETURN TEMP-TABLE ttLeverancier:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a lever by levnr.
        Errors : AppError code 404 - levnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteLeverancier( INPUT piLevnr AS INTEGER ):

        DO TRANSACTION:
            FIND FIRST lever EXCLUSIVE-LOCK WHERE lever.levnr EQ piLevnr NO-ERROR.
            IF NOT AVAILABLE lever THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Leverancier &1 not found":u, piLevnr), 404).

            DELETE lever.
        END.

    END METHOD.

END CLASS.

