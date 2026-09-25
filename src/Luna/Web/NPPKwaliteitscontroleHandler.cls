/*------------------------------------------------------------------------
    File        : NPPKwaliteitscontroleHandler.cls
    Purpose     : WebHandler for the NPP "kwaliteitscontrole" (QC) workflow
                  - see Luna.BusinessLogic.NPPKwaliteitscontroleBE for all
                  validation/booking logic. This handler only reads the
                  X-Auth-Token header, validates the session, parses the
                  path/JSON body, delegates to the BE, and reshapes the
                  returned result(s) into the documented response shapes.
    Syntax      : GET  /npp/kwaliteitscontrole/queue
                  POST /npp/kwaliteitscontrole/{bonnr}/{groepnr}/session
                  GET  /npp/kwaliteitscontrole/{bonnr}/{groepnr}/session
                  PUT  /npp/kwaliteitscontrole/{bonnr}/{groepnr}/{volgnr}/items/{lijnnr}
                  POST /npp/kwaliteitscontrole/{bonnr}/{groepnr}/{volgnr}/afkeur
    Description : Thin WebHandler only - no business logic, no direct DB
                  access. Auth follows Luna.Web.LogoutHandler's
                  X-Auth-Token idiom (mirrors Luna.Web.NPPStockBewegingHandler).
                  Error-status allowlist is "400,401,403,404,409":u - 403
                  added on top of the usual "400,401,404,409" set for the
                  self-QC guard.
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-30
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Net.HTTP.HttpHeader.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.AuthBE.
USING Luna.BusinessLogic.NPPKwaliteitscontroleBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.NPPKwaliteitscontroleHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/npp/kwaliteitscontrole"
       with the implicit trailing wildcard - this constant is the mount
       point we strip off PathInfo to find the remaining path segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/npp/kwaliteitscontrole":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount
                 point, e.g. "/npp/kwaliteitscontrole/queue" -> "queue",
                 "/npp/kwaliteitscontrole/20345/2/session" -> "20345/2/session".
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

    /* Number of "/"-separated segments in the path remainder ("" -> 0). */
    METHOD PRIVATE INTEGER SegmentCount( INPUT pcRemainder AS CHARACTER ):

        IF pcRemainder EQ "":u THEN
            RETURN 0.

        RETURN NUM-ENTRIES(pcRemainder, "/":u).

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

    /* Extracts the session token from the X-Auth-Token header - mirrors
       Luna.Web.LogoutHandler:GetAuthToken exactly. Returns "":u if the
       header is absent/blank. */
    METHOD PRIVATE CHARACTER GetAuthToken( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oHeader AS HttpHeader NO-UNDO.
        DEFINE VARIABLE cValue  AS CHARACTER  NO-UNDO.

        IF NOT poRequest:HasHeader("X-Auth-Token":u) THEN
            RETURN "":u.

        oHeader = CAST(poRequest:GetHeader("X-Auth-Token":u), HttpHeader).
        cValue  = oHeader:Value.

        IF cValue EQ ? THEN
            RETURN "":u.

        RETURN TRIM(cValue).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject.
        Errors : Throws AppError 400 if the body is missing/not a JSON
                 object, or malformed JSON.
    ------------------------------------------------------------------------------*/
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

    /* Serializes a temp-table result handle (SERIALIZE-NAME "items") to a
       JsonObject shaped as {"items": [...]}. */
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /* Writes a JSON response with the given status code. */
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

    /* Writes a JSON error response: {"error": {"message": ..., "code": n}}. */
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

    /* Maps an AppError raised by AuthBE/NPPKwaliteitscontroleBE
       (400/401/403/404/409) to an HTTP status code, defaulting
       unrecognized codes to 500 so no ABL stack trace ever leaks to the
       client. 403 is added on top of the usual sibling-handler
       "400,404,409" allowlist for the self-QC guard. */
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,401,403,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates the X-Auth-Token session for every request on
                 this endpoint. Writes the 401 response itself and
                 returns "":u if invalid - callers check for "":u.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER Authenticate( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cToken  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKode   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iNiveau AS INTEGER   NO-UNDO.
        DEFINE VARIABLE oAuthBE AS AuthBE    NO-UNDO.

        cToken  = GetAuthToken(poRequest).
        oAuthBE = NEW AuthBE().

        IF NOT oAuthBE:ValidateToken(cToken, OUTPUT cKode, OUTPUT iNiveau) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:Unauthorized), "Ongeldige of verlopen sessie":u).
            RETURN "":u.
        END.

        RETURN cKode.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /npp/kwaliteitscontrole/queue
                 GET /npp/kwaliteitscontrole/{bonnr}/{groepnr}/session
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cKode      AS CHARACTER               NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER               NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE oService   AS NPPKwaliteitscontroleBE NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE                  NO-UNDO.
        DEFINE VARIABLE oResponse  AS JsonObject               NO-UNDO.
        DEFINE VARIABLE oItemsJson AS JsonObject               NO-UNDO.
        DEFINE VARIABLE iBonnr     AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iGroepnr   AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE dDatum     AS DATE                    NO-UNDO.

        cKode = Authenticate(poRequest).
        IF cKode EQ "":u THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        oService = NEW NPPKwaliteitscontroleBE().

        IF iSegCount EQ 1 AND ENTRY(1, cRemainder, "/":u) EQ "queue":u THEN
        DO:
            hResult   = oService:GetQueue(cKode).
            oResponse = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResponse).
            RETURN 0.
        END.

        IF iSegCount EQ 3 AND ENTRY(3, cRemainder, "/":u) EQ "session":u THEN
        DO:
            iBonnr   = ParseEntryInt(cRemainder, 1, "bonnr":u).
            iGroepnr = ParseEntryInt(cRemainder, 2, "groepnr":u).

            hResult    = oService:PeekSession(iBonnr, iGroepnr, OUTPUT iVolgnr, OUTPUT dDatum).
            oItemsJson = ResultHandleToJson(hResult).

            oResponse = NEW JsonObject().
            oResponse:Add("bonnr":u, iBonnr).
            oResponse:Add("groepnr":u, iGroepnr).
            oResponse:Add("volgnr":u, iVolgnr).
            oResponse:Add("datum":u, STRING(dDatum, "9999-99-99":u)).
            oResponse:Add("items":u, oItemsJson:GetJsonArray("items":u)).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResponse).
            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), "Unknown /npp/kwaliteitscontrole GET route":u).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /npp/kwaliteitscontrole/{bonnr}/{groepnr}/session
                 POST /npp/kwaliteitscontrole/{bonnr}/{groepnr}/{volgnr}/afkeur
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cKode      AS CHARACTER               NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER               NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE oService   AS NPPKwaliteitscontroleBE NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE                  NO-UNDO.
        DEFINE VARIABLE oResponse  AS JsonObject               NO-UNDO.
        DEFINE VARIABLE oItemsJson AS JsonObject               NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject               NO-UNDO.
        DEFINE VARIABLE iBonnr     AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iGroepnr   AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE dDatum     AS DATE                    NO-UNDO.
        DEFINE VARIABLE lResumed   AS LOGICAL                 NO-UNDO.

        cKode = Authenticate(poRequest).
        IF cKode EQ "":u THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        oService = NEW NPPKwaliteitscontroleBE().

        IF iSegCount EQ 3 AND ENTRY(3, cRemainder, "/":u) EQ "session":u THEN
        DO:
            iBonnr   = ParseEntryInt(cRemainder, 1, "bonnr":u).
            iGroepnr = ParseEntryInt(cRemainder, 2, "groepnr":u).

            hResult    = oService:StartOrResumeSession(iBonnr, iGroepnr, cKode,
                             OUTPUT iVolgnr, OUTPUT dDatum, OUTPUT lResumed).
            oItemsJson = ResultHandleToJson(hResult).

            oResponse = NEW JsonObject().
            oResponse:Add("bonnr":u, iBonnr).
            oResponse:Add("groepnr":u, iGroepnr).
            oResponse:Add("volgnr":u, iVolgnr).
            oResponse:Add("datum":u, STRING(dDatum, "9999-99-99":u)).
            oResponse:Add("resumed":u, lResumed).
            oResponse:Add("items":u, oItemsJson:GetJsonArray("items":u)).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResponse).
            RETURN 0.
        END.

        IF iSegCount EQ 4 AND ENTRY(4, cRemainder, "/":u) EQ "afkeur":u THEN
        DO:
            iBonnr   = ParseEntryInt(cRemainder, 1, "bonnr":u).
            iGroepnr = ParseEntryInt(cRemainder, 2, "groepnr":u).
            iVolgnr  = ParseEntryInt(cRemainder, 3, "volgnr":u).

            oBody = GetJsonBody(poRequest).

            oService:Afkeuren(iBonnr, iGroepnr, iVolgnr, oBody, cKode).

            oResponse = NEW JsonObject().
            oResponse:Add("outcome":u, "rejected":u).
            oResponse:Add("bonnr":u, iBonnr).
            oResponse:Add("groepnr":u, iGroepnr).
            oResponse:Add("volgnr":u, iVolgnr).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResponse).
            RETURN 0.
        END.

        WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), "Unknown /npp/kwaliteitscontrole POST route":u).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /npp/kwaliteitscontrole/{bonnr}/{groepnr}/{volgnr}/items/{lijnnr}
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cKode        AS CHARACTER               NO-UNDO.
        DEFINE VARIABLE cRemainder   AS CHARACTER               NO-UNDO.
        DEFINE VARIABLE iSegCount    AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE oService     AS NPPKwaliteitscontroleBE NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE                  NO-UNDO.
        DEFINE VARIABLE oResponse    AS JsonObject               NO-UNDO.
        DEFINE VARIABLE oItemsJson   AS JsonObject               NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject               NO-UNDO.
        DEFINE VARIABLE iBonnr       AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iGroepnr     AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iVolgnr      AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE iLijnnr      AS INTEGER                 NO-UNDO.
        DEFINE VARIABLE lComplete    AS LOGICAL                 NO-UNDO.
        DEFINE VARIABLE cOutcome     AS CHARACTER               NO-UNDO.

        cKode = Authenticate(poRequest).
        IF cKode EQ "":u THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount NE 5 OR ENTRY(4, cRemainder, "/":u) NE "items":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), "Unknown /npp/kwaliteitscontrole PUT route":u).
            RETURN 0.
        END.

        iBonnr   = ParseEntryInt(cRemainder, 1, "bonnr":u).
        iGroepnr = ParseEntryInt(cRemainder, 2, "groepnr":u).
        iVolgnr  = ParseEntryInt(cRemainder, 3, "volgnr":u).
        iLijnnr  = ParseEntryInt(cRemainder, 5, "lijnnr":u).

        oBody = GetJsonBody(poRequest).

        oService = NEW NPPKwaliteitscontroleBE().

        hResult    = oService:UpdateItem(iBonnr, iGroepnr, iVolgnr, iLijnnr, oBody, cKode,
                         OUTPUT lComplete, OUTPUT cOutcome).
        oItemsJson = ResultHandleToJson(hResult).

        oResponse = NEW JsonObject().
        oResponse:Add("item":u, oItemsJson:GetJsonArray("items":u):GetJsonObject(1)).
        oResponse:Add("sessionComplete":u, lComplete).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResponse).
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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /npp/kwaliteitscontrole":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /npp/kwaliteitscontrole":u).
        RETURN 0.
    END METHOD.

END CLASS.

