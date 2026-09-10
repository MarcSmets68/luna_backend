/*------------------------------------------------------------------------
    File        : LedLijstparametersHandler.cls
    Purpose     : WebHandler exposing CRUD for led_lijstparameters.
    Syntax      : GET    /web/led-lijstparameters                              - list (paged/filtered)
                  GET    /web/led-lijstparameters/{categorie}/{volgnr}/{artnr}  - get one
                  POST   /web/led-lijstparameters                              - create
                  PUT    /web/led-lijstparameters/{categorie}/{volgnr}/{artnr}  - update (swBegins only)
                  DELETE /web/led-lijstparameters/{categorie}/{volgnr}/{artnr}  - delete
    Description : Thin WebHandler only - all DB access/business logic lives
                  in Luna.BusinessLogic.LedLijstparametersBE. Composite key
                  path segments are in the fixed order categorie/volgnr/artnr
                  and are assumed not to contain a literal "/".
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LedLijstparametersBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LedLijstparametersHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-lijstparameters":u.

    /*------------------------------------------------------------------------------
        Purpose: Returns the "/"-delimited path segments after the mount
                 point, e.g. "/led-lijstparameters/A/1/X" -> "A/1/X" split
                 into a 3-entry list. Returns "" (0 entries) for the list
                 endpoint itself.
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

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
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
        Purpose: Parses the 3 key path segments (categorie/volgnr/artnr) out
                 of poRequest. Returns FALSE (and already writes the 400
                 error response) if the path doesn't have exactly 3
                 non-empty segments or volgnr isn't a valid integer.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ParseKey(
        INPUT  poRequest   AS IWebRequest,
        OUTPUT pcCategorie AS CHARACTER,
        OUTPUT piVolgnr    AS INTEGER,
        OUTPUT pcArtnr     AS CHARACTER ):

        DEFINE VARIABLE cRemainder AS CHARACTER NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).

        IF NUM-ENTRIES(cRemainder, "/":u) NE 3 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                "Expected /led-lijstparameters/categorie/volgnr/artnr (3 non-empty path segments)":u).
            RETURN FALSE.
        END.

        ASSIGN
            pcCategorie = ENTRY(1, cRemainder, "/":u)
            pcArtnr     = ENTRY(3, cRemainder, "/":u)
            .

        IF pcCategorie EQ "":u OR pcArtnr EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "categorie and artnr path segments cannot be empty":u).
            RETURN FALSE.
        END.

        piVolgnr = INTEGER(ENTRY(2, cRemainder, "/":u)) NO-ERROR.
        IF piVolgnr EQ ? OR ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Invalid volgnr &1":u, ENTRY(2, cRemainder, "/":u))).
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS LedLijstparametersBE NO-UNDO.
        DEFINE VARIABLE cRemainder  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cCategorie  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iVolgnr     AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cArtnr      AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray   NO-UNDO.
        DEFINE VARIABLE iPage       AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize   AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cCatFilter  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cArtnrFilter AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE lHasMore    AS LOGICAL     NO-UNDO.

        oService   = NEW LedLijstparametersBE().
        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "":u THEN
        DO:
            IF NOT ParseKey(poRequest, OUTPUT cCategorie, OUTPUT iVolgnr, OUTPUT cArtnr) THEN
                RETURN 0.

            hResult = oService:GetItem(cCategorie, iVolgnr, cArtnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                    SUBSTITUTE("led_lijstparameters &1/&2/&3 not found":u, cCategorie, iVolgnr, cArtnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        cCatFilter = poRequest:URI:GetQueryValue("categorie":u).
        IF cCatFilter EQ ? THEN cCatFilter = "":u.

        cArtnrFilter = poRequest:URI:GetQueryValue("artnr":u).
        IF cArtnrFilter EQ ? THEN cArtnrFilter = "":u.

        hResult = oService:GetItems(iPage, iPageSize, cCatFilter, cArtnrFilter, OUTPUT lHasMore).
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

    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService   AS LedLijstparametersBE NO-UNDO.
        DEFINE VARIABLE oReqBody   AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cCategorie AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cArtnr     AS CHARACTER  NO-UNDO.

        oService = NEW LedLijstparametersBE().
        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("categorie":u) OR TRIM(oReqBody:GetCharacter("categorie":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "categorie is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("artnr":u) OR TRIM(oReqBody:GetCharacter("artnr":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "artnr is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("volgnr":u) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "volgnr is required":u).
            RETURN 0.
        END.

        ASSIGN
            cCategorie = oReqBody:GetCharacter("categorie":u)
            iVolgnr    = oReqBody:GetInteger("volgnr":u)
            cArtnr     = oReqBody:GetCharacter("artnr":u)
            .

        hResult = oService:CreateItem(cCategorie, iVolgnr, cArtnr, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService   AS LedLijstparametersBE NO-UNDO.
        DEFINE VARIABLE cCategorie AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cArtnr     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oReqBody   AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray  NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cCategorie, OUTPUT iVolgnr, OUTPUT cArtnr) THEN
            RETURN 0.

        oService = NEW LedLijstparametersBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:UpdateItem(cCategorie, iVolgnr, cArtnr, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService   AS LedLijstparametersBE NO-UNDO.
        DEFINE VARIABLE cCategorie AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cArtnr     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cCategorie, OUTPUT iVolgnr, OUTPUT cArtnr) THEN
            RETURN 0.

        oService = NEW LedLijstparametersBE().
        oService:DeleteItem(cCategorie, iVolgnr, cArtnr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("categorie":u, cCategorie).
        oBody:Add("volgnr":u, iVolgnr).
        oBody:Add("artnr":u, cArtnr).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-lijstparameters":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-lijstparameters":u).
        RETURN 0.
    END METHOD.

END CLASS. 
