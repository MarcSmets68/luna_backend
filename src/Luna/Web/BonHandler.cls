/*------------------------------------------------------------------------ 
    File        : BonHandler.cls 
    Purpose     : WebHandler exposing full CRUD for the "bon" (customer
                  order) table (core field subset - see
                  Luna.BusinessLogic.BonBE for the field map), plus full
                  CRUD for its `bonlijn` (order line) child rows nested
                  under it (see Luna.BusinessLogic.BonLijnBE for the field
                  map).
    Syntax      : GET    /web/bon                        - list (paged/filtered)
                  GET    /web/bon/{bonnr}                - get one bon
                  POST   /web/bon                        - create bon
                  PUT    /web/bon/{bonnr}                - update bon
                  DELETE /web/bon/{bonnr}                - delete bon (409 if bonlijn/other child rows exist,
                                                            or if any bonlijn has besteld <> 0)
                  POST   /web/bon/{bonnr}/annuleer        - cancel bon (stempel must be 'V' or 'B'; body ignored)
                  GET    /web/bon/{bonnr}/lijn            - list bonlijn for this bon
                  GET    /web/bon/{bonnr}/lijn/{lijnnr}   - get one bonlijn
                  POST   /web/bon/{bonnr}/lijn            - create bonlijn
                  PUT    /web/bon/{bonnr}/lijn/{lijnnr}   - update bonlijn (409 if stempel = 'D')
                  DELETE /web/bon/{bonnr}/lijn/{lijnnr}   - delete bonlijn (releases any pending/
                                                            confirmed reservation still held - see
                                                            Luna.BusinessLogic.BonBE:ReleaseReservationForLijn)
                  POST   /web/bon/{bonnr}/lijn/{lijnnr}/reservering            - manual reservation delta
                  POST   /web/bon/{bonnr}/lijn/{lijnnr}/reservering/bevestig  - confirm entire pending
                                                            reservation (all-or-nothing, not idempotent -
                                                            see Luna.BusinessLogic.BonLijnReserveringBevestigingBE)

                  GET /web/bon supports an optional ?geparkeerd=true|false
                  query filter alongside the existing klnr/type/bonnr/naam/
                  page/pageSize ones.
    Description : Thin WebHandler only - routing, request parsing, response 
                  formatting and HTTP status/error mapping. No business logic 
                  and no direct DB access - all of that lives in 
                  Luna.BusinessLogic.BonBE (bon) and
                  Luna.BusinessLogic.BonLijnBE (bonlijn). `bonnr`, `bedrag`
                  and `btw` in the request body (if any) are ignored on
                  bon create/update - see BonBE:ApplyFields. Deleting a bon
                  does NOT cascade to bonlijn - BonBE:DeleteBon still 409s
                  if any bonlijn (or other child table) rows exist; delete
                  lines individually via the endpoints below first.
    Author(s)   : Devin 
    Created     : 2026-08-11 
    Updated     : 2026-08-13 - added nested bonlijn CRUD, refactored path
                  parsing to the GetPathRemainder/SegmentCount/Parse*
                  pattern (mirrors Luna.Web.FactuurHandler).
  ----------------------------------------------------------------------*/ 
 
USING Progress.Lang.*. 
USING OpenEdge.Web.WebResponseWriter. 
USING OpenEdge.Net.HTTP.StatusCodeEnum. 
USING OpenEdge.Web.WebHandler. 
USING OpenEdge.Web.IWebRequest. 
USING Progress.Json.ObjectModel.JsonObject. 
USING Progress.Json.ObjectModel.JsonArray. 
USING Progress.Json.ObjectModel.ObjectModelParser. 
USING Luna.BusinessLogic.BonBE. 
USING Luna.BusinessLogic.BonLijnBE.
USING Luna.BusinessLogic.BonLijnProductieBE.
USING Luna.BusinessLogic.BonLedBE.
USING Luna.BusinessLogic.BonLedQcBE.
USING Luna.BusinessLogic.BonHerstelBE.
USING Luna.BusinessLogic.BonLijnReserveringBE.
USING Luna.BusinessLogic.BonLijnReserveringBevestigingBE.
USING Luna.BusinessLogic.PakLijnBE.
 
BLOCK-LEVEL ON ERROR UNDO, THROW. 
 
