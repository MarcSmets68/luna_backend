/*------------------------------------------------------------------------
    File        : LedEindHandler.cls
    Purpose     : WebHandler exposing CRUD for led_eind.
    Syntax      : GET    /web/led-eind                        - list (paged/filtered)
                  GET    /web/led-eind/{eind}/{profiel}/{cover} - get one (409 if >1 row matches)
                  POST   /web/led-eind                         - create
                  PUT    /web/led-eind/{eind}/{profiel}/{cover} - no-op besides key checks (no other fields)
                  DELETE /web/led-eind/{eind}/{profiel}/{cover} - delete
    Description : Thin WebHandler only - all DB access/business logic lives
                  in Luna.BusinessLogic.LedEindBE (which also owns the
                  "multiple rows match" 409 check since eind/profiel/cover
                  isn't declared unique at the DB level).
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
USING Luna.BusinessLogic.LedEindBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LedEindHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-eind":u.

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
        Purpose: Parses the 3 key path segments (eind/profiel/cover).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ParseKey(
        INPUT  poRequest AS IWebRequest,
        OUTPUT pcEind    AS CHARACTER,
        OUTPUT pcProfiel AS CHARACTER,
        OUTPUT pcCover   AS CHARACTER ):

        DEFINE VARIABLE cRemainder AS CHARACTER NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).

        IF NUM-ENTRIES(cRemainder, "/":u) NE 3 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                "Expected /led-eind/eind/profiel/cover (3 non-empty path segments)":u).
            RETURN FALSE.
        END.

        ASSIGN
            pcEind    = ENTRY(1, cRemainder, "/":u)
            pcProfiel = ENTRY(2, cRemainder, "/":u)
            pcCover   = ENTRY(3, cRemainder, "/":u)
            .

        IF pcEind EQ "":u OR pcProfiel EQ "":u OR pcCover EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "eind, profiel and cover path segments cannot be empty":u).
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService     AS LedEindBE  NO-UNDO.
        DEFINE VARIABLE cRemainder   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEind        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cProfiel     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cCover       AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems       AS JsonArray  NO-UNDO.
        DEFINE VARIABLE iPage        AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPageSize    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cEindFilter  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cEindPrefix  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE lHasMore     AS LOGICAL    NO-UNDO.

        oService   = NEW LedEindBE().
        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "":u THEN
        DO:
            IF NOT ParseKey(poRequest, OUTPUT cEind, OUTPUT cProfiel, OUTPUT cCover) THEN
                RETURN 0.

            hResult = oService:GetItem(cEind, cProfiel, cCover).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound),
                    SUBSTITUTE("led_eind &1/&2/&3 not found":u, cEind, cProfiel, cCover)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        cEindFilter = poRequest:URI:GetQueryValue("eind":u).
        IF cEindFilter EQ ? THEN cEindFilter = "":u.

        cEindPrefix = poRequest:URI:GetQueryValue("eindPrefix":u).
        IF cEindPrefix EQ ? THEN cEindPrefix = "":u.

        hResult = oService:GetItems(iPage, iPageSize, cEindFilter, cEindPrefix, OUTPUT lHasMore).
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

        DEFINE VARIABLE oService AS LedEindBE   NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject  NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray   NO-UNDO.
        DEFINE VARIABLE cEind    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cProfiel AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cCover   AS CHARACTER   NO-UNDO.

        oService = NEW LedEindBE().
        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("eind":u) OR TRIM(oReqBody:GetCharacter("eind":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "eind is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("profiel":u) OR TRIM(oReqBody:GetCharacter("profiel":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "profiel is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("cover":u) OR TRIM(oReqBody:GetCharacter("cover":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "cover is required":u).
            RETURN 0.
        END.

        ASSIGN
            cEind    = oReqBody:GetCharacter("eind":u)
            cProfiel = oReqBody:GetCharacter("profiel":u)
            cCover   = oReqBody:GetCharacter("cover":u)
            .

        hResult = oService:CreateItem(cEind, cProfiel, cCover).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /led-eind/{eind}/{profiel}/{cover}. This table has no
                 fields besides its 3-part key (immutable via PUT), so this
                 just re-confirms the key resolves to exactly one row and
                 returns it. Any body content is ignored.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LedEindBE   NO-UNDO.
        DEFINE VARIABLE cEind    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cProfiel AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cCover   AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray   NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cEind, OUTPUT cProfiel, OUTPUT cCover) THEN
            RETURN 0.

        oService = NEW LedEindBE().
        hResult  = oService:UpdateItem(cEind, cProfiel, cCover).
        oBody    = ResultHandleToJson(hResult).
        oItems   = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LedEindBE   NO-UNDO.
        DEFINE VARIABLE cEind    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cProfiel AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cCover   AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject  NO-UNDO.

        IF NOT ParseKey(poRequest, OUTPUT cEind, OUTPUT cProfiel, OUTPUT cCover) THEN
            RETURN 0.

        oService = NEW LedEindBE().
        oService:DeleteItem(cEind, cProfiel, cCover).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("eind":u, cEind).
        oBody:Add("profiel":u, cProfiel).
        oBody:Add("cover":u, cCover).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-eind":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-eind":u).
        RETURN 0.
    END METHOD.

END CLASS. 
