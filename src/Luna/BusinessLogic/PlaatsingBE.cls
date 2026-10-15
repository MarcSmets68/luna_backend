/*------------------------------------------------------------------------
    File        : PlaatsingBE.cls
    Purpose     : Business Entity for the "plaatsing" table (on-site
                  installation appointments) - read-only access.
    Field map (JSON key -> source column):
                  planr           -> plaatsing.planr
                  datum           -> plaatsing.datum
                  klnr            -> plaatsing.klnr
                  klantNaam       -> klant.naam (falls back to plaatsing.naam)
                  vrtgw           -> plaatsing.vrtgw
                  vrtgwNaam       -> gebruiker.naam (via vrtgw = gebruiker.kode)
                  project         -> plaatsing.project (character, "" if none)
                  bonnr           -> plaatsing.bonnr (null if 0)
                  factuur         -> plaatsing.factuur
                  datumAfsluiting -> plaatsing.datum-afsluiting
                  naam..stad      -> plaatsing.naam/naam1/adres/postnr/stad
                  land            -> klant.land
                  lnaam..lstad    -> plaatsing.lnaam/lnaam1/ladres/lpostnr/lstad
                  telefoon        -> klant.tel
                  gsm, gsm2       -> klant.gsm, klant.gsm2
                  email, email2   -> klant.email, klant.email2
                  plaatsingswijze -> plaatsing.plaatsing
                  plaatsingsdatum -> plaatsing.plaatsingsdatum
                  prijs           -> plaatsing.prijs
                  locatie         -> plaatsing.magazijn
                  swVoorbereiding -> plaatsing.sw_voorbereiding
                  voorbereiding   -> plaatsing.voorbereiding
                  swOpvolging     -> plaatsing.sw_opvolging
                  opvolging       -> plaatsing.opvolging
                  opm             -> plaatsing.opm
                  facturatie      -> plaatsing.facturatie
                  klassementmap   -> plaatsing.klassementmap
                  werkbonmap      -> plaatsing.werkbonmap
    Notes       : Pagination follows Luna.BusinessLogic.BonBE: no exact total
                  count, scanning stops one row beyond the requested page and
                  reports that through plHasMore. Newest planr first.
    Syntax      : Called from Luna.Web.PlaatsingHandler (GET /web/plaatsing
                  and /web/plaatsing/{planr})
    Author(s)   : Devin
    Created     : 2026-10-14
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.PlaatsingBE:

    DEFINE BUFFER bPlaatsing FOR plaatsing.
    DEFINE BUFFER bKlant     FOR klant.
    DEFINE BUFFER bGebruiker FOR gebruiker.

    DEFINE TEMP-TABLE ttPlaatsing NO-UNDO SERIALIZE-NAME "items":u
        FIELD planr           AS INTEGER   SERIALIZE-NAME "planr":u
        FIELD datum           AS DATE      SERIALIZE-NAME "datum":u
        FIELD klnr            AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD klantNaam       AS CHARACTER SERIALIZE-NAME "klantNaam":u
        FIELD vrtgw           AS CHARACTER SERIALIZE-NAME "vrtgw":u
        FIELD vrtgwNaam       AS CHARACTER SERIALIZE-NAME "vrtgwNaam":u
        FIELD project         AS CHARACTER SERIALIZE-NAME "project":u
        FIELD bonnr           AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD factuur         AS LOGICAL   SERIALIZE-NAME "factuur":u
        FIELD datumAfsluiting AS DATE      SERIALIZE-NAME "datumAfsluiting":u
        FIELD naam            AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD naam1           AS CHARACTER SERIALIZE-NAME "naam1":u
        FIELD adres           AS CHARACTER SERIALIZE-NAME "adres":u
        FIELD postnr          AS CHARACTER SERIALIZE-NAME "postnr":u
        FIELD stad            AS CHARACTER SERIALIZE-NAME "stad":u
        FIELD land            AS CHARACTER SERIALIZE-NAME "land":u
        FIELD lnaam           AS CHARACTER SERIALIZE-NAME "lnaam":u
        FIELD lnaam1          AS CHARACTER SERIALIZE-NAME "lnaam1":u
        FIELD ladres          AS CHARACTER SERIALIZE-NAME "ladres":u
        FIELD lpostnr         AS CHARACTER SERIALIZE-NAME "lpostnr":u
        FIELD lstad           AS CHARACTER SERIALIZE-NAME "lstad":u
        FIELD telefoon        AS CHARACTER SERIALIZE-NAME "telefoon":u
        FIELD gsm             AS CHARACTER SERIALIZE-NAME "gsm":u
        FIELD gsm2            AS CHARACTER SERIALIZE-NAME "gsm2":u
        FIELD email           AS CHARACTER SERIALIZE-NAME "email":u
        FIELD email2          AS CHARACTER SERIALIZE-NAME "email2":u
        FIELD plaatsingswijze AS CHARACTER SERIALIZE-NAME "plaatsingswijze":u
        FIELD plaatsingsdatum AS DATE      SERIALIZE-NAME "plaatsingsdatum":u
        FIELD prijs           AS DECIMAL   SERIALIZE-NAME "prijs":u
        FIELD locatie         AS CHARACTER SERIALIZE-NAME "locatie":u
        FIELD swVoorbereiding AS LOGICAL   SERIALIZE-NAME "swVoorbereiding":u
        FIELD voorbereiding   AS CHARACTER SERIALIZE-NAME "voorbereiding":u
        FIELD swOpvolging     AS LOGICAL   SERIALIZE-NAME "swOpvolging":u
        FIELD opvolging       AS CHARACTER SERIALIZE-NAME "opvolging":u
        FIELD opm             AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD facturatie      AS CHARACTER SERIALIZE-NAME "facturatie":u
        FIELD klassementmap   AS CHARACTER SERIALIZE-NAME "klassementmap":u
        FIELD werkbonmap      AS CHARACTER SERIALIZE-NAME "werkbonmap":u
        INDEX idx-planr IS PRIMARY planr DESCENDING.

    /*------------------------------------------------------------------------------
        Purpose: Copies a plaatsing row (plus the klant/gebruiker data it
                 references) into a new ttPlaatsing row.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID AddRow( BUFFER pbPlaatsing FOR plaatsing ):

        DEFINE BUFFER bTt FOR ttPlaatsing.

        FIND FIRST bKlant     NO-LOCK WHERE bKlant.klnr  EQ pbPlaatsing.klnr NO-ERROR.
        FIND FIRST bGebruiker NO-LOCK WHERE bGebruiker.kode EQ pbPlaatsing.vrtgw NO-ERROR.

        CREATE bTt.
        ASSIGN
            bTt.planr           = pbPlaatsing.planr
            bTt.datum           = pbPlaatsing.datum
            bTt.klnr            = pbPlaatsing.klnr
            bTt.klantNaam       = (IF AVAILABLE bKlant THEN bKlant.naam ELSE pbPlaatsing.naam)
            bTt.vrtgw           = pbPlaatsing.vrtgw
            bTt.vrtgwNaam       = (IF AVAILABLE bGebruiker THEN bGebruiker.naam ELSE "":u)
            bTt.project         = pbPlaatsing.project
            bTt.bonnr           = (IF pbPlaatsing.bonnr GT 0 THEN pbPlaatsing.bonnr ELSE ?)
            bTt.factuur         = pbPlaatsing.factuur
            bTt.datumAfsluiting = pbPlaatsing.datum-afsluiting
            bTt.naam            = pbPlaatsing.naam
            bTt.naam1           = pbPlaatsing.naam1
            bTt.adres           = pbPlaatsing.adres
            bTt.postnr          = pbPlaatsing.postnr
            bTt.stad            = pbPlaatsing.stad
            bTt.land            = (IF AVAILABLE bKlant THEN bKlant.land ELSE "":u)
            bTt.lnaam           = pbPlaatsing.lnaam
            bTt.lnaam1          = pbPlaatsing.lnaam1
            bTt.ladres          = pbPlaatsing.ladres
            bTt.lpostnr         = pbPlaatsing.lpostnr
            bTt.lstad           = pbPlaatsing.lstad
            bTt.telefoon        = (IF AVAILABLE bKlant THEN bKlant.tel ELSE "":u)
            bTt.gsm             = (IF AVAILABLE bKlant THEN bKlant.gsm ELSE "":u)
            bTt.gsm2            = (IF AVAILABLE bKlant THEN bKlant.gsm2 ELSE "":u)
            bTt.email           = (IF AVAILABLE bKlant THEN bKlant.email ELSE "":u)
            bTt.email2          = (IF AVAILABLE bKlant THEN bKlant.email2 ELSE "":u)
            bTt.plaatsingswijze = pbPlaatsing.plaatsing
            bTt.plaatsingsdatum = pbPlaatsing.plaatsingsdatum
            bTt.prijs           = pbPlaatsing.prijs
            bTt.locatie         = pbPlaatsing.magazijn
            bTt.swVoorbereiding = pbPlaatsing.sw_voorbereiding
            bTt.voorbereiding   = pbPlaatsing.voorbereiding
            bTt.swOpvolging     = pbPlaatsing.sw_opvolging
            bTt.opvolging       = pbPlaatsing.opvolging
            bTt.opm             = pbPlaatsing.opm
            bTt.facturatie      = pbPlaatsing.facturatie
            bTt.klassementmap   = pbPlaatsing.klassementmap
            bTt.werkbonmap      = pbPlaatsing.werkbonmap
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of plaatsingen, newest planr first, optionally
                 filtered by klnr (exact; 0 = no filter), planr (prefix match
                 on the string form) and naam (substring match on klant name
                 or plaatsing name). plHasMore is TRUE if at least one more
                 matching row exists beyond the page.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetPlaatsingen(
        INPUT  piKlnr     AS INTEGER,
        INPUT  pcPlanr    AS CHARACTER,
        INPUT  pcNaam     AS CHARACTER,
        INPUT  piPage     AS INTEGER,
        INPUT  piPageSize AS INTEGER,
        OUTPUT plHasMore  AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.
        DEFINE VARIABLE cKlantNaam AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttPlaatsing.

        ASSIGN
            pcPlanr   = TRIM(pcPlanr)
            pcNaam    = UPPER(TRIM(pcNaam))
            iSkip     = (piPage - 1) * piPageSize
            plHasMore = FALSE
            .

        FOR EACH bPlaatsing NO-LOCK
            WHERE (piKlnr LE 0 OR bPlaatsing.klnr EQ piKlnr)
            BY bPlaatsing.planr DESCENDING:

            IF pcPlanr NE "":u AND NOT (STRING(bPlaatsing.planr) BEGINS pcPlanr) THEN NEXT.

            IF pcNaam NE "":u THEN
            DO:
                FIND FIRST bKlant NO-LOCK WHERE bKlant.klnr EQ bPlaatsing.klnr NO-ERROR.
                cKlantNaam = (IF AVAILABLE bKlant THEN bKlant.naam ELSE "":u).
                IF INDEX(UPPER(cKlantNaam), pcNaam) EQ 0
                   AND INDEX(UPPER(bPlaatsing.naam), pcNaam) EQ 0 THEN NEXT.
            END.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            AddRow( BUFFER bPlaatsing ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttPlaatsing:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single plaatsing by planr, or an empty ttPlaatsing
                 if it doesn't exist (the WebHandler turns that into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetPlaatsing( INPUT piPlanr AS INTEGER ):

        EMPTY TEMP-TABLE ttPlaatsing.

        FIND FIRST bPlaatsing NO-LOCK WHERE bPlaatsing.planr EQ piPlanr NO-ERROR.

        IF AVAILABLE bPlaatsing THEN
            AddRow( BUFFER bPlaatsing ).

        RETURN TEMP-TABLE ttPlaatsing:HANDLE.

    END METHOD.

END CLASS.
