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
                  DELETE /web/bon/{bonnr}/lijn/{lijnnr}   - delete bonlijn

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
 
        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 2 THEN
        DO:
            /* GET /bon/{bonnr}/lijn[/{lijnnr}] */
            ValidateLijnSegment(cRemainder).
            iBonnr     = ParseBonnr(cRemainder).
            oBonLijnBE = NEW BonLijnBE().

            IF iSegCount EQ 3 THEN
            DO:
                iLijnnr = ParseLijnnr(cRemainder).

                hResult = oBonLijnBE:GetBonLijn(iBonnr, iLijnnr).
                oBody   = ResultHandleToJson(hResult).
                oItems  = oBody:GetJsonArray("items":u).

                IF oItems:Length EQ 0 THEN
                    WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                        SUBSTITUTE("Bonlijn &1/&2 not found":u, iBonnr, iLijnnr)).
                ELSE
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF iSegCount NE 2 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /bon/[bonnr]/lijn[/[lijnnr]], got &1":u, cRemainder)).
                RETURN 0.
            END.

            /* GET /bon/{bonnr}/lijn (list, no paging - a bon typically has
               a bounded number of lines). */
            hResult = oBonLijnBE:GetBonLijnen(iBonnr).
            oBody   = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
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

        hResult = oService:GetBonnen(iKlnr, cType, cBonnrFilter, cNaam, iPage, iPageSize, cGeparkeerd, OUTPUT lHasMore).
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

        DEFINE VARIABLE oService    AS BonBE      NO-UNDO.
        DEFINE VARIABLE oBonLijnBE  AS BonLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBonnr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.

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

        IF iSegCount EQ 2 AND ENTRY(2, cRemainder, "/":u) EQ "annuleer":u THEN
        DO:
            /* POST /bon/{bonnr}/annuleer (cancel bon). Request body is
               ignored - nothing is read from oReqBody here. */
            iBonnr = ParseBonnr(cRemainder).

            oService = NEW BonBE().
            hResult  = oService:AnnuleerBon(iBonnr).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 2 THEN
        DO:
            /* POST /bon/{bonnr}/lijn (create bonlijn) */
            ValidateLijnSegment(cRemainder).
            iBonnr = ParseBonnr(cRemainder).

            oBonLijnBE = NEW BonLijnBE().
            hResult    = oBonLijnBE:CreateBonLijn(iBonnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Expected /bon or /bon/[bonnr]/lijn, got &1":u, cRemainder)).
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

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /bon/[bonnr] or /bon/[bonnr]/lijn/[lijnnr], got &1":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        IF iSegCount EQ 3 THEN
        DO:
            /* PUT /bon/{bonnr}/lijn/{lijnnr} (update bonlijn) */
            ValidateLijnSegment(cRemainder).
            iBonnr  = ParseBonnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).

            oBonLijnBE = NEW BonLijnBE().
            hResult    = oBonLijnBE:UpdateBonLijn(iBonnr, iLijnnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* PUT /bon/{bonnr} (update bon) */
        iBonnr = ParseBonnr(cRemainder).

        oService = NEW BonBE().
        hResult  = oService:UpdateBon(iBonnr, oReqBody).
        oBody    = ResultHandleToJson(hResult).
        oItems   = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

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

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /bon/[bonnr] or /bon/[bonnr]/lijn/[lijnnr], got &1":u, cRemainder)).
            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            /* DELETE /bon/{bonnr}/lijn/{lijnnr} */
            ValidateLijnSegment(cRemainder).
            iBonnr  = ParseBonnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).

            oBonLijnBE = NEW BonLijnBE().
            oBonLijnBE:DeleteBonLijn(iBonnr, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("bonnr":u, iBonnr).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        /* DELETE /bon/{bonnr} */
        iBonnr = ParseBonnr(cRemainder).

        oService = NEW BonBE().
        oService:DeleteBon(iBonnr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("bonnr":u, iBonnr).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

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
