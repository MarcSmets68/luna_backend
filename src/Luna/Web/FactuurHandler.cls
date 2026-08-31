/*------------------------------------------------------------------------
    File        : FactuurHandler.cls
    Purpose     : WebHandler exposing full CRUD for the "factuur" (invoice)
                  table (core field subset - see Luna.BusinessLogic.FactuurBE
                  for the field map), plus full CRUD for its `faclijn`
                  (invoice line) child rows nested under it (see
                  Luna.BusinessLogic.FacLijnBE for the field map), plus full
                  CRUD for `fac_led` (LED-configuration detail) rows nested
                  under each faclijn (see Luna.BusinessLogic.FacLedBE for
                  the field map). v1 only ever operates on invoices, never
                  credit notes - factuur.type EQ TRUE is enforced inside
                  FactuurBE/FacLijnBE, not here.
    Syntax      : GET    /web/factuur                                            - list factuur (paged/filtered)
                  GET    /web/factuur/{facnr}                                    - get one factuur
                  POST   /web/factuur                                            - create factuur
                  PUT    /web/factuur/{facnr}                                    - update factuur
                  DELETE /web/factuur/{facnr}                                    - delete factuur (cascades faclijn/fac_led rows)
                  GET    /web/factuur/{facnr}/lijn                               - list faclijn for this factuur
                  GET    /web/factuur/{facnr}/lijn/{lijnnr}                      - get one faclijn
                  POST   /web/factuur/{facnr}/lijn                               - create faclijn
                  PUT    /web/factuur/{facnr}/lijn/{lijnnr}                      - update faclijn
                  DELETE /web/factuur/{facnr}/lijn/{lijnnr}                      - delete faclijn (cascades fac_led rows)
                  GET    /web/factuur/{facnr}/lijn/{lijnnr}/led                  - list fac_led for this faclijn
                  GET    /web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn} - get one fac_led
                  POST   /web/factuur/{facnr}/lijn/{lijnnr}/led                  - create fac_led
                  PUT    /web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn} - update fac_led
                  DELETE /web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn} - delete fac_led
    Description : Thin WebHandler only - routing, request parsing, response
                  formatting and HTTP status/error mapping. No business logic
                  and no direct DB access - all of that lives in
                  Luna.BusinessLogic.FactuurBE (factuur),
                  Luna.BusinessLogic.FacLijnBE (faclijn) and
                  Luna.BusinessLogic.FacLedBE (fac_led).
    Author(s)   : Devin
    Created     : 2026-08-11
    Updated     : 2026-08-12 - added full factuur CRUD and nested faclijn/
                  fac_led CRUD.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.FactuurBE.
USING Luna.BusinessLogic.FacLijnBE.
USING Luna.BusinessLogic.FacLedBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.FactuurHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/factuur" with the implicit
       trailing wildcard, so this also matches every nested path below it
       too (facnr, facnr/lijn[/lijnnr], and facnr/lijn/lijnnr/led[/groepnr/
       ledLijn]). This constant is the mount point we strip off PathInfo to
       find the remaining path segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/factuur":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount point,
                 e.g. "/factuur/20456" -> "20456",
                 "/factuur/20456/lijn/1/led/1/2" -> "20456/lijn/1/led/1/2",
                 "/factuur" or "/factuur/" -> "".
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
        Purpose: Parses the 1st path segment (facnr) into an integer.
        Errors : Throws AppError 400 if the segment is missing/not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER ParseFacnr( INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE cFacnr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iFacnr AS INTEGER   NO-UNDO.

        cFacnr = ENTRY(1, pcRemainder, "/":u).

        iFacnr = INTEGER(cFacnr) NO-ERROR.
        IF iFacnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid facnr &1":u, cFacnr), 400).

        RETURN iFacnr.

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
        IF iLijnnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid lijnnr &1":u, cLijnnr), 400).

        RETURN iLijnnr.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the 5th/6th path segments (groepnr/ledLijn) into
                 integers.
        Errors : Throws AppError 400 if either segment is not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ParseGroepnrLedLijn(
        INPUT  pcRemainder AS CHARACTER,
        OUTPUT piGroepnr   AS INTEGER,
        OUTPUT piLedLijn   AS INTEGER ):

        DEFINE VARIABLE cGroepnr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cLedLijn AS CHARACTER NO-UNDO.

        cGroepnr = ENTRY(5, pcRemainder, "/":u).
        cLedLijn = ENTRY(6, pcRemainder, "/":u).

        piGroepnr = INTEGER(cGroepnr) NO-ERROR.
        IF piGroepnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid groepnr &1":u, cGroepnr), 400).

        piLedLijn = INTEGER(cLedLijn) NO-ERROR.
        IF piLedLijn EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid ledLijn &1":u, cLedLijn), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates that the 2nd path segment (if present) is the
                 literal "lijn" - the only nested resource under factuur.
        Errors : Throws AppError 400 if it isn't.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateLijnSegment( INPUT pcRemainder AS CHARACTER ):

        IF ENTRY(2, pcRemainder, "/":u) NE "lijn":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Expected /factuur/[facnr]/lijn[/[lijnnr]], got &1":u, pcRemainder), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates that the 4th path segment (if present) is the
                 literal "led" - the only nested resource under faclijn.
        Errors : Throws AppError 400 if it isn't.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateLedSegment( INPUT pcRemainder AS CHARACTER ):

        IF ENTRY(4, pcRemainder, "/":u) NE "led":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Expected /factuur/[facnr]/lijn/[lijnnr]/led[/[groepnr]/[ledLijn]], got &1":u,
                    pcRemainder), 400).

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
        Purpose: Serializes a ttFactuur/ttFacLijn/ttFacLed result handle to
                 a JsonObject shaped as {"items": [...]}.
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
        Purpose: Maps an AppError raised by FactuurBE/FacLijnBE/FacLedBE
                 (400/404/409) to an HTTP status code, defaulting
                 unrecognized codes to 500 so no ABL stack trace ever leaks
                 to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /factuur (list, paged/filtered), GET /factuur/{facnr}
                 (single factuur), GET /factuur/{facnr}/lijn (list faclijn),
                 GET /factuur/{facnr}/lijn/{lijnnr} (single faclijn),
                 GET /factuur/{facnr}/lijn/{lijnnr}/led (list fac_led) and
                 GET /factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn}
                 (single fac_led).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oFactuurBE AS FactuurBE   NO-UNDO.
        DEFINE VARIABLE oFacLijnBE AS FacLijnBE   NO-UNDO.
        DEFINE VARIABLE oFacLedBE  AS FacLedBE    NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iFacnr     AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iLijnnr    AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iGroepnr   AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iLedLijn   AS INTEGER     NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray   NO-UNDO.
        DEFINE VARIABLE cKlnr      AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iKlnr      AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cNaam      AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cDatum     AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE dDatum     AS DATE        NO-UNDO.
        DEFINE VARIABLE cProjectnr AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iProjectnr AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPage      AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize  AS INTEGER     NO-UNDO.
        DEFINE VARIABLE lHasMore   AS LOGICAL     NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 4 THEN
        DO:
            /* GET /factuur/{facnr}/lijn/{lijnnr}/led[/{groepnr}/{ledLijn}] */
            ValidateLijnSegment(cRemainder).
            iFacnr  = ParseFacnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).
            ValidateLedSegment(cRemainder).

            oFacLedBE = NEW FacLedBE().

            IF iSegCount EQ 6 THEN
            DO:
                ParseGroepnrLedLijn(cRemainder, OUTPUT iGroepnr, OUTPUT iLedLijn).

                hResult = oFacLedBE:GetFacLed(iFacnr, iLijnnr, iGroepnr, iLedLijn).
                oBody   = ResultHandleToJson(hResult).
                oItems  = oBody:GetJsonArray("items":u).

                IF oItems:Length EQ 0 THEN
                    WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                        SUBSTITUTE("Fac_led &1/&2/&3/&4 not found":u, iFacnr, iLijnnr, iGroepnr, iLedLijn)).
                ELSE
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF iSegCount NE 4 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /factuur/[facnr]/lijn/[lijnnr]/led[/[groepnr]/[ledLijn]], got &1":u,
                        cRemainder)).
                RETURN 0.
            END.

            /* GET /factuur/{facnr}/lijn/{lijnnr}/led (list, no paging - a
               faclijn typically has a bounded number of LED-detail rows). */
            hResult = oFacLedBE:GetFacLeds(iFacnr, iLijnnr).
            oBody   = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount GE 2 THEN
        DO:
            /* GET /factuur/{facnr}/lijn[/{lijnnr}] */
            ValidateLijnSegment(cRemainder).
            iFacnr    = ParseFacnr(cRemainder).
            oFacLijnBE = NEW FacLijnBE().

            IF iSegCount EQ 3 THEN
            DO:
                iLijnnr = ParseLijnnr(cRemainder).

                hResult = oFacLijnBE:GetFacLijn(iFacnr, iLijnnr).
                oBody   = ResultHandleToJson(hResult).
                oItems  = oBody:GetJsonArray("items":u).

                IF oItems:Length EQ 0 THEN
                    WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                        SUBSTITUTE("Faclijn &1/&2 not found":u, iFacnr, iLijnnr)).
                ELSE
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF iSegCount NE 2 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /factuur/[facnr]/lijn[/[lijnnr]], got &1":u, cRemainder)).
                RETURN 0.
            END.

            /* GET /factuur/{facnr}/lijn (list, no paging - an invoice
               typically has a bounded number of lines). */
            hResult = oFacLijnBE:GetFacLijnen(iFacnr).
            oBody   = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount EQ 1 THEN
        DO:
            /* GET /factuur/{facnr} */
            iFacnr = ParseFacnr(cRemainder).
            oFactuurBE = NEW FactuurBE().

            hResult = oFactuurBE:GetFactuur(iFacnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                    SUBSTITUTE("Factuur &1 not found":u, iFacnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* GET /factuur (list). GetQueryValue returns the unknown value (?)
           when a query param is absent - normalize that to "" (or 0 for
           klnr/projectnr, ? for datum) so the FactuurBE filters treat "not
           supplied" and "supplied blank" the same way. */
        cKlnr      = poRequest:URI:GetQueryValue("klnr":u).
        cNaam      = poRequest:URI:GetQueryValue("naam":u).
        cDatum     = poRequest:URI:GetQueryValue("datum":u).
        cProjectnr = poRequest:URI:GetQueryValue("projectnr":u).

        IF cNaam EQ ? THEN cNaam = "":u.

        iKlnr = INTEGER(cKlnr) NO-ERROR.
        IF iKlnr EQ ? THEN iKlnr = 0.

        iProjectnr = INTEGER(cProjectnr) NO-ERROR.
        IF iProjectnr EQ ? THEN iProjectnr = 0.

        /* Query param is YYYY-MM-DD (ISO), not the session date format, so
           parse it explicitly instead of calling DATE() on the raw string. */
        IF cDatum EQ ? THEN
            dDatum = ?.
        ELSE
        DO:
            dDatum = DATE(INTEGER(SUBSTRING(cDatum, 6, 2)), INTEGER(SUBSTRING(cDatum, 9, 2)), INTEGER(SUBSTRING(cDatum, 1, 4))) NO-ERROR.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        oFactuurBE = NEW FactuurBE().
        hResult    = oFactuurBE:GetFacturen(iKlnr, cNaam, dDatum, iProjectnr, iPage, iPageSize, OUTPUT lHasMore).
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
        Purpose: POST /factuur (create factuur),
                 POST /factuur/{facnr}/lijn (create faclijn) and
                 POST /factuur/{facnr}/lijn/{lijnnr}/led (create fac_led).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oFactuurBE AS FactuurBE   NO-UNDO.
        DEFINE VARIABLE oFacLijnBE AS FacLijnBE   NO-UNDO.
        DEFINE VARIABLE oFacLedBE  AS FacLedBE    NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iFacnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody   AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray  NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).
        oReqBody   = GetJsonBody(poRequest).

        IF iSegCount EQ 0 THEN
        DO:
            /* POST /factuur (create factuur) */
            oFactuurBE = NEW FactuurBE().
            hResult    = oFactuurBE:CreateFactuur(oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 2 THEN
        DO:
            /* POST /factuur/{facnr}/lijn (create faclijn) */
            ValidateLijnSegment(cRemainder).
            iFacnr = ParseFacnr(cRemainder).

            oFacLijnBE = NEW FacLijnBE().
            hResult    = oFacLijnBE:CreateFacLijn(iFacnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 4 THEN
        DO:
            /* POST /factuur/{facnr}/lijn/{lijnnr}/led (create fac_led) */
            ValidateLijnSegment(cRemainder).
            iFacnr  = ParseFacnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).
            ValidateLedSegment(cRemainder).

            oFacLedBE = NEW FacLedBE().
            hResult   = oFacLedBE:CreateFacLed(iFacnr, iLijnnr, oReqBody).
            oBody     = ResultHandleToJson(hResult).
            oItems    = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Expected /factuur, /factuur/[facnr]/lijn or /factuur/[facnr]/lijn/[lijnnr]/led, got &1":u,
                cRemainder)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /factuur/{facnr} (update factuur),
                 PUT /factuur/{facnr}/lijn/{lijnnr} (update faclijn) and
                 PUT /factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn}
                 (update fac_led).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oFactuurBE AS FactuurBE   NO-UNDO.
        DEFINE VARIABLE oFacLijnBE AS FacLijnBE   NO-UNDO.
        DEFINE VARIABLE oFacLedBE  AS FacLedBE    NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iFacnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iGroepnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLedLijn   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody   AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray  NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3,6":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /factuur/[facnr], /factuur/[facnr]/lijn/[lijnnr] or &1, got &2":u,
                    "/factuur/[facnr]/lijn/[lijnnr]/led/[groepnr]/[ledLijn]":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        IF iSegCount EQ 6 THEN
        DO:
            /* PUT /factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn} */
            ValidateLijnSegment(cRemainder).
            iFacnr  = ParseFacnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).
            ValidateLedSegment(cRemainder).
            ParseGroepnrLedLijn(cRemainder, OUTPUT iGroepnr, OUTPUT iLedLijn).

            oFacLedBE = NEW FacLedBE().
            hResult   = oFacLedBE:UpdateFacLed(iFacnr, iLijnnr, iGroepnr, iLedLijn, oReqBody).
            oBody     = ResultHandleToJson(hResult).
            oItems    = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            /* PUT /factuur/{facnr}/lijn/{lijnnr} (update faclijn) */
            ValidateLijnSegment(cRemainder).
            iFacnr  = ParseFacnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).

            oFacLijnBE = NEW FacLijnBE().
            hResult    = oFacLijnBE:UpdateFacLijn(iFacnr, iLijnnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* PUT /factuur/{facnr} (update factuur) */
        iFacnr = ParseFacnr(cRemainder).

        oFactuurBE = NEW FactuurBE().
        hResult    = oFactuurBE:UpdateFactuur(iFacnr, oReqBody).
        oBody      = ResultHandleToJson(hResult).
        oItems     = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: DELETE /factuur/{facnr} (delete factuur, cascades its
                 faclijn/fac_led rows),
                 DELETE /factuur/{facnr}/lijn/{lijnnr} (delete faclijn,
                 cascades its fac_led rows) and
                 DELETE /factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn}
                 (delete fac_led).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oFactuurBE AS FactuurBE   NO-UNDO.
        DEFINE VARIABLE oFacLijnBE AS FacLijnBE   NO-UNDO.
        DEFINE VARIABLE oFacLedBE  AS FacLedBE    NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iFacnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iGroepnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLedLijn   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3,6":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /factuur/[facnr], /factuur/[facnr]/lijn/[lijnnr] or &1, got &2":u,
                    "/factuur/[facnr]/lijn/[lijnnr]/led/[groepnr]/[ledLijn]":u, cRemainder)).
            RETURN 0.
        END.

        IF iSegCount EQ 6 THEN
        DO:
            /* DELETE /factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn} */
            ValidateLijnSegment(cRemainder).
            iFacnr  = ParseFacnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).
            ValidateLedSegment(cRemainder).
            ParseGroepnrLedLijn(cRemainder, OUTPUT iGroepnr, OUTPUT iLedLijn).

            oFacLedBE = NEW FacLedBE().
            oFacLedBE:DeleteFacLed(iFacnr, iLijnnr, iGroepnr, iLedLijn).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("facnr":u, iFacnr).
            oBody:Add("lijnnr":u, iLijnnr).
            oBody:Add("groepnr":u, iGroepnr).
            oBody:Add("ledLijn":u, iLedLijn).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            /* DELETE /factuur/{facnr}/lijn/{lijnnr} */
            ValidateLijnSegment(cRemainder).
            iFacnr  = ParseFacnr(cRemainder).
            iLijnnr = ParseLijnnr(cRemainder).

            oFacLijnBE = NEW FacLijnBE().
            oFacLijnBE:DeleteFacLijn(iFacnr, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("facnr":u, iFacnr).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        /* DELETE /factuur/{facnr} */
        iFacnr = ParseFacnr(cRemainder).

        oFactuurBE = NEW FactuurBE().
        oFactuurBE:DeleteFactuur(iFacnr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("facnr":u, iFacnr).

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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /factuur":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /factuur":u).
        RETURN 0.
    END METHOD.

END CLASS.
