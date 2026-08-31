/*------------------------------------------------------------------------
    File        : LoginHandler.cls
    Purpose     : Thin WebHandler for the Auth-MVP login feature. Parses
                  the request body, calls Luna.BusinessLogic.AuthBE for
                  all validation/business logic, and formats the
                  response/error envelope. Never reads gebruiker.Password
                  or authenticationToken directly - all DB access lives
                  in AuthBE.
    Syntax      : POST /web/login  (no auth required)
    Description : See docs/architecture/login-auth-ontwerp.md paragraaf 1.2.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.AuthBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LoginHandler INHERITS WebHandler:

    /* Parses the request body entity into a JsonObject.
       Errors: Throws AppError 400 if the body is missing, not a JSON
       object, or malformed (same pattern/rationale as
       Luna.Web.KlantHandler:GetJsonBody() - see that class for the full
       BOM/malformed-JSON regression note). */
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

    /* Serializes a ttLoginResult result handle (from AuthBE) to a
       JsonObject shaped as "items": [...]. */
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR         NO-UNDO.
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

    /* Maps an AppError raised by AuthBE (400/401/403) to an HTTP status
       code, defaulting unrecognized codes to 500 so no ABL stack trace
       ever leaks to the client - same pattern as
       Luna.Web.KlantHandler:HandleAppError(). */
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,401,403":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /* POST /login - kode/password in the JSON body. All validation and
       session creation happens in AuthBE:Login() - see ontwerp paragraaf
       1.2/1.2.1 for the exact decision tree. */
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService  AS AuthBE     NO-UNDO.
        DEFINE VARIABLE oReqBody  AS JsonObject NO-UNDO.
        DEFINE VARIABLE cKode     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cPassword AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE hResult   AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody     AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems    AS JsonArray  NO-UNDO.

        oReqBody = GetJsonBody(poRequest).

        cKode     = IF oReqBody:Has("kode":u)     THEN oReqBody:GetCharacter("kode":u)     ELSE "":u.
        cPassword = IF oReqBody:Has("password":u) THEN oReqBody:GetCharacter("password":u) ELSE "":u.

        oService = NEW AuthBE().
        hResult  = oService:Login(cKode, cPassword).

        oBody  = ResultHandleToJson(hResult).
        oItems = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /* Handler for unsupported HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /login":u).
        RETURN 0.
    END METHOD.

    /* Handler for unimplemented HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /login":u).
        RETURN 0.
    END METHOD.

END CLASS.