CLASS Luna.Web.BonHandler INHERITS WebHandler: 

    /* URI mapping in openedge.properties is "/bon" with the implicit
       trailing wildcard, so this also matches every nested path below it
       too (bonnr and bonnr/lijn[/lijnnr]). This constant is the mount
       point we strip off PathInfo to find the remaining path segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/bon":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount point,
                 e.g. "/bon/12345" -> "12345", "/bon/12345/lijn/1" ->
                 "12345/lijn/1", "/bon" or "/bon/" -> "".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetPathRemainder( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cPathInfo AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRest     AS CHARACTER NO-UNDO.

        cPathInfo = poRequest:PathInfo.

        IF cPathInfo BEGINS cMountPoint THEN
            cRest = SUBSTRING(cPathInfo, LENGTH(cMountPoint) + 1).
        ELSE
            cRest = cPathInfo.

        cRest = TRIM(cRest, "/":u).

        RETURN cRest.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Number of "/"-separated segments in the path remainder ("" -> 0).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER SegmentCount( INPUT pcRemainder AS CHARACTER ):

        IF pcRemainder EQ "":u THEN
            RETURN 0.

        RETURN NUM-ENTRIES(pcRemainder, "/":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the 1st path segment (bonnr) into an integer.
        Errors : Throws AppError 400 if the segment is not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseBonnr( INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE cBonnr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iBonnr AS INTEGER   NO-UNDO.

        cBonnr = ENTRY(1, pcRemainder, "/":u).

        iBonnr = INTEGER(cBonnr) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid bonnr &1":u, cBonnr), 400).

        RETURN iBonnr.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the 3rd path segment (lijnnr) into an integer.
        Errors : Throws AppError 400 if the segment is not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseLijnnr( INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE cLijnnr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iLijnnr AS INTEGER   NO-UNDO.

        cLijnnr = ENTRY(3, pcRemainder, "/":u).

        iLijnnr = INTEGER(cLijnnr) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid lijnnr &1":u, cLijnnr), 400).

        RETURN iLijnnr.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates that the 2nd path segment (if present) is the
                 literal "lijn" - the only nested resource under bon.
        Errors : Throws AppError 400 if it isn't.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateLijnSegment( INPUT pcRemainder AS CHARACTER ):

        IF ENTRY(2, pcRemainder, "/":u) NE "lijn":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Expected /bon/[bonnr]/lijn[/[lijnnr]], got &1":u, pcRemainder), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the Nth path segment into an integer.
        Errors : Throws AppError 400 if the segment is not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseEntryInt( INPUT pcRemainder AS CHARACTER, INPUT piEntryNum AS INTEGER, INPUT pcLabel AS CHARACTER ):

        DEFINE VARIABLE cValue AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iValue AS INTEGER   NO-UNDO.

        cValue = ENTRY(piEntryNum, pcRemainder, "/":u).

        iValue = INTEGER(cValue) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid &1 &2":u, pcLabel, cValue), 400).

        RETURN iValue.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject.
        Errors : Throws AppError 400 if the body is missing or not a JSON object.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            /* poRequest:Entity lazily deserializes the raw request body the
               first time it's accessed, right here. A malformed body (e.g.
               a stray UTF-8 BOM prepended by some HTTP clients/tools before
               the JSON, or plain invalid JSON) makes the underlying
               OpenEdge JSON parser throw a non-AppError (a JSON parser
               lexical error) - uncaught, that used to escape this method
               entirely, bypass the calling method's own
               "CATCH ... AS Progress.Lang.AppError", and reach PASOE's
               generic framework error handler, producing a raw 500 (HTML,
               or a JSON envelope with empty exception fields) instead of
               the documented 400. Re-throw AppErrors as-is (e.g. the
               "must be a JSON object" one above); convert anything else
               (the JSON parser error case) into a clean AppError 400 here
               so it's mapped the same as any other bad request. */
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.
 
    /*------------------------------------------------------------------------------ 
        Purpose: Serializes a ttBon result handle (from BonBE) to a 
                 JsonObject shaped as {"items": [...]}. 
    ------------------------------------------------------------------------------*/ 
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ): 
 
        DEFINE VARIABLE lcJson  AS LONGCHAR         NO-UNDO. 
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO. 
 
        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE). 
 
        oParser = NEW ObjectModelParser(). 
 
        RETURN CAST(oParser:Parse(lcJson), JsonObject). 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Writes a JSON response with the given status code. 
    ------------------------------------------------------------------------------*/ 
    METHOD PRIVATE VOID WriteJsonResponse( INPUT piStatusCode AS INTEGER, INPUT poBody AS JsonObject ): 
 
        DEFINE VARIABLE oResponse AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO. 
        DEFINE VARIABLE oWriter   AS WebResponseWriter               NO-UNDO. 
 
        ASSIGN 
            oResponse             = NEW OpenEdge.Web.WebResponse() 
            oResponse:StatusCode  = piStatusCode 
            oResponse:Entity      = poBody 
            oResponse:ContentType = "application/json":u 
            . 
 
        oWriter = NEW WebResponseWriter(oResponse). 
        oWriter:Open(). 
        oWriter:Close(). 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Writes a JSON error response: {"error": {"message": "...", "code": n}}. 
    ------------------------------------------------------------------------------*/ 
    METHOD PRIVATE VOID WriteErrorResponse( INPUT piStatusCode AS INTEGER, INPUT pcMessage AS CHARACTER ): 
 
        DEFINE VARIABLE oError AS JsonObject NO-UNDO. 
        DEFINE VARIABLE oBody  AS JsonObject NO-UNDO. 
 
        oError = NEW JsonObject(). 
        oError:Add("message":u, pcMessage). 
        oError:Add("code":u, piStatusCode). 
 
        oBody = NEW JsonObject(). 
        oBody:Add("error":u, oError). 
 
        WriteJsonResponse(piStatusCode, oBody). 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Maps an AppError raised by BonBE (400/404/409) to an HTTP 
                 status code, defaulting unrecognized codes to 500 so no ABL 
                 stack trace ever leaks to the client. 
    ------------------------------------------------------------------------------*/ 
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ): 
 
        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO. 
 
        iStatus = poError:GetMessageNum(1). 
 
        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN 
            iStatus = INTEGER(StatusCodeEnum:InternalServerError). 
 
        WriteErrorResponse(iStatus, poError:GetMessage(1)). 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: GET /bon (list, paged/filtered), GET /bon/{bonnr} (single
                 bon), GET /bon/{bonnr}/lijn (list bonlijn) and
                 GET /bon/{bonnr}/lijn/{lijnnr} (single bonlijn). 
    ------------------------------------------------------------------------------*/ 
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ): 
 
        DEFINE VARIABLE oService    AS BonBE      NO-UNDO. 
        DEFINE VARIABLE oBonLijnBE  AS BonLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBonnr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cKlnr      AS CHARACTER  NO-UNDO. 
        DEFINE VARIABLE iKlnr      AS INTEGER    NO-UNDO. 
        DEFINE VARIABLE cType      AS CHARACTER  NO-UNDO. 
        DEFINE VARIABLE cBonnrFilter AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cNaam      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cGeparkeerd AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cPage      AS CHARACTER  NO-UNDO. 
        DEFINE VARIABLE iPage      AS INTEGER    NO-UNDO. 
        DEFINE VARIABLE cPageSize  AS CHARACTER  NO-UNDO. 
        DEFINE VARIABLE iPageSize  AS INTEGER    NO-UNDO. 
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO. 
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO. 
        DEFINE VARIABLE lHasMore   AS LOGICAL    NO-UNDO. 
        DEFINE VARIABLE cEntry2    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEntry4    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iPLijnnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iGroepnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLedLijn   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cGroepnrQ  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iGroepnrFilter AS INTEGER NO-UNDO.
        DEFINE VARIABLE oProdBE    AS BonLijnProductieBE NO-UNDO.
        DEFINE VARIABLE oLedBE     AS BonLedBE           NO-UNDO.
        DEFINE VARIABLE oLedQcBE   AS BonLedQcBE         NO-UNDO.
        DEFINE VARIABLE oHerstelBE AS BonHerstelBE       NO-UNDO.
        DEFINE VARIABLE oPakLijnBE AS PakLijnBE          NO-UNDO.
 
        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 2 THEN
        DO:
            iBonnr  = ParseBonnr(cRemainder).
            cEntry2 = ENTRY(2, cRemainder, "/":u).

            CASE cEntry2:
                WHEN "lijn":u THEN
                DO:
                    IF iSegCount EQ 2 THEN
                    DO:
                        /* GET /bon/{bonnr}/lijn (list, no paging - a bon
                           typically has a bounded number of lines). */
                        oBonLijnBE = NEW BonLijnBE().
                        hResult    = oBonLijnBE:GetBonLijnen(iBonnr).
                        oBody      = ResultHandleToJson(hResult).

                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                        RETURN 0.
                    END.

                    iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).

                    IF iSegCount EQ 3 THEN
                    DO:
                        /* GET /bon/{bonnr}/lijn/{lijnnr} */
                        oBonLijnBE = NEW BonLijnBE().
                        hResult    = oBonLijnBE:GetBonLijn(iBonnr, iLijnnr).
                        oBody      = ResultHandleToJson(hResult).
                        oItems     = oBody:GetJsonArray("items":u).

                        IF oItems:Length EQ 0 THEN
                            WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                                SUBSTITUTE("Bonlijn &1/&2 not found":u, iBonnr, iLijnnr)).
                        ELSE
                            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                        RETURN 0.
                    END.

                    /* iSegCount >= 4: /lijn/{lijnnr}/productie[/{lijnnr}]
                       or /lijn/{lijnnr}/pakbonnen */
                    cEntry4 = ENTRY(4, cRemainder, "/":u).

                    IF cEntry4 EQ "productie":u THEN
                    DO:
                        oProdBE = NEW BonLijnProductieBE().

                        IF iSegCount EQ 4 THEN
                        DO:
                            hResult = oProdBE:GetProductieLijnen(iBonnr, iLijnnr).
                            oBody   = ResultHandleToJson(hResult).
                            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                            RETURN 0.
                        END.

                        iPLijnnr = ParseEntryInt(cRemainder, 5, "lijnnr":u).

                        hResult = oProdBE:GetProductieLijn(iBonnr, iLijnnr, iPLijnnr).
                        oBody   = ResultHandleToJson(hResult).
                        oItems  = oBody:GetJsonArray("items":u).

                        IF oItems:Length EQ 0 THEN
                            WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                                SUBSTITUTE("Productie sublijn &1/&2/&3 not found":u, iBonnr, iLijnnr, iPLijnnr)).
                        ELSE
                            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                        RETURN 0.
                    END.

                    IF cEntry4 EQ "pakbonnen":u AND iSegCount EQ 4 THEN
                    DO:
                        oPakLijnBE = NEW PakLijnBE().
                        hResult    = oPakLijnBE:GetPakLijnenForBonlijn(iBonnr, iLijnnr).
                        oBody      = ResultHandleToJson(hResult).
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                        RETURN 0.
                    END.

                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Unknown /bon/[bonnr]/lijn/[lijnnr]/... sub-resource, got &1":u, cRemainder)).
                    RETURN 0.
                END.

                WHEN "led":u THEN
                DO:
                    oLedBE = NEW BonLedBE().

                    IF iSegCount EQ 2 THEN
                    DO:
                        cGroepnrQ = poRequest:URI:GetQueryValue("groepnr":u).
                        iGroepnrFilter = 0.
                        IF cGroepnrQ NE ? THEN
                        DO:
                            iGroepnrFilter = INTEGER(cGroepnrQ) NO-ERROR.
                            IF ERROR-STATUS:ERROR THEN
                            DO:
                                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                                    SUBSTITUTE("Invalid groepnr &1":u, cGroepnrQ)).
                                RETURN 0.
                            END.
                        END.

                        hResult = oLedBE:GetBonLedLijnen(iBonnr, iGroepnrFilter).
                        oBody   = ResultHandleToJson(hResult).
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                        RETURN 0.
                    END.

                    iGroepnr = ParseEntryInt(cRemainder, 3, "groepnr":u).
                    iLedLijn = ParseEntryInt(cRemainder, 4, "ledLijn":u).
                    iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

                    hResult = oLedBE:GetBonLedLijn(iBonnr, iGroepnr, iLedLijn, iLijnnr).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    IF oItems:Length EQ 0 THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                            SUBSTITUTE("LED-lijn &1/&2/&3/&4 not found":u, iBonnr, iGroepnr, iLedLijn, iLijnnr)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.

                WHEN "led-qc":u THEN
                DO:
                    oLedQcBE = NEW BonLedQcBE().

                    IF iSegCount EQ 2 THEN
                    DO:
                        cGroepnrQ = poRequest:URI:GetQueryValue("groepnr":u).
                        iGroepnrFilter = 0.
                        IF cGroepnrQ NE ? THEN
                        DO:
                            iGroepnrFilter = INTEGER(cGroepnrQ) NO-ERROR.
                            IF ERROR-STATUS:ERROR THEN
                            DO:
                                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                                    SUBSTITUTE("Invalid groepnr &1":u, cGroepnrQ)).
                                RETURN 0.
                            END.
                        END.

                        hResult = oLedQcBE:GetBonLedQcLijnen(iBonnr, iGroepnrFilter).
                        oBody   = ResultHandleToJson(hResult).
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).
                        RETURN 0.
                    END.

                    iGroepnr = ParseEntryInt(cRemainder, 3, "groepnr":u).
                    iVolgnr  = ParseEntryInt(cRemainder, 4, "volgnr":u).
                    iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

                    hResult = oLedQcBE:GetBonLedQcLijn(iBonnr, iGroepnr, iVolgnr, iLijnnr).
                    oBody   = ResultHandleToJson(hResult).
                    oItems  = oBody:GetJsonArray("items":u).

                    IF oItems:Length EQ 0 THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                            SUBSTITUTE("LED-QC-lijn &1/&2/&3/&4 not found":u, iBonnr, iGroepnr, iVolgnr, iLijnnr)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.

                WHEN "herstel":u THEN
                DO:
                    oHerstelBE = NEW BonHerstelBE().
                    hResult    = oHerstelBE:GetBonHerstel(iBonnr).
                    oBody      = ResultHandleToJson(hResult).
                    oItems     = oBody:GetJsonArray("items":u).

                    IF oItems:Length EQ 0 THEN
                        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                            SUBSTITUTE("Bon &1 has no bon_herstel record":u, iBonnr)).
                    ELSE
                        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.

                OTHERWISE
                DO:
                    WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                        SUBSTITUTE("Unknown /bon/[bonnr]/... sub-resource, got &1":u, cRemainder)).
                    RETURN 0.
                END.
            END CASE.
        END.

        oService = NEW BonBE(). 

        IF iSegCount EQ 1 THEN
        DO:
            /* GET /bon/{bonnr} */
            iBonnr = ParseBonnr(cRemainder).

            hResult = oService:GetBon(iBonnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Bon &1 not found":u, iBonnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* GET /bon (list). GetQueryValue returns the unknown value (?) 
           when a query param is absent - normalize that to "0"/"" so the 
           BonBE filters treat "not supplied" and "supplied as 0" the same 
           way. Non-numeric klnr/page/pageSize is a 400, out-of-range 
           page/pageSize is clamped rather than rejected. bonnr filters by 
           prefix match, naam by substring match (case-insensitive) - see 
           BonBE:GetBonnen. */ 
        cKlnr = poRequest:URI:GetQueryValue("klnr":u). 
        IF cKlnr EQ ? THEN cKlnr = "0":u. 
 
        iKlnr = INTEGER(cKlnr) NO-ERROR. 
        IF ERROR-STATUS:ERROR THEN 
        DO: 
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid klnr &1":u, cKlnr)). 
            RETURN 0. 
        END. 
 
        cType = poRequest:URI:GetQueryValue("type":u).
        IF cType EQ ? OR cType EQ "0":u THEN cType = "":u.

        cBonnrFilter = poRequest:URI:GetQueryValue("bonnr":u).
        IF cBonnrFilter EQ ? THEN cBonnrFilter = "":u.

        cNaam = poRequest:URI:GetQueryValue("naam":u).
        IF cNaam EQ ? THEN cNaam = "":u.

        cGeparkeerd = poRequest:URI:GetQueryValue("geparkeerd":u).
        IF cGeparkeerd EQ ? THEN cGeparkeerd = "":u.
        IF LOOKUP(cGeparkeerd, "":u + ",true,false":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid geparkeerd &1":u, cGeparkeerd)).
            RETURN 0.
        END.

        cPage = poRequest:URI:GetQueryValue("page":u).
        IF cPage EQ ? THEN cPage = "1":u.

        iPage = INTEGER(cPage) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid page &1":u, cPage)).
            RETURN 0.
        END.
        IF iPage LT 1 THEN iPage = 1.

        cPageSize = poRequest:URI:GetQueryValue("pageSize":u).
        IF cPageSize EQ ? THEN cPageSize = "25":u.

        iPageSize = INTEGER(cPageSize) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid pageSize &1":u, cPageSize)).
            RETURN 0.
        END.
        IF iPageSize LT 1 THEN iPageSize = 1.
        IF iPageSize GT 200 THEN iPageSize = 200.

        hResult = oService:GetBonnen(iKlnr, cType, cBonnrFilter, cNaam, iPage, iPageSize, cGeparkeerd, "":u, OUTPUT lHasMore).
        oBody   = ResultHandleToJson(hResult).

        oBody:Add("page":u, iPage).
        oBody:Add("pageSize":u, iPageSize).
        oBody:Add("hasMore":u, lHasMore).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /bon (create bon, `bonnr`/`bedrag`/`btw` in the body
                 (if any) are ignored - see BonBE:ApplyFields) and
                 POST /bon/{bonnr}/lijn (create bonlijn, `bonnr`/`lijnnr`
                 in the body (if any) are ignored - see
                 BonLijnBE:ApplyFields/CreateBonLijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService     AS BonBE      NO-UNDO.
        DEFINE VARIABLE oBonLijnBE   AS BonLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBonnr       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody     AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems       AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cEntry2      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEntry3      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEntry4      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEntry5      AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oProdBE      AS BonLijnProductieBE     NO-UNDO.
        DEFINE VARIABLE oLedBE       AS BonLedBE               NO-UNDO.
        DEFINE VARIABLE oLedQcBE     AS BonLedQcBE             NO-UNDO.
        DEFINE VARIABLE oHerstelBE   AS BonHerstelBE           NO-UNDO.
        DEFINE VARIABLE oReserveBE   AS BonLijnReserveringBE   NO-UNDO.
        DEFINE VARIABLE oBevestigBE  AS BonLijnReserveringBevestigingBE NO-UNDO.
        DEFINE VARIABLE dDelta       AS DECIMAL                NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).
        oReqBody   = GetJsonBody(poRequest).

        IF iSegCount EQ 0 THEN
        DO:
            /* POST /bon (create bon) */
            oService = NEW BonBE().
            hResult  = oService:CreateBon(oReqBody).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iBonnr  = ParseBonnr(cRemainder).
        cEntry2 = ENTRY(2, cRemainder, "/":u).

        IF iSegCount EQ 2 AND cEntry2 EQ "annuleer":u THEN
        DO:
            /* POST /bon/{bonnr}/annuleer (cancel bon). Request body is
               ignored - nothing is read from oReqBody here. */
            oService = NEW BonBE().
            hResult  = oService:AnnuleerBon(iBonnr).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF cEntry2 EQ "lijn":u THEN
        DO:
            IF iSegCount EQ 2 THEN
            DO:
                /* POST /bon/{bonnr}/lijn (create bonlijn) */
                oBonLijnBE = NEW BonLijnBE().
                hResult    = oBonLijnBE:CreateBonLijn(iBonnr, oReqBody).
                oBody      = ResultHandleToJson(hResult).
                oItems     = oBody:GetJsonArray("items":u).

                WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).
            cEntry4 = ENTRY(4, cRemainder, "/":u).

            IF cEntry4 EQ "productie":u AND iSegCount EQ 4 THEN
            DO:
                /* POST /bon/{bonnr}/lijn/{lijnnr}/productie */
                oProdBE = NEW BonLijnProductieBE().
                hResult = oProdBE:CreateProductieLijn(iBonnr, iLijnnr, oReqBody).
                oBody   = ResultHandleToJson(hResult).
                oItems  = oBody:GetJsonArray("items":u).

                WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF cEntry4 EQ "reservering":u AND iSegCount EQ 4 THEN
            DO:
                /* POST /bon/{bonnr}/lijn/{lijnnr}/reservering */
                IF NOT oReqBody:Has("delta":u) THEN
                    UNDO, THROW NEW Progress.Lang.AppError("delta is required":u, 400).

                dDelta = oReqBody:GetDecimal("delta":u).

                oReserveBE = NEW BonLijnReserveringBE().
                hResult    = oReserveBE:ApplyReservering(iBonnr, iLijnnr, dDelta).
                oBody      = ResultHandleToJson(hResult).
                oItems     = oBody:GetJsonArray("items":u).

                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF cEntry4 EQ "reservering":u AND iSegCount EQ 5 THEN
            DO:
                cEntry5 = ENTRY(5, cRemainder, "/":u).

                IF cEntry5 EQ "bevestig":u THEN
                DO:
                    /* POST /bon/{bonnr}/lijn/{lijnnr}/reservering/bevestig
                       (all-or-nothing confirm - see
                       Luna.BusinessLogic.BonLijnReserveringBevestigingBE
                       and docs/architecture/bon-auto-reservering-design.md
                       §2). No request body is read. */
                    oBevestigBE = NEW BonLijnReserveringBevestigingBE().
                    hResult     = oBevestigBE:Bevestig(iBonnr, iLijnnr).
                    oBody       = ResultHandleToJson(hResult).
                    oItems      = oBody:GetJsonArray("items":u).

                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                    RETURN 0.
                END.

                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Unknown /bon/[bonnr]/lijn/[lijnnr]/reservering/... sub-resource, got &1":u,
                        cRemainder)).
                RETURN 0.
            END.

            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Unknown /bon/[bonnr]/lijn/[lijnnr]/... sub-resource, got &1":u, cRemainder)).
            RETURN 0.
        END.

        IF cEntry2 EQ "led":u AND iSegCount EQ 2 THEN
        DO:
            /* POST /bon/{bonnr}/led (create bon_led) */
            oLedBE  = NEW BonLedBE().
            hResult = oLedBE:CreateBonLedLijn(iBonnr, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF cEntry2 EQ "led-qc":u AND iSegCount EQ 2 THEN
        DO:
            /* POST /bon/{bonnr}/led-qc (create bon_led_qc) */
            oLedQcBE = NEW BonLedQcBE().
            hResult  = oLedQcBE:CreateBonLedQcLijn(iBonnr, oReqBody).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF cEntry2 EQ "herstel":u THEN
        DO:
            IF iSegCount EQ 2 THEN
            DO:
                /* POST /bon/{bonnr}/herstel (create bon_herstel) */
                oHerstelBE = NEW BonHerstelBE().
                hResult    = oHerstelBE:CreateBonHerstel(iBonnr, oReqBody).
                oBody      = ResultHandleToJson(hResult).
                oItems     = oBody:GetJsonArray("items":u).

                WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF iSegCount EQ 3 THEN
            DO:
                cEntry3    = ENTRY(3, cRemainder, "/":u).
                oHerstelBE = NEW BonHerstelBE().

                CASE cEntry3:
                    WHEN "diagnose":u THEN
                        hResult = oHerstelBE:TransitionToDiagnose(iBonnr).
                    WHEN "bestellen":u THEN
                        hResult = oHerstelBE:TransitionToBesteld(iBonnr).
                    WHEN "hersteld":u THEN
                        hResult = oHerstelBE:TransitionToHersteld(iBonnr).
                    OTHERWISE
                    DO:
                        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                            SUBSTITUTE("Unknown /bon/[bonnr]/herstel/... action, got &1":u, cRemainder)).
                        RETURN 0.
                    END.
                END CASE.

                oBody  = ResultHandleToJson(hResult).
                oItems = oBody:GetJsonArray("items":u).

                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Expected /bon or /bon/[bonnr]/..., got &1":u, cRemainder)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /bon/{bonnr} (update bon, `bonnr`/`bedrag`/`btw` in
                 the body (if any) are ignored - see BonBE:ApplyFields) and
                 PUT /bon/{bonnr}/lijn/{lijnnr} (update bonlijn,
                 `bonnr`/`lijnnr` in the body (if any) are ignored - see
                 BonLijnBE:ApplyFields).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS BonBE      NO-UNDO.
        DEFINE VARIABLE oBonLijnBE  AS BonLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBonnr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cEntry2     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEntry4     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iPLijnnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iGroepnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLedLijn    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVolgnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oProdBE     AS BonLijnProductieBE NO-UNDO.
        DEFINE VARIABLE oLedBE      AS BonLedBE           NO-UNDO.
        DEFINE VARIABLE oLedQcBE    AS BonLedQcBE         NO-UNDO.
        DEFINE VARIABLE oHerstelBE  AS BonHerstelBE       NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,2,3,5":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Unsupported PUT path /bon/&1":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        IF iSegCount EQ 1 THEN
        DO:
            /* PUT /bon/{bonnr} (update bon) */
            iBonnr = ParseBonnr(cRemainder).

            oService = NEW BonBE().
            hResult  = oService:UpdateBon(iBonnr, oReqBody).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iBonnr  = ParseBonnr(cRemainder).
        cEntry2 = ENTRY(2, cRemainder, "/":u).

        IF iSegCount EQ 2 AND cEntry2 EQ "herstel":u THEN
        DO:
            /* PUT /bon/{bonnr}/herstel (update non-status fields) */
            oHerstelBE = NEW BonHerstelBE().
            hResult    = oHerstelBE:UpdateBonHerstel(iBonnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 3 AND cEntry2 EQ "lijn":u THEN
        DO:
            /* PUT /bon/{bonnr}/lijn/{lijnnr} (update bonlijn) */
            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).

            oBonLijnBE = NEW BonLijnBE().
            hResult    = oBonLijnBE:UpdateBonLijn(iBonnr, iLijnnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 5 AND cEntry2 EQ "lijn":u THEN
        DO:
            /* PUT /bon/{bonnr}/lijn/{lijnnr}/productie/{lijnnr} */
            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).
            cEntry4 = ENTRY(4, cRemainder, "/":u).

            IF cEntry4 NE "productie":u THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Unsupported PUT path /bon/&1":u, cRemainder)).
                RETURN 0.
            END.

            iPLijnnr = ParseEntryInt(cRemainder, 5, "lijnnr":u).

            oProdBE = NEW BonLijnProductieBE().
            hResult = oProdBE:UpdateProductieLijn(iBonnr, iLijnnr, iPLijnnr, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 5 AND cEntry2 EQ "led":u THEN
        DO:
            /* PUT /bon/{bonnr}/led/{groepnr}/{ledLijn}/{lijnnr} */
            iGroepnr = ParseEntryInt(cRemainder, 3, "groepnr":u).
            iLedLijn = ParseEntryInt(cRemainder, 4, "ledLijn":u).
            iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

            oLedBE  = NEW BonLedBE().
            hResult = oLedBE:UpdateBonLedLijn(iBonnr, iGroepnr, iLedLijn, iLijnnr, oReqBody).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 5 AND cEntry2 EQ "led-qc":u THEN
        DO:
            /* PUT /bon/{bonnr}/led-qc/{groepnr}/{volgnr}/{lijnnr} */
            iGroepnr = ParseEntryInt(cRemainder, 3, "groepnr":u).
            iVolgnr  = ParseEntryInt(cRemainder, 4, "volgnr":u).
            iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

            oLedQcBE = NEW BonLedQcBE().
            hResult  = oLedQcBE:UpdateBonLedQcLijn(iBonnr, iGroepnr, iVolgnr, iLijnnr, oReqBody).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Unsupported PUT path /bon/&1":u, cRemainder)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: DELETE /bon/{bonnr} (409 if related order lines/records
                 still exist - bonlijn, bonlijn_productie,
                 bonlijn_variabel, bon_herstel, bon_led, bon_led_qc - no
                 cascade, delete bonlijn rows individually first) and
                 DELETE /bon/{bonnr}/lijn/{lijnnr} (delete one bonlijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS BonBE      NO-UNDO.
        DEFINE VARIABLE oBonLijnBE  AS BonLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBonnr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE cEntry2     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEntry4     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iPLijnnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iGroepnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLedLijn    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVolgnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oProdBE     AS BonLijnProductieBE NO-UNDO.
        DEFINE VARIABLE oLedBE      AS BonLedBE           NO-UNDO.
        DEFINE VARIABLE oLedQcBE    AS BonLedQcBE         NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3,5":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Unsupported DELETE path /bon/&1":u, cRemainder)).
            RETURN 0.
        END.

        IF iSegCount EQ 1 THEN
        DO:
            /* DELETE /bon/{bonnr} */
            iBonnr = ParseBonnr(cRemainder).

            oService = NEW BonBE().
            oService:DeleteBon(iBonnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("bonnr":u, iBonnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        iBonnr  = ParseBonnr(cRemainder).
        cEntry2 = ENTRY(2, cRemainder, "/":u).

        IF iSegCount EQ 3 AND cEntry2 EQ "lijn":u THEN
        DO:
            /* DELETE /bon/{bonnr}/lijn/{lijnnr} */
            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).

            oBonLijnBE = NEW BonLijnBE().
            oBonLijnBE:DeleteBonLijn(iBonnr, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("bonnr":u, iBonnr).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount EQ 5 AND cEntry2 EQ "lijn":u THEN
        DO:
            /* DELETE /bon/{bonnr}/lijn/{lijnnr}/productie/{lijnnr} */
            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).
            cEntry4 = ENTRY(4, cRemainder, "/":u).

            IF cEntry4 NE "productie":u THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Unsupported DELETE path /bon/&1":u, cRemainder)).
                RETURN 0.
            END.

            iPLijnnr = ParseEntryInt(cRemainder, 5, "lijnnr":u).

            oProdBE = NEW BonLijnProductieBE().
            oProdBE:DeleteProductieLijn(iBonnr, iLijnnr, iPLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("bonnr":u, iBonnr).
            oBody:Add("blijnnr":u, iLijnnr).
            oBody:Add("lijnnr":u, iPLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount EQ 5 AND cEntry2 EQ "led":u THEN
        DO:
            /* DELETE /bon/{bonnr}/led/{groepnr}/{ledLijn}/{lijnnr} */
            iGroepnr = ParseEntryInt(cRemainder, 3, "groepnr":u).
            iLedLijn = ParseEntryInt(cRemainder, 4, "ledLijn":u).
            iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

            oLedBE = NEW BonLedBE().
            oLedBE:DeleteBonLedLijn(iBonnr, iGroepnr, iLedLijn, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("bonnr":u, iBonnr).
            oBody:Add("groepnr":u, iGroepnr).
            oBody:Add("ledLijn":u, iLedLijn).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount EQ 5 AND cEntry2 EQ "led-qc":u THEN
        DO:
            /* DELETE /bon/{bonnr}/led-qc/{groepnr}/{volgnr}/{lijnnr} */
            iGroepnr = ParseEntryInt(cRemainder, 3, "groepnr":u).
            iVolgnr  = ParseEntryInt(cRemainder, 4, "volgnr":u).
            iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

            oLedQcBE = NEW BonLedQcBE().
            oLedQcBE:DeleteBonLedQcLijn(iBonnr, iGroepnr, iVolgnr, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("bonnr":u, iBonnr).
            oBody:Add("groepnr":u, iGroepnr).
            oBody:Add("volgnr":u, iVolgnr).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Unsupported DELETE path /bon/&1":u, cRemainder)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /bon":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /bon":u).
        RETURN 0.
    END METHOD.

END CLASS.
