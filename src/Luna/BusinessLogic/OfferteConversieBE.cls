/*------------------------------------------------------------------------
    File        : OfferteConversieBE.cls
    Purpose     : Iteratie D - Offerte->Order conversie. Converts an
                  offerte (quote) into a bon (order/orderbevestiging):
                  creates a new bon + its bonlijn/bon_led rows from the
                  offerte's overdraagbare (transferable) offlijn/off_led
                  rows, recalculates pricing (Luna.BusinessLogic.
                  PricingEngineBE) and BTW (Luna.BusinessLogic.
                  BtwBerekeningBE) on the way, and marks the offerte as
                  (partially) verkocht/geleverd.
    Syntax      : Called from Luna.Web.OfferteHandler (POST
                  /web/offerte/{offnr}/{versie}/omzetten-naar-order).
    Description : Owns all DB access for this feature - no direct DB
                  access is allowed from the WebHandler layer. The entire
                  conversion runs inside ONE DO TRANSACTION block (all or
                  nothing) - BonBE:AllocateBonnr and BonLijnBE:
                  CreateBonLijnInternal are called from inside it; ABL
                  nested DO TRANSACTION collapses into the outermost
                  transaction, so those calls' own DO TRANSACTION blocks
                  simply extend this one instead of creating independent
                  commit points.

    Implementation decisions taken where the design doc left the exact
    mechanics ambiguous (flagging explicitly per the "diverge and
    document" rule):

      1. groepnr/subgroepnr dense renumbering is precomputed ONCE, in a
         single pass over every transferable offlijn in offerte-lijnnr
         order (both subtotaal and non-subtotaal lines together) - see
         BuildGroepMapping/ttGroepMap/ttSubgroepMap/ttGroepExpansion/
         ttLedGroepMap - rather than being computed separately/
         incrementally inside Pass 1 and Pass 2. This guarantees the same
         original groepnr always maps to the same new groepnr regardless
         of which pass encounters it first (Pass 1 only sees subtotaal
         lines, Pass 2 sees everything else, and a group's subtotaal line
         is not always first in offerte-lijnnr order within its group).
         A default (non-split) ttGroepExpansion/ttLedGroepMap entry
         (copyIndex 1) is seeded for every nonzero groepnr right away, so
         Pass 2 never has to special-case a group with no subtotaal line
         at all.
      2. Subtotaal-blok-splitsing (splitsen=TRUE, aantal>1) needs MORE
         physical groepnr values than the base dense mapping provides
         (one extra full group copy per extra aantal). These extra
         groepnr values are allocated on the fly in Pass 1 (continuing
         after the highest groepnr used by the base mapping) and appended
         to ttGroepExpansion (oldGroepnr -> list of new groepnr "copies").
         Pass 2 looks up ALL copies for an item's original groepnr and
         creates one bonlijn per copy (replicating the item into every
         duplicated group).
      3. subgroepnr's dense mapping is NOT duplicated per group-copy - the
         same new subgroepnr values are reused identically across every
         physical copy of a split group, since subgroepnr is a label
         local to a group's internal item structure, not a cross-group
         sequence.
      4. bonlijn.bedrag is computed here (aantal * vprijs * (1 -
         korting/100), ROUND to 2 decimals) for item lines only -
         BonLijnBE's ApplyFields never computes it automatically, it only
         ever passes through whatever the caller supplies. Subtotaal/
         kolomtitel/infolijn lines get bedrag = 0 (no monetary amount of
         their own - the BTW basis is driven entirely by the item lines,
         avoiding double-counting).
      5. bonlijn.gereserv is documented in Luna.BusinessLogic.BonLijnBE as
         read-only/computed (by the Iteratie C auto-reservation hook) and
         is NOT part of ApplyFields/ApplyFieldsExtended's writable field
         set. Design doc step 7 explicitly requires copying
         offlijn.te-leveren into bonlijn.gereserv for kolomtitel/infolijn
         lines (which never go through the auto-reservation hook, since
         that hook only fires for item lines with artnr <> ""). To make
         this possible without breaking BonLijnBE's read-only contract for
         the public API, "gereserv" was added to ApplyFieldsExtended
         (internal-only path) - see BonLijnBE.cls. Flagging this as an
         addition beyond the field list literally given in the design doc
         for ApplyFieldsExtended.
      6. bon.project-dat as named in the original design doc does not
         exist on bon - the actual column is bon.project-datum (see
         docs/db-analysis/schema_dump.txt). Implemented against
         project-datum; flagging this doc/code divergence explicitly per
         the "fix the design doc too" rule.

    Author(s)   : Devin
    Created     : 2026-10-04
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.BonBE.
USING Luna.BusinessLogic.BonLijnBE.
USING Luna.BusinessLogic.PricingEngineBE.
USING Luna.BusinessLogic.BtwBerekeningBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.OfferteConversieBE:

    DEFINE TEMP-TABLE ttConversieResultaat NO-UNDO SERIALIZE-NAME "resultaat":u
        FIELD bonnr                      AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD offnr                      AS INTEGER   SERIALIZE-NAME "offnr":u
        FIELD versie                     AS INTEGER   SERIALIZE-NAME "versie":u
        FIELD offerteStempel             AS CHARACTER SERIALIZE-NAME "offerteStempel":u
        FIELD aantalLijnenOvergenomen    AS INTEGER   SERIALIZE-NAME "aantalLijnenOvergenomen":u
        FIELD aantalLedLijnenOvergenomen AS INTEGER   SERIALIZE-NAME "aantalLedLijnenOvergenomen":u
        FIELD totBtw                     AS DECIMAL   SERIALIZE-NAME "totBtw":u
        FIELD totaalBasis                AS DECIMAL   SERIALIZE-NAME "totaalBasis":u
        FIELD totaalInclBtw              AS DECIMAL   SERIALIZE-NAME "totaalInclBtw":u.

    /* --- Working state, private to one OmzettenNaarOrder() call -------- */

    DEFINE PRIVATE TEMP-TABLE ttGroepMap NO-UNDO
        FIELD oldGroepnr AS INTEGER
        FIELD newGroepnr AS INTEGER
        INDEX idx-pk IS UNIQUE oldGroepnr.

    DEFINE PRIVATE TEMP-TABLE ttSubgroepMap NO-UNDO
        FIELD oldSubgroepnr AS INTEGER
        FIELD newSubgroepnr AS INTEGER
        INDEX idx-pk IS UNIQUE oldSubgroepnr.

    DEFINE PRIVATE TEMP-TABLE ttGroepExpansion NO-UNDO
        FIELD oldGroepnr AS INTEGER
        FIELD copyIndex  AS INTEGER
        FIELD newGroepnr AS INTEGER
        INDEX idx-pk IS UNIQUE oldGroepnr copyIndex.

    DEFINE PRIVATE TEMP-TABLE ttLijnnrMap NO-UNDO
        FIELD offLijnnr AS INTEGER
        FIELD bonLijnnr AS INTEGER
        INDEX idx-pk IS UNIQUE offLijnnr.

    DEFINE PRIVATE TEMP-TABLE ttLedGroepMap NO-UNDO
        FIELD offGroepnr AS INTEGER
        FIELD bonGroepnr AS INTEGER
        INDEX idx-pk IS UNIQUE offGroepnr.

    DEFINE PRIVATE VARIABLE iLijnnrCounter              AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iGroepnrCounter              AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iSubgroepnrCounter           AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iBonnr                       AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iAantalLijnenOvergenomen     AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iAantalLedLijnenOvergenomen  AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE lSwRecupel                   AS LOGICAL   NO-UNDO.
    DEFINE PRIVATE VARIABLE cTypeKortingOfferte           AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE dResultTotBtw                AS DECIMAL   NO-UNDO.
    DEFINE PRIVATE VARIABLE dResultTotaalBasis            AS DECIMAL   NO-UNDO.
    DEFINE PRIVATE VARIABLE dResultTotaalInclBtw          AS DECIMAL   NO-UNDO.

    DEFINE PRIVATE VARIABLE hBtwInvoerLijnen AS HANDLE NO-UNDO.

    /* Kept alive as an instance variable (not a bare NEW BtwBerekeningBE()
       inline expression) for the whole OmzettenNaarOrder() call - the
       ttBtwInvoerLijn temp-table handle returned by GetInvoerLijnenHandle()
       is owned by this instance and would be silently destroyed (leaving
       hBtwInvoerLijnen an "Invalid handle") the moment a NEW
       BtwBerekeningBE() expression with no surviving object reference goes
       out of scope - discovered during live smoke-testing. */
    DEFINE PRIVATE VARIABLE oBtwService AS BtwBerekeningBE NO-UNDO.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the offerte doesn't exist, 409 if
                 it doesn't have stempel "O" (Open). NO-LOCK.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureOfferteOpenbaar( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER ):

        FIND FIRST offerte NO-LOCK
            WHERE offerte.offnr EQ piOffnr
              AND offerte.versie EQ piVersie NO-ERROR.

        IF NOT AVAILABLE offerte THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Offerte &1/&2 not found":u, piOffnr, piVersie), 404).

        IF offerte.stempel NE "O":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Offerte &1/&2 has stempel '&3' - only an open offerte (stempel 'O') can be converted to an order":u,
                    piOffnr, piVersie, offerte.stempel), 409).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: TRUE if the given offlijn is part of the "overdraagbare"
                 (transferable) set: (te-leveren <> 0 OR kolomtitel OR
                 infolijn) AND variante = FALSE.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL IsOverdraagbaar( BUFFER pbOfflijn FOR offlijn ):

        RETURN (pbOfflijn.te-leveren NE 0 OR pbOfflijn.kolomtitel OR pbOfflijn.infolijn)
           AND pbOfflijn.variante EQ FALSE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Orchestrates the full offerte -> bon conversion.
        Errors : AppError 404 - offerte not found.
                 AppError 409 - offerte.stempel <> "O" (checked both before
                          and, as a race guard, again inside the
                          transaction).
                 AppError 400 - no overdraagbare offlijn rows.
                 Propagates any AppError raised by PricingEngineBE/
                 BtwBerekeningBE/BonLijnBE:CreateBonLijnInternal as-is.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE OmzettenNaarOrder( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER ):

        DEFINE BUFFER bOfflijnCheck FOR offlijn.
        DEFINE VARIABLE lHeeftOverdraagbareLijn AS LOGICAL NO-UNDO.

        EMPTY TEMP-TABLE ttConversieResultaat.

        EnsureOfferteOpenbaar( piOffnr, piVersie ).

        FOR EACH bOfflijnCheck NO-LOCK
            WHERE bOfflijnCheck.offnr  EQ piOffnr
              AND bOfflijnCheck.versie EQ piVersie:
            IF IsOverdraagbaar( BUFFER bOfflijnCheck ) THEN
            DO:
                lHeeftOverdraagbareLijn = TRUE.
                LEAVE.
            END.
        END.

        IF NOT lHeeftOverdraagbareLijn THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Offerte &1/&2 has no overdraagbare (transferable) lines to convert":u, piOffnr, piVersie), 400).

        EMPTY TEMP-TABLE ttGroepMap.
        EMPTY TEMP-TABLE ttSubgroepMap.
        EMPTY TEMP-TABLE ttGroepExpansion.
        EMPTY TEMP-TABLE ttLijnnrMap.
        EMPTY TEMP-TABLE ttLedGroepMap.
        ASSIGN
            iLijnnrCounter              = 0
            iGroepnrCounter             = 0
            iSubgroepnrCounter          = 0
            iAantalLijnenOvergenomen    = 0
            iAantalLedLijnenOvergenomen = 0
            .

        oBtwService      = NEW BtwBerekeningBE().
        hBtwInvoerLijnen = oBtwService:GetInvoerLijnenHandle().

        DO TRANSACTION:

            FIND FIRST offerte EXCLUSIVE-LOCK
                WHERE offerte.offnr EQ piOffnr
                  AND offerte.versie EQ piVersie NO-ERROR.

            IF NOT AVAILABLE offerte THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offerte &1/&2 not found":u, piOffnr, piVersie), 404).

            IF offerte.stempel NE "O":u THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offerte &1/&2 has stempel '&3' - only an open offerte (stempel 'O') can be converted to an order":u,
                        piOffnr, piVersie, offerte.stempel), 409).

            cTypeKortingOfferte = offerte.type-korting.

            BuildGroepMapping( BUFFER offerte ).

            CreateBonHeader( BUFFER offerte ).

            ProcessPass1Subtotalen( BUFFER offerte ).
            ProcessPass2Overige( BUFFER offerte ).

            CopyLedLijnen( BUFFER offerte ).

            BerekenEnSchrijfBtw( BUFFER offerte ).

            FinalizeOfferte( BUFFER offerte ).

            CREATE ttConversieResultaat.
            ASSIGN
                ttConversieResultaat.bonnr                      = iBonnr
                ttConversieResultaat.offnr                      = piOffnr
                ttConversieResultaat.versie                     = piVersie
                ttConversieResultaat.offerteStempel             = offerte.stempel
                ttConversieResultaat.aantalLijnenOvergenomen    = iAantalLijnenOvergenomen
                ttConversieResultaat.aantalLedLijnenOvergenomen = iAantalLedLijnenOvergenomen
                ttConversieResultaat.totBtw                     = dResultTotBtw
                ttConversieResultaat.totaalBasis                = dResultTotaalBasis
                ttConversieResultaat.totaalInclBtw              = dResultTotaalInclBtw
                .

        END.

        RETURN TEMP-TABLE ttConversieResultaat:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the dense groepnr/subgroepnr renumbering (see
                 class header, decision 1) by scanning every transferable
                 offlijn under this offerte, in offerte-lijnnr order,
                 assigning a new dense number the first time a nonzero old
                 groepnr/subgroepnr value is seen. Also seeds a default
                 (non-split) ttGroepExpansion/ttLedGroepMap entry for every
                 nonzero groepnr right away.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildGroepMapping( BUFFER pbOfferte FOR offerte ):

        DEFINE BUFFER bOfflijn FOR offlijn.

        FOR EACH bOfflijn OF pbOfferte NO-LOCK BY bOfflijn.lijnnr:

            IF NOT IsOverdraagbaar( BUFFER bOfflijn ) THEN NEXT.

            IF bOfflijn.groepnr NE 0 AND NOT CAN-FIND(FIRST ttGroepMap WHERE ttGroepMap.oldGroepnr EQ bOfflijn.groepnr) THEN
            DO:
                iGroepnrCounter = iGroepnrCounter + 1.
                CREATE ttGroepMap.
                ASSIGN
                    ttGroepMap.oldGroepnr = bOfflijn.groepnr
                    ttGroepMap.newGroepnr = iGroepnrCounter
                    .

                CREATE ttGroepExpansion.
                ASSIGN
                    ttGroepExpansion.oldGroepnr = bOfflijn.groepnr
                    ttGroepExpansion.copyIndex  = 1
                    ttGroepExpansion.newGroepnr = iGroepnrCounter
                    .

                CREATE ttLedGroepMap.
                ASSIGN
                    ttLedGroepMap.offGroepnr = bOfflijn.groepnr
                    ttLedGroepMap.bonGroepnr = iGroepnrCounter
                    .
            END.

            IF bOfflijn.subgroepnr NE 0 AND NOT CAN-FIND(FIRST ttSubgroepMap WHERE ttSubgroepMap.oldSubgroepnr EQ bOfflijn.subgroepnr) THEN
            DO:
                iSubgroepnrCounter = iSubgroepnrCounter + 1.
                CREATE ttSubgroepMap.
                ASSIGN
                    ttSubgroepMap.oldSubgroepnr = bOfflijn.subgroepnr
                    ttSubgroepMap.newSubgroepnr = iSubgroepnrCounter
                    .
            END.

        END.

    END METHOD.

    METHOD PRIVATE INTEGER NieuwGroepnr( INPUT piOldGroepnr AS INTEGER ):

        IF piOldGroepnr EQ 0 THEN RETURN 0.

        FIND FIRST ttGroepMap WHERE ttGroepMap.oldGroepnr EQ piOldGroepnr NO-ERROR.
        RETURN (IF AVAILABLE ttGroepMap THEN ttGroepMap.newGroepnr ELSE 0).

    END METHOD.

    METHOD PRIVATE INTEGER NieuwSubgroepnr( INPUT piOldSubgroepnr AS INTEGER ):

        IF piOldSubgroepnr EQ 0 THEN RETURN 0.

        FIND FIRST ttSubgroepMap WHERE ttSubgroepMap.oldSubgroepnr EQ piOldSubgroepnr NO-ERROR.
        RETURN (IF AVAILABLE ttSubgroepMap THEN ttSubgroepMap.newSubgroepnr ELSE 0).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Allocates the next bonlijn.lijnnr - starts at 5000, +5000
                 per call, shared across Pass 1 and Pass 2.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER VolgendeLijnnr():

        iLijnnrCounter = iLijnnrCounter + 5000.
        RETURN iLijnnrCounter.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates the new bon header row, copying the 1:1 fields
                 from offerte, applying the fixed/derived fields per the
                 design doc. Sets iBonnr (instance variable) for later use.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CreateBonHeader( BUFFER pbOfferte FOR offerte ):

        DEFINE VARIABLE iDagenLever   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iDagenProject AS INTEGER NO-UNDO.
        DEFINE BUFFER bKlant   FOR klant.
        DEFINE BUFFER bSyspara FOR syspara.

        iBonnr = NEW BonBE():AllocateBonnr().

        CREATE bon.
        ASSIGN
            bon.bonnr = iBonnr

            bon.klnr             = pbOfferte.klnr
            bon.naam             = pbOfferte.naam
            bon.naam1            = pbOfferte.naam1
            bon.adres            = pbOfferte.adres
            bon.postnr           = pbOfferte.postnr
            bon.stad             = pbOfferte.stad
            bon.lnaam            = pbOfferte.lnaam
            bon.lnaam1           = pbOfferte.lnaam1
            bon.ladres           = pbOfferte.ladres
            bon.lpostnr          = pbOfferte.lpostnr
            bon.lstad            = pbOfferte.lstad
            bon.vrtgw            = pbOfferte.vrtgw
            bon.project          = pbOfferte.project
            bon.vperiode         = pbOfferte.vperiode
            bon.u-ref            = pbOfferte.u-ref
            bon.btw-nr           = pbOfferte.btw-nr
            bon.kort-kont        = pbOfferte.kort-kont
            bon.korting          = pbOfferte.korting
            bon.taal             = pbOfferte.taal
            bon.munt             = pbOfferte.munt
            bon.btw-reg          = pbOfferte.btw-reg
            bon.land             = pbOfferte.land
            bon.projectnr        = pbOfferte.projectnr
            bon.contact-nr       = pbOfferte.contact-nr
            bon.plaatsing-wijze  = pbOfferte.plaatsing-wijze
            bon.plaatsing-prijs  = pbOfferte.plaatsing-prijs
            bon.swVersturen      = pbOfferte.swVersturen
            bon.klassementmap    = pbOfferte.klassementmap
            bon.klassementnr     = pbOfferte.klassementnr
            bon.swNomaled        = pbOfferte.swNomaled

            bon.stempel          = "O":u
            bon.type             = "ORDERBEVESTIGING":u
            bon.datum            = TODAY
            bon.volgnr           = 0
            bon.verzonden        = FALSE
            bon.bestel-datum     = TODAY
            .

        FIND FIRST bSyspara NO-LOCK NO-ERROR.
        ASSIGN
            iDagenLever   = (IF AVAILABLE bSyspara THEN bSyspara.dagen_lever   ELSE 0)
            iDagenProject = (IF AVAILABLE bSyspara THEN bSyspara.dagen_project ELSE 0)
            .

        ASSIGN
            bon.lev-dat       = (IF iDagenLever   NE 0 THEN TODAY + iDagenLever   ELSE ?)
            bon.project-datum = (IF iDagenProject NE 0 THEN TODAY + iDagenProject ELSE ?)
            .

        ASSIGN
            bon.klnr2 = (IF pbOfferte.klnr2 NE 0
                            THEN (IF pbOfferte.klnr NE pbOfferte.klnr2 THEN pbOfferte.klnr2 ELSE pbOfferte.klnr1)
                            ELSE 0)
            bon.klnr3 = (IF pbOfferte.klnr3 NE 0
                            THEN (IF pbOfferte.klnr NE pbOfferte.klnr3 THEN pbOfferte.klnr3 ELSE pbOfferte.klnr1)
                            ELSE 0)
            .

        IF pbOfferte.type-korting BEGINS "K4":u THEN
            bon.korting = 0.

        FIND FIRST bKlant NO-LOCK WHERE bKlant.klnr EQ bon.klnr NO-ERROR.
        bon.opm = (IF AVAILABLE bKlant THEN bKlant.opm ELSE "":u).

        lSwRecupel = (bon.land EQ "BE":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns the typeKorting to pass into PricingEngineBE:
                 SUBSTRING(offerte.type-korting,1,2) if it BEGINS "K1".."K5",
                 otherwise "" (silent fallback - see design doc).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER BepaalTypeKortingVoorPricing():

        DEFINE VARIABLE cKort AS CHARACTER NO-UNDO.

        cKort = SUBSTRING(cTypeKortingOfferte, 1, 2).

        IF LOOKUP(cKort, "K1,K2,K3,K4,K5":u) GT 0 THEN
            RETURN cKort.

        RETURN "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Adds one row to the BTW-invoerlijnen accumulator for a
                 newly created bonlijn.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID VoegBtwInvoerlijnToe(
        INPUT pcBtwKode AS CHARACTER, INPUT pdBedrag AS DECIMAL, INPUT pdTotaalRecupel AS DECIMAL ):

        DEFINE VARIABLE hBuffer AS HANDLE NO-UNDO.

        hBuffer = hBtwInvoerLijnen:DEFAULT-BUFFER-HANDLE.
        hBuffer:BUFFER-CREATE().
        hBuffer:BUFFER-FIELD("btwKode":u):BUFFER-VALUE       = pcBtwKode.
        hBuffer:BUFFER-FIELD("bedrag":u):BUFFER-VALUE        = pdBedrag.
        hBuffer:BUFFER-FIELD("totaalRecupel":u):BUFFER-VALUE = pdTotaalRecupel.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Pass 1 - creates the bonlijn for every transferable
                 subtotaal offlijn, in offerte-lijnnr order, handling the
                 subtotaal-blok-splitsing rule (splitsen=TRUE -> N physical
                 group copies, splitsen=FALSE -> off_aantal scaling within
                 the one group). Extends ttGroepExpansion for split groups.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ProcessPass1Subtotalen( BUFFER pbOfferte FOR offerte ):

        DEFINE BUFFER bOfflijn FOR offlijn.
        DEFINE VARIABLE dSubAantal    AS DECIMAL NO-UNDO.
        DEFINE VARIABLE iNieuwGroep   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iCopy         AS INTEGER NO-UNDO.
        DEFINE VARIABLE iAantalCopies AS INTEGER NO-UNDO.
        DEFINE VARIABLE iNewLijnnr    AS INTEGER NO-UNDO.
        DEFINE VARIABLE oBody         AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult       AS HANDLE     NO-UNDO.

        FOR EACH bOfflijn OF pbOfferte
            WHERE bOfflijn.subtotaal EQ TRUE
            NO-LOCK BY bOfflijn.lijnnr:

            IF NOT IsOverdraagbaar( BUFFER bOfflijn ) THEN NEXT.

            dSubAantal = MAXIMUM(1, bOfflijn.aantal).

            IF dSubAantal GT 1 AND bOfflijn.splitsen THEN
                iAantalCopies = INTEGER(dSubAantal).
            ELSE
                iAantalCopies = 1.

            DO iCopy = 1 TO iAantalCopies:

                IF iCopy EQ 1 THEN
                    iNieuwGroep = NieuwGroepnr(bOfflijn.groepnr).
                ELSE
                DO:
                    iGroepnrCounter = iGroepnrCounter + 1.
                    iNieuwGroep = iGroepnrCounter.
                    CREATE ttGroepExpansion.
                    ASSIGN
                        ttGroepExpansion.oldGroepnr = bOfflijn.groepnr
                        ttGroepExpansion.copyIndex  = iCopy
                        ttGroepExpansion.newGroepnr = iNieuwGroep
                        .
                END.

                iNewLijnnr = VolgendeLijnnr().

                oBody = NEW JsonObject().
                oBody:Add("artnr":u, bOfflijn.artnr).
                oBody:Add("omschrijving":u, bOfflijn.omschr).
                oBody:Add("aantal":u, bOfflijn.aantal).
                oBody:Add("teLeveren":u, bOfflijn.te-leveren).
                oBody:Add("vprijs":u, bOfflijn.vprijs).
                oBody:Add("aprijs":u, bOfflijn.aprijs).
                oBody:Add("korting":u, bOfflijn.korting).
                oBody:Add("btwKode":u, bOfflijn.btw-kode).
                oBody:Add("bedrag":u, 0.0).
                oBody:Add("klnr":u, bon.klnr).
                oBody:Add("groepnr":u, iNieuwGroep).
                oBody:Add("subgroepnr":u, NieuwSubgroepnr(bOfflijn.subgroepnr)).
                oBody:Add("hold":u, bOfflijn.hold).
                oBody:Add("opm":u, bOfflijn.opm).
                oBody:Add("subtotaal":u, TRUE).
                oBody:Add("bestelDatum":u, bon.bestel-datum).
                oBody:Add("levDatum":u, (IF bOfflijn.montage THEN bOfflijn.lev-dat ELSE bon.lev-dat)).
                oBody:Add("stempel":u, "O":u).
                oBody:Add("offnr":u, pbOfferte.offnr).
                oBody:Add("versie":u, pbOfferte.versie).
                oBody:Add("olijnnr":u, bOfflijn.lijnnr).
                oBody:Add("swLed":u, bOfflijn.swLed).
                oBody:Add("swSikta":u, bOfflijn.swSikta).
                oBody:Add("montage":u, bOfflijn.montage).
                oBody:Add("ledmontage":u, bOfflijn.ledmontage).
                oBody:Add("circuit":u, bOfflijn.circuit).
                oBody:Add("recupel":u, bOfflijn.recupel).
                oBody:Add("meer_min":u, bOfflijn.meer_min).
                oBody:Add("off_aantal":u, (IF dSubAantal GT 1 AND NOT bOfflijn.splitsen THEN dSubAantal ELSE 1)).
                oBody:Add("swStdPrijs":u, bOfflijn.swStdPrijs).
                oBody:Add("uitverkoop":u, bOfflijn.uitverkoop).
                oBody:Add("SiktaKleurKodes":u, bOfflijn.SiktaKleurKodes[1]).

                hResult = NEW BonLijnBE():CreateBonLijnInternal( iBonnr, oBody, iNewLijnnr ).

                IF iCopy EQ 1 THEN
                DO:
                    CREATE ttLijnnrMap.
                    ASSIGN
                        ttLijnnrMap.offLijnnr = bOfflijn.lijnnr
                        ttLijnnrMap.bonLijnnr = iNewLijnnr
                        .
                END.

                VoegBtwInvoerlijnToe(bOfflijn.btw-kode, 0.0, 0.0).

            END.

            FIND CURRENT bOfflijn EXCLUSIVE-LOCK.
            ASSIGN
                bOfflijn.stempel     = "D":u
                bOfflijn.te-leveren  = 0
                .

            iAantalLijnenOvergenomen = iAantalLijnenOvergenomen + 1.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Pass 2 - creates the bonlijn(en) for every remaining
                 transferable offlijn (item/kolomtitel/infolijn, i.e.
                 subtotaal = FALSE), in offerte-lijnnr order. Item lines
                 are repriced via PricingEngineBE. A line whose groepnr
                 belongs to a split subtotaal block (ttGroepExpansion has
                 more than 1 copy for it) is replicated once per copy;
                 groepnr = 0 lines have no ttGroepExpansion entry and are
                 created exactly once, ungrouped.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ProcessPass2Overige( BUFFER pbOfferte FOR offerte ):

        DEFINE BUFFER bOfflijn           FOR offlijn.
        DEFINE BUFFER bSubtotaalOfflijn  FOR offlijn.
        DEFINE VARIABLE cTypeKortingPricing AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE oPricingService     AS PricingEngineBE NO-UNDO.
        DEFINE VARIABLE hPricingTable       AS HANDLE    NO-UNDO.
        DEFINE VARIABLE hPricingBuffer      AS HANDLE    NO-UNDO.
        DEFINE VARIABLE dVprijs             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dAprijs             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dKorting            AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dBedrag             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dAantalOpBonlijn    AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE lIsItemLijn         AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE dSubAantal          AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE lSplitsen           AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE dOffAantal          AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE iNewLijnnr          AS INTEGER   NO-UNDO.
        DEFINE VARIABLE oBody               AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult             AS HANDLE    NO-UNDO.
        DEFINE VARIABLE lFirstCopyDone      AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE iCopyGroepnr        AS INTEGER   NO-UNDO.
        DEFINE VARIABLE lAnyCopyMade        AS LOGICAL   NO-UNDO.

        cTypeKortingPricing = BepaalTypeKortingVoorPricing().

        FOR EACH bOfflijn OF pbOfferte
            WHERE bOfflijn.subtotaal EQ FALSE
            NO-LOCK BY bOfflijn.lijnnr:

            IF NOT IsOverdraagbaar( BUFFER bOfflijn ) THEN NEXT.

            lIsItemLijn = NOT bOfflijn.kolomtitel AND NOT bOfflijn.infolijn.

            ASSIGN
                dVprijs  = bOfflijn.vprijs
                dAprijs  = bOfflijn.aprijs
                dKorting = bOfflijn.korting
                .

            IF lIsItemLijn THEN
            DO:
                /* oPricingService MUST be a variable (not a bare NEW
                   PricingEngineBE() inline expression) - see
                   oBtwService's declaration comment for why: the returned
                   ttPricingResult temp-table handle is owned by this
                   instance and would be invalid the moment nothing keeps
                   the instance alive. */
                oPricingService = NEW PricingEngineBE().
                hPricingTable   = oPricingService:BerekenPrijs(
                    bOfflijn.artnr, bon.klnr, bOfflijn.aantal, cTypeKortingPricing, pbOfferte.korting).
                hPricingBuffer = hPricingTable:DEFAULT-BUFFER-HANDLE.
                hPricingBuffer:FIND-FIRST().
                ASSIGN
                    dVprijs  = hPricingBuffer:BUFFER-FIELD("vprijs":u):BUFFER-VALUE
                    dAprijs  = hPricingBuffer:BUFFER-FIELD("aprijs":u):BUFFER-VALUE
                    dKorting = hPricingBuffer:BUFFER-FIELD("korting":u):BUFFER-VALUE
                    .
            END.

            ASSIGN
                dSubAantal = 1
                lSplitsen  = FALSE
                dOffAantal = 1
                .

            IF bOfflijn.groepnr NE 0 THEN
            DO:
                FIND FIRST bSubtotaalOfflijn OF pbOfferte
                    WHERE bSubtotaalOfflijn.groepnr   EQ bOfflijn.groepnr
                      AND bSubtotaalOfflijn.subtotaal EQ TRUE NO-LOCK NO-ERROR.
                IF AVAILABLE bSubtotaalOfflijn THEN
                DO:
                    dSubAantal = MAXIMUM(1, bSubtotaalOfflijn.aantal).
                    lSplitsen  = bSubtotaalOfflijn.splitsen.
                    IF dSubAantal GT 1 AND NOT lSplitsen THEN
                        dOffAantal = dSubAantal.
                END.
            END.

            lFirstCopyDone = FALSE.
            lAnyCopyMade   = FALSE.

            IF bOfflijn.groepnr NE 0 THEN
            DO:
                FOR EACH ttGroepExpansion
                    WHERE ttGroepExpansion.oldGroepnr EQ bOfflijn.groepnr
                    BY ttGroepExpansion.copyIndex:

                    lAnyCopyMade = TRUE.
                    iCopyGroepnr = ttGroepExpansion.newGroepnr.

                    ASSIGN
                        dAantalOpBonlijn = (IF dSubAantal GT 1 AND NOT lSplitsen THEN bOfflijn.aantal * dSubAantal ELSE bOfflijn.aantal)
                        dBedrag          = 0
                        iNewLijnnr       = VolgendeLijnnr()
                        .

                    IF lIsItemLijn THEN
                        dBedrag = ROUND(dAantalOpBonlijn * dVprijs * (1 - dKorting / 100), 2).

                    oBody = NEW JsonObject().
                    oBody:Add("artnr":u, bOfflijn.artnr).
                    oBody:Add("omschrijving":u, bOfflijn.omschr).
                    oBody:Add("aantal":u, dAantalOpBonlijn).
                    oBody:Add("teLeveren":u, bOfflijn.te-leveren).
                    oBody:Add("vprijs":u, dVprijs).
                    oBody:Add("aprijs":u, dAprijs).
                    oBody:Add("korting":u, dKorting).
                    oBody:Add("btwKode":u, bOfflijn.btw-kode).
                    oBody:Add("bedrag":u, dBedrag).
                    oBody:Add("klnr":u, bon.klnr).
                    oBody:Add("groepnr":u, iCopyGroepnr).
                    oBody:Add("subgroepnr":u, NieuwSubgroepnr(bOfflijn.subgroepnr)).
                    oBody:Add("hold":u, bOfflijn.hold).
                    oBody:Add("opm":u, bOfflijn.opm).
                    oBody:Add("kolomtitel":u, bOfflijn.kolomtitel).
                    oBody:Add("infolijn":u, bOfflijn.infolijn).
                    oBody:Add("subtotaal":u, FALSE).
                    oBody:Add("bestelDatum":u, bon.bestel-datum).
                    oBody:Add("levDatum":u, (IF bOfflijn.montage THEN bOfflijn.lev-dat ELSE bon.lev-dat)).
                    oBody:Add("stempel":u, "O":u).
                    oBody:Add("besteld":u, 0).
                    oBody:Add("offnr":u, pbOfferte.offnr).
                    oBody:Add("versie":u, pbOfferte.versie).
                    oBody:Add("olijnnr":u, bOfflijn.lijnnr).
                    oBody:Add("swLed":u, bOfflijn.swLed).
                    oBody:Add("swSikta":u, bOfflijn.swSikta).
                    oBody:Add("montage":u, bOfflijn.montage).
                    oBody:Add("ledmontage":u, bOfflijn.ledmontage).
                    oBody:Add("circuit":u, bOfflijn.circuit).
                    oBody:Add("recupel":u, bOfflijn.recupel).
                    oBody:Add("meer_min":u, bOfflijn.meer_min).
                    oBody:Add("off_aantal":u, dOffAantal).
                    oBody:Add("swStdPrijs":u, bOfflijn.swStdPrijs).
                    oBody:Add("uitverkoop":u, bOfflijn.uitverkoop).
                    oBody:Add("SiktaKleurKodes":u, bOfflijn.SiktaKleurKodes[1]).

                    IF NOT lIsItemLijn THEN
                        oBody:Add("gereserv":u, bOfflijn.te-leveren).

                    hResult = NEW BonLijnBE():CreateBonLijnInternal( iBonnr, oBody, iNewLijnnr ).

                    IF NOT lFirstCopyDone THEN
                    DO:
                        IF NOT CAN-FIND(FIRST ttLijnnrMap WHERE ttLijnnrMap.offLijnnr EQ bOfflijn.lijnnr) THEN
                        DO:
                            CREATE ttLijnnrMap.
                            ASSIGN
                                ttLijnnrMap.offLijnnr = bOfflijn.lijnnr
                                ttLijnnrMap.bonLijnnr = iNewLijnnr
                                .
                        END.
                        lFirstCopyDone = TRUE.
                    END.

                    VoegBtwInvoerlijnToe(bOfflijn.btw-kode, dBedrag, 0.0).

                END.
            END.

            IF NOT lAnyCopyMade THEN
            DO:
                iNewLijnnr = VolgendeLijnnr().

                dBedrag = 0.
                IF lIsItemLijn THEN
                    dBedrag = ROUND(bOfflijn.aantal * dVprijs * (1 - dKorting / 100), 2).

                oBody = NEW JsonObject().
                oBody:Add("artnr":u, bOfflijn.artnr).
                oBody:Add("omschrijving":u, bOfflijn.omschr).
                oBody:Add("aantal":u, bOfflijn.aantal).
                oBody:Add("teLeveren":u, bOfflijn.te-leveren).
                oBody:Add("vprijs":u, dVprijs).
                oBody:Add("aprijs":u, dAprijs).
                oBody:Add("korting":u, dKorting).
                oBody:Add("btwKode":u, bOfflijn.btw-kode).
                oBody:Add("bedrag":u, dBedrag).
                oBody:Add("klnr":u, bon.klnr).
                oBody:Add("groepnr":u, 0).
                oBody:Add("subgroepnr":u, NieuwSubgroepnr(bOfflijn.subgroepnr)).
                oBody:Add("hold":u, bOfflijn.hold).
                oBody:Add("opm":u, bOfflijn.opm).
                oBody:Add("kolomtitel":u, bOfflijn.kolomtitel).
                oBody:Add("infolijn":u, bOfflijn.infolijn).
                oBody:Add("subtotaal":u, FALSE).
                oBody:Add("bestelDatum":u, bon.bestel-datum).
                oBody:Add("levDatum":u, (IF bOfflijn.montage THEN bOfflijn.lev-dat ELSE bon.lev-dat)).
                oBody:Add("stempel":u, "O":u).
                oBody:Add("besteld":u, 0).
                oBody:Add("offnr":u, pbOfferte.offnr).
                oBody:Add("versie":u, pbOfferte.versie).
                oBody:Add("olijnnr":u, bOfflijn.lijnnr).
                oBody:Add("swLed":u, bOfflijn.swLed).
                oBody:Add("swSikta":u, bOfflijn.swSikta).
                oBody:Add("montage":u, bOfflijn.montage).
                oBody:Add("ledmontage":u, bOfflijn.ledmontage).
                oBody:Add("circuit":u, bOfflijn.circuit).
                oBody:Add("recupel":u, bOfflijn.recupel).
                oBody:Add("meer_min":u, bOfflijn.meer_min).
                oBody:Add("off_aantal":u, 1).
                oBody:Add("swStdPrijs":u, bOfflijn.swStdPrijs).
                oBody:Add("uitverkoop":u, bOfflijn.uitverkoop).
                oBody:Add("SiktaKleurKodes":u, bOfflijn.SiktaKleurKodes[1]).

                IF NOT lIsItemLijn THEN
                    oBody:Add("gereserv":u, bOfflijn.te-leveren).

                hResult = NEW BonLijnBE():CreateBonLijnInternal( iBonnr, oBody, iNewLijnnr ).

                CREATE ttLijnnrMap.
                ASSIGN
                    ttLijnnrMap.offLijnnr = bOfflijn.lijnnr
                    ttLijnnrMap.bonLijnnr = iNewLijnnr
                    .

                VoegBtwInvoerlijnToe(bOfflijn.btw-kode, dBedrag, 0.0).

            END.

            FIND CURRENT bOfflijn EXCLUSIVE-LOCK.
            ASSIGN
                bOfflijn.stempel    = "D":u
                bOfflijn.te-leveren = 0
                .

            iAantalLijnenOvergenomen = iAantalLijnenOvergenomen + 1.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: LED-copy (design doc step 8). For every offerte groepnr
                 recorded in ttLedGroepMap, copies every off_led row under
                 that groepnr to a new bon_led row under the corresponding
                 new bon groepnr, relinking doc-lijnnr via ttLijnnrMap and
                 recalculating prijs/montage-prijs from the linked
                 artikel's current vprijs/montage-prijs. Also handles the
                 "deadline-lijn" exception (led_lijn = 0 AND lijnnr = 30):
                 creates an extra kolomtitel bonlijn at
                 (gekoppelde-bonlijn.lijnnr + 100).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyLedLijnen( BUFFER pbOfferte FOR offerte ):

        DEFINE BUFFER bOffLed  FOR off_led.
        DEFINE BUFFER bArtikel FOR artikel.
        DEFINE VARIABLE iDocLijnnr AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO.

        FOR EACH ttLedGroepMap:

            FOR EACH bOffLed NO-LOCK
                WHERE bOffLed.offnr   EQ pbOfferte.offnr
                  AND bOffLed.versie  EQ pbOfferte.versie
                  AND bOffLed.groepnr EQ ttLedGroepMap.offGroepnr:

                iDocLijnnr = 0.
                IF bOffLed.doc-lijnnr NE 0 THEN
                DO:
                    FIND FIRST ttLijnnrMap WHERE ttLijnnrMap.offLijnnr EQ bOffLed.doc-lijnnr NO-ERROR.
                    IF AVAILABLE ttLijnnrMap THEN
                        iDocLijnnr = ttLijnnrMap.bonLijnnr.
                END.

                CREATE bon_led.
                ASSIGN
                    bon_led.bonnr              = iBonnr
                    bon_led.groepnr            = ttLedGroepMap.bonGroepnr
                    bon_led.led_lijn           = bOffLed.led_lijn
                    bon_led.lijnnr             = bOffLed.lijnnr
                    bon_led.artnr              = bOffLed.artnr
                    bon_led.lengte             = bOffLed.lengte
                    bon_led.gereserv           = bOffLed.gereserv
                    bon_led.prijs              = bOffLed.prijs
                    bon_led.datum              = bOffLed.datum
                    bon_led.opm                = bOffLed.opm
                    bon_led.switch1            = bOffLed.switch1
                    bon_led.circuit            = bOffLed.circuit
                    bon_led.soort              = bOffLed.soort
                    bon_led.aantal             = bOffLed.aantal
                    bon_led.Lmaat              = bOffLed.Lmaat
                    bon_led.Rmaat              = bOffLed.Rmaat
                    bon_led.switch2            = bOffLed.switch2
                    bon_led.comp               = bOffLed.comp
                    bon_led.reflector          = bOffLed.reflector
                    bon_led.lev-dat            = bOffLed.lev-dat
                    bon_led.bestel-dat         = bOffLed.bestel-dat
                    bon_led.montage-datum      = bOffLed.montage-datum
                    bon_led.montage-prijs      = bOffLed.montage-prijs
                    bon_led.sturing            = bOffLed.sturing
                    bon_led.doc-lijnnr         = iDocLijnnr
                    bon_led.controle           = bOffLed.controle
                    bon_led.voorraad           = bOffLed.voorraad
                    bon_led.besteld            = bOffLed.besteld
                    bon_led.te-leveren         = bOffLed.te-leveren
                    bon_led.swEffectief        = bOffLed.swEffectief
                    bon_led.kode               = bOffLed.kode
                    bon_led.swPreconfig        = bOffLed.swPreconfig
                    bon_led.swStdPrijs         = bOffLed.swStdPrijs
                    bon_led.locatie            = bOffLed.locatie
                    bon_led.prebesteld         = bOffLed.prebesteld
                    bon_led.effectief-gereserv = bOffLed.effectief-gereserv
                    bon_led.SiktaKleurKodes[1] = bOffLed.SiktaKleurKodes[1]
                    .

                FIND FIRST bArtikel NO-LOCK WHERE bArtikel.artnr EQ bOffLed.artnr NO-ERROR.
                IF AVAILABLE bArtikel THEN
                    ASSIGN
                        bon_led.prijs         = bArtikel.vprijs
                        bon_led.montage-prijs = bArtikel.montage-prijs
                        .

                iAantalLedLijnenOvergenomen = iAantalLedLijnenOvergenomen + 1.

                IF bOffLed.led_lijn EQ 0 AND bOffLed.lijnnr EQ 30 AND iDocLijnnr NE 0 THEN
                DO:
                    oBody = NEW JsonObject().
                    oBody:Add("kolomtitel":u, TRUE).
                    oBody:Add("stempel":u, "O":u).
                    oBody:Add("klnr":u, bon.klnr).
                    oBody:Add("bestelDatum":u, bon.bestel-datum).
                    oBody:Add("offnr":u, pbOfferte.offnr).
                    oBody:Add("versie":u, pbOfferte.versie).

                    hResult = NEW BonLijnBE():CreateBonLijnInternal( iBonnr, oBody, iDocLijnnr + 100 ).
                END.

            END.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Gathers every newly created bonlijn's btw-kode/bedrag/
                 totaal-recupel (already accumulated incrementally into
                 hBtwInvoerLijnen by the pass methods) and calls
                 BtwBerekeningBE:BerekenBtw() once, writing the result onto
                 bon.tot-btw / bon.b-bedrag and this instance's
                 dResultTotBtw/dResultTotaalBasis/dResultTotaalInclBtw for
                 the response.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BerekenEnSchrijfBtw( BUFFER pbOfferte FOR offerte ):

        DEFINE BUFFER bBtwRegime FOR btw-regime.
        DEFINE BUFFER bSyspara   FOR syspara.
        DEFINE VARIABLE lSwRegime             AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lSwPrijsRecup         AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cTypeKortingBtw       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dDocKortingBedrag     AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dDocKortingPercentage AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE hResultaatDataset     AS HANDLE    NO-UNDO.
        DEFINE VARIABLE hTotaalBuffer         AS HANDLE    NO-UNDO.

        FIND FIRST bBtwRegime NO-LOCK WHERE bBtwRegime.kode EQ bon.btw-reg NO-ERROR.
        lSwRegime = (IF AVAILABLE bBtwRegime THEN bBtwRegime.sw1 ELSE TRUE).

        FIND FIRST bSyspara NO-LOCK NO-ERROR.
        lSwPrijsRecup = (IF AVAILABLE bSyspara THEN bSyspara.swRecupel ELSE FALSE) AND lSwRecupel.

        IF cTypeKortingOfferte BEGINS "K3":u THEN
            ASSIGN
                cTypeKortingBtw   = "K3":u
                dDocKortingBedrag = pbOfferte.korting
                .
        ELSE IF cTypeKortingOfferte BEGINS "K5":u THEN
            ASSIGN
                cTypeKortingBtw       = "K5":u
                dDocKortingPercentage = pbOfferte.korting
                .
        ELSE
            cTypeKortingBtw = "":u.

        /* Reuses oBtwService (the same instance that owns hBtwInvoerLijnen)
           rather than a fresh NEW BtwBerekeningBE() - see the field's
           declaration comment. */
        hResultaatDataset = oBtwService:BerekenBtw(
            hBtwInvoerLijnen, lSwRegime, lSwPrijsRecup,
            cTypeKortingBtw, dDocKortingBedrag, dDocKortingPercentage).

        hTotaalBuffer = hResultaatDataset:GET-BUFFER-HANDLE("ttBtwTotaal":u).
        hTotaalBuffer:FIND-FIRST().

        ASSIGN
            dResultTotBtw        = hTotaalBuffer:BUFFER-FIELD("totBtw":u):BUFFER-VALUE
            dResultTotaalBasis   = hTotaalBuffer:BUFFER-FIELD("totaalBasis":u):BUFFER-VALUE
            dResultTotaalInclBtw = hTotaalBuffer:BUFFER-FIELD("totaalInclBtw":u):BUFFER-VALUE
            bon.tot-btw          = dResultTotBtw
            bon.b-bedrag         = dResultTotaalBasis
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Marks the offerte as (partially) converted: verkocht =
                 TRUE, verkochtdatum = TODAY (bevestigde afwijking van
                 legacy), stempel = "D" if every offlijn now has stempel
                 "D", otherwise "B" (partially delivered/converted).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID FinalizeOfferte( BUFFER pbOfferte FOR offerte ):

        ASSIGN
            pbOfferte.verkochtdatum = TODAY
            pbOfferte.verkocht      = TRUE
            .

        IF NOT CAN-FIND(FIRST offlijn OF pbOfferte WHERE offlijn.stempel NE "D":u) THEN
            pbOfferte.stempel = "D":u.
        ELSE
            pbOfferte.stempel = "B":u.

    END METHOD.

END CLASS.
