/*------------------------------------------------------------------------
    File        : PakLijnBE.cls
    Purpose     : Business Entity for the "paklijn" (packing slip line)
                  table - full CRUD for a curated core subset of fields,
                  child of pakbon (linked via paknr), mirroring
                  Luna.BusinessLogic.BonLijnBE's pattern. Also backs the
                  read-only GET /web/bon/{bonnr}/lijn/{lijnnr}/pakbonnen
                  reverse lookup (via the paklijn-x4 index on bonnr).
                  `paklijn` has 44 fields in total; only the subset below
                  is exposed via the API.
    Field map (JSON key -> paklijn column):
                  paknr      -> paknr      (PK, from parent path, immutable)
                  lijnnr     -> lijnnr     (PK, server-generated on create)
                  groepnr    -> groepnr
                  subgroepnr -> subgroepnr
                  artnr      -> artnr
                  omschr     -> omschr
                  aantal     -> aantal
                  teLeveren  -> te-leveren
                  afgehaald  -> afgehaald
                  vprijs     -> vprijs
                  aprijs     -> aprijs
                  korting    -> korting
                  btwKode    -> btw-kode
                  bedrag     -> bedrag
                  stempel    -> stempel
                  klnr       -> klnr
                  bonnr      -> bonnr
                  blijnnr    -> blijnnr
                  hold       -> hold
                  swLed      -> swLed
                  swSikta    -> swSikta
                  subtotaal  -> subtotaal
                  kolomtitel -> kolomtitel
                  infolijn   -> infolijn
                  opm        -> opm
    Syntax      : Called from Luna.Web.PakbonHandler
                  (/web/pakbon/{paknr}/lijn[/{lijnnr}]) and
                  Luna.Web.BonHandler
                  (/web/bon/{bonnr}/lijn/{lijnnr}/pakbonnen)
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.PakLijnBE:

    DEFINE TEMP-TABLE ttPakLijn NO-UNDO SERIALIZE-NAME "items":u
        FIELD paknr      AS INTEGER   SERIALIZE-NAME "paknr":u
        FIELD lijnnr     AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD groepnr    AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD subgroepnr AS INTEGER   SERIALIZE-NAME "subgroepnr":u
        FIELD artnr      AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschr     AS CHARACTER SERIALIZE-NAME "omschr":u
        FIELD aantal     AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD teLeveren  AS DECIMAL   SERIALIZE-NAME "teLeveren":u
        FIELD afgehaald  AS DECIMAL   SERIALIZE-NAME "afgehaald":u
        FIELD vprijs     AS DECIMAL   SERIALIZE-NAME "vprijs":u
        FIELD aprijs     AS DECIMAL   SERIALIZE-NAME "aprijs":u
        FIELD korting    AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD btwKode    AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD bedrag     AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD stempel    AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD klnr       AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD bonnr      AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD blijnnr    AS INTEGER   SERIALIZE-NAME "blijnnr":u
        FIELD hold       AS LOGICAL   SERIALIZE-NAME "hold":u
        FIELD swLed      AS LOGICAL   SERIALIZE-NAME "swLed":u
        FIELD swSikta    AS LOGICAL   SERIALIZE-NAME "swSikta":u
        FIELD subtotaal  AS LOGICAL   SERIALIZE-NAME "subtotaal":u
        FIELD kolomtitel AS LOGICAL   SERIALIZE-NAME "kolomtitel":u
        FIELD infolijn   AS LOGICAL   SERIALIZE-NAME "infolijn":u
        FIELD opm        AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-lijnnr IS PRIMARY paknr lijnnr.

    METHOD PRIVATE VOID EnsurePakbonExists( INPUT piPaknr AS INTEGER ):

        FIND FIRST pakbon NO-LOCK WHERE pakbon.paknr EQ piPaknr NO-ERROR.
        IF NOT AVAILABLE pakbon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Pakbon &1 not found":u, piPaknr), 404).

    END METHOD.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbPakLijn FOR paklijn, BUFFER pbTt FOR ttPakLijn ):

        ASSIGN
            pbTt.paknr      = pbPakLijn.paknr
            pbTt.lijnnr     = pbPakLijn.lijnnr
            pbTt.groepnr    = pbPakLijn.groepnr
            pbTt.subgroepnr = pbPakLijn.subgroepnr
            pbTt.artnr      = pbPakLijn.artnr
            pbTt.omschr     = pbPakLijn.omschr
            pbTt.aantal     = pbPakLijn.aantal
            pbTt.teLeveren  = pbPakLijn.te-leveren
            pbTt.afgehaald  = pbPakLijn.afgehaald
            pbTt.vprijs     = pbPakLijn.vprijs
            pbTt.aprijs     = pbPakLijn.aprijs
            pbTt.korting    = pbPakLijn.korting
            pbTt.btwKode    = pbPakLijn.btw-kode
            pbTt.bedrag     = pbPakLijn.bedrag
            pbTt.stempel    = pbPakLijn.stempel
            pbTt.klnr       = pbPakLijn.klnr
            pbTt.bonnr      = pbPakLijn.bonnr
            pbTt.blijnnr    = pbPakLijn.blijnnr
            pbTt.hold       = pbPakLijn.hold
            pbTt.swLed      = pbPakLijn.swLed
            pbTt.swSikta    = pbPakLijn.swSikta
            pbTt.subtotaal  = pbPakLijn.subtotaal
            pbTt.kolomtitel = pbPakLijn.kolomtitel
            pbTt.infolijn   = pbPakLijn.infolijn
            pbTt.opm        = pbPakLijn.opm
            .

    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbPakLijn FOR paklijn ):

        IF poBody:Has("groepnr":u)    THEN pbPakLijn.groepnr    = poBody:GetInteger("groepnr":u).
        IF poBody:Has("subgroepnr":u) THEN pbPakLijn.subgroepnr = poBody:GetInteger("subgroepnr":u).
        IF poBody:Has("artnr":u)      THEN pbPakLijn.artnr      = poBody:GetCharacter("artnr":u).
        IF poBody:Has("omschr":u)     THEN pbPakLijn.omschr     = poBody:GetCharacter("omschr":u).
        IF poBody:Has("aantal":u)     THEN pbPakLijn.aantal     = poBody:GetDecimal("aantal":u).
        IF poBody:Has("teLeveren":u)  THEN pbPakLijn.te-leveren = poBody:GetDecimal("teLeveren":u).
        IF poBody:Has("afgehaald":u)  THEN pbPakLijn.afgehaald  = poBody:GetDecimal("afgehaald":u).
        IF poBody:Has("vprijs":u)     THEN pbPakLijn.vprijs     = poBody:GetDecimal("vprijs":u).
        IF poBody:Has("aprijs":u)     THEN pbPakLijn.aprijs     = poBody:GetDecimal("aprijs":u).
        IF poBody:Has("korting":u)    THEN pbPakLijn.korting    = poBody:GetDecimal("korting":u).
        IF poBody:Has("btwKode":u)    THEN pbPakLijn.btw-kode   = poBody:GetCharacter("btwKode":u).
        IF poBody:Has("bedrag":u)     THEN pbPakLijn.bedrag     = poBody:GetDecimal("bedrag":u).
        IF poBody:Has("stempel":u)    THEN pbPakLijn.stempel    = poBody:GetCharacter("stempel":u).
        IF poBody:Has("klnr":u)       THEN pbPakLijn.klnr       = poBody:GetInteger("klnr":u).
        IF poBody:Has("bonnr":u)      THEN pbPakLijn.bonnr      = poBody:GetInteger("bonnr":u).
        IF poBody:Has("blijnnr":u)    THEN pbPakLijn.blijnnr    = poBody:GetInteger("blijnnr":u).
        IF poBody:Has("hold":u)       THEN pbPakLijn.hold       = poBody:GetLogical("hold":u).
        IF poBody:Has("swLed":u)      THEN pbPakLijn.swLed      = poBody:GetLogical("swLed":u).
        IF poBody:Has("swSikta":u)    THEN pbPakLijn.swSikta    = poBody:GetLogical("swSikta":u).
        IF poBody:Has("subtotaal":u)  THEN pbPakLijn.subtotaal  = poBody:GetLogical("subtotaal":u).
        IF poBody:Has("kolomtitel":u) THEN pbPakLijn.kolomtitel = poBody:GetLogical("kolomtitel":u).
        IF poBody:Has("infolijn":u)   THEN pbPakLijn.infolijn   = poBody:GetLogical("infolijn":u).
        IF poBody:Has("opm":u)        THEN pbPakLijn.opm        = poBody:GetCharacter("opm":u).

    END METHOD.

    METHOD PUBLIC HANDLE GetPakLijnen( INPUT piPaknr AS INTEGER ):

        EnsurePakbonExists( piPaknr ).

        EMPTY TEMP-TABLE ttPakLijn.

        FOR EACH paklijn NO-LOCK
            WHERE paklijn.paknr EQ piPaknr
            BY paklijn.lijnnr:

            CREATE ttPakLijn.
            CopyToTt( BUFFER paklijn, BUFFER ttPakLijn ).
        END.

        RETURN TEMP-TABLE ttPakLijn:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetPakLijn( INPUT piPaknr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsurePakbonExists( piPaknr ).

        EMPTY TEMP-TABLE ttPakLijn.

        FIND FIRST paklijn NO-LOCK
            WHERE paklijn.paknr  EQ piPaknr
              AND paklijn.lijnnr EQ piLijnnr NO-ERROR.

        IF AVAILABLE paklijn THEN
        DO:
            CREATE ttPakLijn.
            CopyToTt( BUFFER paklijn, BUFFER ttPakLijn ).
        END.

        RETURN TEMP-TABLE ttPakLijn:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE CreatePakLijn( INPUT piPaknr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iNewLijnnr AS INTEGER NO-UNDO.

        EnsurePakbonExists( piPaknr ).

        EMPTY TEMP-TABLE ttPakLijn.

        DO TRANSACTION:
            FIND LAST paklijn USE-INDEX paklijn-x1 EXCLUSIVE-LOCK
                WHERE paklijn.paknr EQ piPaknr NO-ERROR.

            iNewLijnnr = (IF AVAILABLE paklijn THEN paklijn.lijnnr ELSE 0) + 1.

            CREATE paklijn.
            ASSIGN
                paklijn.paknr  = piPaknr
                paklijn.lijnnr = iNewLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER paklijn ).

            CREATE ttPakLijn.
            CopyToTt( BUFFER paklijn, BUFFER ttPakLijn ).
        END.

        RETURN TEMP-TABLE ttPakLijn:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE UpdatePakLijn( INPUT piPaknr AS INTEGER, INPUT piLijnnr AS INTEGER, INPUT poBody AS JsonObject ):

        EnsurePakbonExists( piPaknr ).

        EMPTY TEMP-TABLE ttPakLijn.

        DO TRANSACTION:
            FIND FIRST paklijn EXCLUSIVE-LOCK
                WHERE paklijn.paknr  EQ piPaknr
                  AND paklijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE paklijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Paklijn &1/&2 not found":u, piPaknr, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER paklijn ).

            CREATE ttPakLijn.
            CopyToTt( BUFFER paklijn, BUFFER ttPakLijn ).
        END.

        RETURN TEMP-TABLE ttPakLijn:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeletePakLijn( INPUT piPaknr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsurePakbonExists( piPaknr ).

        DO TRANSACTION:
            FIND FIRST paklijn EXCLUSIVE-LOCK
                WHERE paklijn.paknr  EQ piPaknr
                  AND paklijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE paklijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Paklijn &1/&2 not found":u, piPaknr, piLijnnr), 404).

            DELETE paklijn.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Read-only reverse lookup - which pakbon(nen) contain a
                 given bonlijn (bonnr+blijnnr), via the paklijn-x4 index
                 on bonnr. Used by
                 GET /web/bon/{bonnr}/lijn/{lijnnr}/pakbonnen. No
                 bonlijn.paknr field exists in the schema - this is the
                 only supported way to find this relationship.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetPakLijnenForBonlijn( INPUT piBonnr AS INTEGER, INPUT piBlijnnr AS INTEGER ):

        EMPTY TEMP-TABLE ttPakLijn.

        FOR EACH paklijn USE-INDEX paklijn-x4 NO-LOCK
            WHERE paklijn.bonnr  EQ piBonnr
              AND paklijn.blijnnr EQ piBlijnnr
            BY paklijn.paknr:

            CREATE ttPakLijn.
            CopyToTt( BUFFER paklijn, BUFFER ttPakLijn ).
        END.

        RETURN TEMP-TABLE ttPakLijn:HANDLE.

    END METHOD.

END CLASS.

