/*------------------------------------------------------------------------
    File        : PakbonHandler.cls
    Purpose     : WebHandler exposing full CRUD for the "pakbon" (packing
                  slip) table (core field subset - see
                  Luna.BusinessLogic.PakbonBE for the field map), plus
                  full CRUD for its `paklijn` child rows nested under it
                  (see Luna.BusinessLogic.PakLijnBE). Mirrors
                  Luna.Web.BonHandler's pattern (pagination, filters,
                  error shapes).
    Syntax      : GET    /web/pakbon                          - list (paged/filtered)
                  GET    /web/pakbon/{paknr}                  - get one pakbon
                  POST   /web/pakbon                          - create pakbon
                  PUT    /web/pakbon/{paknr}                  - update pakbon
                  DELETE /web/pakbon/{paknr}                  - delete pakbon (409 if paklijn rows exist)
                  POST   /web/pakbon/{paknr}/afhalen          - mark picked up
                  GET    /web/pakbon/{paknr}/lijn             - list paklijn for this pakbon
                  GET    /web/pakbon/{paknr}/lijn/{lijnnr}    - get one paklijn
                  POST   /web/pakbon/{paknr}/lijn             - create paklijn
                  PUT    /web/pakbon/{paknr}/lijn/{lijnnr}    - update paklijn
                  DELETE /web/pakbon/{paknr}/lijn/{lijnnr}    - delete paklijn
    Description : Thin WebHandler only - routing, request parsing,
                  response formatting and HTTP status/error mapping. No
                  business logic and no direct DB access - all of that
                  lives in Luna.BusinessLogic.PakbonBE (pakbon) and
                  Luna.BusinessLogic.PakLijnBE (paklijn).
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.PakbonBE.
USING Luna.BusinessLogic.PakLijnBE.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.PakbonHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/pakbon":u.

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

    METHOD PRIVATE INTEGER SegmentCount( INPUT pcRemainder AS CHARACTER ):

        IF pcRemainder EQ "":u THEN
            RETURN 0.

        RETURN NUM-ENTRIES(pcRemainder, "/":u).

    END METHOD.

    METHOD PRIVATE INTEGER ParsePaknr( INPUT pcRemainder AS CHARACTER ):

        DEFINE VARIABLE cPaknr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iPaknr AS INTEGER   NO-UNDO.

        cPaknr = ENTRY(1, pcRemainder, "/":u).

        iPaknr = INTEGER(cPaknr) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid paknr &1":u, cPaknr), 400).

        RETURN iPaknr.

    END METHOD.

    METHOD PRIVATE INTEGER ParseEntryInt( INPUT pcRemainder AS CHARACTER, INPUT piEntryNum AS INTEGER, INPUT pcLabel AS CHARACTER ):

        DEFINE VARIABLE cValue AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iValue AS INTEGER   NO-UNDO.

        cValue = ENTRY(piEntryNum, pcRemainder, "/":u).

        iValue = INTEGER(cValue) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Invalid &1 &2":u, pcLabel, cValue), 400).

        RETURN iValue.

    END METHOD.

    METHOD PRIVATE VOID ValidateLijnSegment( INPUT pcRemainder AS CHARACTER ):

        IF ENTRY(2, pcRemainder, "/":u) NE "lijn":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Expected /pakbon/[paknr]/lijn[/[lijnnr]], got &1":u, pcRemainder), 400).

    END METHOD.

    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR         NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

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

    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /pakbon (list, paged/filtered), GET /pakbon/{paknr}
                 (single pakbon), GET /pakbon/{paknr}/lijn (list paklijn)
                 and GET /pakbon/{paknr}/lijn/{lijnnr} (single paklijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService     AS PakbonBE   NO-UNDO.
        DEFINE VARIABLE oPakLijnBE   AS PakLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPaknr       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oItems       AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cKlnr        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iKlnr        AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cStempel     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cPaknrFilter AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cNaam        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cProjectnr   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iProjectnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cPage        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iPage        AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cPageSize    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iPageSize    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE lHasMore     AS LOGICAL    NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 2 THEN
        DO:
            /* GET /pakbon/{paknr}/lijn[/{lijnnr}] */
            ValidateLijnSegment(cRemainder).
            iPaknr     = ParsePaknr(cRemainder).
            oPakLijnBE = NEW PakLijnBE().

            IF iSegCount EQ 3 THEN
            DO:
                iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).

                hResult = oPakLijnBE:GetPakLijn(iPaknr, iLijnnr).
                oBody   = ResultHandleToJson(hResult).
                oItems  = oBody:GetJsonArray("items":u).

                IF oItems:Length EQ 0 THEN
                    WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                        SUBSTITUTE("Paklijn &1/&2 not found":u, iPaknr, iLijnnr)).
                ELSE
                    WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

                RETURN 0.
            END.

            IF iSegCount NE 2 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /pakbon/[paknr]/lijn[/[lijnnr]], got &1":u, cRemainder)).
                RETURN 0.
            END.

            hResult = oPakLijnBE:GetPakLijnen(iPaknr).
            oBody   = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        oService = NEW PakbonBE().

        IF iSegCount EQ 1 THEN
        DO:
            /* GET /pakbon/{paknr} */
            iPaknr = ParsePaknr(cRemainder).

            hResult = oService:GetPakbon(iPaknr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Pakbon &1 not found":u, iPaknr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* GET /pakbon (list) */
        cKlnr = poRequest:URI:GetQueryValue("klnr":u).
        IF cKlnr EQ ? THEN cKlnr = "0":u.

        iKlnr = INTEGER(cKlnr) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid klnr &1":u, cKlnr)).
            RETURN 0.
        END.

        cStempel = poRequest:URI:GetQueryValue("stempel":u).
        IF cStempel EQ ? THEN cStempel = "":u.

        cPaknrFilter = poRequest:URI:GetQueryValue("paknr":u).
        IF cPaknrFilter EQ ? THEN cPaknrFilter = "":u.

        cNaam = poRequest:URI:GetQueryValue("naam":u).
        IF cNaam EQ ? THEN cNaam = "":u.

        cProjectnr = poRequest:URI:GetQueryValue("projectnr":u).
        IF cProjectnr EQ ? THEN cProjectnr = "0":u.

        iProjectnr = INTEGER(cProjectnr) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid projectnr &1":u, cProjectnr)).
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

        hResult = oService:GetPakbonnen(iKlnr, cStempel, cPaknrFilter, cNaam, iProjectnr, iPage, iPageSize, OUTPUT lHasMore).
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
        Purpose: POST /pakbon (create), POST /pakbon/{paknr}/afhalen
                 (mark picked up) and POST /pakbon/{paknr}/lijn (create
                 paklijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS PakbonBE   NO-UNDO.
        DEFINE VARIABLE oPakLijnBE  AS PakLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPaknr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cAfgehaaldId AS CHARACTER NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).
        oReqBody   = GetJsonBody(poRequest).

        IF iSegCount EQ 0 THEN
        DO:
            /* POST /pakbon (create pakbon) */
            oService = NEW PakbonBE().
            hResult  = oService:CreatePakbon(oReqBody).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 2 AND ENTRY(2, cRemainder, "/":u) EQ "afhalen":u THEN
        DO:
            /* POST /pakbon/{paknr}/afhalen */
            iPaknr = ParsePaknr(cRemainder).

            cAfgehaaldId = "":u.
            IF oReqBody:Has("afgehaaldId":u) THEN cAfgehaaldId = oReqBody:GetCharacter("afgehaaldId":u).

            oService = NEW PakbonBE().
            hResult  = oService:AfhalenPakbon(iPaknr, cAfgehaaldId).
            oBody    = ResultHandleToJson(hResult).
            oItems   = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        IF iSegCount EQ 2 THEN
        DO:
            /* POST /pakbon/{paknr}/lijn (create paklijn) */
            ValidateLijnSegment(cRemainder).
            iPaknr = ParsePaknr(cRemainder).

            oPakLijnBE = NEW PakLijnBE().
            hResult    = oPakLijnBE:CreatePakLijn(iPaknr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
            SUBSTITUTE("Expected /pakbon or /pakbon/[paknr]/..., got &1":u, cRemainder)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /pakbon/{paknr} (update) and
                 PUT /pakbon/{paknr}/lijn/{lijnnr} (update paklijn).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS PakbonBE   NO-UNDO.
        DEFINE VARIABLE oPakLijnBE  AS PakLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPaknr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oReqBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray  NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /pakbon/[paknr] or /pakbon/[paknr]/lijn/[lijnnr], got &1":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        IF iSegCount EQ 3 THEN
        DO:
            /* PUT /pakbon/{paknr}/lijn/{lijnnr} */
            ValidateLijnSegment(cRemainder).
            iPaknr  = ParsePaknr(cRemainder).
            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).

            oPakLijnBE = NEW PakLijnBE().
            hResult    = oPakLijnBE:UpdatePakLijn(iPaknr, iLijnnr, oReqBody).
            oBody      = ResultHandleToJson(hResult).
            oItems     = oBody:GetJsonArray("items":u).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* PUT /pakbon/{paknr} */
        iPaknr = ParsePaknr(cRemainder).

        oService = NEW PakbonBE().
        hResult  = oService:UpdatePakbon(iPaknr, oReqBody).
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
        Purpose: DELETE /pakbon/{paknr} (409 if paklijn rows exist, no
                 cascade) and DELETE /pakbon/{paknr}/lijn/{lijnnr}.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS PakbonBE   NO-UNDO.
        DEFINE VARIABLE oPakLijnBE  AS PakLijnBE  NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iSegCount   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPaknr      AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF LOOKUP(STRING(iSegCount), "1,3":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /pakbon/[paknr] or /pakbon/[paknr]/lijn/[lijnnr], got &1":u, cRemainder)).
            RETURN 0.
        END.

        IF iSegCount EQ 3 THEN
        DO:
            /* DELETE /pakbon/{paknr}/lijn/{lijnnr} */
            ValidateLijnSegment(cRemainder).
            iPaknr  = ParsePaknr(cRemainder).
            iLijnnr = ParseEntryInt(cRemainder, 3, "lijnnr":u).

            oPakLijnBE = NEW PakLijnBE().
            oPakLijnBE:DeletePakLijn(iPaknr, iLijnnr).

            oBody = NEW JsonObject().
            oBody:Add("status":u, "deleted":u).
            oBody:Add("paknr":u, iPaknr).
            oBody:Add("lijnnr":u, iLijnnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        /* DELETE /pakbon/{paknr} */
        iPaknr = ParsePaknr(cRemainder).

        oService = NEW PakbonBE().
        oService:DeletePakbon(iPaknr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("paknr":u, iPaknr).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /pakbon":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /pakbon":u).
        RETURN 0.
    END METHOD.

END CLASS.

