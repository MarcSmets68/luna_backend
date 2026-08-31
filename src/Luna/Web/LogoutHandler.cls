/*------------------------------------------------------------------------
    File        : LogoutHandler.cls
    Purpose     : Thin WebHandler for the Auth-MVP logout feature. Reads
                  the X-Auth-Token header, calls
                  Luna.BusinessLogic.AuthBE:Logout(), and formats the
                  response/error envelope. Never touches
                  authenticationToken directly.
    Syntax      : POST /web/logout  (X-Auth-Token header required - see
                  GetBearerToken() below for why this is a custom header
                  and not the standard Authorization header the original
                  ontwerp specified).
    Description : See docs/architecture/login-auth-ontwerp.md paragraaf
                  1.3/1.4.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Net.HTTP.HttpHeader.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.AuthBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LogoutHandler INHERITS WebHandler:

    /* Extracts the session token from the X-Auth-Token header.
       DEVIATION FROM ORIGINAL ONTWERP (paragraaf 1.4): the ontwerp
       originally specified a standard "Authorization: Bearer TOKEN"
       header. Confirmed via a live test against the running PASOE
       MarcTest instance (temporary debug probe, since removed) that
       poRequest:HasHeader("Authorization") always returns FALSE / the
       header never reaches this WebHandler layer at all, while an
       arbitrary custom header (e.g. X-Auth-Token, X-Foo) DOES arrive
       intact - PASOE/Tomcat intercepts/reserves the standard
       "Authorization" header for its own container-level auth handling
       before the request reaches OpenEdge.Web.WebHandler code, with no
       app-level opt-out found in this MarcTest configuration. Switched to
       a custom "X-Auth-Token: TOKEN":u header (no "Bearer " prefix, just
       the raw token) to avoid that interception. See
       docs/architecture/login-auth-ontwerp.md paragraaf 1.4 for the
       updated contract - this comment plus that doc update are the
       required "fix the design doc too" step for this deviation.
       Returns "":u if the header is absent/blank - AuthBE treats an
       empty token the same as a missing/unknown one (401). */
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

    /* Writes a JSON response with the given status code. */
    METHOD PRIVATE VOID WriteJsonResponse( INPUT piStatusCode AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE oResponse AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter               NO-UNDO.
        DEFINE VARIABLE oHeader   AS OpenEdge.Net.HTTP.HttpHeader    NO-UNDO.

        ASSIGN
            oResponse             = NEW OpenEdge.Web.WebResponse()
            oResponse:StatusCode  = piStatusCode
            oResponse:Entity      = poBody
            oResponse:ContentType = "application/json":u
            .

        /* CORS headers - allow frontend (localhost:3000) to call this endpoint
           with the X-Auth-Token header. */
        oHeader = NEW OpenEdge.Net.HTTP.HttpHeader("Access-Control-Allow-Origin":u, "http://localhost:3000":u).
        oResponse:SetHeader(oHeader).

        oHeader = NEW OpenEdge.Net.HTTP.HttpHeader("Access-Control-Allow-Methods":u, "POST, OPTIONS":u).
        oResponse:SetHeader(oHeader).

        oHeader = NEW OpenEdge.Net.HTTP.HttpHeader("Access-Control-Allow-Headers":u, "Content-Type, X-Auth-Token":u).
        oResponse:SetHeader(oHeader).

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

    /* Maps an AppError raised by AuthBE (401 only, per ontwerp paragraaf
       1.3/1.7) to an HTTP status code, defaulting unrecognized codes to
       500 so no ABL stack trace ever leaks to the client. */
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "401":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /* OPTIONS /logout - CORS preflight request handler.
       Returns CORS headers to allow the frontend to send POST requests
       with the X-Auth-Token header. */
    METHOD OVERRIDE PROTECTED INTEGER HandleOptions( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oBody AS JsonObject NO-UNDO.

        oBody = NEW JsonObject().
        oBody:Add("message":u, "CORS preflight OK":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

    END METHOD.

    /* POST /logout - X-Auth-Token header, no body.
       AuthBE:Logout() both validates (existence + expiry) and deletes
       the authenticationToken record - see ontwerp paragraaf 1.3. */
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS AuthBE     NO-UNDO.
        DEFINE VARIABLE cToken   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.

        cToken = GetAuthToken(poRequest).

        oService = NEW AuthBE().
        oService:Logout(cToken).

        oBody = NEW JsonObject().
        oBody:Add("message":u, "Uitgelogd":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /* Handler for unsupported HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /logout":u).
        RETURN 0.
    END METHOD.

    /* Handler for unimplemented HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /logout":u).
        RETURN 0.
    END METHOD.

END CLASS.
