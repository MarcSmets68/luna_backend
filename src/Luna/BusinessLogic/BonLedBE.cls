/*------------------------------------------------------------------------
    File        : BonLedBE.cls
    Purpose     : Business Entity for the "bon_led" table - LED
                  configuratie regels onder een bon. Always scoped to an
                  existing bonnr (EnsureBonExists guard on every method).
    Field map (JSON key -> bon_led column):
                  bonnr             -> bonnr    (PK, from path, immutable)
                  groepnr           -> groepnr  (PK, required in body on create)
                  ledLijn           -> led_lijn (PK, required in body on create)
                  lijnnr            -> lijnnr   (PK, server-generated on create)
                  docLijnnr         -> doc-lijnnr
                  soort             -> soort
                  kode              -> kode
                  artnr             -> artnr
                  aantal            -> aantal
                  lengte            -> lengte
                  lMaat             -> Lmaat
                  rMaat             -> Rmaat
                  switch1           -> switch1
                  switch2           -> switch2
                  reflector         -> reflector
                  prijs             -> prijs
                  montagePrijs      -> montage-prijs
                  circuit           -> circuit
                  comp              -> comp
                  sturing           -> sturing
                  opm               -> opm
                  siktaKleurKodes[] -> SiktaKleurKodes (extent 5)
                  Read-only werkvelden (never written from the body, even
                  if present): teLeveren, gereserv, effectiefGereserv,
                  swEffectief, besteld, prebesteld, voorraad, levDatum,
                  bestelDatum, montageDatum, controle.
    Validation  : SiktaKleurKodes[1] must be non-blank before a bon_led
                  row can be created/updated (RAL/SC color code) - see
                  ValidateSiktaKleurKode. This mirrors the legacy
                  check-configuratie rule in Bon.w to the extent it could
                  be verified without live access to the legacy screen;
                  flagged as an assumption in the handoff note.
                  Also blocks create/update if the linked bonlijn
                  (bon_led.doc-lijnnr -> bonlijn.lijnnr, same bonnr) has
                  stempel = "D" (geleverd).
    Syntax      : Called from Luna.Web.BonHandler
                  (/web/bon/{bonnr}/led[/{groepnr}/{ledLijn}/{lijnnr}])
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLedBE:

    DEFINE TEMP-TABLE ttBonLed NO-UNDO SERIALIZE-NAME "items":u
        FIELD bonnr             AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD groepnr            AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD ledLijn            AS INTEGER   SERIALIZE-NAME "ledLijn":u
        FIELD lijnnr             AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD docLijnnr          AS INTEGER   SERIALIZE-NAME "docLijnnr":u
        FIELD soort              AS CHARACTER SERIALIZE-NAME "soort":u
        FIELD kode               AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD artnr              AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD aantal             AS INTEGER   SERIALIZE-NAME "aantal":u
        FIELD lengte             AS DECIMAL   SERIALIZE-NAME "lengte":u
        FIELD lMaat              AS DECIMAL   SERIALIZE-NAME "lMaat":u
        FIELD rMaat              AS DECIMAL   SERIALIZE-NAME "rMaat":u
        FIELD switch1            AS LOGICAL   SERIALIZE-NAME "switch1":u
        FIELD switch2            AS LOGICAL   SERIALIZE-NAME "switch2":u
        FIELD reflector          AS LOGICAL   SERIALIZE-NAME "reflector":u
        FIELD prijs              AS DECIMAL   SERIALIZE-NAME "prijs":u
        FIELD montagePrijs       AS DECIMAL   SERIALIZE-NAME "montagePrijs":u
        FIELD circuit            AS INTEGER   SERIALIZE-NAME "circuit":u
        FIELD comp               AS CHARACTER SERIALIZE-NAME "comp":u
        FIELD sturing            AS CHARACTER SERIALIZE-NAME "sturing":u
        FIELD opm                AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD siktaKleurKodes    AS CHARACTER SERIALIZE-NAME "siktaKleurKodes":u EXTENT 5
        FIELD teLeveren          AS DECIMAL   SERIALIZE-NAME "teLeveren":u
        FIELD gereserv           AS DECIMAL   SERIALIZE-NAME "gereserv":u
        FIELD effectiefGereserv  AS DECIMAL   SERIALIZE-NAME "effectiefGereserv":u
        FIELD swEffectief        AS LOGICAL   SERIALIZE-NAME "swEffectief":u
        FIELD besteld            AS DECIMAL   SERIALIZE-NAME "besteld":u
        FIELD prebesteld         AS DECIMAL   SERIALIZE-NAME "prebesteld":u
        FIELD voorraad           AS DECIMAL   SERIALIZE-NAME "voorraad":u
        FIELD levDatum           AS DATE      SERIALIZE-NAME "levDatum":u
        FIELD bestelDatum        AS DATE      SERIALIZE-NAME "bestelDatum":u
        FIELD montageDatum       AS DATE      SERIALIZE-NAME "montageDatum":u
        FIELD controle           AS LOGICAL   SERIALIZE-NAME "controle":u
        INDEX idx-lijnnr IS PRIMARY bonnr groepnr ledLijn lijnnr.

    METHOD PRIVATE VOID EnsureBonExists( INPUT piBonnr AS INTEGER ):

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Blocks create/update if the linked bonlijn (via
                 bon_led.doc-lijnnr, same bonnr) has stempel = "D".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CheckLinkedBonlijnNotDelivered( INPUT piBonnr AS INTEGER, INPUT piDocLijnnr AS INTEGER ):

        DEFINE BUFFER bfBonlijn FOR bonlijn.

        IF piDocLijnnr EQ 0 THEN RETURN.

        FIND FIRST bfBonlijn NO-LOCK
            WHERE bfBonlijn.bonnr  EQ piBonnr
              AND bfBonlijn.lijnnr EQ piDocLijnnr NO-ERROR.

        IF AVAILABLE bfBonlijn AND bfBonlijn.stempel EQ "D":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bonlijn &1/&2 has stempel 'D' (geleverd) and cannot have its LED-configuratie updated":u,
                    piBonnr, piDocLijnnr), 409).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: SiktaKleurKodes[1] must be non-blank (RAL/SC color code)
                 before a bon_led row can be saved.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateSiktaKleurKode(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        BUFFER pbBonLed FOR bon_led ):

        IF TRIM(pbBonLed.SiktaKleurKodes[1]) EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("LED-lijn &1/&2/&3/&4 requires a RAL/SC color code (SiktaKleurKodes) before it can be saved":u,
                    piBonnr, piGroepnr, piLedLijn, piLijnnr), 400).

    END METHOD.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbBonLed FOR bon_led, BUFFER pbTt FOR ttBonLed ):

        DEFINE VARIABLE iExtent AS INTEGER NO-UNDO.

        ASSIGN
            pbTt.bonnr             = pbBonLed.bonnr
            pbTt.groepnr           = pbBonLed.groepnr
            pbTt.ledLijn           = pbBonLed.led_lijn
            pbTt.lijnnr            = pbBonLed.lijnnr
            pbTt.docLijnnr         = pbBonLed.doc-lijnnr
            pbTt.soort             = pbBonLed.soort
            pbTt.kode              = pbBonLed.kode
            pbTt.artnr             = pbBonLed.artnr
            pbTt.aantal            = pbBonLed.aantal
            pbTt.lengte            = pbBonLed.lengte
            pbTt.lMaat             = pbBonLed.Lmaat
            pbTt.rMaat             = pbBonLed.Rmaat
            pbTt.switch1           = pbBonLed.switch1
            pbTt.switch2           = pbBonLed.switch2
            pbTt.reflector         = pbBonLed.reflector
            pbTt.prijs             = pbBonLed.prijs
            pbTt.montagePrijs      = pbBonLed.montage-prijs
            pbTt.circuit           = pbBonLed.circuit
            pbTt.comp              = pbBonLed.comp
            pbTt.sturing           = pbBonLed.sturing
            pbTt.opm               = pbBonLed.opm
            pbTt.teLeveren         = pbBonLed.te-leveren
            pbTt.gereserv          = pbBonLed.gereserv
            pbTt.effectiefGereserv = pbBonLed.effectief-gereserv
            pbTt.swEffectief       = pbBonLed.swEffectief
            pbTt.besteld           = pbBonLed.besteld
            pbTt.prebesteld        = pbBonLed.prebesteld
            pbTt.voorraad          = pbBonLed.voorraad
            pbTt.levDatum          = pbBonLed.lev-dat
            pbTt.bestelDatum       = pbBonLed.bestel-dat
            pbTt.montageDatum      = pbBonLed.montage-datum
            pbTt.controle          = pbBonLed.controle
            .

        DO iExtent = 1 TO 5:
            pbTt.siktaKleurKodes[iExtent] = pbBonLed.SiktaKleurKodes[iExtent].
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies writable fields from the JSON body. groepnr/
                 ledLijn/lijnnr/bonnr and every read-only werkveld are
                 never touched here.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbBonLed FOR bon_led ):

        DEFINE VARIABLE oArr    AS JsonArray NO-UNDO.
        DEFINE VARIABLE iExtent AS INTEGER   NO-UNDO.

        IF poBody:Has("docLijnnr":u)    THEN pbBonLed.doc-lijnnr    = poBody:GetInteger("docLijnnr":u).
        IF poBody:Has("soort":u)        THEN pbBonLed.soort         = poBody:GetCharacter("soort":u).
        IF poBody:Has("kode":u)         THEN pbBonLed.kode          = poBody:GetCharacter("kode":u).
        IF poBody:Has("artnr":u)        THEN pbBonLed.artnr         = poBody:GetCharacter("artnr":u).
        IF poBody:Has("aantal":u)       THEN pbBonLed.aantal        = poBody:GetInteger("aantal":u).
        IF poBody:Has("lengte":u)       THEN pbBonLed.lengte        = poBody:GetDecimal("lengte":u).
        IF poBody:Has("lMaat":u)        THEN pbBonLed.Lmaat         = poBody:GetDecimal("lMaat":u).
        IF poBody:Has("rMaat":u)        THEN pbBonLed.Rmaat         = poBody:GetDecimal("rMaat":u).
        IF poBody:Has("switch1":u)      THEN pbBonLed.switch1       = poBody:GetLogical("switch1":u).
        IF poBody:Has("switch2":u)      THEN pbBonLed.switch2       = poBody:GetLogical("switch2":u).
        IF poBody:Has("reflector":u)    THEN pbBonLed.reflector     = poBody:GetLogical("reflector":u).
        IF poBody:Has("prijs":u)        THEN pbBonLed.prijs         = poBody:GetDecimal("prijs":u).
        IF poBody:Has("montagePrijs":u) THEN pbBonLed.montage-prijs = poBody:GetDecimal("montagePrijs":u).
        IF poBody:Has("circuit":u)      THEN pbBonLed.circuit       = poBody:GetInteger("circuit":u).
        IF poBody:Has("comp":u)         THEN pbBonLed.comp          = poBody:GetCharacter("comp":u).
        IF poBody:Has("sturing":u)      THEN pbBonLed.sturing       = poBody:GetCharacter("sturing":u).
        IF poBody:Has("opm":u)          THEN pbBonLed.opm           = poBody:GetCharacter("opm":u).

        IF poBody:Has("siktaKleurKodes":u) THEN
        DO:
            oArr = poBody:GetJsonArray("siktaKleurKodes":u).
            DO iExtent = 1 TO 5:
                IF iExtent LE oArr:Length THEN
                    pbBonLed.SiktaKleurKodes[iExtent] = oArr:GetCharacter(iExtent).
                ELSE
                    pbBonLed.SiktaKleurKodes[iExtent] = "":u.
            END.
        END.

    END METHOD.

    METHOD PUBLIC HANDLE GetBonLedLijnen( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLed.

        FOR EACH bon_led NO-LOCK
            WHERE bon_led.bonnr EQ piBonnr
              AND (piGroepnr LE 0 OR bon_led.groepnr EQ piGroepnr)
            BY bon_led.groepnr BY bon_led.led_lijn BY bon_led.lijnnr:

            CREATE ttBonLed.
            CopyToTt( BUFFER bon_led, BUFFER ttBonLed ).
        END.

        RETURN TEMP-TABLE ttBonLed:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetBonLedLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER,
        INPUT piLijnnr  AS INTEGER ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLed.

        FIND FIRST bon_led NO-LOCK
            WHERE bon_led.bonnr   EQ piBonnr
              AND bon_led.groepnr EQ piGroepnr
              AND bon_led.led_lijn EQ piLedLijn
              AND bon_led.lijnnr  EQ piLijnnr NO-ERROR.

        IF AVAILABLE bon_led THEN
        DO:
            CREATE ttBonLed.
            CopyToTt( BUFFER bon_led, BUFFER ttBonLed ).
        END.

        RETURN TEMP-TABLE ttBonLed:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a bon_led row. groepnr/ledLijn are required in
                 the body; lijnnr is server-generated (last lijnnr for
                 bonnr+groepnr+ledLijn + 1) inside the same transaction.
        Errors : AppError 404 - bon not found.
                 AppError 400 - groepnr/ledLijn missing, or SiktaKleurKodes[1] blank.
                 AppError 409 - linked bonlijn has stempel "D".
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBonLedLijn( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iGroepnr   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iLedLijn   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iNewLijnnr AS INTEGER NO-UNDO.

        EnsureBonExists( piBonnr ).

        IF NOT poBody:Has("groepnr":u) OR NOT poBody:Has("ledLijn":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "groepnr and ledLijn are required to create a bon_led row":u, 400).

        iGroepnr = poBody:GetInteger("groepnr":u).
        iLedLijn = poBody:GetInteger("ledLijn":u).

        EMPTY TEMP-TABLE ttBonLed.

        DO TRANSACTION:
            FIND LAST bon_led USE-INDEX bon_led-x1 EXCLUSIVE-LOCK
                WHERE bon_led.bonnr    EQ piBonnr
                  AND bon_led.groepnr  EQ iGroepnr
                  AND bon_led.led_lijn EQ iLedLijn NO-ERROR.

            iNewLijnnr = (IF AVAILABLE bon_led THEN bon_led.lijnnr ELSE 0) + 1.

            CREATE bon_led.
            ASSIGN
                bon_led.bonnr    = piBonnr
                bon_led.groepnr  = iGroepnr
                bon_led.led_lijn = iLedLijn
                bon_led.lijnnr   = iNewLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER bon_led ).

            ValidateSiktaKleurKode( piBonnr, iGroepnr, iLedLijn, iNewLijnnr, BUFFER bon_led ).
            CheckLinkedBonlijnNotDelivered( piBonnr, bon_led.doc-lijnnr ).

            CREATE ttBonLed.
            CopyToTt( BUFFER bon_led, BUFFER ttBonLed ).
        END.

        RETURN TEMP-TABLE ttBonLed:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE UpdateBonLedLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        INPUT poBody    AS JsonObject ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLed.

        DO TRANSACTION:
            FIND FIRST bon_led EXCLUSIVE-LOCK
                WHERE bon_led.bonnr    EQ piBonnr
                  AND bon_led.groepnr  EQ piGroepnr
                  AND bon_led.led_lijn EQ piLedLijn
                  AND bon_led.lijnnr   EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bon_led THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("LED-lijn &1/&2/&3/&4 not found":u, piBonnr, piGroepnr, piLedLijn, piLijnnr), 404).

            CheckLinkedBonlijnNotDelivered( piBonnr, bon_led.doc-lijnnr ).

            ApplyFields( INPUT poBody, BUFFER bon_led ).

            ValidateSiktaKleurKode( piBonnr, piGroepnr, piLedLijn, piLijnnr, BUFFER bon_led ).
            CheckLinkedBonlijnNotDelivered( piBonnr, bon_led.doc-lijnnr ).

            CREATE ttBonLed.
            CopyToTt( BUFFER bon_led, BUFFER ttBonLed ).
        END.

        RETURN TEMP-TABLE ttBonLed:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteBonLedLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER,
        INPUT piLijnnr  AS INTEGER ):

        EnsureBonExists( piBonnr ).

        DO TRANSACTION:
            FIND FIRST bon_led EXCLUSIVE-LOCK
                WHERE bon_led.bonnr    EQ piBonnr
                  AND bon_led.groepnr  EQ piGroepnr
                  AND bon_led.led_lijn EQ piLedLijn
                  AND bon_led.lijnnr   EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bon_led THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("LED-lijn &1/&2/&3/&4 not found":u, piBonnr, piGroepnr, piLedLijn, piLijnnr), 404).

            DELETE bon_led.
        END.

    END METHOD.

END CLASS.

