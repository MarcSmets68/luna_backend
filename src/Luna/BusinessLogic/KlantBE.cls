/*------------------------------------------------------------------------
    File        : KlantBE.cls
    Purpose     : Business Entity for the "klant" (customer master) table -
                  owns full CRUD access for a curated core subset of fields
                  (identification, contact, address, financial, status).
                  The `klant` table has ~50 fields in total; only the
                  commonly-used subset below is exposed via the API for now.
    Field map (JSON key -> klant column):
                  klnr             -> klnr              (PK, immutable)
                  naam             -> naam
                  naam1            -> naam1
                  contact          -> contact
                  adres            -> adres
                  postnr           -> postnr
                  stad             -> stad
                  land             -> land
                  tel              -> tel
                  fax              -> fax
                  gsm              -> gsm
                  email            -> email
                  taal             -> taal
                  munt             -> munt
                  btwNr            -> btw-nr
                  saldo            -> saldo
                  geblokkeerd      -> blokkeren
                  opm              -> opm
                  Plus a second "uitgebreid" (extended) scalar field tab -
                  see the ttKlantUitgebreid temp-table def below for its
                  ~38-field map - and three nested child resources owned by
                  their own Business Entities: Luna.BusinessLogic.KlantAdresBE
                  (klant-adr), Luna.BusinessLogic.KlantContactBE
                  (klant-contact) and Luna.BusinessLogic.KlantKortingBE
                  (korting).
    Syntax      : Called from Luna.Web.KlantHandler (GET/POST/PUT/DELETE
                  /web/klant and /web/klant/{klnr}, GET/PUT
                  /web/klant/{klnr}/uitgebreid)
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes.
    Author(s)   : Devin
    Created     : 2026-08-10
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.KlantBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttKlant NO-UNDO SERIALIZE-NAME "items":u
        FIELD klnr        AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam        AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD naam1       AS CHARACTER SERIALIZE-NAME "naam1":u
        FIELD contact     AS CHARACTER SERIALIZE-NAME "contact":u
        FIELD adres       AS CHARACTER SERIALIZE-NAME "adres":u
        FIELD postnr      AS CHARACTER SERIALIZE-NAME "postnr":u
        FIELD stad        AS CHARACTER SERIALIZE-NAME "stad":u
        FIELD land        AS CHARACTER SERIALIZE-NAME "land":u
        FIELD tel         AS CHARACTER SERIALIZE-NAME "tel":u
        FIELD fax         AS CHARACTER SERIALIZE-NAME "fax":u
        FIELD gsm         AS CHARACTER SERIALIZE-NAME "gsm":u
        FIELD email       AS CHARACTER SERIALIZE-NAME "email":u
        FIELD taal        AS CHARACTER SERIALIZE-NAME "taal":u
        FIELD munt        AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD btwNr       AS CHARACTER SERIALIZE-NAME "btwNr":u
        FIELD saldo       AS DECIMAL   SERIALIZE-NAME "saldo":u
        FIELD geblokkeerd AS LOGICAL   SERIALIZE-NAME "geblokkeerd":u
        FIELD opm         AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-klnr IS PRIMARY klnr.

    /* Result shape for the "uitgebreid" (extended) klant tab - a curated
       subset of the ~38 remaining klant fields not exposed via ttKlant
       above. Field map (JSON key -> klant column):
                  klnr                   -> klnr              (PK, immutable)
                  klnrOld                -> klnr-old
                  omzHuidigBoekjaar      -> omzhuibj
                  omzVorigBoekjaar       -> omzvobj
                  btwRegime              -> btw-reg
                  betalingstermijn       -> btermijn
                  tekst                  -> tekst
                  besteld                -> besteld
                  vertegenwoordiger      -> vrtgw
                  aktiviteit             -> aktiviteit
                  soort                  -> soort
                  soort2                 -> soort2
                  korting                -> korting
                  kortKontant            -> kort-kont
                  prijsAfdrukken         -> prijs
                  gsm2                   -> gsm2
                  factuurAutomatisch     -> factuur
                  netTel                 -> net-tel
                  netFax                 -> net-fax
                  faxenOrderbev          -> faxen
                  alfaCode               -> alfa-code
                  email2                 -> email2
                  boekhouding            -> boekhouding
                  toBoekhouding          -> to-boekhouding
                  reknr                  -> reknr
                  offOmschrijving        -> off_omschr
                  offNummer              -> off_nummer
                  referentieAfdrukken    -> referentie
                  klassementmap          -> klassementmap
                  emailGebruiken         -> swMail
                  aanmaning              -> aanmaning
                  opvolging              -> opvolging
                  aanspreking            -> aanspreking
                  proformaZonderTotalen  -> swTotaal
                  pakketVersturen        -> swVersturen
                  nomaledKlant           -> swNomaled
                  kode                   -> kode
                  altijdFranco           -> swFranco
                  magazijn               -> magazijn
                  logo                   -> logo
                  portalnaam             -> portalnaam
       Every field is always included in the response, even when blank/0/
       false - there is no conditional omission (this tab exists precisely
       to show the "empty" fields too). */
    DEFINE TEMP-TABLE ttKlantUitgebreid NO-UNDO SERIALIZE-NAME "items":u
        FIELD klnr                  AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD klnrOld                AS CHARACTER SERIALIZE-NAME "klnrOld":u
        FIELD omzHuidigBoekjaar      AS DECIMAL   SERIALIZE-NAME "omzHuidigBoekjaar":u
        FIELD omzVorigBoekjaar       AS DECIMAL   SERIALIZE-NAME "omzVorigBoekjaar":u
        FIELD btwRegime              AS INTEGER   SERIALIZE-NAME "btwRegime":u
        FIELD betalingstermijn       AS CHARACTER SERIALIZE-NAME "betalingstermijn":u
        FIELD tekst                  AS CHARACTER SERIALIZE-NAME "tekst":u
        FIELD besteld                AS DECIMAL   SERIALIZE-NAME "besteld":u
        FIELD vertegenwoordiger      AS CHARACTER SERIALIZE-NAME "vertegenwoordiger":u
        FIELD aktiviteit             AS CHARACTER SERIALIZE-NAME "aktiviteit":u
        FIELD soort                  AS CHARACTER SERIALIZE-NAME "soort":u
        FIELD soort2                 AS CHARACTER SERIALIZE-NAME "soort2":u
        FIELD korting                AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD kortKontant            AS DECIMAL   SERIALIZE-NAME "kortKontant":u
        FIELD prijsAfdrukken         AS LOGICAL   SERIALIZE-NAME "prijsAfdrukken":u
        FIELD gsm2                   AS CHARACTER SERIALIZE-NAME "gsm2":u
        FIELD factuurAutomatisch     AS LOGICAL   SERIALIZE-NAME "factuurAutomatisch":u
        FIELD netTel                 AS CHARACTER SERIALIZE-NAME "netTel":u
        FIELD netFax                 AS CHARACTER SERIALIZE-NAME "netFax":u
        FIELD faxenOrderbev          AS LOGICAL   SERIALIZE-NAME "faxenOrderbev":u
        FIELD alfaCode               AS CHARACTER SERIALIZE-NAME "alfaCode":u
        FIELD email2                 AS CHARACTER SERIALIZE-NAME "email2":u
        FIELD boekhouding            AS LOGICAL   SERIALIZE-NAME "boekhouding":u
        FIELD toBoekhouding          AS LOGICAL   SERIALIZE-NAME "toBoekhouding":u
        FIELD reknr                  AS INTEGER   SERIALIZE-NAME "reknr":u
        FIELD offOmschrijving        AS CHARACTER SERIALIZE-NAME "offOmschrijving":u
        FIELD offNummer              AS CHARACTER SERIALIZE-NAME "offNummer":u
        FIELD referentieAfdrukken    AS LOGICAL   SERIALIZE-NAME "referentieAfdrukken":u
        FIELD klassementmap          AS CHARACTER SERIALIZE-NAME "klassementmap":u
        FIELD emailGebruiken         AS LOGICAL   SERIALIZE-NAME "emailGebruiken":u
        FIELD aanmaning              AS CHARACTER SERIALIZE-NAME "aanmaning":u
        FIELD opvolging              AS LOGICAL   SERIALIZE-NAME "opvolging":u
        FIELD aanspreking            AS CHARACTER SERIALIZE-NAME "aanspreking":u
        FIELD proformaZonderTotalen  AS LOGICAL   SERIALIZE-NAME "proformaZonderTotalen":u
        FIELD pakketVersturen        AS LOGICAL   SERIALIZE-NAME "pakketVersturen":u
        FIELD nomaledKlant           AS LOGICAL   SERIALIZE-NAME "nomaledKlant":u
        FIELD kode                   AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD altijdFranco           AS LOGICAL   SERIALIZE-NAME "altijdFranco":u
        FIELD magazijn               AS CHARACTER SERIALIZE-NAME "magazijn":u
        FIELD logo                   AS CHARACTER SERIALIZE-NAME "logo":u
        FIELD portalnaam             AS CHARACTER SERIALIZE-NAME "portalnaam":u
        INDEX idx-klnr IS PRIMARY klnr.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from a `klant` buffer into a
                 ttKlant row, for use by every read/write method below.
        Notes  : Kept private - callers always go through GetKlant(en)/Create/
                 Update so this mapping stays in one place.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbKlant FOR klant, BUFFER pbTt FOR ttKlant ):

        ASSIGN
            pbTt.klnr        = pbKlant.klnr
            pbTt.naam        = pbKlant.naam
            pbTt.naam1       = pbKlant.naam1
            pbTt.contact     = pbKlant.contact
            pbTt.adres       = pbKlant.adres
            pbTt.postnr      = pbKlant.postnr
            pbTt.stad        = pbKlant.stad
            pbTt.land        = pbKlant.land
            pbTt.tel         = pbKlant.tel
            pbTt.fax         = pbKlant.fax
            pbTt.gsm         = pbKlant.gsm
            pbTt.email       = pbKlant.email
            pbTt.taal        = pbKlant.taal
            pbTt.munt        = pbKlant.munt
            pbTt.btwNr       = pbKlant.btw-nr
            pbTt.saldo       = pbKlant.saldo
            pbTt.geblokkeerd = pbKlant.blokkeren
            pbTt.opm         = pbKlant.opm
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto the
                 given `klant` buffer. Fields absent from the body are left
                 untouched, so this also works for partial updates. `klnr` is
                 never touched here - it is set once on create and is immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbKlant FOR klant ):

        IF poBody:Has("naam":u)        THEN pbKlant.naam      = poBody:GetCharacter("naam":u).
        IF poBody:Has("naam1":u)       THEN pbKlant.naam1     = poBody:GetCharacter("naam1":u).
        IF poBody:Has("contact":u)     THEN pbKlant.contact   = poBody:GetCharacter("contact":u).
        IF poBody:Has("adres":u)       THEN pbKlant.adres     = poBody:GetCharacter("adres":u).
        IF poBody:Has("postnr":u)      THEN pbKlant.postnr    = poBody:GetCharacter("postnr":u).
        IF poBody:Has("stad":u)        THEN pbKlant.stad      = poBody:GetCharacter("stad":u).
        IF poBody:Has("land":u)        THEN pbKlant.land      = poBody:GetCharacter("land":u).
        IF poBody:Has("tel":u)         THEN pbKlant.tel       = poBody:GetCharacter("tel":u).
        IF poBody:Has("fax":u)         THEN pbKlant.fax       = poBody:GetCharacter("fax":u).
        IF poBody:Has("gsm":u)         THEN pbKlant.gsm       = poBody:GetCharacter("gsm":u).
        IF poBody:Has("email":u)       THEN pbKlant.email     = poBody:GetCharacter("email":u).
        IF poBody:Has("taal":u)        THEN pbKlant.taal      = poBody:GetCharacter("taal":u).
        IF poBody:Has("munt":u)        THEN pbKlant.munt      = poBody:GetCharacter("munt":u).
        IF poBody:Has("btwNr":u)       THEN pbKlant.btw-nr    = poBody:GetCharacter("btwNr":u).
        IF poBody:Has("saldo":u)       THEN pbKlant.saldo     = poBody:GetDecimal("saldo":u).
        IF poBody:Has("geblokkeerd":u) THEN pbKlant.blokkeren = poBody:GetLogical("geblokkeerd":u).
        IF poBody:Has("opm":u)         THEN pbKlant.opm       = poBody:GetCharacter("opm":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the extended subset of fields from a `klant` buffer
                 into a ttKlantUitgebreid row. Every field is copied
                 unconditionally (including blank/0/false) - the whole point
                 of this tab is to also surface the "empty" fields.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTtUitgebreid( BUFFER pbKlant FOR klant, BUFFER pbTt FOR ttKlantUitgebreid ):

        ASSIGN
            pbTt.klnr                  = pbKlant.klnr
            pbTt.klnrOld               = pbKlant.klnr-old
            pbTt.omzHuidigBoekjaar     = pbKlant.omzhuibj
            pbTt.omzVorigBoekjaar      = pbKlant.omzvobj
            pbTt.btwRegime             = pbKlant.btw-reg
            pbTt.betalingstermijn      = pbKlant.btermijn
            pbTt.tekst                 = pbKlant.tekst
            pbTt.besteld               = pbKlant.besteld
            pbTt.vertegenwoordiger     = pbKlant.vrtgw
            pbTt.aktiviteit            = pbKlant.aktiviteit
            pbTt.soort                 = pbKlant.soort
            pbTt.soort2                = pbKlant.soort2
            pbTt.korting               = pbKlant.korting
            pbTt.kortKontant           = pbKlant.kort-kont
            pbTt.prijsAfdrukken        = pbKlant.prijs
            pbTt.gsm2                  = pbKlant.gsm2
            pbTt.factuurAutomatisch    = pbKlant.factuur
            pbTt.netTel                = pbKlant.net-tel
            pbTt.netFax                = pbKlant.net-fax
            pbTt.faxenOrderbev         = pbKlant.faxen
            pbTt.alfaCode              = pbKlant.alfa-code
            pbTt.email2                = pbKlant.email2
            pbTt.boekhouding           = pbKlant.boekhouding
            pbTt.toBoekhouding         = pbKlant.to-boekhouding
            pbTt.reknr                 = pbKlant.reknr
            pbTt.offOmschrijving       = pbKlant.off_omschr
            pbTt.offNummer             = pbKlant.off_nummer
            pbTt.referentieAfdrukken   = pbKlant.referentie
            pbTt.klassementmap         = pbKlant.klassementmap
            pbTt.emailGebruiken        = pbKlant.swMail
            pbTt.aanmaning             = pbKlant.aanmaning
            pbTt.opvolging             = pbKlant.opvolging
            pbTt.aanspreking           = pbKlant.aanspreking
            pbTt.proformaZonderTotalen = pbKlant.swTotaal
            pbTt.pakketVersturen       = pbKlant.swVersturen
            pbTt.nomaledKlant          = pbKlant.swNomaled
            pbTt.kode                  = pbKlant.kode
            pbTt.altijdFranco          = pbKlant.swFranco
            pbTt.magazijn              = pbKlant.magazijn
            pbTt.logo                  = pbKlant.logo
            pbTt.portalnaam            = pbKlant.portalnaam
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every extended field present in the JSON request
                 body onto the given `klant` buffer. Fields absent from the
                 body are left untouched (partial update). `klnr` is never
                 touched here - it is immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyUitgebreidFields( INPUT poBody AS JsonObject, BUFFER pbKlant FOR klant ):

        IF poBody:Has("klnrOld":u)               THEN pbKlant.klnr-old      = poBody:GetCharacter("klnrOld":u).
        IF poBody:Has("omzHuidigBoekjaar":u)      THEN pbKlant.omzhuibj     = poBody:GetDecimal("omzHuidigBoekjaar":u).
        IF poBody:Has("omzVorigBoekjaar":u)       THEN pbKlant.omzvobj      = poBody:GetDecimal("omzVorigBoekjaar":u).
        IF poBody:Has("btwRegime":u)              THEN pbKlant.btw-reg      = poBody:GetInteger("btwRegime":u).
        IF poBody:Has("betalingstermijn":u)       THEN pbKlant.btermijn     = poBody:GetCharacter("betalingstermijn":u).
        IF poBody:Has("tekst":u)                  THEN pbKlant.tekst        = poBody:GetCharacter("tekst":u).
        IF poBody:Has("besteld":u)                THEN pbKlant.besteld      = poBody:GetDecimal("besteld":u).
        IF poBody:Has("vertegenwoordiger":u)      THEN pbKlant.vrtgw        = poBody:GetCharacter("vertegenwoordiger":u).
        IF poBody:Has("aktiviteit":u)              THEN pbKlant.aktiviteit   = poBody:GetCharacter("aktiviteit":u).
        IF poBody:Has("soort":u)                  THEN pbKlant.soort        = poBody:GetCharacter("soort":u).
        IF poBody:Has("soort2":u)                 THEN pbKlant.soort2       = poBody:GetCharacter("soort2":u).
        IF poBody:Has("korting":u)                THEN pbKlant.korting      = poBody:GetDecimal("korting":u).
        IF poBody:Has("kortKontant":u)             THEN pbKlant.kort-kont    = poBody:GetDecimal("kortKontant":u).
        IF poBody:Has("prijsAfdrukken":u)          THEN pbKlant.prijs        = poBody:GetLogical("prijsAfdrukken":u).
        IF poBody:Has("gsm2":u)                    THEN pbKlant.gsm2         = poBody:GetCharacter("gsm2":u).
        IF poBody:Has("factuurAutomatisch":u)      THEN pbKlant.factuur      = poBody:GetLogical("factuurAutomatisch":u).
        IF poBody:Has("netTel":u)                  THEN pbKlant.net-tel      = poBody:GetCharacter("netTel":u).
        IF poBody:Has("netFax":u)                  THEN pbKlant.net-fax      = poBody:GetCharacter("netFax":u).
        IF poBody:Has("faxenOrderbev":u)           THEN pbKlant.faxen        = poBody:GetLogical("faxenOrderbev":u).
        IF poBody:Has("alfaCode":u)                THEN pbKlant.alfa-code    = poBody:GetCharacter("alfaCode":u).
        IF poBody:Has("email2":u)                  THEN pbKlant.email2       = poBody:GetCharacter("email2":u).
        IF poBody:Has("boekhouding":u)              THEN pbKlant.boekhouding  = poBody:GetLogical("boekhouding":u).
        IF poBody:Has("toBoekhouding":u)            THEN pbKlant.to-boekhouding = poBody:GetLogical("toBoekhouding":u).
        IF poBody:Has("reknr":u)                    THEN pbKlant.reknr        = poBody:GetInteger("reknr":u).
        IF poBody:Has("offOmschrijving":u)          THEN pbKlant.off_omschr   = poBody:GetCharacter("offOmschrijving":u).
        IF poBody:Has("offNummer":u)                THEN pbKlant.off_nummer   = poBody:GetCharacter("offNummer":u).
        IF poBody:Has("referentieAfdrukken":u)      THEN pbKlant.referentie   = poBody:GetLogical("referentieAfdrukken":u).
        IF poBody:Has("klassementmap":u)            THEN pbKlant.klassementmap = poBody:GetCharacter("klassementmap":u).
        IF poBody:Has("emailGebruiken":u)           THEN pbKlant.swMail       = poBody:GetLogical("emailGebruiken":u).
        IF poBody:Has("aanmaning":u)                THEN pbKlant.aanmaning    = poBody:GetCharacter("aanmaning":u).
        IF poBody:Has("opvolging":u)                THEN pbKlant.opvolging    = poBody:GetLogical("opvolging":u).
        IF poBody:Has("aanspreking":u)              THEN pbKlant.aanspreking  = poBody:GetCharacter("aanspreking":u).
        IF poBody:Has("proformaZonderTotalen":u)    THEN pbKlant.swTotaal     = poBody:GetLogical("proformaZonderTotalen":u).
        IF poBody:Has("pakketVersturen":u)          THEN pbKlant.swVersturen  = poBody:GetLogical("pakketVersturen":u).
        IF poBody:Has("nomaledKlant":u)             THEN pbKlant.swNomaled    = poBody:GetLogical("nomaledKlant":u).
        IF poBody:Has("kode":u)                     THEN pbKlant.kode         = poBody:GetCharacter("kode":u).
        IF poBody:Has("altijdFranco":u)             THEN pbKlant.swFranco     = poBody:GetLogical("altijdFranco":u).
        IF poBody:Has("magazijn":u)                 THEN pbKlant.magazijn     = poBody:GetCharacter("magazijn":u).
        IF poBody:Has("logo":u)                     THEN pbKlant.logo         = poBody:GetCharacter("logo":u).
        IF poBody:Has("portalnaam":u)               THEN pbKlant.portalnaam   = poBody:GetCharacter("portalnaam":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns TRUE if every whitespace-separated word in pcFilter
                 occurs (as a substring, case-insensitive, in any order)
                 somewhere across naam + naam1 combined - e.g. filter "Smets
                 Marc" matches naam "Smets" / naam1 "Marc" as well as naam
                 "Marc Smets", so searching on "achternaam voornaam" or
                 vice versa both work. An empty filter always matches.
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
        Purpose: Returns a page of klant rows, optionally filtered by naam
                 (every whitespace-separated word in the filter must occur,
                 case-insensitive, somewhere across naam + naam1 - see
                 MatchesNaamFilter() - so "Smets Marc" matches naam "Smets"
                 / naam1 "Marc" regardless of word order).
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already be
                 validated/clamped by the caller (page >= 1, 1 <= pageSize <= 200).
                 This deliberately does NOT compute an exact total count -
                 instead it stops scanning as soon as it has one extra row
                 beyond the requested page and reports that via plHasMore, same
                 approach as Luna.BusinessLogic.ArtikelBE:GetArtikelen(). A
                 naam filter scans every klant row (no index on naam) - same
                 tradeoff as Luna.BusinessLogic.FactuurBE:GetFacturen().
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlanten(
        INPUT  piPage     AS INTEGER,
        INPUT  piPageSize AS INTEGER,
        INPUT  pcNaam     AS CHARACTER,
        OUTPUT plHasMore  AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttKlant.

        ASSIGN
            pcNaam    = UPPER(TRIM(pcNaam))
            iSkip     = (piPage - 1) * piPageSize
            iSeen     = 0
            iTaken    = 0
            plHasMore = FALSE
            .

        FOR EACH klant NO-LOCK BY klant.klnr:

            IF NOT MatchesNaamFilter(pcNaam, klant.naam, klant.naam1) THEN NEXT.

            iSeen = iSeen + 1.

            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttKlant.
            CopyToTt( BUFFER klant, BUFFER ttKlant ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttKlant:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single klant by klnr, or an empty ttKlant if it
                 doesn't exist (the WebHandler turns that into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlant( INPUT piKlnr AS INTEGER ):

        EMPTY TEMP-TABLE ttKlant.

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.

        IF AVAILABLE klant THEN
        DO:
            CREATE ttKlant.
            CopyToTt( BUFFER klant, BUFFER ttKlant ).
        END.

        RETURN TEMP-TABLE ttKlant:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new klant. `klnr` is required in the body and must
                 not already exist.
        Errors : AppError code 400 - klnr missing/invalid.
                 AppError code 409 - klnr already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateKlant( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iKlnr AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttKlant.

        IF NOT poBody:Has("klnr":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("klnr is required":u, 400).

        iKlnr = poBody:GetInteger("klnr":u) NO-ERROR.
        IF iKlnr EQ ? OR iKlnr LE 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("klnr must be a positive integer":u, 400).

        DO TRANSACTION:
            FIND FIRST klant EXCLUSIVE-LOCK WHERE klant.klnr EQ iKlnr NO-ERROR.
            IF AVAILABLE klant THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Klant &1 already exists":u, iKlnr), 409).

            CREATE klant.
            ASSIGN klant.klnr = iKlnr.

            ApplyFields( INPUT poBody, BUFFER klant ).

            CREATE ttKlant.
            CopyToTt( BUFFER klant, BUFFER ttKlant ).
        END.

        RETURN TEMP-TABLE ttKlant:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing klant. Only fields present in the JSON body
                 are changed (partial update); `klnr` itself is immutable.
        Errors : AppError code 404 - klnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateKlant( INPUT piKlnr AS INTEGER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttKlant.

        DO TRANSACTION:
            FIND FIRST klant EXCLUSIVE-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.
            IF NOT AVAILABLE klant THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Klant &1 not found":u, piKlnr), 404).

            ApplyFields( INPUT poBody, BUFFER klant ).

            CREATE ttKlant.
            CopyToTt( BUFFER klant, BUFFER ttKlant ).
        END.

        RETURN TEMP-TABLE ttKlant:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a klant by klnr, cascading to every child row that
                 would otherwise be left orphaned (unreachable, since each
                 child Business Entity's EnsureKlantExists would 404 forever
                 afterwards): all klant-adr rows, all klant-contact rows and
                 all korting rows for this klnr (both swGroep = FALSE and
                 swGroep = TRUE - this feature only exposes swGroep = FALSE
                 rows, but leaving swGroep = TRUE rows orphaned would be
                 equally wrong). Done directly here (same pattern as
                 Luna.BusinessLogic.OfferteBE.DeleteOfferte cascading to
                 offlijn) rather than delegating to the child Business
                 Entities, since their public Delete methods are scoped to a
                 single child row (and to swGroep = FALSE for korting) and
                 would each re-validate the parent klant, which no longer
                 makes sense mid-cascade.
        Notes  : All deletes happen in one transaction - all-or-nothing.
                 korting.klnr is CHARACTER(8) while klant.klnr is INTEGER;
                 the plain (non-padded) STRING(piKlnr) conversion mirrors
                 Luna.BusinessLogic.KlantKortingBE.FormatKlntForKorting.
        Errors : AppError code 404 - klnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteKlant( INPUT piKlnr AS INTEGER ):

        DEFINE VARIABLE cKlnrForKorting AS CHARACTER NO-UNDO.

        cKlnrForKorting = STRING(piKlnr).

        DO TRANSACTION:
            FIND FIRST klant EXCLUSIVE-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.
            IF NOT AVAILABLE klant THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Klant &1 not found":u, piKlnr), 404).

            FOR EACH klant-adr EXCLUSIVE-LOCK WHERE klant-adr.klnr EQ piKlnr:
                DELETE klant-adr.
            END.

            FOR EACH klant-contact EXCLUSIVE-LOCK WHERE klant-contact.klnr EQ piKlnr:
                DELETE klant-contact.
            END.

            FOR EACH korting EXCLUSIVE-LOCK WHERE korting.klnr EQ cKlnrForKorting:
                DELETE korting.
            END.

            DELETE klant.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns the extended ("uitgebreid") scalar field set for a
                 single klant by klnr, or an empty ttKlantUitgebreid if it
                 doesn't exist (the WebHandler turns that into a 404). Every
                 field is always included, even when blank/0/false.
        Notes  : NO-LOCK read-only.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlantUitgebreid( INPUT piKlnr AS INTEGER ):

        EMPTY TEMP-TABLE ttKlantUitgebreid.

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.

        IF AVAILABLE klant THEN
        DO:
            CREATE ttKlantUitgebreid.
            CopyToTtUitgebreid( BUFFER klant, BUFFER ttKlantUitgebreid ).
        END.

        RETURN TEMP-TABLE ttKlantUitgebreid:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates the extended ("uitgebreid") scalar field set of an
                 existing klant. Only fields present in the JSON body are
                 changed (partial update); `klnr` itself is immutable.
        Errors : AppError code 404 - klnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateKlantUitgebreid( INPUT piKlnr AS INTEGER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttKlantUitgebreid.

        DO TRANSACTION:
            FIND FIRST klant EXCLUSIVE-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.
            IF NOT AVAILABLE klant THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Klant &1 not found":u, piKlnr), 404).

            ApplyUitgebreidFields( INPUT poBody, BUFFER klant ).

            CREATE ttKlantUitgebreid.
            CopyToTtUitgebreid( BUFFER klant, BUFFER ttKlantUitgebreid ).
        END.

        RETURN TEMP-TABLE ttKlantUitgebreid:HANDLE.

    END METHOD.

END CLASS.
