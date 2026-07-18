"""Standard error envelope (API contract §Error Envelope):

    { "error": { "code", "message", "field_errors"?, "request_id" } }

Raw exception detail goes to Sentry only (threat model I-5); clients never see internals.
"""

from __future__ import annotations

import uuid
from typing import Any

from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler


def veridian_exception_handler(exc: Exception, context: dict[str, Any]) -> Response | None:
    response = drf_exception_handler(exc, context)
    request_id = str(uuid.uuid4())

    if response is None:
        # Unhandled: return a generic envelope, never a stack trace.
        return Response(
            {
                "error": {
                    "code": "INTERNAL_ERROR",
                    "message": "An unexpected error occurred.",
                    "request_id": request_id,
                }
            },
            status=500,
        )

    detail = response.data
    code = getattr(exc, "default_code", "error")
    envelope: dict[str, Any] = {
        "error": {
            "code": str(code).upper(),
            "message": _message_from_detail(detail),
            "request_id": request_id,
        }
    }
    if isinstance(detail, dict) and response.status_code == 400:
        envelope["error"]["field_errors"] = detail

    response.data = envelope
    return response


def _message_from_detail(detail: Any) -> str:
    if isinstance(detail, dict):
        return "Request validation failed."
    if isinstance(detail, list) and detail:
        return str(detail[0])
    return str(detail)
