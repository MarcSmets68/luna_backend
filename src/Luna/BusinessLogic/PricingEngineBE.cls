/*------------------------------------------------------------------------
    File        : PricingEngineBE.cls
    Purpose     : Pure read-only pricing service (Iteratie A, K1-K5). Does
                  NOT write to offlijn/bonlijn or any other table - it only
                  looks up existing discount/price/promotion data and
                  returns a single computed result. 1:1 port of the legacy
                  `Include/Prijs.i` procedures (CprijsI/GprijsI/AprijsI) plus
                  the promotie ("actie") override that 4 independent legacy
                  call sites apply after those three, verified against
                  \\LHDC01\TESTLUNA$\LunaV12\Include\Prijs.i and
                  docs/db-analysis/schema_dump.txt (korting, art_prijs,
                  art_netto, artlijn, lever-voorzet, actie, syspara,
                  art_profiel tables).

    Deliberate simplifications vs. the legacy procedures (all documented
    inline at the point they're applied too):
      1. sw-uitverkoop (legacy CprijsI/GprijsI parameter) is always treated
         as TRUE here - i.e. artikel.uitverkoop alone decides the
         uitverkoop-override/early-return, exactly as if the legacy caller
         had always passed sw-uitverkoop = TRUE. No caller of this service
         needs to opt out of uitverkoop pricing in this iteration.
      2. iplGroep (legacy CprijsI "Ticket 471a" parameter, swGroep on the
         korting lookup) is always FALSE here - no caller passes a
         groepconfiguratie context in this iteration. A later iteration
         (LED-config context) may need to pass TRUE.
      3. sw-LedConfig (legacy global that gates the profielgroep-based
         korting-lookup steps) is not read here - instead, exactly as
         confirmed in the architect analysis, the presence/absence of an
         art_profiel record for the artikel (which supplies profielgroep)
         is what gates those steps, matching CprijsI's own
         `profgroep <> ""` guard.
      4. PasPromotieToe's plLocked output does not try to preserve a
         "some other rule already locked this" state from BepaalKorting -
         BepaalKorting always returns plLocked = FALSE for every
         typeKorting (K1-K5 - see BepaalKorting), so the simplest
         consistent behaviour is: kortingLocked in the final result is
         TRUE iff the promotie is actief. Documented again at
         PasPromotieToe itself.

    Syntax      : Called from Luna.Web.PricingHandler (POST
                  /web/pricing/bereken).
    Description : The only layer allowed to touch the DB for this
                  feature - NO-LOCK throughout, no transaction (read-only).
    Author(s)   : Devin
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.PricingEngineBE:

    DEFINE TEMP-TABLE ttPricingResult NO-UNDO SERIALIZE-NAME "pricing":u
        FIELD artnr               AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD klnr                AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD aantal              AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD vprijs              AS DECIMAL   SERIALIZE-NAME "vprijs":u
        FIELD aprijs              AS DECIMAL   SERIALIZE-NAME "aprijs":u
        FIELD korting             AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD kortingLocked       AS LOGICAL   SERIALIZE-NAME "kortingLocked":u
        FIELD promotieActief      AS LOGICAL   SERIALIZE-NAME "promotieActief":u
        FIELD nettoPrijsToegepast AS LOGICAL   SERIALIZE-NAME "nettoPrijsToegepast":u
        FIELD uitverkoopToegepast AS LOGICAL   SERIALIZE-NAME "uitverkoopToegepast":u
        INDEX idx-pk IS PRIMARY artnr klnr.

    /*------------------------------------------------------------------------------
        Purpose: Returns the "voorzetsel" (article-prefix) used throughout
                 the pricing lookups: the part of the artnr up to and
                 including the first "." - exactly the legacy
                 `SUBSTRING(artnr,1,INDEX(artnr,"."))` (empty string if
                 there is no "." in the artnr, since INDEX then returns 0
                 and SUBSTRING(x,1,0) = "").
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER Voorzetsel( INPUT pcArtnr AS CHARACTER ):

        DEFINE VARIABLE iDot AS INTEGER NO-UNDO.

        iDot = INDEX(pcArtnr, ".":u).

        IF iDot EQ 0 THEN
            RETURN "":u.

        RETURN SUBSTRING(pcArtnr, 1, iDot).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Orchestrates the full pricing calculation for one
                 artnr/klnr/aantal/typeKorting combination, in the fixed
                 order BepaalKorting -> BepaalVerkoopprijs ->
                 BepaalAankoopprijs -> PasPromotieToe. Returns a HANDLE to
                 a 1-row ttPricingResult.
        Errors : AppError 400 - pcTypeKorting is not one of K1..K5.
                 AppError 404 - pcArtnr does not exist in artikel.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE BerekenPrijs(
        INPUT pcArtnr           AS CHARACTER,
        INPUT piKlnr            AS INTEGER,
        INPUT pdAantal          AS DECIMAL,
        INPUT pcTypeKorting     AS CHARACTER,
        INPUT pdDocumentKorting AS DECIMAL ):

        DEFINE VARIABLE dKorting             AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dVerkoopprijs        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dAankoopprijs        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE lKortingLocked       AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lNettoPrijsToegepast AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lUitverkoopToegepast AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lPromotieActief      AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lPromoLocked         AS LOGICAL NO-UNDO.

        IF LOOKUP(pcTypeKorting, "K1,K2,K3,K4,K5":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Unknown typeKorting '&1', expected K1-K5":u, pcTypeKorting), 400).

        IF NOT CAN-FIND(FIRST artikel WHERE artikel.artnr EQ pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 not found":u, pcArtnr), 404).

        dKorting      = BepaalKorting(pcArtnr, piKlnr, pdAantal, pcTypeKorting, pdDocumentKorting, OUTPUT lKortingLocked).
        dVerkoopprijs = BepaalVerkoopprijs(pcArtnr, piKlnr, pdAantal, OUTPUT lNettoPrijsToegepast, OUTPUT lUitverkoopToegepast).
        dAankoopprijs = BepaalAankoopprijs(pcArtnr, pdAantal, dVerkoopprijs).

        PasPromotieToe(pcArtnr, INPUT-OUTPUT dVerkoopprijs, INPUT-OUTPUT dKorting,
            OUTPUT lPromotieActief, OUTPUT lPromoLocked).

        EMPTY TEMP-TABLE ttPricingResult.
        CREATE ttPricingResult.
        ASSIGN
            ttPricingResult.artnr               = pcArtnr
            ttPricingResult.klnr                = piKlnr
            ttPricingResult.aantal              = pdAantal
            ttPricingResult.vprijs              = dVerkoopprijs
            ttPricingResult.aprijs              = dAankoopprijs
            ttPricingResult.korting             = dKorting
            /* BepaalKorting always returns plLocked = FALSE for every
               typeKorting - see its header comment - so the lock state of
               the final result is entirely driven by the promotie
               override. Kept as an OR so a future BepaalKorting change
               that does start locking doesn't silently get lost here. */
            ttPricingResult.kortingLocked       = lKortingLocked OR lPromoLocked
            ttPricingResult.promotieActief      = lPromotieActief
            ttPricingResult.nettoPrijsToegepast = lNettoPrijsToegepast
            ttPricingResult.uitverkoopToegepast = lUitverkoopToegepast
            .

        RETURN TEMP-TABLE ttPricingResult:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: 1:1 port of legacy CprijsI (Include/Prijs.i). K3 returns 0
                 (the fixed document-level amount itself is out of scope -
                 a later iteration's concern). K4/K5 pass pdDocumentKorting
                 straight through unchanged. K1/K2 both run the identical
                 15-step klnr/artnr hierarchy lookup against `korting`,
                 capped by lever-voorzet.maxKorting.
        Notes  : plLocked is always FALSE from this method - none of
                 K1-K5's own discount-lookup rules lock the result; only
                 PasPromotieToe can lock it (see BerekenPrijs).
                 sw-uitverkoop is assumed TRUE (see class header note 1).
                 iplGroep is assumed FALSE (see class header note 2).
                 sw-LedConfig is replaced by "does an art_profiel record
                 exist for this artikel" (see class header note 3).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL BepaalKorting(
        INPUT pcArtnr AS CHARACTER, INPUT piKlnr AS INTEGER, INPUT pdAantal AS DECIMAL,
        INPUT pcTypeKorting AS CHARACTER, INPUT pdDocumentKorting AS DECIMAL,
        OUTPUT plLocked AS LOGICAL ):

        DEFINE BUFFER bArtikel FOR artikel.

        DEFINE VARIABLE dHoev        AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cKlkode      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKlstr       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cArtstr      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cVoorzetsel  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cProfgroep   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dMaxKorting  AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dKorting     AS DECIMAL   NO-UNDO.

        plLocked = FALSE.

        IF pcTypeKorting EQ "K3":u THEN
            RETURN 0.

        IF pcTypeKorting EQ "K4":u OR pcTypeKorting EQ "K5":u THEN
            RETURN pdDocumentKorting.

        /* K1/K2 - identical 15-step hierarchy lookup. */
        dHoev = pdAantal.
        IF dHoev LT 1 THEN dHoev = 1.

        cKlkode = STRING(piKlnr).

        FIND FIRST bArtikel NO-LOCK WHERE bArtikel.artnr EQ pcArtnr NO-ERROR.
        IF AVAILABLE bArtikel THEN
        DO:
            ASSIGN
                cArtstr     = bArtikel.groep
                cVoorzetsel = Voorzetsel(pcArtnr)
                .

            IF bArtikel.uitverkoop THEN
                RETURN bArtikel.korting.

            FIND FIRST art_profiel NO-LOCK WHERE art_profiel.artnr EQ bArtikel.artnr NO-ERROR.
            IF AVAILABLE art_profiel THEN
                cProfgroep = art_profiel.profielgroep.
            ELSE
                cProfgroep = "":u.
        END.
        ELSE
            ASSIGN
                cArtstr     = "*":u
                cVoorzetsel = "":u
                cProfgroep  = "":u
                .

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.
        IF AVAILABLE klant THEN
            cKlstr = klant.soort.
        ELSE
            cKlstr = "*":u.
        IF cKlstr EQ "":u THEN
            cKlstr = "*":u.

        FIND FIRST lever-voorzet NO-LOCK WHERE lever-voorzet.voorzetsel EQ cVoorzetsel NO-ERROR.
        IF AVAILABLE lever-voorzet THEN
            dMaxKorting = lever-voorzet.maxKorting.
        ELSE
            dMaxKorting = 0.

        FIND FIRST korting NO-LOCK
            WHERE korting.klnr EQ cKlkode AND korting.artnr EQ pcArtnr AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting AND cProfgroep NE "":u THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlkode AND korting.artnr EQ cProfgroep AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlkode AND korting.artnr EQ cVoorzetsel AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlkode AND korting.artnr EQ cArtstr AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlkode AND korting.artnr EQ "*":u AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlstr AND korting.artnr EQ pcArtnr AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting AND cProfgroep NE "":u THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlstr AND korting.artnr EQ cProfgroep AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlstr AND korting.artnr EQ cVoorzetsel AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlstr AND korting.artnr EQ cArtstr AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ cKlstr AND korting.artnr EQ "*":u AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ "*":u AND korting.artnr EQ pcArtnr AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting AND cProfgroep NE "":u THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ "*":u AND korting.artnr EQ cProfgroep AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ "*":u AND korting.artnr EQ cVoorzetsel AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ "*":u AND korting.artnr EQ cArtstr AND korting.swGroep EQ FALSE NO-ERROR.

        IF NOT AVAILABLE korting THEN
            FIND FIRST korting NO-LOCK
                WHERE korting.klnr EQ "*":u AND korting.artnr EQ "*":u AND korting.swGroep EQ FALSE NO-ERROR.

        IF AVAILABLE korting THEN
        DO:
            dKorting = korting.korting.
            IF dMaxKorting GT 0 AND dMaxKorting LT dKorting THEN
                dKorting = dMaxKorting.
        END.
        ELSE
            dKorting = 0.

        RETURN dKorting.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: 1:1 port of legacy GprijsI (Include/Prijs.i): base
                 verkoopprijs, composite-BOM recomputation, exact-match
                 art_netto override, uitverkoop override.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL BepaalVerkoopprijs(
        INPUT pcArtnr AS CHARACTER, INPUT piKlnr AS INTEGER, INPUT pdAantal AS DECIMAL,
        OUTPUT plNettoPrijsToegepast AS LOGICAL,
        OUTPUT plUitverkoopToegepast AS LOGICAL ):

        DEFINE BUFFER bArtikel    FOR artikel.
        DEFINE BUFFER bAltArtikel FOR artikel.

        DEFINE VARIABLE dVprijs        AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dWPrijs        AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dHoev          AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dDeHoev        AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cArtnrMontage  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKlantSoort    AS CHARACTER NO-UNDO.

        plNettoPrijsToegepast = FALSE.
        plUitverkoopToegepast = FALSE.

        FIND FIRST bArtikel NO-LOCK WHERE bArtikel.artnr EQ pcArtnr NO-ERROR.
        IF NOT AVAILABLE bArtikel THEN
            RETURN 0.

        dVprijs = bArtikel.vprijs.

        IF bArtikel.soort THEN
        DO:
            /* Composite (BOM) article - avoid divide-by-zero, analogous to
               the korting-lookup clamp (see BepaalKorting). */
            dHoev = pdAantal.
            IF dHoev LT 1 THEN dHoev = 1.

            FIND FIRST syspara NO-LOCK NO-ERROR.
            IF AVAILABLE syspara THEN
                cArtnrMontage = syspara.artnr-WBmontage.
            ELSE
                cArtnrMontage = "":u.

            dWPrijs = 0.
            FOR EACH artlijn OF bArtikel NO-LOCK
                WHERE NOT CAN-FIND(FIRST artikel WHERE artikel.artnr EQ artlijn.l-artnr AND artikel.swZoekblok EQ TRUE):

                FIND FIRST bAltArtikel NO-LOCK WHERE bAltArtikel.artnr EQ artlijn.l-artnr NO-ERROR.
                IF AVAILABLE bAltArtikel THEN
                DO:
                    IF artlijn.swVast AND bAltArtikel.artnr NE cArtnrMontage THEN
                        dDeHoev = 1.
                    ELSE IF artlijn.swVast AND bAltArtikel.artnr EQ cArtnrMontage THEN
                        dDeHoev = MAXIMUM(1, dHoev).
                    ELSE
                        dDeHoev = dHoev.

                    dWPrijs = dWPrijs + (dDeHoev * (artlijn.aantal * bAltArtikel.vprijs)).
                END.
            END.

            dVprijs = dWPrijs / dHoev.
        END.

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.
        IF AVAILABLE klant THEN
            cKlantSoort = klant.soort.
        ELSE
            cKlantSoort = "":u.

        IF cKlantSoort NE "":u THEN
        DO:
            FIND FIRST art_netto NO-LOCK
                WHERE art_netto.artnr EQ pcArtnr
                AND   art_netto.soort EQ cKlantSoort
                AND   art_netto.aantal EQ pdAantal NO-ERROR.
            IF AVAILABLE art_netto THEN
                ASSIGN
                    dVprijs               = art_netto.vprijs
                    plNettoPrijsToegepast = TRUE
                    .
        END.

        IF bArtikel.uitverkoop AND bArtikel.uit-prijs NE 0 THEN
            ASSIGN
                dVprijs               = bArtikel.uit-prijs / 1.21
                plUitverkoopToegepast = TRUE
                .

        RETURN dVprijs.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: 1:1 port of legacy AprijsI (Include/Prijs.i): staffel
                 art_prijs lookup, composite-BOM recomputation (using
                 component aprijs), lever/lever-voorzet-based fallback.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL BepaalAankoopprijs(
        INPUT pcArtnr AS CHARACTER, INPUT pdAantal AS DECIMAL, INPUT pdVerkoopprijs AS DECIMAL ):

        DEFINE BUFFER bArtikel    FOR artikel.
        DEFINE BUFFER bAltArtikel FOR artikel.

        DEFINE VARIABLE dAprijs       AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dWPrijs       AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dHoev         AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dDeHoev       AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cArtnrMontage AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dBasis        AS DECIMAL   NO-UNDO.

        FIND FIRST bArtikel NO-LOCK WHERE bArtikel.artnr EQ pcArtnr NO-ERROR.
        IF NOT AVAILABLE bArtikel THEN
            RETURN 0.

        dHoev = pdAantal.
        IF dHoev LT 1 THEN dHoev = 1.

        FIND LAST art_prijs NO-LOCK
            WHERE art_prijs.artnr EQ pcArtnr AND art_prijs.aantal LE dHoev NO-ERROR.
        IF AVAILABLE art_prijs THEN
            dAprijs = art_prijs.aprijs.
        ELSE
            dAprijs = 0.

        IF dAprijs EQ 0 THEN
        DO:
            IF bArtikel.soort THEN
            DO:
                FIND FIRST syspara NO-LOCK NO-ERROR.
                IF AVAILABLE syspara THEN
                    cArtnrMontage = syspara.artnr-WBmontage.
                ELSE
                    cArtnrMontage = "":u.

                dWPrijs = 0.
                FOR EACH artlijn OF bArtikel NO-LOCK
                    WHERE NOT CAN-FIND(FIRST artikel WHERE artikel.artnr EQ artlijn.l-artnr AND artikel.swZoekblok EQ TRUE):

                    FIND FIRST bAltArtikel NO-LOCK WHERE bAltArtikel.artnr EQ artlijn.l-artnr NO-ERROR.
                    IF AVAILABLE bAltArtikel THEN
                    DO:
                        IF artlijn.swVast AND bAltArtikel.artnr NE cArtnrMontage THEN
                            dDeHoev = 1.
                        ELSE IF artlijn.swVast AND bAltArtikel.artnr EQ cArtnrMontage THEN
                            dDeHoev = MAXIMUM(1, dHoev).
                        ELSE
                            dDeHoev = dHoev.

                        dWPrijs = dWPrijs + (dDeHoev * (artlijn.aantal * bAltArtikel.aprijs)).
                    END.
                END.

                dAprijs = dWPrijs / dHoev.
            END.
            ELSE
            DO:
                IF bArtikel.aprijs EQ 0 THEN
                DO:
                    FIND FIRST lever NO-LOCK WHERE lever.levnr EQ bArtikel.levnr NO-ERROR.
                    IF AVAILABLE lever THEN
                    DO:
                        FIND FIRST lever-voorzet NO-LOCK
                            WHERE lever-voorzet.levnr EQ bArtikel.levnr
                            AND   bArtikel.artnr BEGINS lever-voorzet.voorzetsel NO-ERROR.
                        IF AVAILABLE lever-voorzet AND lever-voorzet.swNoAankoop EQ FALSE THEN
                        DO:
                            IF bArtikel.vprijs EQ 0 THEN
                                dBasis = pdVerkoopprijs.
                            ELSE
                                dBasis = bArtikel.vprijs.

                            dAprijs = dBasis - (dBasis * lever-voorzet.korting / 100).
                        END.
                    END.
                END.
                ELSE
                    dAprijs = bArtikel.aprijs.
            END.
        END.

        RETURN dAprijs.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies an active promotie ("actie") override on top of the
                 verkoopprijs/korting already computed, confirmed against 4
                 independent legacy call sites.
        Notes  : plLocked simplification (see class header note 4) - since
                 BepaalKorting never locks the result itself, plLocked here
                 is simply set equal to plPromotieActief: TRUE only when an
                 active promotie actually overrides the price.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID PasPromotieToe(
        INPUT pcArtnr AS CHARACTER,
        INPUT-OUTPUT pdVerkoopprijs AS DECIMAL,
        INPUT-OUTPUT pdKorting AS DECIMAL,
        OUTPUT plPromotieActief AS LOGICAL,
        OUTPUT plLocked AS LOGICAL ):

        FIND FIRST actie NO-LOCK
            WHERE actie.artnr EQ pcArtnr
            AND   actie.vdatum LE TODAY
            AND   actie.tdatum GE TODAY NO-ERROR.

        IF AVAILABLE actie AND actie.vprijs NE 0 THEN
            ASSIGN
                pdVerkoopprijs   = actie.vprijs
                pdKorting        = 0
                plPromotieActief = TRUE
                plLocked          = TRUE
                .
        ELSE
            ASSIGN
                plPromotieActief = FALSE
                plLocked          = FALSE
                .

    END METHOD.

END CLASS.
